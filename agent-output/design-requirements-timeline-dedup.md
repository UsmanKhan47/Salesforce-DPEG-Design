# Design Requirements — EAC / Pipeline Timeline Duplicate Rows

**Request (verbatim):** "Alright, what we can do for duplicate rows, we need to handle it smartly."

**Module:** DPEG Broker Protection — EAC Capture Pipeline
**Org:** `usman-dpeg`
**Date:** 2026-08-04
**Status:** awaiting Gate 1 confirmation. One decision below is the user's to make, not mine.

---

## 0. THE HEADLINE, BEFORE ANYTHING ELSE

**My recommendation deletes EAC's duplicate copy of an inbound broker email. It therefore does
NOT fix "You sent an email" — it removes the only row on the timeline that was captioned
correctly.**

The two complaints are not merely coupled; on inbound mail they are in **direct opposition**:

| | Rows on the Lead timeline for one inbound email | Caption on the surviving row(s) |
|---|---|---|
| Today | 2 (pipeline + EAC) | one wrong ("You sent an email"), one right |
| After this change | 1 (pipeline) | wrong — mitigated only by the `From <Broker>: ` Subject prefix shipped 2026-08-04 |
| Alternative (do nothing) | 2 | unchanged |

There is no third state available. `EmailMessage.Incoming` is the only field the Lightning
timeline reads for direction, a standalone `Task` has no counterpart, and migrating the pipeline
to `EmailMessage` is blocked by two independently fatal, already-measured findings (companion-Task
churn destroys `Inbound_Message_Id__c` idempotency; the sender-slot `LIMIT_EXCEEDED` makes
EmailMessage-on-a-Lead systematically impossible once the broker is also a same-address Contact —
`docs/2026-08-04-broker-attribution-on-pipeline-tasks.md` §"Why the EmailMessage Alternative Was
Rejected").

So the gate question is: **is one row with the right sender and the wrong direction better than two
rows, one of which is right?** I recommend yes, because the duplicate is the thing users are
tripping over and the caption is unfixable at any price this module can pay. But it is a judgement
about what the user sees, and it is theirs to make.

---

## 1. THE RULE (recommended)

> **An EAC capture is deleted when it adds nothing.** Today "nothing" means *nothing relevant* —
> the capture is anchored on no record it lives on (the deployed guard). This change adds the
> second case: *nothing new* — the pipeline has already logged **this exact message**, on **every
> record the capture lives on**.

Stated as the fifth scope guard, in the guard's existing vocabulary:

```
Given a capture that already passes guards 1–3
  (1: related to ≥1 Lead;  2: lives on no record outside {Lead, User};  3: EAC fingerprint)

  KEEP   if it is anchored somewhere it lives   AND is not an exact pipeline duplicate  ← unchanged
  DELETE if it is anchored NOWHERE it lives                                             ← guard, unchanged
  DELETE if it is an EXACT PIPELINE DUPLICATE on EVERY record it lives on               ← NEW
```

Framed positively, this is what EAC is *for* in this module after the change:

> **EAC's job is to supply the half of the conversation the pipeline cannot see — outbound mail,
> and inbound messages that never reached the email service. Anything EAC supplies that the
> pipeline already saw is redundant by construction.**

---

## 2. (a) THE MATCH PREDICATE

### The predicate

A capture `C` is an **exact pipeline duplicate on record R** when all of:

1. `C.Incoming == true`
2. `mid := EmailThreadAnchorService.normalize(C.MessageIdentifier)` is non-null
3. some Broker Protection anchor Task with `normalize(Inbound_Message_Id__c) == mid` is attached
   to `R` (via `WhoId` **or** `WhatId`)

and `C` is **deletable** when it is an exact pipeline duplicate on **every** record in
`relatedLeadIds ∪ {C.RelatedToId}` (that set is non-empty by guard 1).

### Message-ID ONLY. Never Thread-Key. This is the single most important line in the design.

`Inbound_Message_Id__c` is *this message's* RFC Message-ID — globally unique per message by RFC
5322. `Thread_Key__c` is the *conversation root*, deliberately **shared by every message in the
thread** (`InboundEmailActivityService` class header; `PropertyMatchingService.computeThreadKey`).
A thread-key match therefore says "*some* message in this conversation was logged", which is not
duplication — it is the normal state of every reply.

The measured evidence contains the exact row a thread-key predicate would destroy:

- `00Tiw000000G4ajEAC` — Junior's **outbound reply**, EmailMessage `02siw0000006BgjAAE`
  (`Incoming = false`). Its `ThreadIdentifier` is the same conversation root the pipeline stamped
  on `00Tiw000000G3tBEAS`. A thread-key rule would classify it as a duplicate and delete **the only
  representation of outbound mail that exists anywhere in Salesforce** — the pipeline is blind to
  outbound by construction.

The same reasoning kills it for inbound too: a broker's 2nd and 3rd messages in a thread share one
`Thread_Key__c`, so a thread-key rule would delete every EAC copy after the first, including
messages the pipeline never logged.

Message-ID matching handles all of this one-for-one and correctly, and it is exactly what the live
evidence supports: pipeline `00Tiw000000G3tBEAS.Inbound_Message_Id__c` and EAC
`02siw0000006BNNAA2.MessageIdentifier` are **byte-identical**, both bracketed.

### `Incoming == true` is belt-and-braces, and it is worth the one selector field

The Message-ID test alone already protects the outbound reply (its own Message-ID anchors nothing).
The `Incoming` test makes outbound preservation an **invariant of the code** rather than an emergent
property of the data — the pipeline only ever logs inbound mail, so an outbound capture can never
be a pipeline duplicate, and saying so in the predicate means a future data surprise cannot make it
false. Cost: one additional field on `EmailMessageSelector.selectByIds`.

### Bracket handling — reused, not reimplemented

`EmailThreadAnchorService.normalize` is the only bracket handling in this feature family (defect
P4), and `TaskSelector.selectThreadAnchorsByAnchorValues` already binds both bracket forms. The new
predicate is expressed **as a third accessor on the existing `AnchorIndex`**, so it consumes values
that class already normalized. **No new normalization is written anywhere.**

### It costs zero new SOQL

`selectThreadAnchorsByAnchorValues` **already selects `Inbound_Message_Id__c`, `WhoId` and
`WhatId`**, and `EmailThreadAnchorService.index(...)` already iterates every anchor row. Today it
*merges* `Thread_Key__c` and `Inbound_Message_Id__c` into one union set per record, which is what
loses the distinction. The change is to keep the Message-ID half in a **second map** alongside the
existing union — same query, same loop, same normalization pass.

---

## 3. (b) WHICH ROW SURVIVES — and can the answer be "both, one visible"?

**No. "Both, but only one visible" is impossible, and I verified why rather than assuming it.**

### Option 1 — delete EAC's Task **and** EmailMessage ✅ RECOMMENDED

Restricted by the predicate above. Preserves the pipeline row, which is the row that always exists.
Trade-off is §0. Details in the rest of this document.

### Option 2 — delete only the companion Task, keep the EmailMessage ❌ NOT AVAILABLE

The platform links them and the deletes **cascade into each other** — this is a recorded, hard-won
finding, not a theory: `EmailThreadGuardService` gotcha 3 exists precisely because deleting the Task
first makes the subsequent `EmailMessage` delete throw `ENTITY_IS_DELETED`, which is why the guard
uses `Database.delete(..., false)`. So "keep the EmailMessage as data, drop it from the timeline" is
not a state this platform offers. (The inverse — keep the message, null its `ActivityId` — is also
unavailable: `ActivityId` is system-writable only, gotcha 1.)

### Option 3 — suppress our Task's timeline presence (null `WhoId` / `WhatId`) ❌ CATASTROPHIC — VERIFIED, NOT ASSUMED

The prompt asked me to verify this rather than repeat it. **It is true, and it is worse than
stated — it breaks three things, not one:**

1. **Reply routing dies.** `TaskSelector.selectLatestByThreadOrMessageIds` selects `WhatId, WhoId`;
   `PropertyMatchingService.findRecordByReplyHeaders` returns
   `(match.WhatId != null) ? match.WhatId : match.WhoId`. With both null it returns **null**, the
   reply prologue in `ExtractAddressQueueable.routePrologueWithoutCallout` does not fire, and the
   reply falls through the whole routing tree — re-minting a Lead or filing a competing submission
   against the broker's own deal.
2. **The EAC guard starts deleting legitimate deal email.**
   `EmailThreadAnchorService.index` builds `anchorsByRecordId` **exclusively** from
   `recordAnchors(result, anchor.WhoId, …)` and `recordAnchors(result, anchor.WhatId, …)`. A
   detached anchor contributes to no record, so `isAnchoredOn` returns false for every record, and
   the guard's keep test fails for every genuine reply. This is exactly the failure the prompt
   flagged as forbidden — and it arrives via a route that looks unrelated to the guard.
3. **Adoption stops.** `resolveOpportunityFor(anchor)` requires `anchor.WhatId` to be an
   Opportunity. Null `WhatId` ⇒ the adopter resolves nothing, forever.

Only idempotency survives detachment (`selectByInboundMessageId` reads neither field). Two of the
three casualties are silent. **Rejected outright.**

**Conclusion: the pipeline Task is irreducibly visible.** It must exist (idempotency) and it must
stay attached (reply routing, guard, adopter), and attached means rendered. There is no hide
mechanism on `Task`.

### Option 4 — merge (copy body/sender onto EAC's row, or anchors onto EAC's row) ❌ REJECTED

- **Anchors onto EAC's companion Task** — this is the `EmailMessage` migration in disguise. It
  puts the anchors on a **platform-owned row that relation churn deletes and recreates with a new
  Id** (measured; `eac-association-mechanics`), silently taking `Inbound_Message_Id__c` with it, and
  it destroys the guard's structural-unreachability guarantee by making an anchor reachable through
  `EmailMessage.ActivityId`. Already rejected on the same two grounds in the 2026-08-04 doc.
- **Body/sender onto EAC's row** — buys nothing. EAC's row already has the real body and the real
  direction; the only thing ours adds is the `From <Broker>: ` Subject prefix, and writing that onto
  a row the platform may rewrite is churn for a cosmetic gain, while still leaving two rows.

### Option 5 — delete OUR Task once EAC's copy arrives (relocate anchors to `Inbound_Email_Staging__c`) ❌ REJECTED

This is the only design that would fix **both** complaints, so it deserves a real refusal rather
than a dismissal:

- **It violates "never zero rows."** EAC is best-effort and late (the outbound reply took ~3 hours
  and the user reported it missing before it synced). A hand-off design has a window — potentially
  permanent — in which neither row exists.
- **It is self-destroying.** With our anchor Task gone, the capture we chose to keep becomes
  unanchored, and the **guard deletes it on EAC's next re-sync**. Fixing that means moving the
  guard's anchor source to staging as well — but `Inbound_Email_Staging__c` holds **one**
  `Result_Record_Id__c` per email while multi-property routing produces **N** per-record anchors, so
  the per-record precision the guard depends on cannot be rebuilt from staging at all.
- It converts a display annoyance into a change that touches idempotency, reply routing and a
  deployed destructive feature simultaneously — the exact shape the prompt calls categorically
  forbidden.

### Option 0 — do nothing destructive; only make the rows easier to tell apart ⚪ THE ZERO-RISK FALLBACK

Already partly shipped: `From <Broker>: …` (pipeline) vs `Email: …` (EAC). Could be pushed further
(e.g. a `[Logged]` marker). Keeps two rows, keeps the correct caption, costs nothing, risks nothing.
**This is the honest fallback if the user decides the correct caption is worth more than the
deduplication**, and it is also the fallback if the durability experiment in §5 fails.

---

## 4. (c) WHERE THE CODE GOES

**Inside `EmailThreadGuardService`'s existing single pass — as guard 5. No new class, no new
service call in the queueable, no second enqueue.**

`EmailCaptureQueueable.execute` is unchanged:

```
EmailThreadAnchorService.index(messageIds)   ← ONE anchor read; now also indexes Message-ID per record
EmailThreadAdopterService.run(ids, index)    ← 1st, unchanged
EmailThreadGuardService.run(ids, index)      ← 2nd, unchanged call site; the rule lives in its loop
```

**Enqueue count: exactly one per trigger chunk. Confirmed and structurally unchanged** — this
change adds no `System.enqueueJob` anywhere and does not touch `EmailMessageTriggerHandler`. The cap
math protecting EAC's own insert is untouched.

### Why not a third service after the guard?

The reconciler's decision needs four inputs. **Three of them are already computed inside the guard's
loop and nowhere else:**

| Input | Where it already exists |
|---|---|
| capture's `MessageIdentifier`, `RelatedToId` | `EmailMessageSelector.selectByIds` (guard re-reads) |
| pipeline anchor by Message-ID, per record | the shared `AnchorIndex` (additive accessor) |
| EAC fingerprint (companion `CreatedBy.UserType`) | `EmailThreadGuardService.companionTasks` |
| which records it lives on + the {Lead, User} classification | `EmailThreadGuardService.indexRelations` |

A standalone third service would need its own relation read and its own companion read (**+2 SOQL**,
budget 7 → 9), its own two delete statements, and — decisively — **a second copy of the W1
{Lead, User} classification**. That classification is the safety-critical part of this whole design.
Duplicating it is precisely the mistake the P4 bracket defect taught: *"Duplicated normalization is
how two halves drift"* — and here a drift means deleting correspondence off a record the feature
never claimed.

### Why it belongs after the adopter (which it structurally does)

The guard re-reads the messages, so the `RelatedToId` it sees is **post-adoption**. That is required
for correctness: the per-record redundancy test must include the Opportunity the adopter just
adopted onto, or a capture could be deleted from a record where no pipeline row exists.

### Ordering interactions — none

The guard's two delete reasons are **disjoint populations**: reason 1 fires on captures anchored
nowhere, reason 2 on captures anchored (by exact Message-ID) everywhere. No capture can satisfy
both, and they share one bulk delete pair.

### Cost to the class's identity

`EmailThreadGuardService` is already documented as *"the only destructive DML in the capture
pipeline"*. Keeping that single-owner property is worth more than a tidy name. Its header must be
amended to state that it now deletes for **two** reasons, and the "Scope Guards" block extended to
five.

---

## 5. (d) SAFETY ANALYSIS

### 5.1 The invariant that makes this safe — state it first

> **For every record from which this rule removes a capture, a pipeline Task carrying the same
> Message-ID is present on that record.**

This is the delete condition itself, not a consequence of it. So the row count on any timeline goes
**2 → 1, never 1 → 0**. That is a *structural* guarantee, not a probabilistic one, and it is what
distinguishes this rule from every rejected option above.

### 5.2 W1 discipline — satisfied, and then strengthened

W1 established that the guard's *scope of judgement* is not its *scope of delete*, and fixed it with
a {Lead, User} allow-list. The new rule inherits that allow-list **unchanged** (it runs inside
guards 1–3, so a capture also living on a Contact / Account / Opportunity is never a candidate), and
then adds a **strictly stronger** per-record test on top: even among the surviving {Lead, User}
population, deletion requires the pipeline row to be present on **every** Lead the capture landed on
plus the `RelatedToId` record. A capture stapled to two Leads where only one carries the pipeline
Task is **kept**.

**Why the allow-list does not silently make the rule dead:** the sender-slot mechanic
(`eac-association-mechanics`) means an *incoming* capture whose `FromAddress` belongs to a
same-address **Contact** cannot take a relation to a same-address **Lead** at all
(`LIMIT_EXCEEDED`). So the population "duplicate visible on a Lead" and the population "capture
lives only on {Lead, User}" **coincide**. The rule fires exactly where the duplicate is visible.

**Known limitation, stated honestly:** once a Lead converts, the pipeline files its Task on the
**Opportunity** (`InboundEmailActivityService.attachTo` sets `WhatId` for non-Lead/Contact, and sets
exactly one of `WhoId`/`WhatId`, never both), while EAC relates the capture to the broker's
**Contact**. The capture then "lives elsewhere", the rule declines, and **duplicates on converted
deals are not cleaned.** That is the correct call under W1 — the Contact timeline has no pipeline
row to fall back on — but it should be understood as a deliberate scope boundary, not an oversight.
Lifting it later requires giving Contacts thread anchors first, which is the exact ordering the
guard's gotcha 7 already prescribes.

### 5.3 EAC re-sync durability — the open assumption, and how to close it for ~zero cost

If EAC re-materialises a deleted capture on its next sync, any delete-based rule is a treadmill and
the duplicate visibly returns between syncs. The deployed guard has been deleting since 2026-08-02
without visibly looping, which is **evidence, not proof** (nobody has been watching for a specific
re-appearance, and deleted rows leave no trace to audit).

**Cheap verification — run it BEFORE writing any code:**

1. **Pre-flight measurement (anonymous Apex, zero deploy, ~2 queries).** Count `EmailMessage` rows
   whose normalized `MessageIdentifier` equals some `Task.Inbound_Message_Id__c`. This does three
   jobs at once: it proves the match predicate holds on real historical data (not just the one
   measured pair), it sizes the backfill, and it surfaces any forwarding shape in which the
   pipeline's recorded Message-ID differs from the one EAC sees.
2. **Single-row durability probe.** Pick **one** duplicate from that list, delete it by hand
   (anon Apex), record its `MessageIdentifier`, and re-query for it after ≥24h and at least one EAC
   sync cycle. The pipeline Task is untouched throughout, so the experiment is safe by construction.
   - **Absent after 24h** ⇒ EAC does not re-materialise deleted captures. Proceed.
   - **Present again** ⇒ treadmill confirmed.

**Fallback if durability is false:** the treadmill costs 2 bulk DML per re-sync and loses no data,
but it **fails the user's actual goal** — the duplicate reappears. In that case do not ship the
delete: fall back to **Option 0** (§3) and record the finding. Do not attempt to defeat re-sync with
a suppression list — that is a new custom object and a new sync-order dependency for a cosmetic win.

### 5.4 Degrading safely when EAC never delivers

The rule **never touches a pipeline Task**. If no EAC copy ever arrives, nothing happens and the
pipeline row stands alone — which is today's behaviour when EAC is slow, and is exactly right.

**Known limitation L1 — the rule is one-shot at capture time.** The only trigger is EAC's
`EmailMessage` insert. If a capture arrives *before* the pipeline's Task (possible if the pipeline's
queueable is delayed), no anchor exists yet, the capture is kept, and nothing re-examines it. The
remedy is the periodic sweep (§6), not a Task trigger — **a Task trigger would create a second route
to a Task and destroy the structural guarantee** (§5.5). Measured evidence suggests this is rare:
pipeline 05:18:34, EAC 05:19:03.

