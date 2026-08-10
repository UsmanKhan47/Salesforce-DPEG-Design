# 🔍 CODE REVIEW REPORT — Tranche 3A (NDA record types + record-type-aware stage advance)

**Review date:** 2026-08-09
**Branch:** `feature/stage-by-stage-alignment`
**Files reviewed:** 34 (10 Apex + 6 Apex test suites read for assertion quality, 14 declarative, 2 LWC bundles + 2 Jest suites)
**Reference docs read:** `CLAUDE.md`, `ARCHITECTURE.md`, `agent-output/stage-by-stage-decisions.md` (D1–D19), `agent-output/design-requirements-disposition-loi-psa-nda.md`, `agent-output/code-review-disposition-foundations.md` (both passes), `.claude/rules/{apex-layering,bulk-test}-rule.md`

**Not re-litigated** (per the brief): the 142-component check-only pass, the two `SharingCriteriaRule` failures (D19.2, deliberate two-phase deploy), the six deliberately-red `RecordStageAdvanceServiceTest` record-type tests, `TestDataFactoryTest.createDisposition_defaultOverload_stampsOnMarketRecordType`, and the two accepted uncovered lines from Tranche 2.

---

## 📊 SUMMARY

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | 2 |
| 🟡 WARNING | 3 |
| 🟢 SUGGESTION | 5 |
| ⚖️ JUDGEMENT CALL (not a defect) | 2 |

**Every one of the six things you asked me to look hardest at came back correct.** The approval-lock pattern is right, the allow-list genuinely moved with `NEXT_STAGE` and is pinned by a falsifying test, the two-factor gate mirrors its twin exactly with the admin bypass in the right order, the D16.3 stamp exists and reads back, the 251-record trigger test is real, and the LWC handles every branch.

**Both criticals are in the same place and neither is Apex: the disposition NDA has no usable UI surface, and the persona that owns it can neither create nor delete an NDA.** The server side of this tranche is finished; the user-facing half is not.

---

## 🔴 CRITICAL ISSUES (must fix before deployment)

### C1 — `NDA_Record_Page` was not touched. `Mark Declined` cannot be invoked by anyone, and a disposition driver sees **no buttons at all** on a disposition NDA.

**Files**
- `force-app/main/default/flexipages/NDA_Record_Page.flexipage-meta.xml:7–25` — `actionNames` contains exactly ONE entry, `NDA__c.Advance_Stage`
- `:31–34` — `enableActionsConfiguration` is `true`, so that list **is** the entire action bar (no inherited actions)
- `:11–23` — its visibility rule is `{!$User.Deal_Driver__c} EQUAL true AND {!Record.Status__c} NE 'Signed'`
- `force-app/main/default/quickActions/NDA__c.Mark_Declined.quickAction-meta.xml` and `force-app/main/default/lwc/ndaMarkDeclined/` — both shipped, both unreachable

Three separate consequences, all live:

1. **The disposition persona sees nothing.** A disposition driver holds `Disposition_Deal_Driver` and `Disposition_Driver__c = true`; they do **not** hold `Acquisition_Deal_Driver`, so they have no FLS read on `User.Deal_Driver__c` and criterion 1 cannot evaluate true. `Advance Stage` is hidden. The `Not Sent → Sent → Signed` walk that this whole tranche exists to deliver is unreachable from the UI for the only persona meant to perform it.
2. **`Mark Declined` appears nowhere.** The quick action, `lwc/ndaMarkDeclined`, `NDA_DISPOSITION_EXPLICIT_TARGETS` and `RecordStageAdvanceService.advanceTo`'s per-record-type allow-list are all dead until this entry exists. The `Declined` step is rendered on `NDA_Path_Disposition:82` with nothing able to reach it.
3. **`Advance Stage` shows on a Declined NDA.** `Status__c NE 'Signed'` does not exclude `'Declined'`, so an admin (or a dual-flagged user) still sees the button on a declined disposition NDA and gets *"There is no next step available from the Declined stage."*

Design §4.7 is explicitly inside 3A's split (§9: `3A = §4.1/4.2(NDA)/4.4/4.5/4.6(NDA)/4.7(NDA)/4.10/4.11/4.13 + §5.1/5.7`), and §4.4's `NDA__c.Is_Decline_Allowed__c` — the discriminator the Mark Declined rule was designed to bind to, because `Sent` is **shared** by both record types — was not built either (repo-wide grep: the only occurrence is in the design document).

**Fix** — three files, no Apex:

