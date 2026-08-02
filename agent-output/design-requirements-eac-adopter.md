# Design Requirements — EAC THREAD ADOPTER (Broker Protection Change 3)

**Date:** 2026-08-02
**Status:** Gate 1 — awaiting user confirmation. Nothing built.
**Routing recommendation:** `salesforce-technical-architect` (cross-feature contention with a live
destructive feature, standard-object trigger path, external capture system, governor/limit math).
**Companion docs:** `docs/2026-08-02-eac-thread-guard.md` (the mirror feature),
`docs/2026-07-24-broker-protection.md` (the pipeline that writes the anchors),
`docs/2026-07-31-competing-broker-no-lead.md`, `ARCHITECTURE.md` §2.
**Do not overwrite:** `agent-output/design-requirements.md` (Broker Protection D1–D18) — this is a
separate document.

---

## 🎯 WHAT THE USER REQUESTED

Build the **EAC Thread Adopter** — the mirror image of the deployed EAC Thread Guard.

- The guard **deletes** Lead-related EAC captures whose thread matches no Broker Protection anchor.
- The adopter **associates** anchored captures onto the deal record EAC failed to reach.

Driving requirement, in the user's words: **full two-way deal email threads visible on deal records**,
because "majority of the discussion will happen in opportunity." EAC is the only system that sees the
**outbound** half of a thread — the pipeline only ever receives inbound mail via the forwarding address
— so adopting EAC captures is the only route to a complete thread on a deal.

Nothing else is in scope. No new UI, no new objects, no reporting, no notification, no change to the
inbound pipeline's routing tree.

---

## 🔎 PREMISE VERIFICATION (code read 2026-08-02, before designing)

Per the standing "verify the premise before designing" rule, every load-bearing claim below was read
out of the repo rather than assumed.

| # | Finding | Evidence |
|---|---|---|
| P1 | **Opportunity anchors already exist — but only post-conversion.** Branch (a) REPLY, branch (b) REPEAT and branch (d) COMPETING all call `PropertyMatchingService.resolveLiveRecord(...)`, which returns `ConvertedOpportunityId` for a converted Lead; `InboundEmailActivityService.attachTo` then puts a non-Lead/Contact Id in **`WhatId`**. So a pipeline Task on an Opportunity, carrying both anchors, is a shape that already occurs. | `ExtractAddressQueueable.cls:523,761,787,850`; `PropertyMatchingService.cls:454-471`; `InboundEmailActivityService.cls:241-251` |
| P2 | **Pre-conversion anchors live on `Task.WhoId = Lead`.** Whether standard conversion repoints that `WhoId` to the Contact (and whether it sets any `WhatId`) is **not determined anywhere in this repo** and is the single load-bearing unknown — see **E1** below. | `InboundEmailActivityService.attachTo`; no conversion-activity assertion exists in `LeadConvertServiceTest` / `LeadConvertTriggerHandlerTest` |
| P3 | **F5 (bracket asymmetry) is confirmed by code, not just by the spike.** `Task.Thread_Key__c` is written through `computeThreadKey`, whose every return path passes through `stripAngleBrackets` → **UNBRACKETED**. `Task.Inbound_Message_Id__c` is written from `staging.Message_Id__c`, which is `firstHeader(email,'message-id')` — the **raw** header value → **BRACKETED**. | `PropertyMatchingService.cls:385-394, 514-520`; `EmailToLeadHandler.cls:243-253`; `InboundEmailActivityService.cls:206-208, 224-225` |
| P4 | **Consequence of P3, and it is a latent defect in the LIVE guard.** `EmailThreadGuardService.isAnchored` compares raw EAC identifiers (bracketed) against both anchors. `MessageIdentifier ↔ Inbound_Message_Id__c` matches (both bracketed). **`ThreadIdentifier ↔ Thread_Key__c` can never match** (bracketed vs stripped). The guard is running on one of its two legs; a reply whose thread root was logged as a *mid-thread* Task (root under `Thread_Key__c` only) is currently **deleted as unanchored**. | `EmailThreadGuardService.cls:418-429`; `TaskSelector.cls:512-523` |
| P5 | **The churn cascade (F3) is bounded and cheap.** The only `Task` trigger in the repo is `TaskRollupTrigger` → `TaskRollupTriggerHandler`, which collects `Transaction_Deal__c` and returns without any SOQL/DML when the set is empty. An EAC companion Task has no `Transaction_Deal__c`, so churn is a no-op. `OnboardingTaskRollupService` is **controller-invoked, not trigger-invoked**, so it is not on this path. | `triggers/TaskRollupTrigger.trigger`; `TaskRollupTriggerHandler.cls:47-68`; `ARCHITECTURE.md` §2 |
| P6 | **The guard cannot see `RelatedToId` at all.** Guard 2 ("lives elsewhere") reads `EmailMessageRelation` only, and `EmailMessageSelector.selectByIds` does not select `RelatedToId`. An adopted capture is therefore, today, **still deletable by the guard seconds later**. | `EmailThreadGuardService.cls:306-320`; `EmailMessageSelector.cls:68-73` |