### 5.5 Structural unreachability of pipeline Tasks — PRESERVED, explicitly

**Yes, my recommendation preserves it.** Three checks:

- **No new route to a Task.** The rule's only Task inputs are (i) the companion via
  `EmailMessage.ActivityId` — the guard's existing single route — and (ii) the shared
  `AnchorIndex`, which is a **read-only decision input whose rows never enter a delete list**
  (unchanged property, already asserted by
  `EmailThreadGuardServiceTest.pipelineAnchorTaskIsStructurallyUnreachable`).
- **No Task DML on anchors.** Zero. The rule deletes only the EAC companion + its EmailMessage,
  identical to the existing guard.
- **No `EmailMessage` is ever created for a pipeline Task.** Nothing in this change writes an
  EmailMessage at all, so `EmailMessage.ActivityId` still cannot point at a pipeline Task.

The `AnchorIndex` additive accessor is worth one explicit note: it makes the index answer a *finer*
question about the same already-read rows. It does not widen the query, does not add a field, and
does not put anchor Ids anywhere they were not already.

### 5.6 Multi-property emails (C-3) — untouched, and provably so

One email routes to N records and logs **N Tasks sharing one Message-ID**, inserted in one DML in
ascending priority so the Id tie-break lands later replies on the deal DPEG owns.

