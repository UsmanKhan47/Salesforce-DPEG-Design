# Broker Protection — Architecture

**Date:** 2026-07-28
**Author:** Documentation Agent
**Companion:** `docs/broker-protection-overview.md`, `docs/broker-protection-data-dictionary.md`

---

## Data Model

### Custom Objects

| Object | Purpose | Sharing Model |
|---|---|---|
| `Inbound_Email_Staging__c` | **The durable landing record for every inbound broker email.** Written synchronously by `EmailToLeadHandler` before anything else happens — captures the raw body, all RFC headers, envelope addresses, and attachment metadata. The async router loads it back, and every terminal state (Processed / Error, outcome label, routed record Id) is stamped onto this row. It is the pipeline's audit trail *and* its restart point. | Private |
| `Property_Registry__c` | The race-safe claim ledger. One row per distinct property; the unique, case-insensitive `Property_Key__c` enforces first-come-first-served registration at the database level. | ReadWrite |
| `Competing_Broker_Submission__c` | Append-only audit trail of every inbound broker email that matched a property, including the winning submission itself. Deliberately **not** master-detail on `Winning_Lead__c` — cascade delete would silently wipe this trail. | ReadWrite |
| `Property_Claim_Lock__c` | Pure concurrency-control lock partition, not a business object. One row per coarse address cluster; a `FOR UPDATE` lock on the row serializes concurrent claims for the same (or fuzzy-equivalent) property so the match-then-insert is atomic. | ReadWrite |

### Lead Fields

| Field | Type | Purpose |
|---|---|---|
| `Email_Subject__c` | Text(255) | Subject line of the inbound broker email that created this Lead. |
| `Forwarded_By_Email__c` | Email | The internal forwarder's / monitored inbox's address — not the broker's. |
| `Is_Duplicate_Property__c` | Checkbox (default false) | Set when this Lead's property was already claimed by an earlier, different-broker submission. A "dead" Lead kept for traceability only. |
| `Duplicate_Of_Lead__c` | Lookup → Lead (`SetNull`) | Points a duplicate Lead at its winner; populated only when `Is_Duplicate_Property__c = true`. |

### Task (Activity) Fields — the RFC threading keys

| Field | Type | Purpose |
|---|---|---|
| `Inbound_Message_Id__c` | Text(255), External ID | This message's own RFC `Message-ID` — the idempotency key. If a Task already carries it, the platform is redelivering an already-processed message. |
| `Thread_Key__c` | Text(255), External ID | The conversation-root `Message-ID` (see `computeThreadKey` below) — shared by every message in a thread, including after a forward, so a later reply can be matched back to the record the original email was routed to. |

Every inbound broker email is logged as one completed `Task` (`TaskSubtype='Email'`), not an
`EmailMessage` — Enhanced Email / Einstein Activity Capture licensing is not present in this org, and a
Task renders in the standard Activity timeline on Lead/Contact/Opportunity with no such dependency.

Full field-level detail (lengths, descriptions, all 16 `Inbound_Email_Staging__c` fields) lives in
`docs/broker-protection-data-dictionary.md`.

---

## The Routing Tree (5 branches)

`ExtractAddressQueueable.route(...)` evaluates strictly in order; the first branch that matches wins.
The order is deliberate — each branch is a reason **not** to do what the branch below it would do:

| # | Branch | Trigger | Result |
|---|---|---|---|
| (a) | **Reply** | The email's `In-Reply-To` / `References` cite a thread this pipeline has already logged (matched via `Task.Thread_Key__c` / `Task.Inbound_Message_Id__c`). | Filed on that conversation's record (following a converted Lead through to its live Opportunity/Contact via `PropertyMatchingService.resolveLiveRecord`). **No Lead is created.** Must run first — a reply almost always still quotes the original broker and property, so every branch below it would otherwise happily create a duplicate. |
| (b) | **Repeat** | The same broker (matched by LLM-extracted email, then by envelope `From` as a fallback) has already submitted this same property within the 90-day lookback window. | An audit-only `Competing_Broker_Submission__c` is appended to their **existing** Lead via `PropertyClaimService.logRepeatSubmission`. **No new Lead**, and — critically — **not** flagged `Is_Duplicate_Property__c`, because a broker chasing their own submission is not a competing broker. |
| (c) | **No-Property** | No usable address could be extracted (including when the LLM callout itself failed — see *Degraded Extraction* below). | A Lead is created so nothing is lost, but **no claim is attempted** — claiming a blank property would poison the registry's unique key. |
| (d) | **Duplicate** | The property is already claimed by a **different** broker. | A Lead is created and immediately flagged (`Is_Duplicate_Property__c`, `Duplicate_Of_Lead__c`) against the winner, plus a non-winning `Competing_Broker_Submission__c` audit row. The winning Lead itself is **never** written to. |
| (e) | **Winner** | Nobody has claimed this property. | A Lead is created and takes the claim under the cluster lock (`PropertyClaimService.claim`). |