**P6 is the finding that shapes the whole design:** without a guard amendment, the adopter's output is
destroyed by the guard. The two features do *not* cleanly partition the space as first assumed.

---

## 🧭 DESIGN DECISIONS (D1–D7)

### D1 — Scope: **Opportunity-only for v1.** Lead outbound-half is deferred.

Recommended answer: adopt onto **Opportunity via `EmailMessage.RelatedToId`**, both thread directions
(inbound and outbound captures). No `EmailMessageRelation` inserts in v1 at all.

Rationale:

1. It is the user's stated priority ("majority of the discussion will happen in opportunity").
2. **The Lead gap is mostly already closed.** A pre-conversion broker Lead carries the broker's address,
   so EAC natively relates captures to it, and the guard already *keeps* those (anchored). Lead **inbound**
   is independently covered by pipeline Tasks. The residual Lead gap is narrow.
3. **F1 makes the remaining Lead-incoming case structurally impossible.** When a same-address Contact
   exists, the sender slot is taken and no `RelationType` succeeds. A v1 that promised Lead adoption would
   deliver it only sometimes, decided by whether a Contact happens to exist — a non-explainable behaviour.
4. **Every relation insert costs churn (F3).** Spending permanent fingerprint loss on a
   largely-redundant gap is a bad trade.

Deferred to v1.1, gated on an **observed** gap (not a suspected one): Lead outbound-half via
`EmailMessageRelation` on `ToAddress`/`CcAddress` captures only.

### D2 — Anchor source: **resolve thread → Opportunity through the anchor Task itself, reusing `resolveLiveRecord`; add conversion-time anchor carry-forward only if E1 shows the Lead pointer is lost.**

This is the load-bearing question, so the answer is stated as a decision **plus the experiment that
picks its branch** — not as an assumption.

**Resolution chain (the adopter's only way to name an Opportunity):**

1. Anchor Task's `WhatId` is an **Opportunity** → that Opportunity. *(Exists today for every
   post-conversion pipeline email — P1.)*
2. Anchor Task's `WhoId` is a **Lead** → `PropertyMatchingService.resolveLiveRecord(leadId)` →
   `ConvertedOpportunityId`. *(Reuses a proven, tested resolver; do not write a second one.)*
3. Anchor Task's `WhoId` is a **Contact**, or the Lead is unconverted, or resolution yields no
   Opportunity → **no adoption.** Fail closed. A Contact can front many deals; guessing produces exactly
   the wrong-deal lie the guard exists to delete.

