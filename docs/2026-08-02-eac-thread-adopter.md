# Broker Protection — Change 3: EAC Thread Adopter

**Date:** 2026-08-02
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg` — deploy `0Afiw000000DIvBCAW`, **252/252 tests**, which also carried
the **destructive delete of `EmailThreadGuardQueueable`** (mechanically renamed to
`EmailCaptureQueueable`). Code-reviewed — Gate 2 returned **APPROVED WITH WARNINGS** (W1 order-swap, W2
destructive-delete manifest); both were fixed same-day, the platform-quirk finding was separately
adjudicated, the test suite was redesigned around it, and the feature shipped on the fourth deploy
attempt. See "Review History" below for the full story.
**Companion docs:** `docs/2026-08-02-eac-thread-guard.md` (Change 2 — the feature this one mirrors and
runs alongside), `docs/2026-07-24-broker-protection.md` (the pipeline that writes the thread anchors
both features read), `docs/2026-07-31-competing-broker-no-lead.md` (Change 1), `ARCHITECTURE.md` §2
("EAC CAPTURE PIPELINE (guard + adopter)" subsection + the `EmailThreadAnchorService` /
`EmailThreadAdopterService` / `EmailThreadGuardService` rows in Key Apex Services — all already current,
not touched by this documentation pass).
**Design source:** `agent-output/design-requirements-eac-adopter.md` (premise verification P1–P6,
decisions D1–D7, experiments E1–E3, live-only checks L1–L5).

---

## 📋 Overview

### Original Request

> Build the mirror image of the deployed EAC Thread Guard: where the guard **deletes** Lead-related EAC
> captures whose thread matches no Broker Protection anchor, the adopter **associates** anchored captures
> onto the deal record EAC failed to reach. Driving requirement, in the user's own words: full two-way
> deal email threads visible on deal records, because "majority of the discussion will happen in
> opportunity." Nothing else is in scope — no new UI, no new objects, no reporting, no notification, no
> change to the inbound routing tree.
> *(Source: `agent-output/design-requirements-eac-adopter.md`, "WHAT THE USER REQUESTED.")*

### Business Objective

Einstein Activity Capture is the **only** system that ever sees the **outbound** half of a deal
conversation — the Broker Protection pipeline receives inbound broker mail exclusively through a
forwarding address, so it never has visibility into what the deal team actually sent back. EAC captures
that outbound reply, but it associates by **address matching alone**, so the reply lands on whatever
record happens to carry the broker's address — a Lead, a Contact, or an Opportunity EAC itself inferred
thread-blindly through a matched Contact — almost never on the Opportunity where "majority of the
discussion will happen." The result, before this feature, was half a conversation sitting on the deal
record: every inbound reply logged by the pipeline, and every outbound reply scattered across whatever
EAC happened to associate it with. The adopter closes that gap by re-pointing an EAC capture onto the
Opportunity its own RFC thread identity proves it belongs to — the same header-identity evidence the
inbound pipeline already treats as the strongest signal available.

### Summary

`EmailCaptureQueueable` (renamed from `EmailThreadGuardQueueable`) now runs **two** services per
captured-email batch, sharing a single anchor read: `EmailThreadAdopterService.run(...)` **first**,
re-pointing `EmailMessage.RelatedToId` to an Opportunity when the capture's RFC identifiers match a
Broker Protection thread anchor whose `WhatId` is that Opportunity; then `EmailThreadGuardService.run(...)`
**second**, unchanged in intent but widened so it no longer deletes what the adopter just wrote. A new
shared service, `EmailThreadAnchorService`, performs the one anchor read and the one bracket
normalization both halves consume with opposite polarity — closing a live bracket-asymmetry defect (P4)
in the deployed guard along the way. The adopter is convergent (a re-run recomputes the same target and
writes only on difference), performs **zero Task DML**, and ships no rollback code because there is
nothing to roll back. It also carries a documented, currently-unexplained platform quirk: the write it
depends on is refused inside `@isTest` against a test-created capture but has been proven, twice, to
commit at runtime against a real one.

### Relationship to the Guard

This is not a standalone feature bolted alongside the guard — it changed the guard too. Building the
adopter surfaced two live defects in the *already-deployed* Change 2 guard that neither its own 12 tests
nor its Gate 2 review had caught: a bracket-format mismatch that silently disabled half its matching
logic (P4), and a structural blind spot that meant the guard would delete the adopter's own output
seconds after it was written (P6). Both are fixed in this change, and both are described below rather
than in the guard's own doc, because they were found *by* building the adopter, not by re-reviewing the
guard in isolation.

---

## 🧩 The Problem — Why This Feature Exists

Broker Protection logs every **inbound** broker email as a pipeline Task, stamped with two RFC thread
anchors (`Thread_Key__c`, the conversation root's Message-ID; `Inbound_Message_Id__c`, that message's own
Message-ID — see `docs/2026-07-24-broker-protection.md`). That gives the deal team a complete inbound
record. But the pipeline has no channel for outbound mail at all — it only ever receives forwarded
inbound messages. Einstein Activity Capture is the one system in this org that captures what the deal
team actually sent, because it watches the connected mailbox directly.

EAC's captures are useless for this purpose on their own, though, because EAC is thread-blind and
address-based (the same property that makes the guard necessary in the first place — see
`docs/2026-08-02-eac-thread-guard.md`). Measured on two live captures in `usman-dpeg` (finding F2): EAC
arrives having already written an `EmailMessage.RelatedToId` — but it named that Opportunity by inferring
it **through a matched Contact**, not through anything resembling the actual conversation. Separately,
finding F1 established that when a same-address Contact already exists, that Contact takes the "sender"
relation slot and no Lead relation succeeds for the same message — so extending the guard's own
`EmailMessageRelation`-based model to Leads doesn't reliably reach the deal either. Address inference,
whichever record it lands on, is not evidence about which deal a reply belongs to.

The Broker Protection pipeline already holds strictly better evidence: an RFC-header identity match. A
genuine reply's `ThreadIdentifier` (its thread root's Message-ID) or `MessageIdentifier` (its own
Message-ID) will equal a value the pipeline itself stamped as a thread anchor when it logged the original
inbound message. That is proof a specific email belongs to a specific, already-known conversation — not
an opinion inferred from an address. The inbound routing tree already treats a header match this way
("a header match is PROOF… a classifier's read of the body is an opinion"); the adopter applies the same
rule to EAC's captures. Where the pipeline anchor names an Opportunity, the adopter re-points the capture
there, overwriting whatever address-inferred guess EAC arrived with.

---

## 🔀 Architecture — One Queueable, One Shared Index, Adopter Before Guard

```
EAC captures an email (an outbound reply, OR a brand-new unrelated conversation)
        │
        ▼
 EmailMessage inserted ──────────────────────────────────────────────────┐
        │                                                                 │
        ▼                                                                 │
 EmailMessageTrigger (after insert, one line, UNCHANGED)                   │
        │                                                                 │
        ▼                                                                 │
 EmailMessageTriggerHandler.afterInsert()                                  │
   • queueable-slot check — UNCHANGED; enqueue count stays ONE per chunk    │
        │                                                                 │
        ▼                                                                 │
 System.enqueueJob(EmailCaptureQueueable)     ← renamed from                │
        │                                       EmailThreadGuardQueueable  │
        │             EmailMessageRelation rows inserted ◄──────────────────┘
        │             (AFTER the EmailMessage, same transaction)
        ▼
  ── transaction commits ──
        │
        ▼
 EmailCaptureQueueable.execute() (post-commit)
   1. EmailThreadAnchorService.index(messageIds)  ← ONE anchor read, ONE normalization
   2. EmailThreadAdopterService.run(ids, anchors) ← 1st: RelatedToId writes (own try/catch)
   3. EmailThreadGuardService.run(ids, anchors)   ← 2nd: deletes (unwrapped — failures must be loud)