- **The rule never deduplicates pipeline Tasks against each other.** It keys on Message-ID only on
  the **capture** side; the pipeline side is a lookup, never a delete list. The N rows are not
  collapsed.
- **Their Id ordering is untouched** — Ids are assigned at insert and this change performs no Task
  DML on them.
- **The per-record test is the right shape for N.** A capture typically lands on only one of the N
  records (EAC address-matches one Lead); the rule requires the pipeline row on **each** record the
  capture actually lives on, which is satisfiable and correct.
- Note the deliberate asymmetry with `AnchorIndex.resolveOpportunity`, which takes **first-wins**
  across N anchors because `RelatedToId` holds one Id. The new accessor must **not** be first-wins:
  it is a per-record membership test and must see **all** anchors for that record.

### 5.7 Failure posture

The rule sits inside the guard, which is deliberately **unwrapped** so failures surface as a failed
`AsyncApexJob`. That posture is correct here too and must not be changed: a silently disabled
dedupe is a cosmetic regression, but a silently disabled *guard* is the failure mode the whole
feature exists to avoid, and they now share a call stack.

---

## 6. (e) BACKFILL

**Yes — every inbound broker email since EAC was enabled carries a duplicate, so shipping without a
backfill fixes only new mail.**

**No new sweep entry point is required.** Because the rule lives inside the guard,
`EmailThreadGuardService.run(Set<Id>)` already **is** the backfill entry point and gains the new
behaviour for free. Sweep discipline is therefore unchanged:

1. **Order: adopter sweep → guard sweep.** Unchanged and still load-bearing — a guard sweep run
   first deletes captures the adopter would have rescued, and a deleted `EmailMessage` is not
   recoverable in Salesforce.
2. **Chunk ≤ 1,000 message Ids.**
3. **`LAST_N_DAYS:1` first, then widen.**
4. **The first `LAST_N_DAYS:1` chunk IS the durability experiment.** Record the deleted
   `MessageIdentifier` values before running, wait ≥24h and one EAC sync cycle, then re-query. Do
   not widen the window until that check comes back clean. This costs nothing extra and converts the
   open assumption in §5.3 into a measured fact on real production data.
5. Re-runs remain free: the guard is self-healing and the new rule is convergent (a deleted row is
   simply absent next pass).

---

## 7. (f) BLAST RADIUS

### Metadata

**NONE.** Zero new objects, zero new fields, zero picklist values, zero permission-set changes, zero
FlexiPage changes. (This matters more than usual here — profiles are `.forceignore`d, so any new
field would need an FLS grant this repo cannot deploy.)

### Apex touched

| Class | Change | Risk |
|---|---|---|
| `EmailThreadAnchorService` | **Additive**: second map (record → normalized `Inbound_Message_Id__c` set) + one public `AnchorIndex` accessor. Existing `isAnchoredOn` / `resolveOpportunity` / `normalize` untouched. | Low — same query, same loop |
| `EmailMessageSelector.selectByIds` | **Additive**: `+ Incoming`. Extend the DO-NOT-NARROW note. | Low |
| `EmailThreadGuardService` | Guard 5 in the existing loop; header amended to "deletes for two reasons"; scope-guard block 4 → 5 | **Medium — this is the deployed destructive class** |
| `EmailCaptureQueueable` | **None** | — |
| `EmailMessageTriggerHandler` / `EmailMessageTrigger` | **None** | — |
| `TaskSelector` | **None** — already selects `Inbound_Message_Id__c`, `WhoId`, `WhatId` | — |
| `EmailMessageRelationSelector` | **None** | — |
| `InboundEmailActivityService`, `ExtractAddressQueueable`, `PropertyMatchingService`, `PropertyClaimService`, `EmailToLeadService` | **None** | — |