**Multi-anchor conflict is real and must be resolved deterministically.** One Message-ID can carry N
Tasks across N records (multi-property routing, `InboundEmailActivityService.logInboundEmail(List<Id>…)`).
`RelatedToId` holds one Id. **Reuse the pipeline's existing tie-break rather than inventing one:**
`ORDER BY CreatedDate DESC, Id DESC` — the same rule as `TaskSelector.selectLatestByThreadOrMessageIds`,
which exists precisely because the epilogue inserts Tasks in ascending priority so the deal DPEG owns
gets the highest Id.

**E1 decides whether carry-forward is required.** If conversion repoints anchor `WhoId` Lead → Contact
without setting `WhatId`, chain step 2 evaporates and **every deal converted before its first
post-conversion inbound email becomes unresolvable** — i.e. the feature would be dead for exactly the
records the user cares about. In that case v1 must also include:

> **Anchor carry-forward at conversion.** In `LeadConvertTriggerHandler`, capture the converting Leads'
> own anchor Task Ids in a **before-update** pass (`WhoId IN :leadIds AND (Thread_Key__c != null OR
> Inbound_Message_Id__c != null)`), then in the existing **after-update** pass stamp
> `WhatId = ConvertedOpportunityId` on exactly those Task Ids. Precise scoping matters: querying by the
> Contact after migration would sweep in *other* deals' threads for the same broker. Plus a one-off
> backfill for already-converted deals (D6).

Carry-forward **adds no `WhoId` change, no anchor-value change, and creates no `EmailMessage` link**, so
the guard's structural-unreachability guarantee is untouched.

### D3 — Architecture: **one queueable, two services, sharing ONE anchor read. Adopter runs FIRST.**

```
EmailMessageTrigger (unchanged, one line)
  └─ EmailMessageTriggerHandler.afterInsert()   ← enqueue count UNCHANGED (see below)
       └─ EmailCaptureQueueable  (renamed from EmailThreadGuardQueueable)
            ├─ EmailThreadAnchorService.index(messageIds)   ← ONE anchor read, ONE normalization
            ├─ EmailThreadAdopterService.run(index)         ← 1st: RelatedToId writes
            └─ EmailThreadGuardService.run(index)           ← 2nd: deletes (unchanged semantics)
```

- **One queueable, not two.** The handler's `Limits.getQueueableJobs()` math is a live, documented,
  load-bearing property that protects EAC's own insert from rollback. A second enqueue per chunk halves
  the guard's throughput ceiling (cap reached at ~5,000 captured rows instead of ~10,000) for no
  correctness gain. Enqueue count must stay at exactly one per trigger chunk.
- **Adopter first.** Adoption is what makes an Opportunity-anchored capture visibly anchored; running the
  guard first would delete the capture before the adopter ever sees it (P6 scenario: capture is related
  to an unrelated same-address Lead, anchored only on the Opportunity thread).
- **Failure isolation without a second transaction:** the adopter's call is wrapped in its own
  `try/catch` inside the queueable's service call chain, and its DML is `Database.update(..., false)`,
  mirroring the guard's `allOrNone = false` posture. An adopter failure must never roll back the guard.
- **Shared anchor read — this is the point of the refactor.** `EmailThreadAnchorService` performs the
  single anchor query **by anchor value** (both External-Id text fields are indexed, so it is selective
  without record scoping), normalizes brackets **once**, and returns an index consumed with opposite
  polarity by both services. This makes the F5 normalization identical **by construction** rather than by
  convention — duplicating it is how the two halves silently drift apart.
- **Rename `EmailThreadGuardQueueable` → `EmailCaptureQueueable`.** A class named "guard" that also
  adopts is a trap for the next reader, and this repo names things for what they are. Mechanical: new
  class + one-line handler change + delete old. The §5.3 sweep entry point is the **service**, so it is
  unaffected. *(If the team prefers zero rename churn, keeping the old name and re-documenting it is an
  acceptable fallback — this is the one reversible choice in the document.)*

### D4 — EAC-`RelatedToId` contention: **overwrite when anchor truth resolves an Opportunity and the current value is null or an Opportunity. Never clear. Never touch a deliberate send.**

