# Broker Protection — Race-Safe Inbound Email-to-Lead Pipeline

**Date:** 2026-07-24
**Author:** Documentation Agent
**Status:** Code-reviewed, APPROVED — deploy-ready (see Code Review section). Not yet deployed to any org as of this writing; post-deploy manual steps below are REQUIRED before the pipeline is usable.

---

## 📋 Overview

### Original Request

> Multiple brokers independently email the same property to different internal DPEG people, who
> forward those emails into a Salesforce Email Service. Build a race-safe "broker protection" layer
> over the inbound email→Lead pipeline: the first broker to submit a property wins; later submissions
> for the same property are marked duplicate/dead and logged for tracking only — **never** overwriting
> the winning Lead's data. The full submission history (winner + every competing broker) must be
> visible on the winning Lead's record page. The pipeline uses an LLM (OpenAI, text or image/vision)
> to extract the broker's name/email, the property address, and the original send time from the
> forwarded email body, with a regex fallback. Race-safety must hold even when two emails for the same
> property arrive within moments of each other.

### Business Objective

DPEG's deal flow starts when brokers email properties to whichever internal contact they know. The
same property routinely gets forwarded into the pipeline by more than one broker (sometimes the same
broker, sometimes competitors), and — because the forwards land at different times, from different
internal people — nothing previously stopped each one from becoming its own, uncoordinated Lead.
Broker Protection turns that into a deterministic "first submission wins" model: exactly one Lead per
property carries the live opportunity, every later submission is preserved as an auditable duplicate
(who else submitted it, when, and via whom), and reviewers get a single place — a component on the
winning Lead — to see that whole history instead of reconstructing it from separate Lead records.

### Summary

An inbound Email Service handler creates a Lead synchronously from the raw envelope, then enqueues an
async Queueable that calls OpenAI (vision-capable, text or image) to extract the broker's name/email,
the property address, and the original "Sent:" time, with a regex fallback on the first `From:` line
when the LLM misses a field. The Queueable normalizes the address and runs a claim against a
backend-only ledger (`Property_Registry__c`): the first normalized/near-duplicate address to claim a
property wins (stays a live, usable Lead); every subsequent claim for that property is marked
`Is_Duplicate_Property__c` and pointed at the winner via `Duplicate_Of_Lead__c`, never touching the
winner's data. Every submission — winning or not — is also logged to an append-only audit object,
`Competing_Broker_Submission__c`, which a new LWC (`competingBrokerSubmissions`) renders as a timeline
on the winning Lead's record page. Concurrent same-property submissions are serialized behind a
pessimistic row lock (`Property_Claim_Lock__c`) so two near-simultaneous claims cannot both win.

This is a from-scratch build: 3 custom objects, 4 Lead fields, 10 production Apex classes + 1
`HttpCalloutMock` + 10 test classes, 1 LWC (+ Jest), 1 permission set, and 1 Named Credential +
External Credential for the direct OpenAI callout (a documented, temporary exception to the org's
ASB-only integration rule).

---

## 🏗️ Architecture / Flow

### Pipeline narrative

1. **Inbound email arrives** at a Salesforce Email Service routed to `EmailToLeadHandler`
   (`Messaging.InboundEmailHandler`).
2. **`EmailToLeadHandler`** (thin boundary) locates the first inline image attachment (if any),
   normalizes its MIME subtype to a valid `image/...` value, and immediately hands the whole envelope
   (from name/address, subject, plain-text/HTML body, optional image) to `EmailToLeadService`. It does
   no DML, no SOQL, no callouts itself.