```

Three ordering decisions are load-bearing, and each is explained in full in the production class headers
rather than repeated here as an aside:

1. **One index, built once.** Both services ask the same question of the same anchor data with opposite
   polarity — the adopter asks "which record does this thread belong to?", the guard asks "is this
   record anchored anywhere it lives?" — so building the index once and handing it to both is what makes
   them normalize RFC identifiers **identically by construction**, not by convention. `EmailThreadAnchorService`
   exists specifically so `EmailCaptureQueueable` holds no SOQL of its own.
2. **Adopter before guard, always — live and in any sweep.** An Opportunity-anchored capture that is
   EAC-related only to an unrelated same-address Lead is unanchored on **every** Lead it lives on.
   Running the guard first deletes it before the adopter ever sees it (finding P6, below). Because the
   guard **re-reads** the messages rather than reusing a stale copy, it observes the `RelatedToId` the
   adopter just wrote and keeps the row through its widened guard 4.
3. **The adopter's failure is isolated; the guard's is not.** The adopter call is wrapped in its own
   `try/catch` so a defect in the newer, additive feature can never regress the older, destructive one.
   The guard is deliberately left unwrapped — a guard failure needs to surface as a failed `AsyncApexJob`,
   because a silently disabled guard is exactly the failure mode the whole pipeline exists to prevent.

The enqueue count stays at **exactly one job per trigger chunk** — this is a hard constraint carried over
from the guard, not a new decision: `EmailMessageTriggerHandler`'s `Limits.getQueueableJobs() <
Limits.getLimitQueueableJobs()` check protects EAC's own bulk insert from a `LimitException` rollback, and
a second enqueue per chunk would halve the throughput ceiling that check exists to protect. A future third
`EmailMessage` concern belongs inside `EmailCaptureQueueable`, not behind a second `System.enqueueJob`.

---

## 🔑 The Mechanism — Why `RelatedToId` Re-Pointing Is the Only Viable Channel

`EmailMessage` carries exactly one channel for naming "what record is this email about" —
`RelatedToId`, a single-value field, not a `WhoId`/`WhatId` pair the way `Task` has. Two alternative
mechanisms were considered and were killed by measured findings before the adopter's design settled on
`RelatedToId`:

- **Inserting an `EmailMessageRelation` row pointing at the Opportunity** — the same mechanism EAC itself
  uses to relate a capture to a Lead or Contact — was ruled out because **`EmailMessageRelation` rejects
  Opportunity `RelationId`s outright**, measured directly while building the adopter's test helpers
  (`EmailThreadAdopterServiceTest.cls` header, measured fact 3). There is no relation-row path onto an
  Opportunity to use even if the design wanted one.
- **Extending Lead-side association via a new `EmailMessageRelation`** was separately ruled out of v1 by
  finding **F1**: when a same-address Contact already exists, that Contact occupies the message's sender
  relation slot and no additional `RelationType` succeeds for the same address. A v1 that promised Lead
  adoption through this channel would only sometimes deliver it, decided by whether a Contact happens to
  exist at that address — a non-explainable, silently partial behaviour design decision D1 explicitly
  rejected. (Lead's own inbound-outbound gap is independently narrow anyway: a pre-conversion broker Lead
  already carries the broker's address, so EAC natively relates captures to it and the guard already
  keeps anchored ones. The Lead outbound-half is deferred to v1.1, gated on an *observed*, not suspected,
  gap.)

That leaves `RelatedToId` re-pointing as the only channel this feature — or any near-term one — can use
to move a capture onto an Opportunity, which is exactly what `EmailThreadAdopterService.adopt(...)` does:
one bulk `Database.update` against `EmailMessage.RelatedToId`, nothing else.

---

## 🧭 The Resolution Chain — Header Identity Beats Address Inference (D2, Reshaped by E1)

The design's original resolution chain (D2) had three steps: (1) the anchor Task's `WhatId` is an
Opportunity, (2) the anchor Task's `WhoId` is a Lead — resolve it through
`PropertyMatchingService.resolveLiveRecord`, or (3) fail closed. **Experiment E1 retired step 2 before any
code was written for it.** Measured directly via `Database.convertLead` on a Lead carrying an anchor Task:
standard Salesforce lead conversion performs the anchor carry-forward **itself** — it repoints the
anchor's `WhoId` from the Lead to the converted Contact **and** stamps the anchor's `WhatId` with the
converted Opportunity, on the pre-existing Task, with no code from this feature involved. Step 1 already
covers every converted deal from the moment of conversion onward, so step 2 could only ever fire for an
**unconverted** Lead — which by definition has no Opportunity to adopt onto and must fail closed anyway.
Step 2 is therefore unreachable and was never implemented; no conversion-time carry-forward component
exists in this feature, and none of the "Amended components" the design conditionally proposed for
`LeadConvertTriggerHandler` / `LeadConvertService` were built.

The resolution chain that shipped, in `EmailThreadAnchorService.AnchorIndex.resolveOpportunity`, is two
branches:

1. **Anchor `WhatId` is an Opportunity → that Opportunity.** The only resolving branch.
2. **Anything else (a Contact `WhoId`, an unconverted Lead, no anchor at all) → no adoption.** Fail
   closed, and this is load-bearing, not incidental: after conversion every anchor's `WhoId` **is** a
   Contact, and one Contact can front many deals. Resolving through it would manufacture exactly the
   wrong-deal lie the guard exists to delete — adopting nothing is strictly better than guessing.

**Consultation order within step 1 matters and was itself a review finding (W1, below):**
`MessageIdentifier` is consulted **before** `ThreadIdentifier`. One inbound email can produce several
sibling anchor Tasks sharing one `Thread_Key__c` conversation root but carrying different
`Inbound_Message_Id__c` values (D1 multi-property extraction routes one email to several properties), and
after conversion those sibling anchors can sit on **different** Opportunities. `MessageIdentifier` says
"the pipeline filed **this specific email** here" — exact identity; `ThreadIdentifier` only says
"something in this conversation was filed somewhere" — conversation-level identity. Consulting
`ThreadIdentifier` first would adopt a reply onto the wrong sibling deal from the same multi-property
email. The harm is bounded (always a sibling deal, never a wholly unrelated one), which is why it was a
review warning rather than a release blocker, but the fix is still exact-identity-first,
`ThreadIdentifier` only as a fallback for the (common) case where a reply's own Message-ID hasn't been
anchored yet and only the conversation root has.

Multiple anchor Tasks can also name the *same* identifier across different records entirely (multi-property
routing again). `RelatedToId` holds one Id, so the tie-break has to be deterministic: the shared index
reuses the pipeline's own rule — the selector orders `CreatedDate DESC, Id DESC` and the index takes
first-wins, because the epilogue inserts anchor Tasks in ascending priority, so the deal DPEG actually
owns carries the highest Id and wins.

---

## 🔴 D4 — The `RelatedToId` Contention Policy

`RelatedToId` almost always already holds something by the time the adopter examines a capture — EAC
wrote its own guess, or a human deliberately related the email to something. This table, implemented
exactly in `EmailThreadAdopterService.adopt(...)`, is the feature's entire decision surface:

| Current `RelatedToId` | Anchor resolves an Opportunity | Action |
|---|---|---|
| `null` | yes | **Write** it |
| an Opportunity, **different** from anchor truth | yes | **Overwrite** |
| an Opportunity, **equal** to anchor truth | yes | **No-op** (convergence) |
| a **non**-Opportunity (Account, Case, `Property__c`, …) | yes | **Leave alone** |
| anything | no | **Leave alone — never write null** |

- **Overwriting an Opportunity is the point, not an oversight.** EAC's own guess is address inference —
  the same class of lie the guard exists to delete elsewhere — and header identity beats it, exactly as
  it does in the inbound routing tree. Leaving a wrong Opportunity in place is worse than showing
  nothing: it is a plausible-looking email sitting on the wrong deal.
- **A non-Opportunity current value is never touched**, the same allow-list direction as the guard's own
  W1 fix (Change 2's finding, not this feature's — see the guard doc): an unanticipated object type falls
  through to "don't touch," never to "overwrite." `RelatedToId` accepts roughly 80 object types in this
  org; this feature claims exactly one of them.
- **Null is never written.** There is no branch that clears the field. A capture the chain cannot resolve
  keeps whatever EAC (or a human) already decided.
- **The EAC fingerprint is required** — the companion Task (reached via `EmailMessage.ActivityId`) must
  have been created by the `AutomatedProcess` user, the same test the guard's own guard 3 makes. A
  composer or Agentforce send's `RelatedToId` was chosen by a human, and overwriting it would override
  explicit human intent.

---

## 🔴 Two Live Guard Defects Fixed En Route

Building the adopter required rebuilding the anchor read the guard already depended on, and doing that
carefully surfaced two defects already live in the deployed Change 2 guard — neither caught by that
feature's own 12 tests or its Gate 2 review.

### P4 — The Bracket Asymmetry (the guard was running on one leg)

The pipeline stores its two thread anchors in **different bracket forms**: `Task.Thread_Key__c` is
written through `PropertyMatchingService.computeThreadKey`, whose every return path runs through
`stripAngleBrackets` — **unbracketed**. `Task.Inbound_Message_Id__c` is written from the raw
`Message-ID` header value — **bracketed**. EAC supplies bracketed identifiers on `ThreadIdentifier` and
`MessageIdentifier`. Measured directly on both live anchor rows in `usman-dpeg` (experiment E3):

```
Thread_Key__c:         PH0P222MB0047…OUTLOOK.COM
Inbound_Message_Id__c: <PH0P222MB0047…OUTLOOK.COM>
```

The deployed guard compared these raw values with no normalization, so its
`ThreadIdentifier ↔ Thread_Key__c` leg could **never** match — it was silently running on its
`MessageIdentifier` leg alone. The practical consequence: a reply whose thread root had been logged as a
**mid-thread** Task (anchored only under `Thread_Key__c`, no matching `Inbound_Message_Id__c`) was being
deleted by the guard as unanchored, even though it belonged to a real, recognized thread. The fix —
`EmailThreadAnchorService.normalize`, the single bracket-handling routine now used by both features —
strips angle brackets and trims on both sides of every comparison, and
`TaskSelector.selectThreadAnchorsByAnchorValues` binds **both** bracket forms in its `WHERE` clause so a
value stored in either shape matches a normalized candidate.
`EmailThreadAnchorServiceTest.bracketAsymmetryIsClosedByNormalization` pins this directly and is named in
the production class header specifically so nobody re-introduces bracket handling anywhere else.

### P6 — The Partition Gap (the guard could delete the adopter's own output)

Before this change, the guard's "lives elsewhere" and "anchored" checks read `EmailMessageRelation` and
the related Leads' anchors only — `EmailMessageSelector.selectByIds` did not even select `RelatedToId`,
so the guard could not see it at all. An adopted capture — anchored on its Opportunity via `RelatedToId`,
but EAC-related only to an unrelated same-address Lead that carries no anchor of its own — would be
unanchored on every Lead it lived on and would be deleted by the guard **seconds after** the adopter wrote
it. This is the finding that reshaped the whole feature: without a guard amendment, the two features do
not cleanly partition the problem space, and the adopter's output is destroyed by its sibling. The fix
widens guard 4 from "anchored on a related Lead" to **"anchored on any record it lives on"** — related
Leads **union** the `RelatedToId` record — and the change is strictly **keep-biased**: it can only ever
cause the guard to delete *fewer* messages than before, never more.

That widening initially shipped with **zero test coverage of its own**, which was itself a finding
surfaced during the deploy cycle (recorded in `EmailThreadAdopterServiceTest.cls` as "finding 3 of the
2026-08-02 deploy"). The original test seeded `RelatedToId = null` and relied on the adopter to populate
it before the guard ran; because the platform's write refusal in test context (see the platform quirk,
below) meant the write never actually landed, the capture stayed unanchored, the guard deleted it as
before, and the test failed for the ordinary reason — never exercising the widened `∪ RelatedToId` leg of
guard 4 against a populated value at all. The coupled test was decomposed:
`adoptedCaptureIsKeptByTheGuard_viaTheRelatedToIdLeg` now **seeds** `RelatedToId` at insert to the already-
adopted state (the shape a completed adoption leaves behind) rather than depending on the write landing,
runs the real trigger path, and asserts the widened leg is what keeps it — with an unanchored capture on
the same Lead as a negative control proving the guard still ran a real deletion pass.

---

## 🔴 The Platform Quirk — `EmailMessage.RelatedToId` and Its Lying Describe

This is the single strangest fact this feature shipped with, and it is documented in full rather than
smoothed over, because the alternative is someone rediscovering it from a monitoring gap in production.

**`describe.updateable` reports `TRUE` for `EmailMessage.RelatedToId`, and it is wrong.** That flag is
exactly what let the feature reach a deploy before the problem surfaced — nothing in the metadata says
this field is unusually protected. Re-describing the field is not a way to "verify" it; the flag has
already been shown to lie once.

What is actually established is a **correlation, not a mechanism** — the two facts below were measured
independently and differ in more than one variable at once, so neither should be read as "solving" the
other:

- **The write commits at runtime.** Proven twice on `usman-dpeg` against a real EAC capture
  (`02siw0000005prVAAQ`) — spike experiment 3a set the field, then reverted it, each change confirmed by
  an independent readback. The mechanism this feature is built on is real and was directly observed.
- **The write is refused inside `@isTest` against a test-created capture.** Seven separate anonymous-Apex
  probes, plus the identical fingerprint recurring across the feature's own failed and successful deploy
  attempts, all return the same error:
  `INSUFFICIENT_ACCESS_OR_READONLY … "You cannot edit this field" … fields=(RelatedToId)`. This was probed
  independent of the message's `Status` (both `Sent` and `Draft` were refused identically), independent of
  whether any `EmailMessageRelation` existed, and it is **not** a whole-record lock —`Subject` updates
  successfully on the identical row in the identical test.
- **Which variable is the actual mechanism is undetermined.** The runtime proof ran as an admin, against a
  real, EAC-materialized row; the test-context refusal runs as the test's own user, against a
  test-inserted row. Two variables changed at once (execution context, and row provenance), and nothing
  measured here isolates them. Neither "test context blocks it" nor "test-created rows block it" should
  be quoted as settled — both remain open questions.
- **Insert-time seeding is unaffected and persists.** Setting `RelatedToId` at the moment of `insert`
  works and the value survives, which is how the test suite stages already-adopted state for convergence
  and D4-row tests without ever needing the update path to succeed.

### What This Forced: The `AdoptionWriter` Seam, Decision-Based Tests, and the Quirk Canary

Because the update genuinely cannot be exercised inside `@isTest` against test data, a test suite that
asserted **committed state** ("`RelatedToId` now equals the target Opportunity") would either fail
outright against the real writer, or — worse — pass **vacuously** if the underlying guard logic were
silently broken, because no write lands in this context regardless of whether the guards work correctly.
This is precisely what happened during the deploy cycle: reviewed and confirmed, **every negative-path
test up to that point was latently vacuous** — "assert the field is unchanged" trivially passes whether
or not the guard clause under test still exists, because nothing was ever going to write in `@isTest`
either way.

The fix is `EmailThreadAdopterService.AdoptionWriter`, the class's one deliberately narrow injectable
seam. It sits **after** every decision has already been made — `adopt(...)` and every D4 guard are
non-injectable, so the full decision logic is always genuinely exercised — and receives exactly the rows
`commitAdoptions` decided to write. Production uses `PlatformAdoptionWriter`, a one-line wrapper around
the real `Database.update`; tests install a `RecordingWriter` double that captures what was selected and
fabricates a successful `SaveResult`, so a test can assert **which rows the decision chose and where it
pointed them** without depending on the platform ever accepting the DML. Every positive-path D4 test now
pairs a `Set<Id>` selection assertion with an explicit write-count assertion (a set silently tolerates a
duplicate write; a count does not), and every negative-path test now asserts the recorder received
**zero** rows — closing the vacuity gap directly rather than trusting an unchanged-field assertion that
could never have caught the regression.

One test, `platformRefusesTheRelatedToIdUpdate_isTheDocumentedQuirk`, deliberately runs **without** the
double, against the real writer, on a row the decision logic has already selected — and pins the quirk by
its **error code**, not by a zero count (which "nothing happened" would also satisfy). It is written as a
genuinely **two-way canary**: it goes red if a *different* error ever appears (something new is blocking
the write and must be investigated), and it goes red — in the good direction — if the platform ever
starts **permitting** the update, at which point `lastRunFailureCodes` comes back empty,
`lastRunAdoptedCount` becomes 1, and the class header records exactly what to do next: retire this test
and restore committed-state assertions across the suite, because the seam will no longer be needed for
these paths.

---

## 🧭 E1's Scope Retirement — Recap

Called out separately because it changed the shipped component list, not just a test: E1 measured that
standard `Database.convertLead` performs the anchor `WhoId`→Contact repoint **and** the `WhatId`→Opportunity
stamp itself, on the pre-existing anchor Task, with zero code from this feature. The conversion-time
carry-forward component the design conditionally scoped into v1 (a before/after-update pair on
`LeadConvertTriggerHandler`) was never built, because the platform already does the job. See "The
Resolution Chain," above, for the full reasoning and the safety property (fail-closed on a Contact
`WhoId`) this retirement did **not** touch.

---

## 🧱 Components

### Apex — production

| Class / Trigger | Layer | Status | Responsibility |
|---|---|---|---|
| `EmailThreadAnchorService.cls` | Service, read-only, `with sharing` | **New** | The single shared anchor read and the single bracket-normalization routine (`normalize`). Builds the `AnchorIndex`: which records carry which normalized anchor values, and which Opportunity each anchor value resolves to (the D2/E1 chain, `CreatedDate DESC, Id DESC` tie-break). No DML. |
| `EmailThreadAdopterService.cls` | Service, `without sharing` | **New** | Owns the D4 decision and the only `RelatedToId` DML in the feature. Zero Task DML. The `AdoptionWriter` seam and its production/test implementations live here. |
| `EmailCaptureQueueable.cls` | Queueable, `with sharing` | **New** (replaces `EmailThreadGuardQueueable.cls`, which was deleted) | Thin async wrapper: builds the shared index, runs the adopter (own `try/catch`), then the guard (unwrapped). No SOQL, no DML, no decision logic. |
| `EmailThreadGuardService.cls` | Service, `without sharing` | **Amended** | Consumes the shared index instead of its own anchor read; guard 4 widened from "anchored on a related Lead" to "anchored on any record it lives on" (related Leads ∪ `RelatedToId`). The four-guard structure, the `{Lead, User}` allow-list, the `ActivityId`-only delete route, and the `without sharing` justification are all unchanged. |
| `EmailMessageTriggerHandler.cls` | Trigger handler | **Amended** | References the renamed queueable. Enqueue-count math (one job per trigger chunk) is unchanged. |
| `TaskSelector.cls` | Selector | **Amended** | `selectThreadAnchorsByWhoIds` **replaced** by `selectThreadAnchorsByAnchorValues(Set<String>)` — scoped by anchor value rather than by related record, because the adopter has no record set to scope by (the anchor is what *names* the record). Binds both bracket forms of every candidate. `WITH SYSTEM_MODE`. |
| `EmailMessageSelector.cls` | Selector | **Amended** | `selectByIds` widened to add `RelatedToId` — the adopter's write target/contention input and the guard's widened guard-4 input. Carries a "DO NOT NARROW" contract in the class header. `WITH SYSTEM_MODE`. |
| `triggers/EmailMessageTrigger.trigger` | Trigger | **Unchanged** | Still one line, `after insert` only, delegates to the handler. |

### Apex — tests

| Test class | Methods | Status | What it proves |
|---|---|---|---|
| `EmailThreadAnchorServiceTest.cls` | 12 | **New** | The normalizer (bracket stripping, blank handling), the P4 bracket-asymmetry regression, the D2/E1 resolution chain (Opportunity `WhatId` resolves, Contact `WhoId` fails closed), the W1 MessageIdentifier-before-ThreadIdentifier consultation order, the multi-anchor tie-break, both `index(...)` overloads, and null/empty/no-identifier short-circuits. |
| `EmailThreadAdopterServiceTest.cls` | 15 | **New** | The full D4 policy matrix (write/overwrite/no-op/leave-alone/never-null), the fingerprint gate, convergence (writes once, then writes nothing), the platform-quirk canary, the P6 cross-feature regression (an adopted capture survives a real adopter-then-guard pass), a literal 251-record bulk test through the real trigger path, and sweep-entry-point/null/empty/already-deleted no-ops. |
| `EmailThreadGuardServiceTest.cls` | 12 | **Unmodified** | All four scope guards, the Change-2 W1 pair, the competing-broker-thread keep case, structural Task unreachability, and a 251-record bulk pass — kept green **without edits** as the regression guardrail for the guard-4 widening. |
| `EmailMessageTriggerHandlerTest.cls` | 3 | **Amended** | The async plumbing end-to-end through the renamed queueable (insert → trigger → handler → queueable → guard deletion), the queueable's own `execute()` contract, and the queueable-cap skip-not-throw guard driven through a real insert. |
| `EmailMessageSelectorTest.cls` | 2 | **Unmodified** | `selectByIds` returns `ActivityId` (and now, implicitly, `RelatedToId` as part of the same row) plus the null/empty short-circuit. |
| `TaskSelectorTest.cls` (5 of the class's methods) | 5 | **Amended** | The two EAC-guard selector contracts: `selectByIds`'s `CreatedBy.UserType` fingerprint (unchanged), and the three tests for the **replaced** `selectThreadAnchorsByAnchorValues` — matches on either threading key, matches both bracket forms (the P4 fix), and null/empty/blank short-circuits. |

**27 test methods are new** to this feature, across 2 new files. Counting the amended files and the
unmodified guard suite kept green as a regression check, **49 test methods across 6 files** exercise the
EAC capture pipeline as a whole. The org-wide deploy that shipped this feature ran **252/252** tests —
the whole local test suite, not just this feature's share of it.

---

## 🔍 Review History

### Gate 2

The build was reviewed against Gate 2 (`salesforce-code-review`) and returned **APPROVED WITH WARNINGS**,
with two warnings:

- **W1 — order-swap.** `EmailThreadAnchorService.AnchorIndex.resolveOpportunity` originally consulted
  `ThreadIdentifier` (conversation-level identity) before `MessageIdentifier` (exact per-message
  identity). Review flagged that D1 multi-property extraction makes sibling anchors on different
  Opportunities sharing one thread root a routine shape, and that thread-first resolution would adopt a
  reply onto the wrong sibling deal in that shape. Fixed same-day by swapping the consultation order —
  `MessageIdentifier` first, `ThreadIdentifier` as the fallback — and pinned by
  `resolveOpportunity_messageIdentifierWinsOverThreadIdentifier`, which goes red if the two lookups are
  ever swapped back. See "The Resolution Chain," above, for the full reasoning.
- **W2 — destructive-delete manifest.** The mechanical rename of `EmailThreadGuardQueueable` to
  `EmailCaptureQueueable` is, at the metadata-API level, a **new** class alongside an **orphaned** old
  one — a Salesforce org does not delete a component just because a differently-named replacement was
  deployed. Review required the deploy package to carry an explicit destructive-changes entry for
  `EmailThreadGuardQueueable` so the old class is actually removed from the org rather than left behind as
  dead, confusing code. The shipped deploy (`0Afiw000000DIvBCAW`) carries that destructive delete.

Separately from the two warnings, the **platform quirk** (`RelatedToId`'s refused-in-test, works-at-runtime
behaviour, described in full above) required its own **adjudication**: whether a feature whose core write
cannot be exercised end-to-end inside `@isTest` can ship at all. The decision was that it could, on the
strength of the independent runtime proof (spike experiment 3a, against a real capture, twice) — the
mechanism is real even though the test harness cannot observe it directly — provided the test suite was
redesigned to assert the **decision** through an injectable seam rather than assert **committed state**
that the harness can never produce. That decision is what produced the `AdoptionWriter` seam, the
decision-based D4 matrix tests, the two-way quirk canary, and the fixes to the latently vacuous negative
paths — all described in "The Platform Quirk," above.

### The Four Deploy Attempts

The redesigned test suite itself took three further attempts to land cleanly, each surfacing a distinct,
narrow defect in the suite's own bookkeeping rather than in the feature's decision logic:

1. **Attempt 1 — the quirk's first sighting.** The original suite asserted committed state directly
   (`RelatedToId` now equals the target Opportunity, read back after `run(...)`). `RunLocalTests` failed:
   every such assertion hit the platform's `INSUFFICIENT_ACCESS_OR_READONLY` refusal on a test-created
   capture. This failure is what forced the seven-probe spike and experiment 3a, which together produced
   the documented platform quirk above.
2. **Attempt 2 — the recorder double outlived its own test.** After the `AdoptionWriter` seam replaced
   committed-state assertions with recorded-decision assertions, `firstPassRecordsExactlyOneWrite`
   expected exactly one recorded write and observed two. Cause: the `RecordingWriter` double is
   installed on a static, so it is still installed when the **real, trigger-enqueued**
   `EmailCaptureQueueable` runs a second time at `Test.stopTest()`. Because the double never actually
   commits `RelatedToId`, that second pass legitimately re-selects the same, still-unadopted capture and
   the recorder accumulates a second row for it. Fixed by snapshotting every recorder/counter assertion
   into a local **inside** the `Test.startTest()`/`Test.stopTest()` block, immediately after the explicit
   call under test.
3. **Attempt 3 — a counter assertion that could never pass.** Fixing attempt 2 unmasked a second,
   independent defect in the same test method: an assertion that `lastRunDmlStatements == 1` while the
   double was installed. Under the double, real DML never runs, so that counter is **always** zero by
   construction — the assertion was contradictory and could never have passed, but had been hiding behind
   the attempt-2 failure in the same method, which failed first. Fixed by moving the "one write is one
   bulk DML statement" claim to where the **real** writer actually runs (`adopterAt251Captures_isBulkSafe`
   and the quirk canary), and by encoding the full "which counter means what, under which writer" table
   directly in the test class header so the mistake cannot recur silently.
4. **Attempt 4 — shipped.** With both test-bookkeeping defects fixed, the suite passed clean at
   **252/252**, deployed as `0Afiw000000DIvBCAW`, carrying the W2 destructive delete of
   `EmailThreadGuardQueueable` in the same package.

---

## ⚙️ Operational Notes

- **This feature fails soft, and that is a deliberate design consequence of the platform quirk, not an
  oversight.** The adopter's entire failure surface is `allOrNone = false` on one bulk `Database.update`
  plus a `System.debug`. If the runtime write is ever blocked the way the test-context write is blocked,
  the result is **zero adoptions and no durable signal anywhere** — no exception, no failed
  `AsyncApexJob`, nothing queryable after the fact. `EmailThreadAdopterService.lastRunFailureCodes` is
  in-transaction only and does not survive the job; it exists for tests and debugging, not for
  monitoring.
- **The symptom to watch for is "adoptions = 0 across a period in which real EAC captures arrived."**
  From outside the system that is indistinguishable from "nothing needed adopting," which is exactly why
  it must be watched deliberately rather than assumed benign.
- **The recurring L-check is not a one-time launch gate.** The runtime proof that the write commits
  (spike experiment 3a) ran as an **admin**. Production runs the adopter as whichever principal Einstein
  Activity Capture committed under — a different identity entirely — and that residual gap is closed only
  by observing **real adoptions in the live pipeline**, not by re-running the spike. Per the design's L1
  check, this means running the actual queueable against an actual EAC capture on a real two-way thread
  and confirming the Opportunity actually changes — **before** any backfill sweep is widened. Until that
  is observed, "it works at runtime" only means "it worked for an admin."
- **Sweep discipline is unchanged from the guard's own, with the order now doubled in importance.** Both
  services expose `run(Set<Id>)` for one-off anonymous-Apex backfill. **Adopter sweep runs before guard
  sweep, always** — running the guard sweep first over a historical window deletes captures the adopter
  would have rescued, and a deleted `EmailMessage` is not recoverable in Salesforce (the mail survives
  only in the connected mailbox). Chunk at **≤ 1,000 message Ids** per call, and start with
  `LAST_N_DAYS:1` before widening the window. Convergence (D5) makes re-runs and overlapping windows free
  — a re-run over already-adopted rows performs zero DML — so there is no reason to reach for a wide
  window on the first pass.
- **No permission-set provisioning was needed for this feature**, for the identical reason recorded for
  the guard: the adopter's reads are `WITH SYSTEM_MODE` and its service is `without sharing` by design, so
  there is no principal to provision — the automated identity EAC commits under is exactly who this
  feature is built to run as, unprovisioned.

---

## ⚠️ Known Limitations / Open Items

| # | Item | Detail |
|---|---|---|
| L2 | **Adoption happens once; an in-place EAC re-sync will not be re-adopted.** Adoption churns the companion Task (the platform deletes and recreates it, now created by the DML user rather than `AutomatedProcess`), so an adopted capture permanently loses the EAC fingerprint. This is safe in direction — an adopted capture is anchored on its `RelatedToId` record and the guard keeps it on two independent grounds (guard 3 fails, and guard 4 now holds) — but it means if EAC ever re-points `RelatedToId` **in place** on the same row rather than re-inserting the capture, this feature will not notice and will not re-adopt it. Remedy is the same one-off sweep described above. If EAC instead re-**inserts** the capture, the fingerprint is fresh and the feature self-heals normally. |
| Residual | **The admin-vs-EAC-principal gap in the platform-quirk proof is not yet closed by observation.** The runtime commit was proven as an admin (spike experiment 3a); the recurring L-check described in Operational Notes is what closes this, and it had not yet been run against a live, principal-authentic EAC capture as of this writing. |
| Mechanism | **Which variable makes `RelatedToId` refuse writes in `@isTest` (execution context, or test-created-row provenance) remains genuinely undetermined**, not merely undocumented. Do not treat either explanation as settled; the quirk canary test is designed to catch the day this changes. |
| Deferred | **The Lead outbound-half is explicitly out of scope for v1** (D1). It is deferred to v1.1 and gated on an **observed** gap via `EmailMessageRelation` on `ToAddress`/`CcAddress` captures — not built speculatively, because F1's sender-slot-exclusivity finding means it would only sometimes work depending on whether a same-address Contact happens to exist. |
| Inherited | **S1 from the guard (`docs/2026-08-02-eac-thread-guard.md`) is unchanged by this feature**: a companion Task deleted independently of its `EmailMessage` (by something other than the guard's own paired delete) leaves the message permanently un-fingerprintable and therefore permanently un-adoptable and un-deletable by either feature. Narrow, previously accepted, not reopened here. |

None of the above were deploy-blocking — the shipped code passed Gate 2 after the W1/W2 fixes, and the
platform quirk was adjudicated as an accepted, documented characteristic rather than a defect. Recorded
here so a future change to either half of the capture pipeline does not have to rediscover any of it.

---

## 📁 File Locations

| Component | Path |
|---|---|
| Trigger (unchanged) | `force-app/main/default/triggers/EmailMessageTrigger.trigger` |
| Trigger handler (amended) | `force-app/main/default/classes/EmailMessageTriggerHandler.cls` |
| Queueable (new, replaces the deleted `EmailThreadGuardQueueable.cls`) | `force-app/main/default/classes/EmailCaptureQueueable.cls` |
| Shared anchor index (new) | `force-app/main/default/classes/EmailThreadAnchorService.cls` |
| Adopter service (new) | `force-app/main/default/classes/EmailThreadAdopterService.cls` |
| Guard service (amended) | `force-app/main/default/classes/EmailThreadGuardService.cls` |
| Selector — EmailMessage (amended) | `force-app/main/default/classes/EmailMessageSelector.cls` |
| Selector — Task (amended) | `force-app/main/default/classes/TaskSelector.cls` |
| Test classes | `force-app/main/default/classes/{EmailThreadAnchorServiceTest,EmailThreadAdopterServiceTest,EmailThreadGuardServiceTest,EmailMessageTriggerHandlerTest,EmailMessageSelectorTest}.cls`, plus the 5 EAC methods in `TaskSelectorTest.cls` |
| Thread anchors both features match against (written by an earlier feature, read-only here) | `force-app/main/default/objects/Activity/fields/{Thread_Key__c,Inbound_Message_Id__c}.field-meta.xml` |
| Design source | `agent-output/design-requirements-eac-adopter.md` |
| Companion doc — the guard this feature runs alongside | `docs/2026-08-02-eac-thread-guard.md` |

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-02 | Documentation Agent | Initial creation — documents the EAC Thread Adopter (Broker Protection Change 3): why EAC's address-based, thread-blind captures leave deal Opportunities with only half a conversation; the shared-index, adopter-before-guard architecture and why each ordering decision is load-bearing; why `RelatedToId` re-pointing is the only viable adoption channel (`EmailMessageRelation` rejects Opportunity RelationIds; F1 sender-slot exclusivity rules out a Lead-side relation approach); the D2/E1 resolution chain and why MessageIdentifier is consulted before ThreadIdentifier (review finding W1); the full D4 contention policy; the two live guard defects this build surfaced and fixed (P4 bracket asymmetry, P6 partition gap, including the initially-zero-coverage widening); the platform quirk in full (`describe.updateable` lying, the runtime-commits/test-refuses correlation, the `AdoptionWriter` seam, the latent test vacuity fix, and the two-way quirk canary); E1's retirement of the conversion-time carry-forward component; the Gate 2 review (APPROVED WITH WARNINGS — W1 order-swap, W2 destructive-delete manifest), the platform-quirk adjudication, and the four-attempt deploy history; operational notes (fail-soft behaviour, the recurring L-check, sweep discipline); and the known limitations (L2 re-sync gap, the undetermined quirk mechanism, the deferred Lead outbound-half, and the inherited S1 item). |