| Current `RelatedToId` | Anchor resolves an Opportunity | Action |
|---|---|---|
| `null` | yes | **Write** it |
| an **Opportunity**, different from anchor truth | yes | **Overwrite** |
| an **Opportunity**, equal to anchor truth | yes | **No-op** (convergence) |
| a **non-Opportunity** (Account, Case, custom, …) | yes | **Leave alone**, count it, do not adopt |
| anything | no | **Leave alone** — never write null |

Rationale — and this is the crux of the whole feature:

- **EAC's `RelatedToId` is the same class of lie the guard deletes.** F2 measured both live Botanica
  captures arriving with `RelatedToId` = an Opportunity inferred **thread-blindly through the matched
  Contact**. The adopter holds strictly better evidence: an RFC-header identity match against an anchor
  the pipeline itself wrote. Address-inference must lose to header-identity, exactly as it does in the
  inbound pipeline (`routePrologueWithoutCallout`: "a header match is PROOF… a classifier's read of the
  body is an opinion"). Leaving a wrong Opportunity in place is **worse** than showing nothing: it is a
  plausible-looking email on the wrong deal.
- **Non-Opportunity current values are left alone** — the allow-list direction the guard's W1 fix
  established. An unanticipated object type falls through to "don't touch," not to "overwrite."
- **The EAC fingerprint is required** (companion Task `CreatedBy.UserType == 'AutomatedProcess'`),
  mirroring guard 3. A composer/Agentforce send's `RelatedToId` was chosen by a human; overwriting it
  would override explicit human intent. See D5 for the consequence.

### D5 — Idempotency: **adoption is CONVERGENT, so there is no rollback story to write.**

The target state is a **pure function** of (thread anchors, capture identifiers): re-running recomputes
the same Opportunity and writes only on difference. Re-runs, EAC re-syncs, partial failures and
overlapping backfill windows all converge to anchor truth. Nothing needs undoing, which is what makes
**F4 (revert asymmetry) a non-issue**: the adopter only ever moves state *toward* anchor truth and never
reverts, so the companion Task's stale `WhatId` after a revert is a state this feature never produces.

Corollaries that must be written into the class header as invariants:

1. **F3 fingerprint loss is one-way and accepted.** Any adoption churns the companion Task (new Id,
   created by the DML user, never `AutomatedProcess`), so an adopted capture permanently loses the EAC
   fingerprint. Direction is safe — an adopted capture is anchored and would be kept anyway — but it
   means **a capture is adopted once**. If EAC ever re-points `RelatedToId` **in place** on an existing
   row (see **L2**), the adopter will not re-adopt it. Known limitation, same shape as the guard's S1;
   remedy is the one-off sweep. If EAC instead re-**inserts** the capture, the fingerprint is fresh and
   the feature self-heals normally.
2. **The forward propagation is free and is the whole visible effect.** F4 implies that setting
   `RelatedToId` propagates to the companion Task's `WhatId` (which is why reverting leaves it stale) —
   that Task is what renders on the Opportunity's Activity timeline. Confirm as **E2**; if it does *not*
   propagate, the feature needs a Task write and the design must be revisited before build.
3. **The adopter performs NO Task DML, ever.** Its only DML is `EmailMessage.RelatedToId`. Task churn is
   the platform's doing, not ours. This is what preserves the guard's structural guarantee.

### D6 — Backfill: **same `run(Set<Id>)` entry point, same gated/narrow-first discipline, adopter sweep BEFORE guard sweep.**

- The adopter exposes `run(...)` for a one-off anonymous-Apex sweep, exactly as the guard does.
- **The §5.3 chunking math still binds and now binds harder.** The relation read is unchanged (~3 rows
  per message → ~16–17k messages against the 50k SOQL-row cap), and the shared anchor read adds rows on
  top. The adopter also adds **DML rows** (one per adopted message; 10k cap) — bulk them into a **single
  `update` statement** so the 150-statement cap is never in play.
- **Recommended sweep shape:** `LAST_N_DAYS:1` first, verify, then widen; chunk at **≤ 1,000 message
  Ids** per `run()` — well inside every cap, and small enough that the churn's Task delete/insert volume
  stays observable.
- **Order the sweeps adopter → guard**, matching live order. Running the guard sweep first over a
  historical window would delete captures the adopter would have rescued, and deletion is not
  recoverable in Salesforce (the mail survives only in the mailbox).
- If **E1** forces anchor carry-forward, a second one-off backfill stamps `WhatId` on already-converted
  deals' anchor Tasks. It must run **before** the adopter sweep.

### D7 — Permission/context: **identical to the guard. `SYSTEM_MODE` reads, `without sharing` service, system-mode DML, no permission set.**

- New/amended selector reads are `WITH SYSTEM_MODE` for the guard's exact reason: the running principal
  is whichever identity EAC committed under, holds none of this repo's permission sets, and `USER_MODE`
  **throws** rather than degrades — silently disabling the feature.
- `EmailThreadAdopterService` is `without sharing`, justified in its header: it must adopt onto **every**
  Opportunity the anchors resolve, not the subset the automated principal can see. A `with sharing`
  version produces the half-complete threads the feature exists to prevent.
- DML is plain system-mode `Database.update(..., false)`. PMD's `ApexCRUDViolation` is **accepted, not
  overlooked**, on the guard's recorded grounds; the blast radius is closed by construction (only
  EAC-fingerprinted captures whose thread the pipeline itself anchored, and only into a resolved
  Opportunity).
