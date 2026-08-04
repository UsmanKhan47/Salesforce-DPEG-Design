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
| `Is_Duplicate_Property__c` | Checkbox (default false) | **LEGACY as of 2026-07-31** — no longer written by any code path. A competing broker no longer receives a Lead to flag; the claim is now recorded as a `Competing_Broker_Submission__c` with `Source_Lead__c = null` instead. Retained for historical data only. |
| `Duplicate_Of_Lead__c` | Lookup → Lead (`SetNull`) | **LEGACY as of 2026-07-31** — no longer written by any code path. Formerly populated only when `Is_Duplicate_Property__c = true`. Retained for historical data only. |

### Deal-Screening Fields (added 2026-07-31 — LLM Field Extraction Enrichment)

19 new Lead fields populated by `LLMExtractionParser` from the LLM's per-property JSON (plus 2 new
`Asset_Type__c` restricted-picklist values, **Hospitality** and **Medical Office**, added on both
`Lead` and `Property__c` so `LeadConvertService` does not silently drop them at conversion). Full
field-by-field detail (lengths, LLM source key, validation rule) lives in
`docs/broker-protection-data-dictionary.md`; summary here:

| Group | Fields |
|---|---|
| Asset identity | `Property_Name__c`, `Building_SF__c`, `Unit_Count__c`, `Year_Built__c`, `Year_Renovated__c`, `Lot_Size_Acres__c`, `Zoning__c`, `Seller_Entity__c` |
| Deal / process | `Sale_Process__c`, `Offer_Due_Date__c`, `Guidance_Price_Low__c`, `Guidance_Price_High__c`, `NOI__c`, `Occupancy_Pct__c`, `WALT_Years__c`, `ADR__c`, `Deal_Room_Link__c` |
| Listing broker (sender ≠ broker on blast platforms) | `Listing_Broker_Name__c`, `Listing_Broker_Email__c` |

The extraction also newly populates several **existing** Lead fields that previously carried only
placeholder/constant values: `Company` (LLM `broker_company`, falling back to the old
`'Unknown - Via Email'` placeholder only when blank — `Company` is required and is never written
blank), `Phone`/`MobilePhone`/`Title`, `Guidance_Price__c`, `Guidance_Cap_Rate__c`, `Asset_Type__c`,
`Deal_Type__c`, `Deal_Notes__c` (the LLM's narrative plus the parser's rejection notes plus, on the
first Lead of a multi-property email, the "additional properties not routed" block), and
`Parse_Confidence__c` (HIGH/MEDIUM/LOW, Apex-derived from the model's 0–1 confidence number — this
field existed before the enrichment but was unused until now).