Every branch ends the same way: the email is logged as a `Task` carrying both RFC threading keys —
which is what makes branch (a) possible for the *next* email in the thread — and the staging row is
stamped with the outcome, the routed record, and a timestamp.

### Idempotency (two independent guards)

1. A staging row already marked `Processed` is never re-run (`ExtractAddressQueueable.execute`).
2. An RFC Message-ID already present on a `Task.Inbound_Message_Id__c` means the platform is
   redelivering a message already routed — the whole routing tree is skipped
   (`InboundEmailActivityService.isAlreadyLogged`). A **blank** Message-ID skips only this second
   guard and proceeds normally, because some forwarding paths strip the header and refusing those
   emails would be worse than occasionally reprocessing one.

### Degraded Extraction (LLM outage)

A `CalloutException` from the OpenAI boundary (429, 5xx, timeout) is treated as the absence of an
optional input, **not** a pipeline failure. It is caught at the callout site and the pipeline degrades
rather than aborts: extraction becomes an empty map, the regex fallback still recovers the broker's
name/email from the raw `From:` line, and routing proceeds normally. Because the regex fallback never
yields a property address, a degraded run can only ever reach branch (a) or branch (c) — a real Lead
is always created (or an existing thread correctly reused), never silently dropped because OpenAI was
rate-limiting. The staging row records the distinct outcome label
`New Lead (no property) — LLM unavailable` so outage-degraded Leads are distinguishable from genuinely
addressless emails and can be re-extracted by hand once the outage clears.

---

## Race-Safety Design

Two mechanisms combine so "first submission wins" holds even under concurrent inbound emails:

1. **Exact-match safety net — the unique `Property_Key__c` index.** Two byte-identical normalized
   addresses inserted concurrently cannot both succeed; the database rejects the second with a
   `DUPLICATE_VALUE` `DmlException`, which `PropertyClaimService.registerWinner` catches and
   reconciles (re-checks for a live winner, then falls back to adopting an orphaned row).
2. **Fuzzy-match safety net — the `Property_Claim_Lock__c` pessimistic lock.** The unique index alone
   does not protect two differently-worded-but-similar addresses (`"123 Main Street"` vs `"123 Main
   St"`) from both winning, because each could pass a fuzzy match against rows that predate the other
   and then insert **distinct** `Property_Key__c` rows. `PropertyClaimService.claim` closes this by
   deriving a coarse **cluster key** (`PropertyMatchingService.deriveClusterKey` = street number +
   first alphabetic street-name token, e.g. `"123 main street"` → `"123 main"`) and acquiring a
   pessimistic `FOR UPDATE` row lock on that cluster **before** running the authoritative
   `findMatchingRegistry` check. A second, concurrent claim for the same (or fuzzy-equivalent) address
   is blocked until the first transaction commits, so it reliably sees the first's committed registry
   and is correctly routed to `markDuplicate` — no dual winners.
3. **Orphan adoption.** Because `Winning_Lead__c` is `SetNull` (a lookup to Lead cannot be
   Restrict/Cascade), deleting a winning Lead leaves its registry row with a null winner — the unique
   key stays occupied but unclaimed. `findMatchingRegistry` filters these rows out, and
   `registerWinner`'s duplicate-key catch block adopts such an orphan rather than leaving the key
   permanently unclaimable.