- **No permission set ships with this feature**, and that is a consequence of the above, not an oversight.

---

## 🔵 ADMIN WORK (salesforce-admin)

**No admin work required for this request.** No new objects, no new fields, no permission sets, no page
layout changes. The Opportunity Activity timeline already renders companion Tasks.

---

## 🟢 DEVELOPMENT WORK (salesforce-technical-architect)

### New components

| Component | Layer | Responsibility |
|---|---|---|
| `EmailThreadAnchorService.cls` | Service (read-only, no DML) | The **single** anchor read + the **single** bracket normalization. Queries anchor Tasks by anchor value, normalizes every identifier (strip `<>`, trim), and returns an `AnchorIndex`: anchors keyed by record Id (`WhoId`/`WhatId`) **and** the resolved target Opportunity per identifier (D2 chain + `CreatedDate DESC, Id DESC` tie-break). Consumed by both the adopter and the guard. |
| `EmailThreadAdopterService.cls` | Service (`without sharing`) | The adopt decision + the only `RelatedToId` DML. Applies D4's policy table. No Task DML, ever. |
| `EmailCaptureQueueable.cls` | Queueable | Replaces `EmailThreadGuardQueueable`. Thin: build index → adopter (try/catch) → guard. No SOQL, no DML. |

### Amended components

| Component | Change | Why it is safe |
|---|---|---|
| `EmailMessageSelector.selectByIds` | **Add `RelatedToId`** to the field set | Widening only; the "DO NOT NARROW" contract is preserved. Both services need it. |
| `TaskSelector` | Replace `selectThreadAnchorsByWhoIds` with `selectThreadAnchorsByAnchorValues(Set<String>)` returning `Id, WhoId, WhatId, Thread_Key__c, Inbound_Message_Id__c`, `WITH SYSTEM_MODE`, `ORDER BY CreatedDate DESC, Id DESC`. Query must bind **both** bracket forms of every candidate identifier (P3/P4). | Still selective — both anchor fields are indexed External Ids. Feeds **keep/adopt decisions only**; its rows are never added to any delete list, so the guard's structural guarantee holds verbatim. |
| `EmailThreadGuardService` | (a) `anchorsFor` replaced by the shared index; (b) **guard 4 widened** from "anchored on a related Lead" to **"anchored on any record it lives on"** — related Leads **∪** the `RelatedToId` record; (c) bracket normalization via the shared matcher (fixes P4). | **Every change is keep-biased** — each one can only cause the guard to delete *fewer* messages, never more. The four scope guards' structure, the `{Lead, User}` allow-list, the delete route via `ActivityId`, and `without sharing` are all untouched. All 12 existing guard tests, including `pipelineAnchorTaskIsStructurallyUnreachable`, must stay green **unmodified**. |
| `EmailMessageTriggerHandler` | One line: enqueue `EmailCaptureQueueable`. **Enqueue count stays at one per chunk.** | The queueable-cap guard and its rationale are unchanged. |
| `LeadConvertTriggerHandler` / `LeadConvertService` | **Conditional on E1 only** — before-update capture of the converting Leads' anchor Task Ids, after-update `WhatId = ConvertedOpportunityId` stamp. | Adds no anchor-value change and no `EmailMessage` link. Bulk-safe: one selector read + one update. |