1. Add `objects/NDA__c/fields/Is_Decline_Allowed__c.field-meta.xml`, formula Checkbox
   `AND(NOT(ISBLANK(Disposition__c)), TEXT(Status__c) = "Sent")`, plus read FLS on `DPEG_Disposition_Edit` / `_View` / `DPEG_Acquisitions` / `DPEG_Admin_Access`.
2. In `NDA_Record_Page`, make `actionNames` **three** `valueListItems` — pure-AND rules only, never a parenthesised OR (design §4.7; the repo already chose the duplicate-entry workaround once):
   - `NDA__c.Advance_Stage` · `{!$User.Deal_Driver__c} EQUAL true AND {!Record.Status__c} NE 'Signed' AND {!Record.Status__c} NE 'Declined'`
   - `NDA__c.Advance_Stage` (second entry) · `{!$User.Disposition_Driver__c} EQUAL true AND {!Record.Status__c} NE 'Signed' AND {!Record.Status__c} NE 'Declined'`
   - `NDA__c.Mark_Declined` · `{!$User.Disposition_Driver__c} EQUAL true AND {!Record.Is_Decline_Allowed__c} EQUAL true`
3. Do **not** enable Dynamic Actions anywhere it is currently off as a side effect — it is already on here, so this is an additive edit.

If the flexipage work is being deliberately deferred to a separate pass, that is a legitimate call — but nothing in the repo or in `stage-by-stage-decisions.md` says so today, and 3A currently ships a quick action and an LWC bundle with nowhere to appear.

---

### C2 — The disposition persona can neither CREATE nor DELETE an `NDA__c`, and two of the tranche's own documented workflows require exactly those.

**Files**
- `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml:506–514` — `NDA__c` `allowCreate=false`, `allowDelete=false`, `allowEdit=true`, `viewAllRecords=false`
- `flexipages/Disposition_Record_Page.flexipage-meta.xml` — **no `NDA__c` related list** (repo-wide grep for `NDA` in that file: zero matches)
- `applications/Disposition.app-meta.xml:3–20` — `actionOverrides` for `Disposition__c` and `Property_Asset__c` only; no `NDA__c`
- `Disposition__c.Primary_NDA__c` appears in permission sets and Apex but in **no** flexipage and **no** layout

Two workflows the tranche itself documents are impossible for the persona that owns them:

- **D19.1's broker NDA.** Auto-create makes the *buyer* NDA only; the introducing-broker NDA is *"added from the related list"*. There is no related list, and `allowCreate=false`. `DispositionStageEntryServiceTest.anExistingBrokerNdaDoesNotSuppressTheBuyerNda:244` proves the service handles a state no disposition persona can produce. Because `All_NDAs_Signed_Before_Progression` counts NDAs that EXIST, a broker-introduced deal simply advances without the broker's NDA ever being collected — which is the requirement (Part 2 line 305) the gate was built for.
- **The documented remedy for a Declined NDA is to DELETE it.** Both `objects/Disposition__c/validationRules/All_NDAs_Signed_Before_Progression.validationRule-meta.xml:67–70` and `lwc/ndaMarkDeclined/ndaMarkDeclined.js:22–31` tell the user *"delete the NDA instead"*. `allowDelete=false`. A Declined NDA counts toward `NDA_Count__c` and never toward `Signed_NDA_Count__c`, so **it blocks every forward stage from `NDA` onward permanently** and only an administrator can clear it. The tranche adds an off-ramp whose exit is locked.

**This is a decision conflict, not a build error, and it should be resolved as one.** D16.1 set `allowCreate=false` on the premise *"creation is the auto-create trigger's job"* — written **before** D19.1 established that the trigger makes the buyer NDA only. D19.1 changed the premise; the grant did not move with it.

**Fix** — pick one and record it:
- **(a) Recommended.** `allowCreate=true` on `DPEG_Disposition_Edit`, add the `NDA__c` related list to `Disposition_Record_Page` (design §4.8) and the `NDA__c` `View` actionOverride to `Disposition.app` (design §4.14). The D17 criteria sharing rule already scopes *which* rows the persona can touch, and `recordTypeVisibilities` already gives them exactly one available type, so the New button applies `Disposition_NDA` with no chooser. Delete stays false, and the "delete the NDA" wording in the VR comment and the LWC prompt is corrected to name the real remedy (ask an admin / re-open the NDA).
- **(b)** Keep both false, and change both pieces of user-facing wording plus D19.1 to say the broker NDA and any decline reversal are administrator actions. Cheaper, but it makes the off-market NDA step a two-persona workflow — say so out loud rather than leaving it to be discovered in UAT.