### Governor impact

| Budget | Today | After |
|---|---|---|
| Queueable enqueues per trigger chunk | 1 | **1** |
| `EmailCaptureQueueable.lastRunQueryCount` | 7 (anchor 2, adopter 2, guard 3) | **7** — pinned by `EmailThreadAdopterServiceTest.QUEUEABLE_QUERY_BUDGET`; must stay green unmodified |
| Guard DML statements | ≤2 bulk | **≤2 bulk** — duplicate rows join the existing delete lists |
| Adopter DML | 1 bulk | 1 bulk |

One acknowledged inefficiency: the adopter may write `RelatedToId` on a capture the guard deletes
moments later — **one wasted field write per duplicate**. Running the dedupe first would save it but
would reintroduce destructive-before-constructive ordering and would evaluate the redundancy test
against a pre-adoption `RelatedToId`. Not worth it; recorded, not fixed.

### D4 and convergence

- **D4 `RelatedToId` contention policy: unaffected.** The rule writes no `RelatedToId` and reads it
  only as a decision input. The overwrite table is untouched.
- **Adopter convergence: unaffected.** A deleted capture is absent on the next pass, so a second
  pass still writes zero DML. Limitation L2 ("adopted once", because adoption churns the EAC
  fingerprint) is unchanged.

### Tests