### Explicit non-goals (do not build these)

- No `EmailMessageRelation` inserts (D1).
- No custom field on `EmailMessage` to mark adoption — convergence (D5) makes a marker unnecessary.
- No new custom object, no thread registry.
- No extension of the **guard's** judged/delete scope beyond Leads.
- No change to the inbound routing tree, the LLM prompt, or `InboundEmailActivityService`'s write contract.

---

## 🧪 VERIFICATION PLAN

### Must run BEFORE build — these decide the design

| # | Question | How | If it comes back the other way |
|---|---|---|---|
| **E1** | Does lead conversion repoint pipeline anchor Tasks (`WhoId` Lead → Contact)? Does it set any `WhatId`? | **Apex-testable, not a live-only guess**: create a Lead + anchor Task, `Database.convertLead`, re-query the Task's `WhoId`/`WhatId`. Throwaway test or anon script on `usman-dpeg`. | If `WhoId` survives as the Lead → carry-forward is optional and should be **dropped** from v1 (chain step 2 works). If it becomes the Contact → carry-forward is **mandatory** or the feature is dead for converted deals. |
| **E2** | Does updating `EmailMessage.RelatedToId` propagate to the companion Task's `WhatId` (i.e. does the email actually appear on the Opportunity timeline)? | Anon Apex on a real capture; F4 strongly implies yes. | If no → the visible effect requires a Task write, which breaks D5's "no Task DML" invariant. **Stop and re-design** rather than adding a Task write quietly. |
| **E3** | Confirm P4 in live data: does any deployed anchor pair have `Thread_Key__c` unbracketed while the capture's `ThreadIdentifier` is bracketed? | Query the two anchor fields on real pipeline Tasks + a real capture. | If brackets already agree, the normalization is still correct but the "guard running on one leg" finding downgrades from defect to hardening. |

### Live-verifiable only (cannot be proven by any test)

| # | Item |
|---|---|
| **L1** | A real EAC capture of an **outbound** reply carries `ThreadIdentifier`/`MessageIdentifier` equal to a pipeline anchor. **This is the feature's entire premise** — if EAC rewrites identifiers, nothing else matters. Verify on one real two-way thread before widening the backfill. |
| **L2** | Whether EAC ever re-points `RelatedToId` **in place** on re-sync (drives the D5 known limitation). |
| **L3** | Whether EAC associates captures to **converted** Leads at all. If it does, the guard may already be deleting legitimate post-conversion replies whose Lead lost its anchors — a pre-existing exposure this design's guard-4 widening partially closes. |
| **L4** | Churn volume at real EAC batch size: Task delete/insert counts and the `TaskRollupTrigger` no-op (P5 says it short-circuits; confirm at volume). |
| **L5** | The adopted email's placement on the Opportunity timeline as a deal-driver persona sees it — **an admin smoke test proves nothing about visibility**, per the standing FLS lesson. |

### Test plan (Apex)