**All 20 new/enriched Lead fields land in FOUR permission sets, not one** — `Broker_Protection_Access`
plus the three sibling deal-screening sets `DPEG_Acquisition_View` (read-only),
`DPEG_Acquisition_Edit`, `DPEG_Acquisitions` — because those three, not `Broker_Protection_Access`,
are what the acquisitions personas who actually work these Leads are assigned. Granting only
`Broker_Protection_Access` would leave the fields invisible to them, and **an admin acceptance test
would not reveal it** (profiles are `.forceignore`d, so an admin's FLS is not representative). See
`docs/2026-07-31-llm-field-extraction.md` for the full field-by-field writeup and the JSON contract.

### Task (Activity) Fields — the RFC threading keys

| Field | Type | Purpose |
|---|---|---|
| `Inbound_Message_Id__c` | Text(255), External ID | This message's own RFC `Message-ID` — the idempotency key. If a Task already carries it, the platform is redelivering an already-processed message. |
| `Thread_Key__c` | Text(255), External ID | The conversation-root `Message-ID` (see `computeThreadKey` below) — shared by every message in a thread, including after a forward, so a later reply can be matched back to the record the original email was routed to. |

Every inbound broker email is logged as one completed `Task` (`TaskSubtype='Email'`, never
`Task.Type` — see the ⚠ note below), not an `EmailMessage`, and a Task renders in the standard
Activity timeline on Lead/Contact/Opportunity. **Correction (2026-07-31):** an earlier version of
this doc stated Enhanced Email / Einstein Activity Capture licensing is not present in this org —
Enhanced Email **is now enabled** (via EAC setup). The Task model is retained anyway, deliberately:
the thread-anchor contract (`Inbound_Message_Id__c` / `Thread_Key__c`) is what reply threading and
repeat detection actually depend on, and migrating to `EmailMessage` would be a separate, deliberate
change, not a side effect of EAC being turned on.

⚠ **`Task.Type` does not exist in this org and must never be set.** It is absent from
`FieldDefinition` entirely (an org-template difference — Enhanced-Email-era orgs retired the classic
`Type` picklist in favor of `TaskSubtype`), yet Apex compiles a `Task.Type` assignment without
complaint and only fails at runtime (`"Operation failed due to fields being inaccessible on Sobject
Task"`). This was latent from the module's first deploy to this org — the builder/scratch orgs still
carry classic `Type`, so it was green everywhere else — and surfaced only when the first two real
inbound emails hit `usman-dpeg` on 2026-07-31, both dying as `Status = 'Error'`. `TaskSubtype` alone
is portable across both org templates and is now the only field this pipeline ever sets; see
`InboundEmailActivityService`'s class header for the full retraction/root-cause writeup.

Since 2026-07-31 one email can log a Task on **several** records at once (D1 multi-property) — see
`docs/2026-07-31-llm-field-extraction.md` for the bulk-logging shape and the reply-thread tie-break
this requires.

Full field-level detail (lengths, descriptions, all 19 `Inbound_Email_Staging__c` fields, including
the 3 added 2026-07-31 for the LLM field-extraction enrichment) lives in
`docs/broker-protection-data-dictionary.md`.

---

## The Routing Tree (prologue → per-property loop → epilogue, reshaped 2026-07-31)

**As of the LLM Field Extraction Enrichment, `route()` is no longer one linear pass over one
property.** One email now produces up to `MAX_PROPERTIES` (10) results, so the tree splits into an
email-level PROLOGUE (runs once), a PER-PROPERTY LOOP (branches (b)/(d)/(e), one pass per addressable
property), and an email-level EPILOGUE (runs once). Full detail — the deadlock-avoidance sort, the
tiered relevance gate, the pre-filter, task-priority ordering, and staging semantics for N results —
lives in `docs/2026-07-31-llm-field-extraction.md`; this table is the current-state summary:

| Phase | Step | Trigger | Result |
|---|---|---|---|
| Prologue | (a) **Reply** | The email's `In-Reply-To` / `References` cite a thread this pipeline has already logged (matched via `Task.Thread_Key__c` / `Task.Inbound_Message_Id__c`). | Filed on that conversation's record (following a converted Lead through to its live Opportunity/Contact via `PropertyMatchingService.resolveLiveRecord`). **No Lead, and — since 2026-07-31 — no LLM callout either**: branch (a) provably never reads the extraction, so it now runs *before* the callout and skips it entirely. Must run first for the same reason as always — a reply almost always still quotes the original broker and property. |
| Prologue | **Deterministic pre-filter** *(new)* | The envelope `From` local-part matches a machine-sender pattern (`noreply`, `mailer-daemon`, `postmaster`, `bounce(s)`, ...) or the raw headers carry `Auto-Submitted: auto-replied/generated`, `X-Autoreply`, or `Precedence: auto_reply`. | **No Lead, no claim, no LLM callout.** Staging `Outcome__c = 'Not Acquisition (pre-filtered)'`; the Task is still logged (Message-ID idempotency must survive a redelivery). ⚠ `Precedence: bulk` is **deliberately excluded** — it means mass-sent, not machine-generated, and is exactly what a legitimate broker blast platform (RCM/Crexi/Buildout) sets on a real listing. |
| Prologue | LLM callout + **relevance gate** *(new)* | The model classifies the email (`email_category`, `is_acquisition_related`, `confidence`). | **Hard gate** (`is_acquisition_related = false` **and** confidence ≥ 0.85 / `HIGH` band) → no Lead, no claim, `Outcome__c = 'Not Acquisition (gated)'`. **Soft gate** (false but less certain) → **still creates the Lead and still claims** — `Parse_Confidence__c = LOW`, which flows into the existing `Review_Queue` list view. The asymmetry is deliberate: an unclaimed real property costs a commission; a claimed junk address costs one deletable row. |
| Loop | (b) **Repeat** | The same broker (matched by LLM-extracted email, then by envelope `From` as a fallback) has already submitted **this property** within the 90-day lookback window. | An audit-only `Competing_Broker_Submission__c` is appended via `PropertyClaimService.logRepeatSubmission`, filed on the record the broker's earlier email already produced: the **winner's own** repeat lands on their own Lead; a **competing** broker's repeat — they have no Lead of their own since 2026-07-31 — lands on the **winning Lead** instead, alongside their new audit row. **No new Lead either way.** Neither shape is (or ever was) flagged `Is_Duplicate_Property__c` — that field is now LEGACY (see below). |
| Loop | (c) **No-Property** | No property in the whole email had a usable address (including when the LLM callout itself failed — see *Degraded Extraction* below). | Fires **once, at the email level**, not per property (unchanged design intent, now explicit): a Lead is created so nothing is lost, but **no claim is attempted**. Properties with no address alongside OTHERS that do have one are never minted as their own Lead — they're preserved verbatim in `Extracted_JSON__c` and appended to the first Lead's `Deal_Notes__c` instead. |
| Loop | (d) **Competing Submission** | This property is already claimed by a **different** broker. | **No Lead is created (changed 2026-07-31).** A non-winning `Competing_Broker_Submission__c` is logged against the winner with `Source_Lead__c = null`, and the email is filed on the **winning Lead** (resolved through conversion). The winning Lead itself is **never** written to. See `docs/2026-07-31-competing-broker-no-lead.md`. |
| Loop | (e) **Winner** | Nobody has claimed this property. | A Lead is created and takes the claim under the cluster lock (`PropertyClaimService.claim`). If a concurrent submission wins the race between this step's pre-read and its lock (`claim()` returns `DUPLICATE_RACE`), the Lead just created is **deleted** (`EmailToLeadService.deleteLead`) and the email is re-routed exactly like branch (d) — outcome `Competing Submission (race)`. |
| Epilogue | Task logging + staging stamp | Once, after the loop. | **One `Task` per DISTINCT routed record** (not one per email, not one per property), one bulk DML, inserted in ascending priority so a later reply resolves onto the record DPEG actually owns. The staging row records the primary record (`Result_Record_Id__c`, unchanged shape), the full N-result audit (`Routed_Record_Ids__c`), and how many properties were found (`Property_Count__c`). |

**Properties within one email are processed in a specific, load-bearing order** — ascending
`deriveClusterKey`, not the model's array order — which is the fix for a multi-property lock
deadlock; see `docs/2026-07-31-llm-field-extraction.md`.

### Idempotency (two independent guards)

1. A staging row already marked `Processed` is never re-run (`ExtractAddressQueueable.execute`).
2. An RFC Message-ID already present on a `Task.Inbound_Message_Id__c` means the platform is
   redelivering a message already routed — the whole routing tree is skipped
   (`InboundEmailActivityService.isAlreadyLogged`). A **blank** Message-ID skips only this second
   guard and proceeds normally, because some forwarding paths strip the header and refusing those
   emails would be worse than occasionally reprocessing one.

### Degraded Extraction (LLM outage, or now a malformed/truncated reply)

A failure at the OpenAI boundary — a 429, a 5xx, a timeout, **or (added 2026-07-31) a malformed/
truncated JSON reply** — is treated as the absence of an optional input, **not** a pipeline failure.
It is caught at the callout site and the pipeline degrades rather than aborts: extraction becomes an
empty result, the regex fallback still recovers the broker's name/email from the raw `From:` line,
and routing proceeds normally. Because the regex fallback never yields a property address, a degraded
run can only ever reach branch (a) or branch (c) — a real Lead is always created (or an existing
thread correctly reused), never silently dropped because OpenAI was rate-limiting. The staging row
records the distinct outcome label `New Lead (no property) — LLM unavailable` so outage-degraded
Leads are distinguishable from genuinely addressless emails and can be re-extracted by hand once the
outage clears.

**The degrade catch was deliberately widened from `CalloutException`-only to also catch
`JSONException`** (2026-07-31, a documented reversal of the prior narrow-catch decision) — the
enriched JSON contract is ~8× larger, so a truncated reply is no longer "a defect in our own
contract," it's the same category of event as an outage. See
`docs/2026-07-31-llm-field-extraction.md` for the full reasoning and the four mitigations
(`MAX_TOKENS` 512→4096, OpenAI JSON mode, prompt-level caps, and this widened catch) that work
together to make truncation both rarer and survivable.

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
| `ExtractAddressQueueable` | Queueable (`Database.AllowsCallouts`) | The async orchestrator — owns the routing tree, now three phases (prologue / per-property loop / epilogue, see above). No inline SOQL/DML; every read/write is delegated. `@TestVisible forceClaimRace` seam forces the race-recovery path under test; `@TestVisible buildWorkList` is the pure, directly-testable deadlock-avoidance sort. |
| `LLMExtractionCalloutService` | Service (callout wrapper) | The single OpenAI HTTP callout in the codebase, mockable via `HttpCalloutMock`. Carries the written §3-exception justification (direct, non-ASB callout). Since 2026-07-31 returns a typed `LLMExtractionResult` (not a 4-key map); `MAX_TOKENS` 4096, `response_format: json_object`, `TIMEOUT_MS` 60000, input body clipped to 40,000 chars. |
| `LLMExtractionParser` | Utility (pure coercion) *(new 2026-07-31)* | Turns one raw model response into a typed `LLMExtractionResult`. **Never throws** — every unparseable value resolves to a typed null plus a human-readable note rather than aborting the routing transaction. Validates restricted picklists (`Asset_Type__c`, `Deal_Type__c`, `Sale_Process__c`) against `Schema.describe` at **runtime**, not compile time. Deliberately a separate class from `InboundEmailFieldUtil` — coercion vs. field-safety are different contracts. |
| `EmailToLeadService` | Service (Lead write side) | The *only* class that inserts a Lead in this pipeline — `createLeadFromExtracted` (one insert, Lead born complete) — and the only class that deletes one (`deleteLead`, lost-race only). Since 2026-07-31 takes a `LeadRequest` DTO (~25 values) rather than positional parameters, and the class-level invariant is now **"one PROPERTY == at most one Lead; one email can produce N"** (not "one email == at most one Lead"). |
| `PropertyMatchingService` | Service (read side, pure + selector-backed) | `normalizeAddress`, `calculateSimilarity` (Jaccard), `deriveClusterKey`, `findMatchingRegistry`/`findOrphanedRegistry`, plus the reply/repeat reads: `findRecordByReplyHeaders`, `findBrokerSubmission`, `computeThreadKey`, `resolveLiveRecord`. Never writes; never queries directly. Signatures unchanged by the 2026-07-31 enrichment — only its class-header Javadoc, noting it is now called once per property rather than once per email. |
| `PropertyClaimService` | Service (write side) | Owns all `Property_Registry__c` / `Competing_Broker_Submission__c` DML: `claim`, `registerWinner`, `markDuplicate`, `logRepeatSubmission`, the cluster-lock get-or-create/acquire helpers. Signatures unchanged by the 2026-07-31 enrichment — `claim()` is now called **N times per transaction** (once per property in a multi-property email), Javadoc-only update. |
| `InboundEmailActivityService` | Service (Task write side) | The *only* class that inserts a Task in this pipeline, and the only place that asks "has this message already been logged?" (`isAlreadyLogged`). Since 2026-07-31 its primary method takes `List<Id>` and does one bulk insert of N Tasks (one per distinct routed record); the original single-Id method survives as a one-element wrapper. Sets `TaskSubtype` only — see the ⚠ `Task.Type` note above. **Since 2026-08-04 both overloads also take `senderName`/`senderEmail` (the 6-arg sender-less forms were removed): `Subject` gets a head-preserving `From <sender>: ` prefix and `Description` gets a `From:`/`Subject:`/rule header block ahead of the body, so the pipeline Task says who sent the email instead of relying on the Lightning "You sent an email" chrome, which this change does NOT fix (direction is not a Task attribute). See `docs/2026-08-04-broker-attribution-on-pipeline-tasks.md`.** |
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
                                                          markDuplicate  (no Lead created for Broker B —
                                                                          changed 2026-07-31)
                                                                                │
                                                                                ▼
                                                          INSERT Competing_Broker_
                                                          Submission__c (non-winning)
                                                          Winning_Lead__c = Lead A
                                                          Source_Lead__c = null   ← Broker B has no
                                                                                    Lead of their own
                                                          (Lead A is NEVER written to; Broker B's
                                                           email Task is logged on Lead A)

                                                          ┌──────────────────────────────────┐
                                                          │ competingBrokerSubmissions LWC     │
                                                          │ on Lead A's record page             │
                                                          │  Winner:    Lead A / Broker A       │
                                                          │  Competing: (no Lead) / Broker B    │
                                                          └──────────────────────────────────┘
```

For the repeat-submission and reply-thread paths (branches (a)/(b)), no Lead is created at all — the
diagram above only shows the winner/duplicate paths ((d)/(e)); see the Routing Tree table for the
other two. As of 2026-07-31 branch (d) never creates a Lead either — see
`docs/2026-07-31-competing-broker-no-lead.md` for the full current-state writeup, including the
destructive lost-race path this diagram does not show.

**This diagram shows the single-property case and is still accurate for it.** It predates D1
multi-property extraction and does not show: the pre-filter / relevance-gate prologue steps that can
resolve an email before any claim is attempted, a work-list of several properties processed in
cluster-key order, or the epilogue's one-Task-per-distinct-record bulk logging. See
`docs/2026-07-31-llm-field-extraction.md` for the multi-property routing tree and its own worked
example.