**Documented residual (accepted, not a defect):** the cluster lock only serializes claims that derive
the *same* cluster key. `deriveClusterKey` picks the first *alphabetic* street-name token, so an
ordinal street name is skipped: `"123 5th street"` → `"123 street"` but `"123 5th st"` → `"123 st"` —
two fuzzy-similar addresses deriving *different* cluster keys therefore would not serialize against
each other. The common case (`"123 Main St"` vs `"123 Main Street"`) is unaffected and covered by
tests. See `docs/broker-protection-limitations.md`.

---

## Services

| Class | Layer | Responsibility |
|---|---|---|
| `EmailToLeadHandler` | Inbound handler (`Messaging.InboundEmailHandler`) | Boundary. Parses envelope, RFC headers, and the first inline image; resolves the monitored inbox (auto- vs. manual-forward); hands a fully-shaped payload to `InboundEmailStagingService` and enqueues `ExtractAddressQueueable`. **Creates no Lead.** No SOQL/DML of its own. |
| `InboundEmailStagingService` | Service (staging write side) | The *only* class that inserts/updates `Inbound_Email_Staging__c`. Fail-soft status writes (`markProcessed`/`markSkipped`/`markError` swallow their own `DmlException` — see class header rationale). |
| `InboundEmailStagingSelector` | Selector | All SOQL against `Inbound_Email_Staging__c`, `WITH USER_MODE`. Wide field set by design (the queueable consumes almost the whole record). |
| `ExtractAddressQueueable` | Queueable (`Database.AllowsCallouts`) | The async orchestrator — owns the routing tree. No inline SOQL/DML; every read/write is delegated. `@TestVisible forceClaimRace` seam forces the race-recovery path under test. |
| `LLMExtractionCalloutService` | Service (callout wrapper) | The single OpenAI HTTP callout in the codebase, mockable via `HttpCalloutMock`. Carries the written §3-exception justification (direct, non-ASB callout). |
| `EmailToLeadService` | Service (Lead write side) | The *only* class that inserts a Lead in this pipeline — `createLeadFromExtracted` (one insert, Lead born complete). |
| `PropertyMatchingService` | Service (read side, pure + selector-backed) | `normalizeAddress`, `calculateSimilarity` (Jaccard), `deriveClusterKey`, `findMatchingRegistry`/`findOrphanedRegistry`, plus the reply/repeat reads: `findRecordByReplyHeaders`, `findBrokerSubmission`, `computeThreadKey`, `resolveLiveRecord`. Never writes; never queries directly. |
| `PropertyClaimService` | Service (write side) | Owns all `Property_Registry__c` / `Competing_Broker_Submission__c` DML: `claim`, `registerWinner`, `markDuplicate`, `logRepeatSubmission`, the cluster-lock get-or-create/acquire helpers. |
| `InboundEmailActivityService` | Service (Task write side) | The *only* class that inserts a Task in this pipeline, and the only place that asks "has this message already been logged?" (`isAlreadyLogged`). |
| `InboundEmailFieldUtil` | Utility (pure functions) | `clip` / `sanitizeEmail` — the chokepoint that stops an over-long or malformed externally-sourced value from throwing a `DmlException` mid-transaction. No SOQL/DML/callouts. |
| `PropertyRegistrySelector` | Selector | All SOQL against `Property_Registry__c`, `WITH USER_MODE`. |
| `PropertyClaimLockSelector` | Selector | All SOQL against `Property_Claim_Lock__c`, `WITH USER_MODE` — the plain existence read and the `FOR UPDATE` lock-acquisition read. |
| `CompetingBrokerSubmissionSelector` | Selector | All SOQL against `Competing_Broker_Submission__c`, `WITH USER_MODE`. |
| `TaskSelector` (shared, cross-module) | Selector | Broker-Protection-relevant methods: `selectByInboundMessageId` (idempotency probe), `selectLatestByThreadOrMessageIds` (reply-thread lookup). |
| `LeadSelector` (shared, cross-module) | Selector | `selectConversionById` — backs `resolveLiveRecord`'s "follow a converted Lead to its live Opportunity/Contact" lookup. |
| `CompetingSubmissionController` | Controller (`@AuraEnabled cacheable=true`) | Thin. Delegates to `CompetingBrokerSubmissionSelector`; every failure → `AuraHandledException` via a private `ahe()` helper. |