3. **`EmailToLeadService.createLeadAndEnqueue`** builds and **synchronously inserts** a raw Lead
   (`LeadSource = 'Email-to-Lead'`, `Status = 'New'`, `Company` placeholder, name split from the
   sender's display name) — this is the only Lead insert in the pipeline, so the Lead exists even if
   everything downstream fails — then enqueues `ExtractAddressQueueable` with the job payload.
4. **`ExtractAddressQueueable.execute`** (async, `Database.AllowsCallouts`) orchestrates the rest of
   the pipeline in one transaction:
   a. Calls **`LLMExtractionCalloutService.extract`** — the single OpenAI HTTP callout in the codebase
      — which returns a fixed four-key map (`broker_name`, `broker_email`, `property_address`,
      `sent_datetime`); any field the model could not find comes back as `''`, never null/absent.
   b. Backfills any still-blank `broker_name` / `broker_email` from the raw first `From:` line via
      regex (never overwrites a good LLM answer).
   c. Calls back into **`EmailToLeadService.applyExtractedDetails`** — the only other Lead write in
      the pipeline — to stamp the resolved broker name/email, property address, and forwarder email
      onto the Lead (each field only when non-blank, so a partial extraction never blanks a value that
      was already correct).
   d. Normalizes the extracted address via **`PropertyMatchingService.normalizeAddress`** and, if
      blank, stops here — the record is left a normal, unclaimed Lead.
   e. Calls **`PropertyClaimService.claim`**, which is the race-safety engine (see below), to decide
      winner vs. duplicate and write `Property_Registry__c` / `Competing_Broker_Submission__c`
      accordingly.
   Any exception anywhere in this flow is caught, logged (`System.debug` only — see **Known
   Limitations**), and swallowed: a bad email never crashes the async job, it just skips
   enrichment/claiming and leaves a plain Lead.
5. **`PropertyClaimService.claim`** derives a coarse cluster key
   (`PropertyMatchingService.deriveClusterKey`), acquires a pessimistic `FOR UPDATE` lock on that
   cluster's `Property_Claim_Lock__c` row (serializing any concurrent claim for the same/near-same
   property), and only then — while holding the lock — calls
   **`PropertyMatchingService.findMatchingRegistry`** to decide:
   - **No existing winner** → `registerWinner`: insert a new `Property_Registry__c` row
     (`Property_Key__c` = the normalized address, unique) + a winning `Competing_Broker_Submission__c`.
   - **Existing winner found** (exact key match, or fuzzy Jaccard ≥ 0.6 within a 90-day lookback) →
     `markDuplicate`: flag the new Lead (`Is_Duplicate_Property__c = true`,
     `Duplicate_Of_Lead__c = <winner>`) and insert a non-winning `Competing_Broker_Submission__c`
     against the winner's Lead. The winning Lead itself is never written to.
6. **`competingBrokerSubmissions` LWC**, placed on the `Lead_Record_Page` FlexiPage, wires
   **`CompetingSubmissionController.getSubmissions`** (thin `@AuraEnabled(cacheable=true)` controller
   over `CompetingBrokerSubmissionSelector.selectByWinningLead`) to render every submission tied to the
   current (winning) Lead, oldest first, with a Winner/Competing badge.

### Sequence diagram

```
Broker email(s)             Salesforce Email Service          Async (Queueable)                    Ledger / Audit
──────────────              ─────────────────────────         ─────────────────                    ──────────────
Broker A forwards  ──►  EmailToLeadHandler
"123 Main St"              (parse image attachment,
                             delegate — no DML/SOQL)
                                   │
                                   ▼
                          EmailToLeadService
                          .createLeadAndEnqueue
                          → INSERT Lead A (raw)
                                   │
                                   ▼ System.enqueueJob
                          ExtractAddressQueueable(A)
                                   │
                    ┌──────────────┼───────────────────┐
                    ▼              ▼                    ▼
       LLMExtractionCalloutService  regex fallback   EmailToLeadService
       .extract (OpenAI callout)    (From: line)      .applyExtractedDetails
                    └──────────────┴───────────────────┘
                                   │
                                   ▼
                     PropertyMatchingService.normalizeAddress
                                   │
                                   ▼
                        PropertyClaimService.claim
                     (a) deriveClusterKey("123 main")
                     (b) FOR UPDATE lock Property_Claim_Lock__c["123 main"]  ◄── serializes
                     (c) findMatchingRegistry → none found
                     (d) registerWinner
                                   │                                    ┌─────────────────────────┐
                                   └───────────────────────────────────►│ Property_Registry__c     │
                                                                         │  PR-0000001              │
                                                                         │  Property_Key__c=        │
                                                                         │   "123 main st"           │
                                                                         │  Winning_Lead__c = Lead A │
                                                                         ├─────────────────────────┤
                                                                         │ Competing_Broker_        │
                                                                         │ Submission__c CBS-0000001│
                                                                         │  Winning_Lead__c=Lead A   │
                                                                         │  Source_Lead__c=Lead A    │
                                                                         │  Is_Winning_Submission__c│
                                                                         │   = true                  │
                                                                         └─────────────────────────┘

Broker B forwards  ──►  EmailToLeadHandler ──► EmailToLeadService ──► INSERT Lead B (raw)
"123 Main Street"                                                          │
  (moments later)                                                          ▼ enqueueJob
                                                              ExtractAddressQueueable(B)
                                                                            │
                                                          (same extract/regex/apply steps)
                                                                            │
                                                                            ▼
                                                              PropertyClaimService.claim
                                                          (a) deriveClusterKey("123 main")  ← SAME
                                                              cluster key as Lead A (coarse bucket)
                                                          (b) FOR UPDATE lock — BLOCKS until Lead A's
                                                              transaction commits
                                                          (c) findMatchingRegistry → fuzzy match on
                                                              "123 main st" (Jaccard ≥ 0.6) → WINNER
                                                              = Lead A found
                                                          (d) markDuplicate
                                                                            │
                                                    ┌───────────────────────┴─────────────────────┐
                                                    ▼                                               ▼
                                     UPDATE Lead B                                   INSERT Competing_Broker_
                                     Is_Duplicate_Property__c = true                 Submission__c CBS-0000002
                                     Duplicate_Of_Lead__c = Lead A                    Winning_Lead__c = Lead A
                                     (Lead A is NEVER written to)                     Source_Lead__c = Lead B
                                                                                       Is_Winning_Submission__c
                                                                                        = false

                                                                            ┌─────────────────────────────┐
                                                                            │ competingBrokerSubmissions   │
                                                                            │ LWC on Lead A's record page   │
                                                                            │ (via CompetingSubmission-     │
                                                                            │ Controller.getSubmissions)     │
                                                                            │  Winner:    Lead A / Broker A │
                                                                            │  Competing: Lead B / Broker B │
                                                                            └─────────────────────────────┘
```