⚠ **`.claude/rules/bulk-test-rule.md`'s per-transaction-singleton exemption does NOT apply** — same
reasoning as the guard and adopter: trigger-driven, EAC batch-inserts. A literal 251-record test is
required.

New / amended:

1. `exactMessageIdDuplicateOnTheSameLead_isDeleted` — the happy path.
2. **`outboundCaptureSharingTheThreadRoot_isKept`** — the headline regression test. Anchor carries
   `Thread_Key__c` = root; capture has `ThreadIdentifier` = root, a **different**
   `MessageIdentifier`, `Incoming = false`. Must survive. This test is the thing that stops a future
   "simplification" to thread-key matching.
3. `inboundMidThreadCaptureThePipelineNeverLogged_isKept` — thread matches, Message-ID does not.
4. `duplicateAlsoLivingOnASecondLeadWithNoPipelineTask_isKept` — the per-record redundancy test.
5. `duplicateLivingOnAContact_isKept` — W1 allow-list still governs.
6. `deliberateSendWithAMatchingMessageId_isKept` — guard 3 fingerprint still governs.
7. `noEacCopy_pipelineTaskSurvives` — degrade-safe; trivial but pins the invariant.
8. `multiPropertyEmail_anchorTasksAreUntouchedAndOrderingPreserved` — assert all N anchor Ids and
   their relative order before/after.