⚠ Whichever you pick, remember a `PermissionSet` deploy **replaces** its whole grant list — reconcile against the org before editing these files.

---

## 🟡 WARNINGS (should fix)

### W1 — `DispositionNdaStampQueueable`'s stated reason for being async is false on this feature's actual path, and the residual it creates is not written down

**File:** `force-app/main/default/classes/DispositionNdaStampQueueable.cls:14–19`, `:69`

> *"All three also set `finalApprovalRecordLock = false`, so the record unlocks when that transaction commits, which is exactly when a Queueable runs."*

That sentence is true of the **acquisition LOI**, which it was copied from — there the LOI stage is entered *by the approval's own final field update*, so the transaction that fires the trigger is the one **releasing** the lock, and a Queueable running after commit genuinely finds the record unlocked. It is not true here. A disposition enters the `NDA` stage by an **ordinary user edit**, and `finalApprovalRecordLock` governs what happens *after final approval* — it does not unlock a record whose approval is still **pending**, which can be days.

Trace the two reachable cases:

- **Disposition not locked** (the normal case — a locked record's stage cannot be edited by a non-admin, so the trigger never fires). Inline and deferred behave identically.
- **Disposition locked, edited by an administrator** — `recordEditability = AdminOnly` permits exactly this. The trigger fires, the NDA inserts (correctly — `NDA__c` is not the record under approval), and the Queueable then runs while the approval is **still pending**. `Database.update(stamps, true, AccessLevel.SYSTEM_MODE)` at `:69` throws `ENTITY_IS_LOCKED`, `allOrNone = true` fails the batch, and **`Primary_NDA__c` is never stamped and nothing retries.** The only signal is a failed `AsyncApexJob`.

**The deferral is still the right call** — it converts "the admin's stage change is rolled back" into "the back-reference is missing" — and I would not change the shape. Two things should change:

1. **Correct the justification.** The benefit here is that a lock failure costs a back-reference instead of the user's own edit; it is *not* that the queueable is guaranteed to find the record unlocked. As written, the next reader will believe the stamp cannot fail.
2. **State the residual and gate it.** `Primary_NDA__c` null with no retry is exactly the silent-null failure the class header says `Opportunity.Primary_LOI__c` was created to prevent. Add a UAT step: put an off-market disposition at Readiness, submit `Sale_Decision_Approval`, then move the stage to `NDA` **as an admin**, and confirm what `Primary_NDA__c` and the `AsyncApexJob` read.

Secondary, same file: `allOrNone = true` on a single statement carrying up to 200 dispositions means **one** locked or deleted parent fails all 200 stamps. `Database.update(stamps, false, SYSTEM_MODE)` plus a `System.debug` of the failed rows would isolate them — but that trades a loud failure for a quiet one, so I am flagging the trade rather than prescribing it.

### W2 — `OpportunityReviewService` reverses design Q5 (stamp unconditionally). The reversal is right; it is not recorded in the decisions file.

**Files:** `classes/OpportunityReviewService.cls:34–57` (rationale), `:298–306` (guarded stamp), `:331–336` (`acquisitionNdaRecordTypeId`)

Design §5.2/Q5 said *"stamp unconditionally (null-safe on the describe lookup only)… the guard buys nothing here."* What shipped is `info != null && info.isAvailable()`.

**I think the implementation is right and the design was wrong**, and the reasoning in the class header is the reason: `ensureNda` runs on **every** Opportunity insert — including `Database.convertLead` from the inbound Broker-Protection pipeline — from an **after-insert** trigger, so an exception rolls the Opportunity back. `RecordStageAdvanceServiceTest.insertNdaOnRecordType:194–209` records the measurement: an unguarded `RecordTypeId` stamp throws `INVALID_CROSS_REFERENCE_KEY`, it does not no-op. Pre-gate-T-A1 the unguarded version is not "one loud failure", it is *nobody in the org can create a deal or convert a lead*, plus a repo-wide red suite. The loudness was correctly relocated to `OpportunityReviewServiceTest.ensureNda_stampsTheAcquisitionRecordType:135–162`, which re-queries `RecordTypeId` from the database (D16.3's read-back requirement, satisfied literally) and fails unconditionally naming gate T-A1.

**Action:** none in code. Record the Q5 reversal in `stage-by-stage-decisions.md` with the blast-radius reasoning, so a later tranche doing the LOI (3B) and Contract Review (3C) stamps re-argues the choice on its own merits — as the class header already tells it to — instead of "restoring" the design's instruction.

### W3 — `NDA_Signed_Rollup` is bulk-exercised only in the *many-parents* shape; the *one-parent* shape is untested and is the classic `DUPLICATE_VALUE`

**Files:** `flows/NDA_Signed_Rollup.flow-meta.xml:157–179`; `DispositionStageEntryServiceTest.cls:328–355`

The flow is well built — the no-change `Counts_Changed` Decision (`:59–88`) and the `faultConnector` (`:163–165`) are both present **from day one**, which is exactly what Tranche 2's C1 fix had to be retrofitted for. Credit that; it is the single most important thing in this tranche's declarative half and it was done right without being asked twice.

The residual is the one Tranche 2 left open. `bulkStageEntryAt251OpensOneNdaEach` inserts 251 NDAs across **251 distinct** dispositions, so the consolidated `Update Records` carries 251 distinct Ids and cannot duplicate. Nothing in the suite inserts many NDAs under **one** disposition (`NdaSelectorTest.selectLatestByOpportunityId_bulk` creates 251, but they are Opportunity-parented and the flow's `Disposition__c IsNull = false` entry filter excludes them). So the `duplicate id in list` shape remains unobserved either way — as it did after Tranche 2's fix round.

**It is bounded, not open:** the fault connector converts any such failure into a stale count rather than a lost NDA, and the no-change Decision removes the write on every save that does not move a counter. **Action: none in code.** Say it in the flow `<description>` — "the many-NDAs-under-one-disposition consolidation is untested and is bounded by the fault connector" — rather than leaving it to be re-derived. Do **not** reduce the 251 counts to dodge it.

---

## 🟢 SUGGESTIONS

- **S1 — `manifest/package.xml` lists none of 3A.** No `RecordType` for the two NDA types, no `PathAssistant` (2 new + 1 deactivated), no `ValidationRule`, no `Flow`, no `SharingCriteriaRule`, no `QuickAction`, no `LightningComponentBundle`, no `PermissionSet` for `Disposition_Deal_Driver`, no `ApexClass` for the four new classes, no `ApexTrigger`. Tranche 2's S4 was closed by refreshing this file; it is stale again one tranche later. If DevOps deploys `--manifest` the tranche silently under-deploys. Either refresh it or confirm the plan is per-component `--source-dir` (which D19.2's two-phase order implies).
- **S2 — translations were not extended (design §4.14).** `objectTranslations/NDA__c-en_US/Status__c.fieldTranslation-meta.xml:5–16` still lists only `Pending` / `Sent` / `Signed` — `Not Sent`, `Received` and `Declined` are missing — and there is no `Party_Role__c` or `Counter_Signed_Date__c` translation file. Cosmetic, deploys clean either way.
- **S3 — `objects/User/fields/Disposition_Driver__c.field-meta.xml:11` names the wrong permission set.** It says *"granted by the Disposition_Driver permission set"*; the file is `Disposition_Deal_Driver`. One word, in the one place an admin provisioning the persona will look.
- **S4 — `lwc/recordStageGuard/recordStageGuard.js:30–35` still says "The five child objects"** in the three-guard comparison table, while the file's own header at `:6–8` correctly says six. The header was updated and the table below it was not.
- **S5 — `DispositionStageEntryService` keys stage entry on the value alone, with no record-type test.** `:140` fires on any disposition reaching `Disposition_Stage__c = 'NDA'`. `NDA` is off-market-only *by value set*, and record-type picklist restriction is **UI-only** — the same fact this tranche cites four times elsewhere — so an on-market or Master-type disposition set to `NDA` by API, seed or data load gets a `Disposition_NDA` buyer NDA. Harmless today, and arguably the right defensive default; but the class header argues the record-type question in two other places and is silent here. Either add the guard or add the sentence.

---

## ⚖️ JUDGEMENT CALLS — not filed as defects

### J1 — The `Declined` off-ramp creates a state with no user-clearable exit, and that is a design property, not a bug

Separate from C2's permission half. Even *with* `allowDelete`, the modelling is worth a second look: `All_NDAs_Signed_Before_Progression` treats Declined as "exists and has not signed", so declining is permanent blockage until a record is destroyed. Deleting an NDA to unblock a deal is a destructive answer to a state change, on an object both permission sets call an audit artefact. The cheaper shape is to **exclude `Declined` from `NDA_Count__c`** (the flow already branches per row at `Is_Row_Signed:89–111` — a third branch that counts neither is two lines) and record the decline as history. I am not recommending it in 3A: it changes the release semantics, and D19.1's "a broker NDA that was never created cannot block, which is correct" reasoning may well extend to a declined one. But the current wording — VR comment `:67–70` and `ndaMarkDeclined.js:22–31` both prescribing deletion — is the tell that the model is fighting the process.

### J2 — `NDA_Signed_Rollup` re-counts every NDA on the parent for every NDA save, which is right, and its DELETE gap is honestly stated

The flow's `<description>:112` says plainly that `recordTriggerType = CreateAndUpdate` leaves counts stale after an NDA delete, names the direction (fail-**closed**: the total stays too high, so the gate keeps blocking), and — the part worth naming — **makes no negative claim about who can delete an NDA**, explicitly because profiles are `.forceignore`d. That is exactly the correction Tranche 2's pass-2 W2 asked for, applied prospectively to a different flow. Good.

---

## ✅ VERIFIED CORRECT — the six things you asked about

1. **The approval-lock pattern is genuinely safe, and the lock analysis is complete.** The child insert at `DispositionStageEntryService.cls:189` is `Database.insert(..., true, AccessLevel.SYSTEM_MODE)` on `NDA__c`, which is **not** the record under approval and therefore not locked. The parent stamp is genuinely deferred (`:211–213`, enqueue guarded on `Limits.getQueueableJobs()` exactly as `OpportunityReviewService`'s LOI block is) and `DispositionStageEntryServiceTest.primaryNdaIsStampedByTheQueueableAfterCommit:282–299` asserts `Primary_NDA__c` is **null before `Test.stopTest()`** — an inlined stamp turns that test red, which is the right way to pin a deferral. **I widened the sweep as asked:** the only writers of `Disposition__c` in the entire repo are `DispositionService.cls:122` (an insert), `DispositionNdaStampQueueable:69`, and two flows — `NDA_Signed_Rollup` and Tranche 2's `Wire_Verification_Rollup` — **both of which carry fault connectors**. Nothing else in the 3A path can touch a locked record. The recursion argument is also sound and correctly preferred over a static flag: the stamp changes `Primary_NDA__c` only, so `priorStage != d.Disposition_Stage__c` is false at `:140` and the re-entry costs zero queries, with the buyer-role read as an independent second guard.

2. **The allow-list moved with `NEXT_STAGE`, and the refusal is falsifiable.** `NDA_DISPOSITION_EXPLICIT_TARGETS` (`RecordStageAdvanceService.cls:284–286`) lives on `StageTypeConfig` alongside `nextStage` **and** the gate (`:443–467`), and `advanceTo` (`:650–661`) resolves the sequence from the **loaded** record before testing membership. `Acquisition_NDA` supplies no explicit targets at all, so `advanceTo(acquisitionNdaId, 'Declined')` is structurally refused — pinned by `RecordStageAdvanceServiceTest.acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget:535`, which asserts the exact refusal message **and** that `Status__c` is still `'Sent'`. `advanceToOnAMissingRecordThrowsQueryExceptionNotARefusal:690` pins the call-order change itself, with an `Assert.fail` in the `RecordStageAdvanceException` branch — so re-hoisting the allow-list check above the load goes red. The five pre-existing objects are untouched: `sequenceKeyFor:777–780` short-circuits on `byRecordType.size() == 1` and never describes. `UNDERWRITING_NEXT_STAGE:376–380` still omits `In Progress`, with `underwritingNeverReachesApprovedFromInProgress:495` asserting both the refusal and that the message names *Submit for Approval*.

3. **The two-factor gate is a faithful mirror and the bypass order is pinned by a test that can fail.** `DispositionActionPermissionService.computeDispositionActionAccess:173–194` runs `hasModifyAllData()` **before** the `UserSelector` read, and `DispositionActionPermissionServiceTest.administratorPassesWithoutTheFlagOrThePermissionSet:227` asserts `isAccessible() == false` **and then** `allowed == true` — reversing the two statements turns that test red, which is the only shape of test that actually proves the ordering. `UserSelector.selectDispositionDriverFlagForCurrentUser:117–128` is `WITH USER_MODE` on a single field, and its Javadoc `:94–101` gives the right reason for keeping it a separate query from `selectDealDriverFlagForCurrentUser` — a merged select would throw for an acquisitions-only driver and silently deny them the actions they already have. **No membership check crept in anywhere:** `membershipWithoutTheFlagIsStillDenied:77` and `anAcquisitionDealDriverIsDeniedTheDispositionGate:133` are the two falsifiers, and the machinery-fault path propagates rather than degrading (`aLookupFaultPropagatesAndCachesNothing:324`, which also asserts the cache is left empty).

4. **D16.3 is stamped, read back, and the guarded choice is defensible** — see W2. The verification re-queries `RecordTypeId` rather than trusting the in-memory copy, and the describe is resolved once per invocation (`:296–298`), not per record.

5. **Bulk safety is real and the governor assertion is the good kind.** `bulkStageEntryAt251OpensOneNdaEach:328` drives 251 dispositions through the **real trigger** (two chunks) and asserts all 251 NDAs, all 251 with `Party_Role__c = 'Buyer'`, and all 251 parents stamped. `suppressionPathCostsOneQueryAndNoDmlAt251:372` then asserts **exactly** 1 query and **exactly** 0 DML for 251 records — and the class header `:24–33` explains why the budget assertion is deliberately made on the suppression path (creating NDAs would fold `NDA_Signed_Rollup`'s own queries into the number and make the suite red on an unrelated declarative change). That is a better answer than a `<=` ceiling. Idempotency is proven **both ways**: `anExistingBuyerNdaSuppressesAutoCreate` and `anExistingBrokerNdaDoesNotSuppressTheBuyerNda`, which is what distinguishes the real "role" key from a lazy "any NDA" key — the second test would pass under either implementation only if the first were deleted. `aSaveThatDoesNotChangeTheStageCostsNothingAt251:419` pins the org-wide cost of adding a trigger to `Disposition__c` at zero.

6. **The LWC is complete.** `ndaMarkDeclined.js:64–94` — permission → confirm → act (never the reverse), `try/catch` around the imperative call, `error.body.message` surfaced verbatim with a fixed fallback, and `getRecordNotifyChange` **only on the success path** (`:80`), which is mandatory here because the write is imperative Apex. `recordStageGuard.guardStageAction:153–168` fails closed on a rejected permission call and requires `=== true` rather than truthiness. The Jest suite covers success, both error shapes, denied and cancelled, and asserts the permission call carries the `recordId` — the per-record signature that is the whole reason this guard is separate from `c/dealActionGuard`.

---

## ✅ OTHER GOOD PRACTICES FOUND

- **The blast-radius warning in the validation rule was actioned, not just written.** I swept for it: every existing test and seed that sets `Disposition_Stage__c` to `Closing` (`WireServiceTest:22`, `WireControllerTest:30`, `DispositionTaskServiceTest:22`, `DispositionTaskControllerTest:28`, `DispositionControllerTest:130,146`, `seed-disposition-bulk.apex:67`) creates through `TestDataFactory`'s **On_Market** default, so `RecordType.DeveloperName = 'Off_Market'` is false and the rule never fires. `DispositionStageEntryServiceTest.otherStageChangesAndPlainEditsOpenNothing:125–129` even carries a comment explaining why its "some other stage" fixture is deliberately on-market. That is Tranche 2's W1 lesson applied before the review asked.
- **`BLANKVALUE(...,0)` in the VR is the right call for the right reason** (`:102–103`, rationale `:55–60`): a Number default applies only at insert, so pre-existing rows hold null, and a null in a comparison makes a validation rule evaluate FALSE — i.e. the naive form fails **open** on exactly the rows most at risk.
- **`RecordStageAdvanceService.recordTypeIdOf:824–832` is built on a measurement, not an assumption** — `getPopulatedFieldsAsMap()` rather than `get('RecordTypeId')` because the direct read throws `SObjectException` on the five selectors that do not select the field, and a *queried but null* field is dropped from the map entirely. Both halves are stated as measured on the org, and the case-insensitive key scan is justified rather than left to look like sloppiness.
- **`NdaSelector.selectByDispositionIds:189–199` is the correct `WITH SYSTEM_MODE` call and argues both halves.** It names the automation-path reason (a `USER_MODE` throw inside an after-update trigger rolls back the user's own stage change — the reproduced `TaskSelector.selectByTransactionDealIds` failure), **and** it separately argues why sharing does *not* need escaping here, contrasting itself with `InboundEmailStagingSelector.RoutingReads` where the rows belong to a different principal. That is the exact two-part check ARCHITECTURE.md demands after the 2026-08-08 incident, and it is the first class in the repo to do it unprompted.
- **`NdaSelectorTest:143–166` pins the field-list contract by catching `SObjectException`** and calling `Assert.fail` inside the catch — so narrowing `selectStageRequiredById` away from `RecordTypeId` goes red instead of silently routing every disposition NDA to the acquisition sequence. That is the right test for a "dropping this degrades silently" contract.
- **D17 is a genuine security narrowing, executed completely.** `viewAllRecords` on `NDA__c` is `false` on both disposition sets, replaced by two criteria rules on `RecordTypeId = NDA__c.Disposition_NDA`. The two-rule split is argued on *population* (Principals reach `DPEG_Disposition_View` through the PSG and may not be in `DPEG_Acquisitions_Team`) rather than on access level, the object-CRUD-is-the-ceiling reasoning for not writing a redundant Read rule is correct, and the deploy-one-at-a-time / group-membership-not-deployable / recalculation-is-async gates are all named in-file.
- **The retraction discipline continues.** `DPEG_Disposition_Edit`'s comment carries D12/W3 → D16.1 → D17 as three dated blocks with the superseded sentences **quoted and explicitly retracted** rather than deleted. That is rarer than writing a new justification and it is what let me verify the history in one file.
- **`ARCHITECTURE.md` §6 is current** — `RecordStageAdvanceService`'s row is amended twice with both the map change and the gate change (and explicitly marks the sentence it used to end with as FALSE), and `DispositionStageEntryService`, `DispositionNdaStampQueueable` and `DispositionActionPermissionService` all have new rows. I checked this before writing a §6 finding; there isn't one.
- **`RecordStageAdvanceServiceTest.theGateIsResolvedPerRecordTypeNotPerObject:820` runs BOTH polarities**, so a hardcoded constant cannot pass — and the header `:810–817` explains why cache-seeding beats `System.runAs` here (OWD Private on `NDA__c` means a bare user's `USER_MODE` selector throws before the gate is consulted, and the test would pass for the wrong reason). Naming why the honest-looking alternative is wrong is more useful than the technique itself.
- **`gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject:909` asserts the short-circuit as a COST (0 vs 1 query)** and pre-announces that the LOI assertion is *expected* to become 1 in Tranche 3B. A test that tells the next author it is meant to change is worth more than one that just breaks.
- **The 255-char `<description>` cap was measured mechanically, not eyeballed** — two breaches found in 3A (`Disposition_NDA` at 266, `All_NDAs_Signed_Before_Progression` at 259), both fixed, both recorded in the file that breached. D18.1's third repetition, finally caught before a deploy.
- **The compile-order dependency is documented where it will be read.** `NdaSelector.cls:227–231` states that a custom object with zero record types has no `RecordTypeId` field **at all**, so this class does not compile until `objects/NDA__c/recordTypes/` is deployed — a compile requirement, not merely a runtime one. That is the single most likely way this tranche's deploy could fail confusingly.
- **`Party_Role__c` and `Counter_Signed_Date__c` are reachable despite not being on any layout**, because `NDA_Path_Disposition:61–76` exposes them as Path key fields. Worth stating explicitly since the layout gap otherwise looks fatal — it is not, though a disposition layout (design §4.7) is still the right home.

---

## 📋 FILE-BY-FILE

| File | Status | 🔴 | 🟡 | 🟢 |
|------|--------|----|----|----|
| `flexipages/NDA_Record_Page.flexipage-meta.xml` | 🔴 | 1 (C1) | 0 | 0 |
| `flexipages/Disposition_Record_Page.flexipage-meta.xml` | 🔴 | (C2, joint) | 0 | 0 |
| `permissionsets/DPEG_Disposition_Edit` | 🔴 | (C2, joint) | 0 | 0 |
| `permissionsets/DPEG_Disposition_View` | ✅ | 0 | 0 | 0 |
| `permissionsets/Disposition_Deal_Driver` | ✅ | 0 | 0 | 0 |
| `permissionsets/DPEG_Admin_Access` · `DPEG_Acquisitions` · `DPEG_Acquisition_Edit` | ✅ | 0 | 0 | 0 |
| `applications/Disposition.app-meta.xml` | 🔴 | (C2, joint) | 0 | 0 |
| `objects/NDA__c/recordTypes/Acquisition_NDA` · `Disposition_NDA` | ✅ | 0 | 0 | 0 |
| `objects/NDA__c/fields/Status__c` · `Party_Role__c` · `Counter_Signed_Date__c` | ✅ | 0 | 0 | 0 |
| `objects/NDA__c/fields/Is_Decline_Allowed__c` | 🔴 | (C1 — absent) | 0 | 0 |
| `objects/Disposition__c/fields/NDA_Count__c` · `Signed_NDA_Count__c` · `Primary_NDA__c` | ✅ | 0 | 0 | 0 |
| `objects/Disposition__c/validationRules/All_NDAs_Signed_Before_Progression` | ✅ | 0 | 0 | 0 |
| `flows/NDA_Signed_Rollup.flow-meta.xml` | 🟡 | 0 | 1 (W3) | 0 |
| `pathAssistants/NDA_Path{,_Acquisition,_Disposition}` | ✅ | 0 | 0 | 0 |
| `sharingRules/NDA__c.sharingRules-meta.xml` | ✅ | 0 | 0 | 0 |
| `objects/User/fields/Disposition_Driver__c` | 🟢 | 0 | 0 | 1 (S3) |
| `layouts/NDA__c-NDA Layout` | 🟡 | 0 | (C2 context) | 0 |
| `objectTranslations/NDA__c-en_US/*` | 🟢 | 0 | 0 | 1 (S2) |
| `classes/RecordStageAdvanceService.cls` | ✅ | 0 | 0 | 0 |
| `classes/RecordStageAdvanceController.cls` | ✅ | 0 | 0 | 0 |
| `classes/DispositionStageEntryService.cls` | 🟢 | 0 | 0 | 1 (S5) |
| `classes/DispositionNdaStampQueueable.cls` | 🟡 | 0 | 1 (W1) | 0 |
| `classes/DispositionTriggerHandler.cls` · `triggers/DispositionTrigger.trigger` | ✅ | 0 | 0 | 0 |
| `classes/DispositionActionPermissionService.cls` | ✅ | 0 | 0 | 0 |
| `classes/UserSelector.cls` · `NdaSelector.cls` | ✅ | 0 | 0 | 0 |
| `classes/OpportunityReviewService.cls` | 🟡 | 0 | 1 (W2) | 0 |
| `classes/TestDataFactory.cls` · `TestDataFactoryTest.cls` | ✅ | 0 | 0 | 0 |
| `classes/*Test.cls` (6 suites) | ✅ | 0 | 0 | 0 |
| `lwc/ndaMarkDeclined` | ✅ | (C1 — unreachable) | 0 | 0 |
| `lwc/recordStageGuard` | 🟢 | 0 | 0 | 1 (S4) |
| `manifest/package.xml` | 🟢 | 0 | 0 | 1 (S1) |
| `ARCHITECTURE.md` | ✅ | 0 | 0 | 0 |

---

## 🏁 VERDICT

❌ **CHANGES REQUIRED** — two critical issues, both on the user-facing surface.

To be plain about the proportion: **the Apex in this tranche is the best I have reviewed on this programme, and it is not close.** The record-type-aware refactor is the sharpest single design point in Tranche 3 and it was executed with the allow-list, the gate and the sequence moved together — the half-finished version (record-type-aware `NEXT_STAGE`, object-wide allow-list) compiles, passes every walk test, and is a hole; that trap was avoided and then pinned with a test that would catch a regression. The approval-lock pattern was copied from the right precedent rather than reinvented, the lock analysis holds under a repo-wide sweep, the bulk test is real and its governor assertion is exact rather than a ceiling, `NdaSelector`'s `SYSTEM_MODE` argues *both* the FLS half and the sharing half unprompted, and `ARCHITECTURE.md` was updated in the same change.

The blocker is that **the server side is finished and the client side was not started.** `NDA_Record_Page` is byte-identical to its pre-3A state, so the `Mark Declined` quick action and `lwc/ndaMarkDeclined` have nowhere to appear, and the one action that *is* on the page is gated on the acquisition persona's flag — which means a disposition driver opens a disposition NDA and sees no way to do anything with it. Alongside that, the persona holds neither `allowCreate` nor `allowDelete` on `NDA__c`, while two of the tranche's own documented workflows (add the broker's NDA; delete a declined one) require exactly those. C2 is a genuine conflict between D16.1 and the later D19.1, not a build error — but it needs a decision, not a note.

Both are declarative fixes measured in files, not in days. Neither touches Apex, and nothing in the Apex needs to change to accommodate them.

---

## 👤 USER ACTION REQUIRED

Critical issues must be fixed. Do you want to:

- **[F] Fix issues** — send C1 (`Is_Decline_Allowed__c` + three `actionNames` entries on `NDA_Record_Page`) to `salesforce-solution-architect`, and answer C2 (grant `allowCreate`, add the related list and the app actionOverride — or accept the two-persona workflow and correct the VR comment and the LWC prompt). Then request a re-review of the flexipage, the permission set and the two wording changes only.
- **[S] Skip deployment for now** — 3A is not deployed and not merged (D14), and both criticals are invisible to a green deploy and to `RunLocalTests`, so they will surface as "the disposition user has no buttons" in UAT gates T-E2 and T-E5 rather than as an error.

Whichever you choose, three items should ride along because they are one line each and one of them is a wrong premise left standing: **W1**'s corrected `finalApprovalRecordLock` justification plus its UAT step, **W2**'s Q5 reversal recorded in the decisions file, and **S3**'s permission-set name.