---

## 🧱 Components

### Custom Objects (3)

| Object API Name | Label | Sharing Model | Description |
|---|---|---|---|
| `Property_Registry__c` | Property Registry | ReadWrite | Backend-only claim ledger. One row per distinct property. The unique, case-insensitive `Property_Key__c` enforces race-safe first-come-first-served registration at the database level. |
| `Competing_Broker_Submission__c` | Competing Broker Submission | ReadWrite | Append-only audit trail of every inbound broker email that matched a property, including the winning submission itself. Deliberately **not** master-detail on `Winning_Lead__c` — cascade delete would silently wipe this trail if a winning Lead were ever deleted. |
| `Property_Claim_Lock__c` | Property Claim Lock | ReadWrite | Concurrency-control lock partition, not a business object. One row per coarse address cluster; a `FOR UPDATE` lock on the row serializes concurrent broker-submission claims for the same property so the fuzzy match-then-insert is atomic. |

### Custom Fields

| Object | Field API Name | Type | Notes |
|---|---|---|---|
| `Lead` | `Email_Subject__c` | Text(255) | Subject line of the inbound broker email that created this Lead. |
| `Lead` | `Forwarded_By_Email__c` | Email | The internal forwarder's email address (not the broker's), from the inbound envelope. Named `_Email` (not `_By__c`) so it is not mistaken for a §1 role-lookup. |
| `Lead` | `Is_Duplicate_Property__c` | Checkbox, default `false` | Set by `ExtractAddressQueueable`/`PropertyClaimService` when this Lead's property was already claimed by an earlier submission. Kept for traceability only — this is a "dead" Lead. |
| `Lead` | `Duplicate_Of_Lead__c` | Lookup → Lead, `deleteConstraint=SetNull` | Points a duplicate Lead at its winner. Populated only when `Is_Duplicate_Property__c = true`. Lookup-to-Lead cannot use Restrict/Cascade, hence `SetNull` + the insert-scoped validation rule below standing in for "required." |
| `Property_Registry__c` | `Property_Key__c` | Text(255), **unique, case-insensitive, `externalId=true`, required** | The atomic claim key — normalized property address. This uniqueness constraint is the database-level race-safety backstop for exact-match collisions. |
| `Property_Registry__c` | `Normalized_Address__c` | Text(255) | The same normalized address, stored for fuzzy-match comparison (`PropertyMatchingService.calculateSimilarity`). |
| `Property_Registry__c` | `Winning_Lead__c` | Lookup → Lead, `SetNull` | The Lead that currently holds this claim. Null when the winner was deleted (an "orphaned" registration — see Race-Safety Design). |
| `Property_Registry__c` | `Registered_DateTime__c` | DateTime | When the claim was registered (claim time, not the email's send time). §1 rule 6/9 conformant — never suffixed `_Date`. |
| `Competing_Broker_Submission__c` | `Winning_Lead__c` | Lookup → Lead, `SetNull` | The Lead that holds the claim this submission was logged against. |
| `Competing_Broker_Submission__c` | `Source_Lead__c` | Lookup → Lead, `SetNull` | The Lead this specific inbound email produced (equals `Winning_Lead__c` for the winning submission). |
| `Competing_Broker_Submission__c` | `Broker_Name__c` | Text(255) | LLM/regex-extracted broker display name. |
| `Competing_Broker_Submission__c` | `Broker_Email__c` | Email | LLM/regex-extracted broker email. |
| `Competing_Broker_Submission__c` | `Email_Subject__c` | Text(255) | The inbound email subject. |
| `Competing_Broker_Submission__c` | `Forwarded_By_Email__c` | Email | The internal forwarder's email (same naming rationale as the Lead field). |
| `Competing_Broker_Submission__c` | `Property_Address_Raw__c` | Text(255) | The raw (un-normalized) extracted address, for display. |
| `Competing_Broker_Submission__c` | `Submitted_DateTime__c` | DateTime | The email's original send time (LLM `sent_datetime`, parsed; defaults to `now()` if unparseable). §1 rule 6/9 conformant. |
| `Competing_Broker_Submission__c` | `Is_Winning_Submission__c` | Checkbox, default `false` | `true` for exactly the one submission that registered the winning claim. |
| `Property_Claim_Lock__c` | `Cluster_Key__c` | Text(255), unique, `externalId=true`, required | Coarse address-cluster bucket key (street number + first alphabetic street-name token) — the `FOR UPDATE` lock partition. See Race-Safety Design. |

### Validation Rules

| Object | Rule Name | Formula | Purpose |
|---|---|---|---|
| `Property_Registry__c` | `Winning_Lead_Required` | `AND(ISNEW(), ISBLANK(Winning_Lead__c))` | Insert-scoped stand-in for "required" on a lookup that must be `SetNull` (Restrict/Cascade to Lead is rejected by the platform). Scoped to `ISNEW()` so a later Lead deletion (which nulls the lookup via `SetNull`) does not retroactively block. |
| `Competing_Broker_Submission__c` | `Winning_Lead_Required` | Same formula/rationale as above | Same pattern, applied to `Competing_Broker_Submission__c.Winning_Lead__c`. |

### Apex Classes (production, by layer)

| Class | Layer | Responsibility |
|---|---|---|
| `EmailToLeadHandler` | Inbound handler (`Messaging.InboundEmailHandler`) | Thin boundary. Attachment MIME parsing only; delegates all Lead creation to `EmailToLeadService`. `global` (interface-mandated), `with sharing` (functionally a no-op — no data access here). |
| `EmailToLeadService` | Service (Lead write side) | The only class that inserts/updates a Lead in this pipeline. `createLeadAndEnqueue` (raw insert + enqueue) and `applyExtractedDetails` (the post-extraction Lead-detail write). Plain DML (no `USER_MODE`) — automated/system context, no running user's FLS to enforce, matching the repo's existing service pattern. |
| `LLMExtractionCalloutService` | Service (callout wrapper) | The single OpenAI HTTP callout in the codebase (mockable via `HttpCalloutMock`). Builds the vision/text chat-completions request, parses the four-key JSON response. Carries the written §3-exception justification (see Integration Note below). |
| `ExtractAddressQueueable` | Queueable (`Database.AllowsCallouts`) | Async orchestrator: callout → regex fallback → apply details → normalize → claim. No inline SOQL/DML — every read/write is delegated. `@TestVisible forceClaimRace` seam forces the race-recovery path under test. |
| `PropertyMatchingService` | Service (read side, pure + selector-backed) | `normalizeAddress`, `calculateSimilarity` (Jaccard), `deriveClusterKey`, `findMatchingRegistry` (exact + fuzzy), `findOrphanedRegistry`. Never writes; never queries directly (delegates to `PropertyRegistrySelector`). |
| `PropertyClaimService` | Service (write side) | Owns all claim/duplicate DML: `claim` (acquire cluster lock → decide winner/duplicate), `registerWinner`, `markDuplicate`, the lock get-or-create/acquire helpers. No SOQL of its own — reads route through `PropertyMatchingService`/selectors. |
| `PropertyRegistrySelector` | Selector | All SOQL against `Property_Registry__c`, `WITH USER_MODE`. `selectByPropertyKeyWithWinner`, `selectRecentWithWinner`, `selectOrphanByPropertyKey`. |
| `PropertyClaimLockSelector` | Selector | All SOQL against `Property_Claim_Lock__c`, `WITH USER_MODE`. `selectByClusterKey` (plain existence read) and `selectByClusterKeyForUpdate` (the `FOR UPDATE` lock-acquisition read). |
| `CompetingBrokerSubmissionSelector` | Selector | All SOQL against `Competing_Broker_Submission__c`, `WITH USER_MODE`. `selectByWinningLead` (oldest-first timeline read). |
| `CompetingSubmissionController` | Controller (`@AuraEnabled(cacheable=true)`) | Thin. `getSubmissions(leadId)` delegates to `CompetingBrokerSubmissionSelector`; every failure → `AuraHandledException` via a private `ahe()` helper (matches `BrokerPortalController`'s pattern). |
| `LLMExtractionCalloutMock` | Test support (`HttpCalloutMock`) | Mocks the OpenAI endpoint for all Apex tests that exercise the extraction/queueable path. |

### Test Classes (10)

| Test Class | Tests For |
|---|---|
| `EmailToLeadHandlerTest` | `EmailToLeadHandler` — image-MIME normalization (bare/qualified subtypes), delegation. |
| `EmailToLeadServiceTest` | `EmailToLeadService` — Lead creation/enqueue, `applyExtractedDetails` partial-fill behavior, `applyName` whitespace-safety (trailing/double space, 3+ tokens). |
| `LLMExtractionCalloutServiceTest` | `LLMExtractionCalloutService` — request shaping (text-only and image+text), response parsing, code-fence stripping, non-200 handling. |
| `ExtractAddressQueueableTest` | `ExtractAddressQueueable` — end-to-end orchestration, regex fallback, `forceClaimRace` seam. |
| `PropertyMatchingServiceTest` | `PropertyMatchingService` — `normalizeAddress`, `calculateSimilarity`, `deriveClusterKey` (including the ordinal-street-name residual case), `findMatchingRegistry`/`findOrphanedRegistry`. |
| `PropertyClaimServiceTest` | `PropertyClaimService` — winner registration, duplicate marking, orphan adoption, cluster-lock acquire/retry/fail-safe paths. |
| `PropertyRegistrySelectorTest` | `PropertyRegistrySelector` — all three selector methods, empty/not-found contracts. |
| `PropertyClaimLockSelectorTest` | `PropertyClaimLockSelector` — plain vs. `FOR UPDATE` reads. |
| `CompetingBrokerSubmissionSelectorTest` | `CompetingBrokerSubmissionSelector` — ordering, empty-list contract. |
| `CompetingSubmissionControllerTest` | `CompetingSubmissionController` — happy path + `AuraHandledException` wrapping. |

`TestDataFactory` was extended (not forked) with `createPropertyRegistry(String, Id, Boolean)` and
`createPropertyClaimLock(String, Boolean)` helpers for this feature, per the org-wide factory
convention.

### Lightning Web Component

| Component | Location | Description |
|---|---|---|
| `competingBrokerSubmissions` | `force-app/main/default/lwc/competingBrokerSubmissions/` | Placed on `Lead_Record_Page`. Single reactive `@wire(getSubmissions, { leadId: '$recordId' })` against `CompetingSubmissionController`; renders a native related-list-style table (winner vs. competing badge, broker/forwarder/address/submitted-time columns), error toast + inline banner on wire failure, empty state when there are no submissions. SLDS 2 tokens only; Jest + `@sa11y/jest` accessibility test included. |

### Integration Credentials

| Credential | Type | Purpose |
|---|---|---|
| `OpenAI_Credential` | External Credential (Custom protocol) | Holds the OpenAI API key as a `NamedPrincipal` authentication parameter (`OpenAI_Principal`), referenced by an `Authorization: Bearer {!$Credential.OpenAI_Credential.API_Key}` `AuthHeader`. The key value itself is entered in Setup **post-deploy** — never in metadata. |
| `OpenAI_API` | Named Credential (`SecuredEndpoint` → `https://api.openai.com`) | `allowMergeFieldsInHeader=true` (required — otherwise the `{!$Credential...}` header is sent literally and OpenAI returns 401). Points at the `OpenAI_Credential` External Credential for authentication. |

### Permission Set

| Permission Set | Description |
|---|---|
| `Broker_Protection_Access` | Object CRUD + `viewAllRecords` on `Property_Registry__c`, `Competing_Broker_Submission__c`, `Property_Claim_Lock__c`; FLS (read/edit) on every new field, including the 4 Lead fields; external-credential principal access for `OpenAI_Credential`. **Must be assigned to the Email Service/Automated Process user and to any rep who needs to view the submission history — see Required Post-Deploy Steps.** |

---

## 🔐 Race-Safety Design

Two independent mechanisms combine to make "first submission wins" hold even under concurrent
inbound emails:

1. **Exact-match safety net — the unique `Property_Key__c` index.** `Property_Registry__c.Property_Key__c`
   is a unique, case-insensitive external ID. Two byte-identical normalized addresses inserted
   concurrently cannot both succeed — the database itself rejects the second insert with a
   `DUPLICATE_VALUE` `DmlException`, which `PropertyClaimService.registerWinner` catches and
   reconciles (re-checks for a live winner, then falls back to adopting an orphaned row — see below).

2. **Fuzzy-match safety net — the `Property_Claim_Lock__c` pessimistic lock.** The unique index alone
   does **not** protect two *differently-worded-but-similar* addresses (e.g. `"123 Main Street"` vs.
   `"123 Main St"`) from both winning, because each could pass a fuzzy `findMatchingRegistry` check
   against rows that predate the other and then insert **distinct** `Property_Key__c` rows. To close
   this, `PropertyClaimService.claim` derives a coarse **cluster key**
   (`PropertyMatchingService.deriveClusterKey` = street number + first alphabetic street-name token,
   e.g. `"123 main street"` → `"123 main"`) and acquires a pessimistic `FOR UPDATE` row lock on that
   cluster's `Property_Claim_Lock__c` row **before** running `findMatchingRegistry`. A second,
   concurrent claim for the same (or fuzzy-equivalent) address is blocked until the first transaction
   commits, so it reliably sees the first's committed registry and is correctly routed to
   `markDuplicate` — no dual winners. The fuzzy match itself (Jaccard similarity ≥ **0.6**, within a
   **90-day** lookback window) remains the arbiter of *whether* two addresses are the same property;
   the lock only ensures that decision is made serially, not concurrently.

   Get-or-create-then-lock is structurally sound: `acquireClusterLock` returns `true` only when a row
   was actually `FOR UPDATE`-locked, lock rows are never deleted, and a lock-wait timeout (~10s, one
   retry) fails safe — the claim is abandoned and the record is left a normal, unclaimed Lead rather
   than proceeding unserialized.

3. **Orphan adoption.** Because `Winning_Lead__c` is `SetNull` (a lookup to Lead cannot be
   Restrict/Cascade), deleting a winning Lead leaves its `Property_Registry__c` row with a null
   winner — the unique key is still occupied but unclaimed. `findMatchingRegistry` filters these rows
   out (so the property reads as unclaimed), and `registerWinner`'s duplicate-key catch block adopts
   such an orphan (repoints it at the new claimant) rather than leaving the key permanently
   unclaimable.

### Documented residual (accepted, not a defect)

The cluster lock only serializes claims that derive the **same** cluster key. `deriveClusterKey` picks
the first *alphabetic* street-name token, so an ordinal street name is skipped: `"123 5th street"` →
`"123 street"` but `"123 5th st"` → `"123 st"` — two fuzzy-similar addresses that derive **different**
cluster keys and therefore would **not** serialize against each other. This is a bounded, honestly
disclosed edge case (the common case, e.g. `"123 Main St"` vs. `"123 Main Street"`, is unaffected and
covered by tests) — see Known Limitations for the recommended follow-up.

---

## ⚠️ Known Limitations / Deferred (per code review)

| # | Item | Status |
|---|---|---|
| W2 | **Async/lock-wait failures are logged via `System.debug` only** (`ExtractAddressQueueable`'s catch-all, and `PropertyClaimService`'s two fail-safe swallow points — lock-wait timeout, and "duplicate key but no live winner and no orphan"). `System.debug` is ephemeral and off by default in production — a silently dropped claim on a commission-protection feature is currently invisible. **Recommended before real broker traffic**: a durable signal — an `Enrichment_Failed__c` flag, a Platform Event, an error-log SObject, or a `System.Finalizer` on the Queueable. |
| — | **Cross-cluster fuzzy residual** (see above) — two addresses that are fuzzy-similar but derive different cluster keys will not serialize. Optional future refinement: include the ordinal token in `deriveClusterKey`, or lock on the street number alone. Left for post-POC per code review. |
| — | **`Property_Claim_Lock__c` rows are never purged** (`allowDelete=false`, no TTL). Growth is bounded by *distinct-property* count (idempotent get-or-create reuse), not claim volume — negligible for a demo; note for a future housekeeping job if lock cardinality ever becomes material. |
| — | **`LLMExtractionCalloutService.MODEL = 'gpt-4o-mini'` is hardcoded.** Suggested (not required) follow-up: move to Custom Metadata so the model can be tuned without a deploy. |

---

## 🚀 Required Post-Deploy Manual Steps (per-org — NOT carried by the metadata bundle)

These four steps are **required**, not optional, before the pipeline can process real email. None of
them travel with the metadata deploy.

1. **Set the OpenAI API key.** In Setup → Named Credentials/External Credentials → `OpenAI_Credential`
   → the `OpenAI_Principal` NamedPrincipal → enter the live OpenAI API key. The key is never stored in
   metadata or source control.
2. **Assign `Broker_Protection_Access` to the Email Service (Automated Process) user, and to any rep
   who needs to view the submission history.** ⚠️ **This is a verified deploy gate, not a nicety.**
   The backend claim engine's selector reads run `WITH USER_MODE` under the Email Service user; if the
   permission set is not assigned, those reads **throw**, and `ExtractAddressQueueable`'s catch-all
   swallows the exception — the entire ledger silently no-ops (Leads are still created, but nothing
   is ever claimed or logged) with no visible error anywhere. Acceptance-test as a **non-admin**
   persona — admin testers won't see this failure mode because `System Administrator` bypasses FLS.
3. **Provision the inbound Email Service + routing address** in Setup → Email Services, pointed at
   `EmailToLeadHandler`. This is org configuration, not portable metadata.
4. **Acceptance-test end-to-end as a non-admin persona** — forward two emails for the same property
   (exact and near-duplicate wording) through the live routing address and confirm: the first Lead is
   the winner, the second is flagged `Is_Duplicate_Property__c` and points at the winner via
   `Duplicate_Of_Lead__c`, and both submissions appear on the winning Lead's `competingBrokerSubmissions`
   panel.

---

## 📁 File Locations

| Component Type | Path |
|---|---|
| Custom Objects | `force-app/main/default/objects/Property_Registry__c/`, `force-app/main/default/objects/Competing_Broker_Submission__c/`, `force-app/main/default/objects/Property_Claim_Lock__c/` |
| Lead fields | `force-app/main/default/objects/Lead/fields/{Email_Subject__c,Forwarded_By_Email__c,Is_Duplicate_Property__c,Duplicate_Of_Lead__c}.field-meta.xml` |
| Apex Classes | `force-app/main/default/classes/{EmailToLeadHandler,EmailToLeadService,LLMExtractionCalloutService,LLMExtractionCalloutMock,ExtractAddressQueueable,PropertyMatchingService,PropertyClaimService,PropertyRegistrySelector,PropertyClaimLockSelector,CompetingBrokerSubmissionSelector,CompetingSubmissionController}.cls` |
| Test Classes | `force-app/main/default/classes/*Test.cls` (10 classes, see table above) |
| LWC | `force-app/main/default/lwc/competingBrokerSubmissions/` |
| FlexiPage edit | `force-app/main/default/flexipages/Lead_Record_Page.flexipage-meta.xml` (added `competingBrokerSubmissions` to the `main` region) |
| Permission Set | `force-app/main/default/permissionsets/Broker_Protection_Access.permissionset-meta.xml` |
| Named Credential | `force-app/main/default/namedCredentials/OpenAI_API.namedCredential-meta.xml` |
| External Credential | `force-app/main/default/externalCredentials/OpenAI_Credential.externalCredential-meta.xml` |

---

## 🧪 Testing

### Code Review Verdict

**APPROVED — deploy-ready** (`agent-output/broker-protection-code-review.md`). Initial pass: 0 Critical,
4 Warnings, 3 Suggestions. A fix delta then resolved 3 of the 4 warnings:

| Warning | Resolution |
|---|---|
| W1 — malformed `data:` URL for bare-subtype image attachments | ✅ Fixed — `EmailToLeadHandler` normalizes bare `png`/`jpeg` subtypes to `image/png`/`image/jpeg` before building the data URL. |
| W2 — async failures swallowed with no durable signal | **Still open** — deferred, recommended before real broker traffic (see Known Limitations). |
| W3 — unsafe name-splitting in `applyName` | ✅ Fixed — `trim()` + split on `\s+` + guarded token count; handles trailing/double space and 3+-token names without index-out-of-bounds or dropped tail. |
| W4 — fuzzy dual-winner race | ✅ Fixed — the `Property_Claim_Lock__c` pessimistic-lock serialization described above; independently re-verified structurally sound (no code path proceeds "as if locked" without holding the lock; failure modes fail safe, never dual-proceed). |

### Notable test coverage

- `PropertyClaimServiceTest` exercises: idempotent lock-row get-or-create, fail-safe blank-address
  abort, the in-lock fuzzy-duplicate recheck (Jaccard exactly at the 0.6 threshold), and repeated calls
  for the same cluster creating only one lock row.
- `EmailToLeadHandlerTest` asserts all three image-MIME shapes: bare `png`, bare `jpeg`, and an
  already-qualified `image/png` (proving no double-prefixing).
- `EmailToLeadServiceTest` asserts `applyName` against `'Jane '`, `'Jane  Broker'`, and
  `'Mary Jane Watson'` through both entry points (`createLeadAndEnqueue` and `applyExtractedDetails`).
- Two branches are documented as legitimately unreachable in single-threaded Apex tests: a real `FOR
  UPDATE` lock-wait timeout, and `registerWinner`'s live-winner re-check under serialization (a live
  winner is always caught pre-insert once serialized) — accepted by the reviewer.

### Bulk-Test-Rule Applicability

Per the code review's ruling (accepted, not overridden): this pipeline is **single-record-per-transaction
by design** — one inbound email produces exactly one Lead and one Queueable execution, with no trigger
and no loops over multiple records. The `.claude/rules/bulk-test-rule.md` 251-record mandate does not
apply here; a 251-record same-transaction test would itself exceed the 150-DML governor limit and would
not exercise any real code path. See the ARCHITECTURE.md §2 update below for the standing carve-out this
established.

---

## 🔒 Security

- All Selectors (`PropertyRegistrySelector`, `PropertyClaimLockSelector`,
  `CompetingBrokerSubmissionSelector`) use `WITH USER_MODE`, per ARCHITECTURE.md §2.
- All Service/Queueable/Handler classes are `with sharing`. Lead/registry/submission DML is plain
  `insert`/`update` (not `AccessLevel.USER_MODE`) because the pipeline runs under the automated Email
  Service user, which has no meaningful running-user FLS to enforce for its own writes — this
  read-USER_MODE/write-system-mode split is the established repo house style (verified against
  `LeadConvertService`, `ContractExecutionService`) and was explicitly accepted by code review.
- `CompetingSubmissionController` is a thin, `cacheable=true` `@AuraEnabled` controller; all failures
  surface as `AuraHandledException` via a private `ahe()` helper (repo-standard pattern).
- **The perm-set assignment (`Broker_Protection_Access` → Email Service user) is a verified deploy
  gate, not a nicety** — see Required Post-Deploy Steps #2. A missing assignment makes the backend
  `USER_MODE` reads throw, and the throw is currently swallowed, so the entire ledger silently no-ops.
- The OpenAI API key is never hardcoded or stored in metadata — it lives only in the `OpenAI_Credential`
  External Credential's `NamedPrincipal`, entered in Setup post-deploy.

---

## 📝 Notes & Considerations

### Deliberate ASB-only exception

`LLMExtractionCalloutService` calls OpenAI **directly** via the `OpenAI_API` Named Credential, bypassing
the org's hub-and-spoke ASB integration model (ARCHITECTURE.md §3). This is intentional and temporary —
no ASB LLM-extraction spoke exists yet, so there is nothing to route through. The exception is scoped
and reversible: when ASB exposes an LLM-extraction endpoint, only the `ENDPOINT` constant (and the
Named Credential it targets) need to change — the public `extract(...)` signature and every downstream
caller are unaffected. Full justification is in the class header of `LLMExtractionCalloutService.cls`.
See the ARCHITECTURE.md §3 update below.

### Why single-record signatures, not `List<...>`, in the claim engine

`PropertyMatchingService` and `PropertyClaimService` expose single-record methods
(`claim(Id, String, ...)`, not `claim(List<ClaimRequest>)`), which at first glance looks like it
conflicts with the org's bulk-safety conventions. Code review explicitly accepted this: one inbound
email produces exactly one Queueable execution and exactly one claim — there is no trigger, no loop,
and no batch entry point in this pipeline, so a collection signature would add ceremony without
changing behavior or safety. See the ARCHITECTURE.md §2 update for the standing carve-out this
establishes for per-transaction-singleton async pipelines.

### Dependencies

- `TestDataFactory` (org-wide test factory) — extended with two new helpers for this feature.
- The existing `Lead_Record_Page` FlexiPage (edited, not created) to host the new LWC.
- `Lead.Property_Address__c` (pre-existing field) — reused as the target of the LLM-extracted address;
  not recreated.

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-07-24 | Documentation Agent | Initial creation — documents the Broker Protection feature (race-safe inbound email-to-Lead pipeline) end to end; companion ARCHITECTURE.md §1/§2/§3 updates landed in the same PR. |