9. Extend `pipelineAnchorTaskIsStructurallyUnreachable` to cover the new decision path.
10. `dedupeAt251Captures_isBulkSafe` — 251 duplicates, one delete pair, query budget still 7,
    asserted on `EmailCaptureQueueable.lastRunQueryCount` (⚠ **never** on `Limits.*` after
    `Test.stopTest()` — stopTest restores pre-test counters and makes the assertion vacuous; and
    snapshot the static into a local **inside** the test block, because inserting an `EmailMessage`
    in a test fires the real trigger and a second queueable will overwrite it).
11. `EmailThreadAnchorServiceTest`: message-Id anchoring is record-scoped and bracket-agnostic.

⚠ **Expect existing `EmailThreadGuardServiceTest` fixtures to need triage.** Any current
"anchored ⇒ kept" test that anchors via `Inbound_Message_Id__c` equal to the capture's
`MessageIdentifier`, on the related Lead, is by the new definition an exact duplicate and will now
assert deletion. Those fixtures should be re-pointed to `Thread_Key__c` anchoring (which is what
"a reply in an anchored thread" actually looks like) rather than having the rule weakened to keep
them green. **This triage is a required, named work item — not an incidental fix.**

### Documentation (§6 of ARCHITECTURE.md — same PR)

- `ARCHITECTURE.md` §2 "EAC CAPTURE PIPELINE": the guard's row gains the second delete reason; the
  scope-guard list goes 4 → 5; the anchor service's row notes the third accessor.