- **251-record bulk test is REQUIRED**, per the guard's precedent — this is a trigger-path addition and
  EAC batch-inserts. One bulk `EmailMessage` insert, one pass, assertions on adopted count and on a
  constant query/DML budget. The singleton exemption in `.claude/rules/bulk-test-rule.md` does **not**
  apply.
- **Governor-headroom assertions on counters captured inside the async context** — never
  `Limits.getQueries()` after `Test.stopTest()` (silently vacuous). Follow
  `ExtractAddressQueueable.lastRunQueryCount` precedent. Budget: anchor read, message read, relation
  read, companion read, resolution read — **constant, not per-message**.
- **Fingerprint test seam** mirroring `EmailThreadGuardService.treatAllAsMaterialized` — the
  `AutomatedProcess` fingerprint is unreproducible in tests, so the adopt path is otherwise unreachable.
- **D4 policy matrix**: one test per row of the table, including the "non-Opportunity current value is
  left alone" and "never write null" rows.
- **Convergence test**: run twice, assert the second pass performs **zero** DML.
- **Cross-feature test (the P6 regression)**: an Opportunity-anchored capture also related to an
  unrelated same-address Lead survives a full adopter→guard pass. This test is the reason the guard
  amendment exists; without it the feature silently regresses to nothing.
- **Bracket-asymmetry test**: an anchor stored unbracketed (`Thread_Key__c`) matched against a bracketed
  `ThreadIdentifier` — must match after normalization. Goes red if anyone removes the normalizer.
- All 12 existing `EmailThreadGuardServiceTest` methods stay green **unmodified**; `TaskSelectorTest`'s
  4 EAC methods are updated for the replaced selector method.

---

## 🔗 EXECUTION ORDER

1. **E1 + E2 + E3** — cheap, decisive, and E1 changes the component list. Nothing is built first.
2. **`EmailThreadAnchorService`** + the `TaskSelector` / `EmailMessageSelector` amendments — everything
   else depends on the shared index.
3. **Guard amendments** (shared index, guard-4 widening, normalization) with the existing suite green.
4. **`EmailThreadAdopterService`** + **`EmailCaptureQueueable`** + handler rewire.
5. **Anchor carry-forward** — *only if E1 requires it.*
6. **Unit testing → code review → deploy.** Then **L1 on one real thread** before any backfill.
7. **Backfill**, narrow-first: carry-forward backfill (if any) → adopter sweep → guard sweep.

---

## 📄 ARCHITECTURE.md UPDATES (in scope, same PR)

- §2 **Key Apex Services**: add `EmailThreadAnchorService` and `EmailThreadAdopterService` rows; amend the
  `EmailThreadGuardService` row (guard 4 now "anchored on any record it lives on"; shared anchor read).
- §2 **EAC Thread Guard subsection**: rename to cover both halves; record adopter-before-guard ordering
  and why; the `RelatedToId` contention policy; the F3 fingerprint-loss invariant; the bracket
  normalization and the P4 defect it closes; the one-enqueue-per-chunk constraint.
- §2 `TaskSelector` mixed-mode note: the replaced `SYSTEM_MODE` anchor method and its by-value shape.
- `.claude/rules/bulk-test-rule.md`: no change — the guard's trigger-path precedent already governs.
- §1: **no change** — no new objects or fields.

---

## ⚠️ RISKS