See `ARCHITECTURE.md` §2 for the authoritative, project-wide services table (these rows are mirrored
there) and §3.3 for the OpenAI direct-callout exception.

---

## Sequence Diagram — winner then a competing duplicate

```
Broker A forwards          Salesforce Email Service            Async (Queueable)
"123 Main St"          ──►  EmailToLeadHandler
                              (parse envelope/headers/image;
                               NO Lead created here)
                                     │
                                     ▼
                          InboundEmailStagingService
                          .createStaging  →  INSERT
                          Inbound_Email_Staging__c
                          (Status = Pending)
                                     │
                                     ▼ System.enqueueJob
                          ExtractAddressQueueable(stagingId)
                                     │
                    ┌────────────────┼─────────────────────┐
                    ▼                ▼                      ▼
       LLMExtractionCalloutService  regex fallback   routing tree (a)-(e)
       .extract (OpenAI callout)    (From: line)      → (e) WINNER (unclaimed)
                    └────────────────┴─────────────────────┘
                                     │
                          EmailToLeadService.createLeadFromExtracted
                          → INSERT Lead A (complete, one write)
                                     │
                                     ▼
                          PropertyClaimService.claim
                     (a) deriveClusterKey("123 main")
                     (b) FOR UPDATE lock Property_Claim_Lock__c["123 main"]  ◄── serializes
                     (c) findMatchingRegistry → none found
                     (d) registerWinner
                                     │                              ┌───────────────────────────┐
                                     └─────────────────────────────►│ Property_Registry__c       │
                                                                     │  Property_Key__c=          │
                                                                     │   "123 main st"             │
                                                                     │  Winning_Lead__c = Lead A   │
                                                                     ├───────────────────────────┤
                                                                     │ Competing_Broker_          │
                                                                     │ Submission__c               │
                                                                     │  Is_Winning_Submission__c   │
                                                                     │   = true                    │
                                                                     └───────────────────────────┘
                                     │
                          InboundEmailActivityService.logInboundEmail
                          → INSERT Task (WhoId=Lead A,
                            Thread_Key__c / Inbound_Message_Id__c stamped)
                                     │
                          InboundEmailStagingService.markProcessed
                          (Outcome = "New Lead (winner)")

Broker B forwards      ──►  EmailToLeadHandler ──► staging row (Pending) ──► enqueueJob
"123 Main Street"                                                                │
 (moments later)                                                                 ▼
                                                              ExtractAddressQueueable(B)
                                                                  routing tree
                                                          (a) no reply match
                                                          (b) different broker → no repeat
                                                          (c) address present → skip
                                                          (d) DUPLICATE check:
                                                              PropertyClaimService.claim
                                                          deriveClusterKey("123 main") ← SAME
                                                          bucket as Lead A
                                                          FOR UPDATE lock — BLOCKS until Lead A's
                                                          transaction commits
                                                          findMatchingRegistry → fuzzy match on
                                                          "123 main st" (Jaccard ≥ 0.6) → WINNER
                                                          = Lead A found
                                                          markDuplicate
                                                                                │
                                        ┌───────────────────────────────────────┴─────────────────┐
                                        ▼                                                          ▼
                         UPDATE Lead B                                          INSERT Competing_Broker_
                         Is_Duplicate_Property__c = true                       Submission__c (non-winning)
                         Duplicate_Of_Lead__c = Lead A                          Winning_Lead__c = Lead A
                         (Lead A is NEVER written to)                          Source_Lead__c = Lead B

                                                          ┌──────────────────────────────────┐
                                                          │ competingBrokerSubmissions LWC     │
                                                          │ on Lead A's record page             │
                                                          │  Winner:    Lead A / Broker A       │
                                                          │  Competing: Lead B / Broker B       │
                                                          └──────────────────────────────────┘
```

For the repeat-submission and reply-thread paths (branches (a)/(b)), no Lead is created at all — the
diagram above only shows the winner/duplicate paths ((d)/(e)); see the Routing Tree table for the
other two.