- `EmailThreadGuardService` / `EmailThreadAnchorService` class headers.
- New `docs/2026-08-04-eac-timeline-dedup.md`.
- `docs/2026-08-04-broker-attribution-on-pipeline-tasks.md` §"The Adjacent Open Decision" →
  resolved, with the caption trade-off recorded as an accepted decision.

---

## 8. WORK SPLIT

### 🔵 ADMIN WORK (`salesforce-admin`)

**None.** No metadata of any kind is required.

### 🟢 DEVELOPMENT WORK

**Step 0 — DevOps / anon-Apex, BEFORE any code (§5.3):** the match-rate measurement script and the
single-row durability probe. **Gate the rest of the work on the probe coming back clean.**

**Step 1 — `salesforce-developer`** (standard Apex; no integration, no LDV, no new architecture —
this is a decision added to an existing pass):

1. `EmailThreadAnchorService` — additive per-record Message-ID map + one `AnchorIndex` accessor.
   Reuse `normalize`; add no bracket handling.
2. `EmailMessageSelector.selectByIds` — add `Incoming`; extend the DO-NOT-NARROW note.
3. `EmailThreadGuardService` — guard 5 inside the existing loop; rows join the existing delete
   lists; amend the header (two delete reasons, five scope guards, the 2→1 invariant, the converted-
   deal limitation, L1 one-shot).
4. Do not touch `EmailCaptureQueueable`, `EmailMessageTriggerHandler`, `TaskSelector`,
   `EmailMessageRelationSelector`, the adopter, or any Broker Protection pipeline class.

**Step 2 — `salesforce-unit-testing`:** the 11 tests in §7, plus triage of the existing guard suite.

**Step 3 — `salesforce-code-review`**, then **DevOps**: deploy, then the staged backfill of §6
(adopter → guard, `LAST_N_DAYS:1` first, durability re-check before widening).

---

## 9. WHAT I NEED FROM THE USER AT GATE 1

**One decision, stated plainly:**

> This removes the duplicate by deleting EAC's copy of inbound broker emails. The surviving row is
> the pipeline's, which shows **`From <Broker>: <subject>`** but is captioned **"You sent an
> email"**. EAC's correctly-captioned copy is the one being deleted, and that caption cannot be
> reproduced on our row at any price this module can pay.
>
> - **Proceed** → one row, right sender, wrong direction word.
> - **Option 0 instead** → keep both rows, keep the correct caption, make them visually distinct.
>   Zero risk, zero deletes.

Secondary, lower-stakes confirmations:

- **Outbound replies stay.** EAC is the only source of outbound mail; they are never deleted.
- **Converted deals keep their duplicates** for now (§5.2) — acceptable, or should it be scoped in?
- **Backfill** of historical duplicates — in scope, or new mail only?