| # | Risk | Mitigation |
|---|---|---|
| R1 | **E1 comes back "anchors migrate to Contact"** → v1 grows a conversion-path change and a second backfill. | Run E1 first; it is a 20-minute experiment that resizes the whole feature. |
| R2 | **Guard regression.** Every guard change is keep-biased, but "keeps more" still changes live behaviour: unrelated conversations that the bracket bug was deleting will now… still be deleted (they are unanchored either way). The behaviour change is confined to genuinely anchored mid-thread replies. | The 12 unmodified guard tests plus the new P6 cross-feature test. |
| R3 | **Adoption onto the wrong Opportunity** — the exact lie the guard deletes. | Fail-closed chain (D2 step 3), fingerprint requirement, deterministic tie-break reusing the pipeline's own rule, and "never write null". |
| R4 | **L1 falsifies the premise** (EAC identifiers don't match pipeline anchors on outbound captures). | Verify on one real thread before the backfill; the feature is a no-op rather than a hazard if it fails. |
| R5 | **Backfill blast radius** — churn on thousands of captures in one anonymous-Apex run. | ≤ 1,000 Ids per `run()`, `LAST_N_DAYS:1` first, adopter before guard, convergence makes re-runs free. |

---

## 📝 PROMPT FOR salesforce-technical-architect

```
Build the EAC Thread Adopter per agent-output/design-requirements-eac-adopter.md.

Read first: ARCHITECTURE.md §2 (EAC Thread Guard subsection + Key Apex Services),
EmailThreadGuardService.cls, EmailMessageTriggerHandler.cls, EmailThreadGuardQueueable.cls,
EmailMessageSelector.cls, TaskSelector.cls, InboundEmailActivityService.cls,
PropertyMatchingService.cls (computeThreadKey / findRecordByReplyHeaders / resolveLiveRecord),
docs/2026-08-02-eac-thread-guard.md.

STEP 0 — run experiments E1, E2, E3 (design §Verification) and report the results BEFORE
writing production code. E1 decides whether the anchor carry-forward component is in scope.

Then build, in the order of design §Execution Order:
  • EmailThreadAnchorService — the single anchor read (by anchor value, WITH SYSTEM_MODE) and the
    single bracket normalization; returns an index of anchors by record Id plus the resolved target
    Opportunity per identifier (resolution chain D2, tie-break CreatedDate DESC, Id DESC).
  • TaskSelector: replace selectThreadAnchorsByWhoIds with selectThreadAnchorsByAnchorValues
    (Id, WhoId, WhatId, Thread_Key__c, Inbound_Message_Id__c; bind BOTH bracket forms).
  • EmailMessageSelector.selectByIds: add RelatedToId (widen only).
  • EmailThreadGuardService: consume the shared index; widen guard 4 to "anchored on any record it
    lives on" (related Leads ∪ the RelatedToId record). Do NOT touch the four-guard structure, the
    {Lead, User} allow-list, the ActivityId-only delete route, or `without sharing`. All 12 existing
    guard tests must pass UNMODIFIED.
  • EmailThreadAdopterService (`without sharing`) — D4 policy table exactly; the ONLY DML is
    EmailMessage.RelatedToId via Database.update(..., false). NO Task DML, ever.
  • EmailCaptureQueueable (replaces EmailThreadGuardQueueable): index → adopter (own try/catch) →
    guard. Handler enqueues exactly ONE job per trigger chunk — do not change the cap math.
  • Anchor carry-forward in the Lead-convert path ONLY if E1 requires it.

Constraints: layering per .claude/rules/apex-layering-rule.md (all SOQL in selectors, no logic in
the trigger or queueable); a literal 251-record bulk test IS required (trigger path, EAC
batch-inserts — the singleton exemption does not apply); governor assertions on counters captured
INSIDE the async context; API 67.0; TestDataFactory; Assert.* style.

Do NOT build: EmailMessageRelation inserts, any custom field on EmailMessage, any new object, any
widening of the guard's delete scope, any change to the inbound routing tree.

Update ARCHITECTURE.md in the same change per design §ARCHITECTURE.md UPDATES. Do not deploy.
```

---

## 📜 Change History

| Date | Author | Change |
|---|---|---|
| 2026-08-02 | Design Agent | Initial creation — EAC Thread Adopter design: premise verification P1–P6 (including the live guard's bracket-asymmetry defect P4 and the adopted-capture-is-still-deletable finding P6), decisions D1–D7, v1 component list, the E1/E2/E3 pre-build experiments and L1–L5 live-only checks, test plan, execution order, ARCHITECTURE.md update scope, and the technical-architect prompt. |
