# 🔍 CODE REVIEW REPORT — Disposition Foundations (Tranche 2)

**Review date:** 2026-08-09
**Branch:** `feature/stage-by-stage-alignment`
**Files reviewed:** 29 (9 Apex + 3 Apex test suites read for assertion quality, 14 declarative, 3 LWC bundles)
**Reference docs read:** `CLAUDE.md`, `ARCHITECTURE.md`, `agent-output/stage-by-stage-decisions.md` (D1–D11), `agent-output/design-requirements-disposition-foundations.md`, `.claude/rules/{apex-layering,bulk-test,invocable}-rule.md`

**Not re-litigated** (per the brief): the 118-component check-only validation, the 66/66 Apex pass, the 94/602 Jest pass, the two accepted uncovered lines, and the `findOrCreate` bulk-test exemption.

---

## 📊 SUMMARY

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | 1 |
| 🟡 WARNING | 5 |
| 🟢 SUGGESTION | 4 |
| ⚖️ JUDGEMENT CALL (not a defect) | 3 |
| ✅ PASSED / verified correct | see below |

**All four items you asked me to look hardest at — the create-only gate and its ordering, the catch order in `DispositionController`, the narrowness of `readNdaStatusFailSoft`, and layering conformance — are correct.** The one critical finding is elsewhere: an interaction between two artifacts that were designed independently and shipped together.

---

## 🔴 CRITICAL ISSUES (must fix before deployment)

### C1 — `Wire_Verification_Rollup` will throw `ENTITY_IS_LOCKED` while the Closing approval is pending, and takes the Wire save down with it

**Files**
- `force-app/main/default/flows/Wire_Verification_Rollup.flow-meta.xml:45–58` (`Update_Disposition_Flag`, no fault connector) and `:59` (`<runInMode>SystemModeWithoutSharing</runInMode>`)
- `force-app/main/default/approvalProcesses/Disposition__c.Closing_Approval.approvalProcess-meta.xml:36–42` (`entryCriteria` = `Disposition_Stage__c` equals `Closing`) and `:47` (`<recordEditability>AdminOnly</recordEditability>`)

**The interaction.** Both artifacts ship in this tranche and they target *the same stage*:

1. Owner submits the disposition for `Closing_Approval` at stage `Closing`.
2. `recordEditability = AdminOnly` **locks the `Disposition__c` record** for the duration.
3. The IR persona then saves the Wire (`WireController.saveWire` → `WireService.saveWire` → `upsert w`).
4. `Wire_Verification_Rollup` fires after-save and issues `Update Records` against `$Record.Disposition__r` — **a locked record.**
5. The update throws `ENTITY_IS_LOCKED`. There is **no fault connector by design** (the element's own `<description>` says so), so the fault is unhandled and **rolls back the Wire save**.
6. The user sees `WireController`'s fixed generic message: *"This change could not be saved. Refresh the page…"* — advice that can never work, since the lock persists until the approval resolves.

**Why `runInMode` does not save this.** `SystemModeWithoutSharing` lifts CRUD, FLS and sharing. It does **not** lift an approval record lock. This is not a general-knowledge claim — `ARCHITECTURE.md` records the measured in-repo precedent in the `OpportunityReviewService` row: *"`SYSTEM_MODE` lifts CRUD/FLS but **does NOT lift an approval lock**, so the inline back-stamp still threw `ENTITY_IS_LOCKED` after the CRUD fix landed."* The remedy there was to defer the write, not to widen the mode. Salesforce also ships a dedicated **Unlock Record** flow core action, which would be pointless if system-mode flows bypassed locks.

**Why this is likely, not theoretical.** Q4 put `Wire_Verification_Completed__c` in `Closing_Approval`'s `approvalPageFields` precisely *"so the approver sees the wire state when deciding."* That framing invites exactly the sequence above — submit, approver looks at the wire state, wire gets completed/corrected during the approval. And `Closing` is the only stage at which a `Wire__c` is worked at all.

**Also note** the flow updates the parent on **every** Wire save, even when the computed value is unchanged — so the lock is hit by any wire edit at all during a pending Closing approval, not only by a genuine flag flip.

**Recommended fix — three parts, all cheap:**

1. **Verify first (5 minutes, in-org).** Put a disposition at `Closing`, submit it for approval, then save a Wire from the UI. If `ENTITY_IS_LOCKED` reproduces, apply 2 and 3. This is the one item where a measurement beats more reasoning.
2. **Add a Decision before `Update_Disposition_Flag`** that skips the update when `{!$Record.Disposition__r.Wire_Verification_Completed__c}` already equals `{!isComplete}`. This removes the parent DML in the overwhelming majority of saves (including every incidental edit) and is correct on its own merits — the flow currently writes the parent unconditionally. It is necessary but **not sufficient**: it does not cover the case where the flag genuinely flips mid-approval.
3. **Add a fault connector on `Update_Disposition_Flag`** routing to an end node, so a locked parent costs a *stale flag* rather than *a lost wire record*. The current "no fault path is safer" reasoning is right for a data-integrity fault and wrong for a lock, because a lock is a state the user cannot clear. A stale flag while locked is harmless — the stage cannot change while locked either, so the validation rule cannot be reached — and the next Wire save reconciles it.
4. **Record the intended order** ("complete the wire verification *before* submitting the Closing approval") in the `Closing` Path step `<info>` on **both** paths and in `Closing_Approval`'s `<description>`, and add it as a UAT gate (B9) alongside B6/B7.

If (1) shows the lock is not hit, this drops to a WARNING (items 2 and 3 are still worth doing) and the verdict below becomes APPROVED WITH WARNINGS.

---

## 🟡 WARNINGS (should fix)

### W1 — The 66/66 Apex green predates the declarative metadata; three existing tests now drive the new flow at 251 children under one parent

**Files:** `DispositionControllerTest.cls:223`, `WireControllerTest.cls:202`, `WireSelectorTest.cls:105` — each `TestDataFactory.createWires(251, d.Id, true)`.

The declarative work was validated **check-only** (not deployed), so the Apex suite has never run with `Wire_Verification_Rollup` active or `Wire_Complete_Before_Completed` enforced. Deploy order §7 puts Apex last (D6), which means the first encounter is that deploy's `RunLocalTests`.

Two specific exposures:

- **Parent-update-per-child at bulk.** Each of those three tests inserts 251 `Wire__c` rows **under a single `Disposition__c`** in one DML. The flow bulkifies into ~2 batches, and within a batch up to 200 interviews all attempt to update **the same** Disposition Id. Flow's consolidated `Update Records` DML with a repeated Id is the classic `DUPLICATE_VALUE: duplicate id in list` shape. I could not settle this from source, and **the repo has no precedent to lean on** — `Underwriting_Opp_Sync` uses the identical `inputReference $Record.Opportunity__r` shape but no test in the repo creates 251 `Underwriting__c` under one Opportunity.
- **Validation-rule blast radius.** I swept for it and it is **clean**: zero tests and zero seed scripts set `Disposition_Stage__c = 'Completed'`, and `TestDataFactory` explicitly documents why it never seeds `Completed`. That half of the design's stated risk is genuinely closed. Credit where due.

**Recommended fix:** before D6, deploy the flow to a scratch/sandbox and run those three test classes alone. If the duplicate-Id failure reproduces, the C1 fix item 2 (the no-change Decision) does **not** rescue it — all 200 interviews compute the same value and still queue the same Id. The robust answer is then to move the rollup to Apex (`WireTrigger` → `WireRollupService`, which is also what `.claude/rules/apex-layering-rule.md` would prefer for a rollup), or to accept it and note that a bulk Wire load under one Disposition is not a production event.

### W2 — `DPEG_Admin_Access` grants no FLS on `Wire_Verification_Completed__c`, and no post-deploy gate covers admin FLS

**Files:** `permissionsets/DPEG_Admin_Access.permissionset-meta.xml:4–8` (a single `fieldPermissions` entry, for `Lease_Inquiry__c.OneDrive_URL__c`); design §8 gates A1–A3 and B1–B8.

`DPEG_Admin_Access`'s own `<description>` says it exists to *"restore tab visibility and FLS the Admin profile granted (Profiles excluded from deployment)"*. Metadata-API-deployed custom fields arrive with **no** field permissions for any profile, System Administrator included — a trap this repo has already paid for (`ARCHITECTURE.md` §2 and the deal-driver gate incident). Consequence: an administrator sees no `Wire Verification Completed` field anywhere, and **an approval page silently omits fields the approver cannot read** — so if either named approver is acting under a profile/permission-set combination lacking that FLS, the Closing approval page shows nothing where the wire state should be. That is precisely the outcome Q4's design was built to avoid, failing silently.

Mitigating fact I verified: `DPEG_Principal_PSG` includes `DPEG_Disposition_View`, which **does** carry `readable=true` on the field (`DPEG_Disposition_View:209–213`). So the two named approvers are covered *provided they hold that PSG*. The admin is not.

**Recommended fix:** add `Disposition__c.Wire_Verification_Completed__c` (`readable=true`, `editable=false`) to `DPEG_Admin_Access` — it is deployable, unlike the profile — and add a gate **A4** to §8: *"grant admin FLS on the new field; verify by opening the Closing approval page as each named approver, not as an admin."*

### W3 — The `NDA__c` grant landed as `viewAllRecords=true`, not the plain read the design specified

**Files:** `DPEG_Disposition_View.permissionset-meta.xml:371–379`, `DPEG_Disposition_Edit.permissionset-meta.xml:371–379`.

Design §4.10(c) and D11/Q7 specify `objectPermissions allowRead=true` plus FLS on `NDA__c.Status__c`. What shipped is `allowRead=true` **plus `viewAllRecords=true`**, mirroring `DPEG_Acquisition_View:1530–1538`.

I think the implementation is *defensibly right and the design was under-specified*: `NDA__c` is `sharingModel = Private` (`NDA__c.object-meta.xml:165`) with no relevant sharing rule, so plain read would have left the pill reading "No NDA" for most disposition users — a false compliance negative, which is the exact defect this item exists to fix. But it is a real widening: every disposition-only persona can now read **every acquisition NDA in the org**, in a security model the 2026-07-22 RBAC build deliberately partitioned by module.

**Recommended fix:** no code change; get an explicit one-line acceptance from the user and record it against Q7 in the decisions file, so the next reviewer doesn't discover it as drift. If the widening is *not* acceptable, the alternative is a `NDA__c` sharing rule scoped to the disposition role — which is more work than this tranche wants.

### W4 — The "badge and gate cannot disagree" invariant is asserted in four places and is only approximately true

Asserted in: `Wire_Verification_Completed__c.field-meta.xml:5`, `Wire_Verification_Rollup.flow-meta.xml:4`, `Wire_Complete_Before_Completed.validationRule-meta.xml:14–16`, and the design §0 Q3 answer.

Two concrete divergences between what the flow computes and what `WireController.getWire` shows:

1. **Tie-break.** `WireSelector.selectMostRecentByDispositionId:61` orders `CreatedDate DESC, Id DESC`. The flow's Get Records (`Wire_Verification_Rollup:41–42`) sorts on `CreatedDate` **Desc only** — Flow supports exactly one sort field, so the `Id DESC` tie-break is inexpressible. `CreatedDate` is second-granular, so two wires created in the same second under one disposition can make the badge and the gate read *different rows*. The team clearly knows this hazard: `BovControllerTest:202–203` neutralises the identical tie for NDAs with `Test.setCreatedDate`.
2. **Predicate.** `WireController.buildRow:58–63` counts a field complete when `!= null`. The flow uses `NOT(ISBLANK(...))`. Those differ on an empty string, which `WireService.saveWire:53–56` can write straight from the LWC's `''`-initialised inputs. Salesforce normally normalises `''` to null on save for text fields, so this is probably inert — but it is an unverified platform assumption sitting under a stated invariant.

**Recommended fix:** don't chase (2) — verify it once and, if inert, ignore it. For (1), soften the claim in all four places to *"the same row the UI badge reads, except on a `CreatedDate` tie, which the Flow Get Records element cannot break"*, or explicitly accept it. The claim as written is stronger than the mechanism supports, and the whole point of Q3 was that these two must not disagree.

### W5 — The disposition seed scripts were not swept for the record-type stamp

**Files:** `scripts/seed-disposition.apex:12`, `scripts/seed-dispositions.apex:38,43,48`, `scripts/seed-disposition-bulk.apex:14,23,33,43`.

Design §5.5 required `TestDataFactory` to stamp a record type — **done, and done well** (`TestDataFactory.cls:1673–1759`, guarded on `isAvailable()`, both types exposed as constants, `Completed` deliberately never seeded). The seed scripts create dispositions at `BOV Outreach`, `Active Listing` and `Closing` with **no `RecordTypeId`**, so they inherit the running user's profile default — which is org state (gate A3) and, before A1/A3 land, is the **Master** type. A seeded `Active Listing` row on an `Off_Market` default would carry a stage outside its own type's value set and match no Path step; record-type restrictions are UI-only, so Apex will insert it silently.

**Recommended fix:** one line per script — `RecordTypeId = TestDataFactory.DISPOSITION_RT_ON_MARKET`-equivalent describe lookup, or simply route the scripts through the factory. Same reasoning the factory itself already documents.

---

## 🟢 SUGGESTIONS

### S1 — Stale class-header reference after the `bandForPeak` move
`PropertyAssetSelector.cls:36` still says *"the readiness band (`SellMeterController.bandForPeak`)"*. Everywhere else in the same file correctly names `SellMeterService`. One-line fix; matters only because that header is otherwise the best documentation of the sell-candidate filter.

### S2 — `TestDataFactory.dispositionRecordTypeId`'s allow-list doesn't deliver the guarantee its Javadoc claims
`TestDataFactory.cls:1747–1758`. The guard uses `recordTypeDeveloperName != DISPOSITION_RT_ON_MARKET`, and Apex `String` `==`/`!=` is **case-insensitive**, while `Map<String, RecordTypeInfo>.get()` is **case-sensitive**. So `'on_market'` passes the allow-list, misses the describe map, returns null, and silently falls back to the platform default — the exact outcome the Javadoc says it prevents (*"a typo fails loudly instead of silently producing a default-record-type fixture"*). Fix: `if (!DISPOSITION_RT_ON_MARKET.equals(name) && !DISPOSITION_RT_OFF_MARKET.equals(name))`.

### S3 — `NdaSelector.selectLatestByDispositionId` has no `Id DESC` tie-break
`NdaSelector.cls:108–116`. Its sibling `WireSelector.selectMostRecentByDispositionId:61` has one. `BovControllerTest:202–203` had to insert a `Test.setCreatedDate` call to make the "most recent wins" test deterministic — which is the tell. Adding `, Id DESC` makes the contract deterministic and lets that workaround go.

### S4 — `manifest/package.xml` is stale, and do **not** hand-author a `FlowDefinition` for the new flow
`manifest/package.xml:144–148` lists only the two Opportunity approval processes; the three new `Disposition__c` ones, `Wire_Verification_Rollup`, both new Paths, the two record types and the validation rule are all absent. If DevOps deploys `--manifest`, the tranche silently under-deploys. Confirm the plan is per-component `--source-dir` (which §7's staged D1–D6 shape implies) or refresh the manifest.

Separately: every one of the 23 existing flows has a `flowDefinitions/*.flowDefinition-meta.xml` carrying `<activeVersionNumber>`; `Wire_Verification_Rollup` has none. **That is correct** — those files are retrieve artifacts, `<status>Active</status>` on the flow is sufficient, and authoring `activeVersionNumber` for a version that does not exist yet can fail the deploy. Flagging it so nobody "fixes" the inconsistency.

---

## ⚖️ JUDGEMENT CALLS — risks I think the design or a decision got wrong (not filed as defects)

### J1 — The wire gate is an anti-fraud control that can be cleared *after* the fact (Q4)

`Wire_Complete_Before_Completed` fires only on `OR(ISNEW(), ISCHANGED(Disposition_Stage__c))`. That shape is correct for the stated purpose and I would not change it — trapping rows already at `Completed` would block every subsequent edit. But the consequence is that the sequence *complete the wire → move to Completed → untick the verbal checkbox on the Wire* leaves a Completed disposition with `Wire_Verification_Completed__c = false` and no signal anywhere. The field description and the flow both call this an anti-fraud gate; a control that can be reversed after it has been passed is a **process** control, not a fraud control.

I am not recommending a change in this tranche (a second rule would have to except the flow's own write, which is fiddly). I am recommending the language be right: describe it as *"blocks the Completed transition"*, not as anti-fraud, so nobody later relies on it for something it does not do. If real fraud protection is wanted, that is field history tracking on the six Wire fields plus a report — a separate item.

### J2 — Q1's "switch the record type early" route has no guard rail, and this tranche made the failure mode worse

D11/Q1 accepts that off-market deals are handled by *changing the record type while the record is still at Readiness*. Nothing enforces "while at Readiness". After this tranche the two value sets are **disjoint**, so a record type switched at, say, `Active Listing` lands on a stage that is not in `Off_Market`'s set: Salesforce's Change Record Type UI does not remap custom-object picklist values, so the record keeps `Active Listing`, matches no `Disposition_Path_Off_Market` step, and renders a Path with no current position. Before this tranche there was one value set and this could not happen.

Compounding it: `Sale_Decision_Approval` has `recordEditability = AdminOnly` and entry criteria `Disposition Readiness` — so during exactly the window in which the switch is supposed to happen, if an approval is pending, the owner **cannot** change the record type at all.

D5 already anticipated this ("if it turns out to be a real business case, it needs its own action"), so I am not filing it. But I would put a one-line validation rule on the backlog now — *block a record-type change when the current stage is not in the target type's set* — because the cost of it appearing in UAT as "the Path disappeared" is a lot higher than the cost of the rule.

### J3 — D11/Q6's mass migration and gate A2 are the single largest unprotected step in the plan

Nothing in the repo can verify A2 ran, and the symptom of it not running (existing rows on **Master**, `Disposition_Path` now `active=false`, so **no Path at all** on every pre-existing disposition) is indistinguishable from a rendering bug. The deploy order in §7 is right — GATE A sits between D1 and D3 — but "must complete before any Path is activated" is a human promise, not a mechanism. Recommend the migration script capture and print the before/after counts and be checked into `scripts/`, so the evidence survives the window. That is not a code change; it is making an irreversible-looking step auditable.

---

## ✅ VERIFIED CORRECT — the four things you asked me to look hardest at

1. **`DispositionService.findOrCreate` — the gate is create-branch-only, and the ordering is right.**
   `DispositionService.cls:104–124`. The existing-record early return is at line 106–110, **ahead** of both the `PropertyAssetSelector` read (112) and the band check (113). An existing Disposition is returned with no band read at all — so a RED re-band cannot orphan a live deal. Pinned by `DispositionServiceTest.findOrCreateReturnsAnExistingDispositionEvenWhenTheAssetIsNowRed:158–174`, which creates while GREEN, re-bands to RED, and asserts the same Id comes back plus a count of 1. That test would go red under any reordering. YELLOW creates (`findOrCreatePermitsAYellowAsset`), null peak refuses, and a missing asset throws `QueryException` **not** the gate exception — with a test that explicitly `Assert.fail`s if the gate type is caught (`:193–194`). This is exactly the right shape.

2. **`DispositionController.findOrCreate` — the `SellMeterGateException` catch is FIRST.**
   `DispositionController.cls:64–73`. Subclass catch above `catch (Exception e)`, refusal rethrown verbatim, platform failure masked. Better than that: `DispositionControllerTest` pins it with a **matched pair asserting opposite message contents** — `refusalSurfacesTheSellMeterWording:102–124` asserts the refusal text is present *and* the generic text is absent; `readPathsThrowAuraHandledException:185–211` asserts the exact inverse. Deleting the first catch turns the pair red. Asserting only "an `AuraHandledException` was thrown" would not have, and the test header says so explicitly. This is the strongest form of catch-order test I have seen in this repo.

3. **`BovController.readNdaStatusFailSoft` — the try block is genuinely narrow, and nothing else can fall into it.**
   `BovController.cls:123–132`. The `try` contains exactly two statements: the `NdaSelector` call and a null-guarded field read. The remaining seven fields of `OutreachSummary` are populated *before* line 89 from `DispositionSelector.selectOutreachById`, entirely outside it. `catch (Exception)` rather than `catch (QueryException)` is the right call and is justified in the method Javadoc (an FLS denial is a `QueryException` today, but nothing in the contract depends on the type, and a narrower catch re-opens the tile-blanking path for a neighbouring failure). Null-on-degrade is indistinguishable from null-on-no-NDA at the client, which is documented on the DTO field (`:25–34`) and honest.

4. **Layering conformance — clean, no exceptions needed.**
   Zero inline SOQL outside selectors in the changed set (I grepped: the only Disposition DML in the whole `classes/` directory is `DispositionService.cls:117`). `PropertyAssetSelector.selectPeakSellDateById` and `NdaSelector.selectLatestByDispositionId` are both `WITH USER_MODE`, and `PropertyAssetSelector`'s header (`:16–20`) carries a written justification for **not** being in the `ARCHITECTURE.md` §2 SYSTEM_MODE table — user-clicked read, no trigger/queueable/batch, a denial is a real provisioning gap. That is the correct reading of the rule and it is refreshing to see the negative case argued rather than assumed. `with sharing` on all four touched classes plus the new service. `AuraHandledException` only in controllers, via the repo-standard `ahe()` helper; services throw raw platform types. `SellMeterService` is a pure function with no state.

---

## ✅ OTHER GOOD PRACTICES FOUND

- **The record types are exactly as designed**: 8 on-market / 7 off-market, `NDA` and `Disposition Offer` off-market only, `Disposition Readiness` default in both, no `<businessProcess>`. The claim *"Disposition__c has exactly two picklists today"* — the one that makes the `Sell_Decision_Trigger__c` enumeration correct rather than lucky — I checked against all 20 field files and it holds. Both files enumerate all four `Sell_Decision_Trigger__c` values unchanged.
- **The XML-comment-inside-the-root pattern is applied correctly** in all three files that need it, each with the "must sit INSIDE the root element" warning preserved, and every `<description>` comfortably under 255 characters.
- **Path text discipline is exemplary.** Five steps copied byte-identical including the Active Listing text that is under OPEN #2, with the reason recorded in the file. The **one** deviation (Off_Market Readiness ending "advancing to NDA" rather than "advancing to BOV Outreach") is disclosed in the file's own comment as a deliberate, requested correction — and it is right, since BOV Outreach does not exist on that path. The deactivated `Disposition_Path` is retained with a comment explaining why deletion would be wrong and why `recordTypeName` cannot be re-pointed.
- **The flexipage inversion is correct and complete**: `1 OR 2 OR 3 OR 4` on `dispositionMain` against the four stages it actually renders, and the exact complement (`NE` × 4, ANDed) on the Details section. Exactly one occupant renders at every one of the ten stages, including all five new ones.
- **The three approvals match the D10 contract byte-for-byte**: `FirstResponse`, `allowedSubmitters` `owner`, both approver usernames identical to the deployed `Underwriting_Approval:22,26`, no `finalApprovalActions`/`finalRejectionActions` on any of the three (correctly justified — an approval field update would bypass the validation rule), mutually exclusive entry criteria, per-object `processOrder` 1/2/3, and `Wire_Verification_Completed__c` present in `Closing_Approval`'s `approvalPageFields:16`.
- **`Submit` is on the layout** at `sortOrder 3` with the other seven renumbered (`Disposition__c-Disposition Layout:69–93`), not via Dynamic Actions — the §1.3 premise correction was real and the trap was avoided.
- **`bandForPeak` was genuinely moved, not rewritten**, and `SellMeterServiceTest` pins **both sides** of both thresholds (30/31, 90/91) plus the three constant *string values* the LWC's `METER` map keys on. A `<=` → `<` "tidy" goes red.
- **LWC error handling is complete** on all three bundles: `sellMeterList` destructures the wire `error`, catches on the imperative call, surfaces `error.body.message` verbatim (correct — the server-side refusal is authored to be shown) and toasts; `bovOutreach` and `dispositionSidebar` both destructure `error` and render an inline `role="alert"` state. No swallowed wires, no silent writes. This bundle does not repeat the pattern the 2026-07-19 audit found.
- **Jest pins the user's own Gate-1 decision.** `sellMeterList.test.js` has the load-bearing pair — confirm-then-create *and* cancel-creates-nothing — plus a server-refusal test asserting the sell-meter wording survives to the toast. `dispositionSidebar.test.js` pins the four rendering stages **and** the three deliberate non-rendering ones (`PSA`, `NDA`, `Disposition Readiness`), which is what stops a future "helpful" widening.
- **`ARCHITECTURE.md` §6 currency** — `SellMeterService` is a new Apex service and would normally be a §6 finding, but it is a pure band function invoked from a controller and a service, not a cross-object orchestrator, so the §2 *Key Apex Services* table is arguably not the right home. I would still add a one-line row for discoverability, but I am not filing it: the tranche's own §6-relevant facts (the two record types, the new field, the derived-flag contract) are all documented at the metadata, which is where a reader will look.

---

## 📋 FILE-BY-FILE

| File | Status | 🔴 | 🟡 | 🟢 |
|------|--------|----|----|----|
| `flows/Wire_Verification_Rollup.flow-meta.xml` | 🔴 | 1 | 2 (W1, W4) | 0 |
| `approvalProcesses/Disposition__c.Closing_Approval` | 🔴 | (C1, joint) | 0 | 0 |
| `approvalProcesses/Disposition__c.Sale_Decision_Approval` | ✅ | 0 | 0 | 0 |
| `approvalProcesses/Disposition__c.Broker_Selection_Approval` | ✅ | 0 | 0 | 0 |
| `permissionsets/DPEG_Admin_Access` | 🟡 | 0 | 1 (W2) | 0 |
| `permissionsets/DPEG_Disposition_View` / `_Edit` | 🟡 | 0 | 1 (W3) | 0 |
| `permissionsets/DPEG_Acquisitions` | ✅ | 0 | 0 | 0 |
| `objects/Disposition__c/recordTypes/On_Market` · `Off_Market` | ✅ | 0 | 0 | 0 |
| `objects/Disposition__c/fields/Disposition_Stage__c` | ✅ | 0 | 0 | 0 |
| `objects/Disposition__c/fields/Wire_Verification_Completed__c` | ✅ | 0 | 1 (W4) | 0 |
| `objects/Disposition__c/validationRules/Wire_Complete_Before_Completed` | ✅ | 0 | 1 (W4) | 0 |
| `pathAssistants/Disposition_Path{,_On_Market,_Off_Market}` | ✅ | 0 | 0 | 0 |
| `flexipages/Disposition_Record_Page` | ✅ | 0 | 0 | 0 |
| `layouts/Disposition__c-Disposition Layout` | ✅ | 0 | 0 | 0 |
| `objectTranslations/…/Disposition_Stage__c` | ✅ | 0 | 0 | 0 |
| `classes/DispositionService.cls` | ✅ | 0 | 0 | 0 |
| `classes/DispositionController.cls` | ✅ | 0 | 0 | 0 |
| `classes/SellMeterService.cls` + `…Test.cls` | ✅ | 0 | 0 | 0 |
| `classes/SellMeterController.cls` | ✅ | 0 | 0 | 0 |
| `classes/PropertyAssetSelector.cls` | 🟢 | 0 | 0 | 1 (S1) |
| `classes/NdaSelector.cls` | 🟢 | 0 | 0 | 1 (S3) |
| `classes/BovController.cls` | ✅ | 0 | 0 | 0 |
| `classes/TestDataFactory.cls` | 🟢 | 0 | 0 | 1 (S2) |
| `lwc/sellMeterList` | ✅ | 0 | 0 | 0 |
| `lwc/bovOutreach` | ✅ | 0 | 0 | 0 |
| `lwc/dispositionSidebar` | ✅ | 0 | 0 | 0 |
| `scripts/seed-disposition*.apex` | 🟡 | 0 | 1 (W5) | 0 |
| `manifest/package.xml` | 🟢 | 0 | 0 | 1 (S4) |

---

## 🏁 VERDICT

❌ **CHANGES REQUIRED** — one critical issue.

To be plain about the proportion: **this is a high-quality changeset.** The Apex is the cleanest layering conformance I have reviewed on this program, the tests are built to *fail* rather than to pass, the metadata carries its own reasoning in the right places, and every premise correction in §1 of the design turned out to be real. Eleven of the twelve things I set out to check came back correct.

The one blocker is not a coding error — it is an interaction between two artifacts that were each designed correctly in isolation and shipped together for the first time here. `Wire_Verification_Rollup` writes to a record that `Closing_Approval` locks, at the one stage they both target, with no fault path. `runInMode` does not help, and this repo has already paid for that exact lesson once. The fix is 20 minutes of Flow work behind a 5-minute in-org check.

W1 is the second thing to settle before the D6 deploy, because it either blocks the deploy loudly (safe) or does not — but you will find out during `RunLocalTests`, and it is cheaper to find out on purpose.

**If C1 does not reproduce in the org, the verdict becomes APPROVED WITH WARNINGS.**

---

## 👤 USER ACTION REQUIRED

1. **Reproduce or clear C1** — disposition at `Closing`, submit for approval, save a Wire. 5 minutes.
2. If it reproduces → **[F] send back** to `salesforce-developer` / `salesforce-solution-architect` for the Decision + fault connector + Path/description wording, then request re-review of the flow only.
3. Run `DispositionControllerTest`, `WireControllerTest`, `WireSelectorTest` against an org with the flow active before D6 (W1).
4. Decide on W2 (add the admin FLS grant + gate A4) and W3 (accept the `viewAllRecords` widening, or don't).
5. W4/W5 and all four suggestions can ride in the same fix pass — none of them blocks.

---
---

# 🔍 CODE REVIEW REPORT — PASS 2 (RE-REVIEW AFTER THE FIX ROUND)

**Review date:** 2026-08-09 (second pass)
**Branch:** `feature/stage-by-stage-alignment`
**Scope:** the fix round only — C1 and W1–W5, S1/S2/S4, plus regression sweep and the two D13 residuals.
**Reference docs read:** pass 1 above, `agent-output/stage-by-stage-decisions.md` (D11/D12/**D13**), `design-requirements-disposition-foundations.md` §7–§8, `ARCHITECTURE.md`, `CLAUDE.md`.

**Not re-derived** (per the brief): validate `0Afiw000000HBqTCAW` (21/21 components, 119 tests, 0 failures, 0 coverage warnings), the earlier 118-component declarative validation, the coverage figures, the two accepted uncovered lines, and the `findOrCreate` bulk-test exemption.

**Not re-raised** (per D12): W3 `viewAllRecords` on `NDA__c`. It is an accepted, informed widening; the in-root XML comment in both disposition permission sets is thorough, states the cost plainly ("a disposition-only persona can now read EVERY NDA in the org"), names the revisit trigger (NDA record types, D7), and pairs the two files ("both must move together"). Documentation is **adequate** — no suggestion.

---

## 📊 SUMMARY — PASS 2

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | **0** |
| 🟡 WARNING | 3 (all new; all second-order consequences of the C1 fix or of claims made while writing it) |
| 🟢 SUGGESTION | 4 |
| ✅ Pass-1 findings verified closed | 9 of 9 |

**C1 is genuinely fixed. Every pass-1 finding is closed on disk.** The three new warnings are what the fix itself introduced or what the fix round asserted without checking — none of them blocks a deploy, and two are one-line documentation corrections.

---

## ✅ PASS-1 FINDINGS — VERIFIED CLOSED

| # | Verified at | Verdict |
|---|---|---|
| 🔴 C1 | `Wire_Verification_Rollup.flow-meta.xml:18–40` (`Flag_Changed`), `:88–90` (`faultConnector`), `:4–17` (`Record_Flag_Update_Fault`), `:87` (rewritten element description), `Disposition_Path_On_Market:69` / `Disposition_Path_Off_Market:66` (identical wire-before-submit sentence) | **Closed.** Shape is correct — see below. |
| 🟡 W1 | tests untouched | **Closed as a risk**, but the *evidence* is weaker than D13 records — see S1 (pass 2). |
| 🟡 W2 | `DPEG_Admin_Access:44–48` + `:10–41` comment + design §8 gate A4 | **Closed, and better than asked.** |
| 🟡 W3 | `DPEG_Disposition_View:8–32`, `DPEG_Disposition_Edit:8–33` | **Accepted, documented adequately.** |
| 🟡 W4 | `NdaSelector.cls:120` (`ORDER BY CreatedDate DESC, Id DESC`) + `:97–101`; flow residual at `Wire_Verification_Rollup:41` | **Closed** (tie-break) / **documented** (Flow single-sort). |
| 🟡 W5 | `seed-disposition.apex:24–42`, `seed-dispositions.apex:44–75`, `seed-disposition-bulk.apex:29–76` | **Closed**, 8 sites; `seed-disposition-offers.apex` correctly untouched. |
| 🟢 S1 | `PropertyAssetSelector.cls:37` now names `SellMeterService.bandForPeak` | Closed. |
| 🟢 S2 | `TestDataFactory.cls:1757–1764` constant-first `.equals()` + `:1747–1755` rationale | Closed. |
| 🟢 S4 | `manifest/package.xml` — ApprovalProcess ×3 (`:154–156`), Flow (`:1480`), PathAssistant ×2 (`:2128–2129`), RecordType ×2 (`:2273–2274`), ValidationRule (`:2992`), CustomField (`:431`), both permission sets (`:2148–2149`). `FlowDefinition` (`:1506–1508`) correctly **not** extended. | Closed. |

---

## 1. THE C1 FIX ITSELF — is the shape right?

**Yes, on all four questions asked.**

- **The Decision is correct and total.** `Flag_Changed` compares `$Record.Disposition__r.Wire_Verification_Completed__c` against `isComplete` with `NotEqualTo`, routing to the update only on a mismatch; the default connector is absent so the flow ends. The field is a Checkbox with `defaultValue false` (`Wire_Verification_Completed__c.field-meta.xml:4`), so it is never null and the comparison is total — the element description says exactly this and it checks out. It cannot desynchronise badge from gate: it writes *precisely when* they differ.
- **The fault path fails safe and silent.** `processType` is `AutoLaunchedFlow` with no screen element; the fault connector routes to an Assignment that ends with no connector. A **handled** fault in a record-triggered flow neither surfaces to the user nor rolls back the triggering DML, and suppresses the flow-error email. The Wire save commits. Correct.
- **Nothing else in the flow writes a lockable record.** `Get_Most_Recent_Wire` is a read; `Update_Disposition_Flag` is the only write and now carries the fault connector. I widened the check beyond this flow: `Wire_Verification_Rollup` is the **only** flow in `flows/` that references `Disposition__c` at all, and `DispositionService.cls:122` (an `insert`) is the only Disposition DML in `classes/`. So the lock analysis is complete — there is exactly one automation that can hit a locked Disposition and it is now handled.
- **The rewritten `<description>` is truthful** on the substance: it names the C1 mechanism, explicitly retracts the old "no fault connector is deliberate" claim, and cites the in-repo `OpportunityReviewService` precedent for system-mode-does-not-lift-a-lock. Two sentences elsewhere in the same file are **not** truthful — W2 and W3 below.

**Bonus, and worth stating because it changes how W1 should be read:** the fault connector also neutralises W1's failure mode. If a consolidated parent update ever did throw `DUPLICATE_VALUE: duplicate id in list`, that is a DML error on `Update_Disposition_Flag` and it now routes to `Record_Flag_Update_Fault` — costing a stale flag, not the wire insert. W1 is bounded now regardless of whether it was ever real.

---

## 🟡 WARNINGS — PASS 2

### W1 (pass 2) — the fault path lets the anti-fraud gate fail **OPEN**, and the written justification stops at the lock boundary

**Files:** `Wire_Verification_Rollup.flow-meta.xml:9` and `:87`; `Disposition__c.Closing_Approval.approvalProcess-meta.xml:43` (`finalApprovalRecordLock=false`); design §8 gate **B9**.

Three places now carry the same reasoning: *"a stale flag is harmless while the lock holds — the stage cannot change while locked either, so `Wire_Complete_Before_Completed` is unreachable in that window."* That is true, and it is **only true inside the window.** `finalApprovalRecordLock` and `finalRejectionRecordLock` are both `false`, so the record unlocks the moment the approval resolves — and **nothing re-fires the rollup.** The flag stays stale until someone saves a Wire again.

The fail-**closed** direction is benign and already signposted: wire completed during the lock → flag stuck `false` → the owner is blocked at Completed until they re-save the Wire. Annoying, recoverable, and B9 already tells the tester to do exactly that.

The fail-**open** direction is the one nobody wrote down:

1. Disposition at `Closing`, wire complete, flag = `true`.
2. Owner submits for `Closing_Approval` → `recordEditability = AdminOnly` locks the record.
3. Someone unticks verbal verification (or saves a newer, incomplete Wire). `isComplete` → `false`, flag is `true`, so `Flag_Changed` **passes**, the update throws `ENTITY_IS_LOCKED`, the fault swallows it, **flag stays `true`.**
4. Approval resolves; the record unlocks; **nothing re-runs the flow.**
5. Owner moves `Closing → Completed`. The VR reads the stale `true` and **allows it.** A disposition is Completed against an unverified wire, with no signal anywhere — and the approval page showed the approver a stale `true` in step 3 as well.

Before the fix, step 3 rolled the wire save back, so the untick never persisted and flag and wire stayed consistent. **The fix is still the right trade** — a lost wire record is worse — but it trades a loud failure for a quiet divergence, and the divergence outlives the condition the docs use to excuse it.

This is a narrow instance of pass-1 judgement call **J1** (the gate is a process control, not a fraud control), which the user has already accepted — so I am not escalating it. But the reasoning as written will stop the next reader from noticing it.

**Recommended fix (documentation + one UAT step, no code):**
- Extend **B9** with the reverse order: put a disposition at `Closing` with a **complete** wire, submit, then **reduce** the wire (untick verbal), approve, and confirm the operator must re-save the Wire before `Completed` is honestly reachable. B9 currently only walks the fail-closed path.
- Amend the sentence in `Wire_Verification_Rollup:87` and design §8 B9 to read *"harmless **while the lock holds**; after the approval resolves the flag remains stale until the next Wire save, which is why B9 requires that save"* — so the excuse is scoped to the window it actually covers.

### W2 (pass 2) — the flow asserts *"no permission set grants `allowDelete` on `Wire__c`"*. That is false.

**Files:** `Wire_Verification_Rollup.flow-meta.xml:41` (last sentence of the flow `<description>`); `DPEG_Acquisitions.permissionset-meta.xml:2196–2204`.

The claim justifies not handling `Wire__c` deletes: `recordTriggerType` is `CreateAndUpdate`, so a delete never recomputes the parent. `DPEG_Disposition_Edit:398–404` does set `allowDelete=false` — but `DPEG_Acquisitions:2197–2203` grants `allowCreate`, `allowDelete`, `allowEdit`, **`modifyAllRecords`** and `viewAllRecords` on `Wire__c`. Any admin also has Modify All Data, and `profiles/**` is `.forceignore`d so no file-based check can support a negative claim about permissions anyway.

Consequence: delete the most-recent (complete) Wire and the flag stays `true` while the badge falls back to an older or absent wire — the same fail-open shape as W1 above, and a live counter-example to the "badge and gate cannot disagree" invariant that four artifacts assert. Low frequency; real mechanism.

**Recommended fix:** correct the sentence (2 minutes) — *"Wire DELETE is not handled. `DPEG_Acquisitions` grants `allowDelete` + `modifyAllRecords` on `Wire__c`, and any admin has Modify All Data, so a delete of the most-recent Wire leaves a stale flag until the next Wire save."* Optionally add a `RecordAfterDelete`-triggered variant later; not now. A false premise is worse than an admitted gap because it closes the question.

### W3 (pass 2) — `Record_Flag_Update_Fault`'s observability claim is wrong, so the swallowed error is effectively unrecoverable

**File:** `Wire_Verification_Rollup.flow-meta.xml:9` and `:121`.

Both say the captured `$Flow.FaultMessage` is *"visible in the interview detail and the debug log."* A **completed** autolaunched flow interview is not retained — only **paused** interviews appear in Setup → Paused Flow Interviews. There is no interview detail to open. The debug log is real but only if a trace flag happens to be active on that user at that moment, which for an after-save flow triggered by an IR persona it will not be.

So the fault is, in practice, **entirely unobservable in production** — which matters more than usual because of W1 above: the one state that can silently pass the anti-fraud gate is the one state that leaves no trace.

**Recommended fix — pick one:**
- *(minimum, and do this regardless)* correct both sentences to say the message is captured **for the debug log only, and is not retrievable after the fact**; or
- *(if a signal is wanted)* add a `Send Email` action or a Platform Event on the fault path. This is an **operational** signal, not a business notification, so D9's notification deferral does not cover it — but it is scope and I would not hold the deploy for it.

---

## 🟢 SUGGESTIONS — PASS 2

### S1 (pass 2) — D13's W1 row overstates what the re-run proved; the three 251-wire tests no longer reach the update at all

**Files:** `TestDataFactory.cls:1902–1917`; `WireControllerTest.cls:202`, `DispositionControllerTest.cls:223`, `WireSelectorTest.cls:105`.

`createWires` seeds `Verbal_Verification_Completed__c = false` and **never sets `Verified_DateTime__c`** — two of the six terms in `isComplete` are therefore false/blank, so `isComplete` is `false`; the parent flag is `false` by default; `Flag_Changed` evaluates `false != false` → **default path → no parent update.** With the flow as it now stands, **none of the three 251-record methods touches `Update_Disposition_Flag`.**

Whether the "24 tests, 0 failures" run disproved anything therefore depends on **which flow version it carried**: pre-fix (unconditional update) it is a genuine disproof; post-fix it is vacuous. That is not recorded anywhere, so the safest reading of D13's *"FALSE ALARM — disproven by running it"* is that it is stronger than the evidence.

I am **not** asking for a test change, and I still agree the 251 counts must not be reduced. The risk is bounded three ways: the fault connector now converts any such failure into a stale flag; 251 wires under one disposition is a data load, not a user action; and `WireServiceTest.saveWireCreatesAndStampsVerifiedDateTime:31` **does** save a fully-populated wire, so the single-record update path was exercised (unasserted) inside the green 119-test run. **Action: correct the D13 W1 row** to say the shape is bounded by the fault connector rather than disproven, and note which flow version the run carried if anyone remembers.

### S2 (pass 2) — RESIDUAL 1: A2's read-back is necessary but **not sufficient**; the production create path has the same guard and no gate

**Files:** `DispositionService.cls:118–121` and `:137–142`; design §8 gates A2 / B8.

D13 frames the `isAvailable()` residual as affecting `TestDataFactory` and the seeds. It affects a third caller, and that one is production: `DispositionService.onMarketRecordTypeId()` uses the identical `info != null && info.isAvailable()` guard, so if availability is genuinely false for the `DPEG_Disposition_Edit` persona post-deploy, **every disposition created by the Sell Meter button silently lands on the platform default record type** — no Path, all ten stage values, i.e. exactly the state A2 exists to eliminate, recreated one click at a time. A2 verifies *migrated* rows; **B8 creates a disposition through the Override and never reads its `RecordTypeId` back.**

**Answering the question the brief asks directly: no, the guard should not fail loudly.** Fail-soft is right in `DispositionService` — a missing record type must not block a live business action, and that reasoning is already written into the class header. The problem is not the softness, it is the **silence**. Fix the silence in two cheap places:

1. **Extend gate B8** — after the Override creates the disposition, `SELECT Id, RecordTypeId, Disposition_Stage__c FROM Disposition__c WHERE Id = :newId` and confirm the record type is `On_Market`, not the default. Run it as `DPEG_Disposition_Edit`, not as an admin (the pass-1 and repo-wide lesson: an admin smoke test proves nothing about a persona gate, and this org has already measured an admin with a resolvable record type Id and `isAvailable() == false`).
2. **One permanent falsifier** — see S3 below.

Three permission sets carry `recordTypeVisibilities` for both types (`DPEG_Disposition_Edit:414–421`, `DPEG_Acquisitions:2205–2212`, `DPEG_Admin_Access:56–63`), which is the right coverage; combined with the fact that the observed `false` came from a **check-only** transaction where the record types and the permission sets were both being applied in the same uncommitted context, I think the residual is most likely a validation artifact. But "most likely" is not a gate, and a read-back costs one query.

### S3 (pass 2) — RESIDUAL 2: the `TestDataFactoryTest` that is missing is also the falsifier residual 1 needs

`TestDataFactory` is `@isTest` (`:123–124`), so a test class for it costs nothing in coverage terms and is legal (an `@isTest` class's methods are callable from another test class). Three methods close both residuals at once:

```
1. dispositionRecordTypeId_caseTypo_throws        -> createDispositions(1, assetId, 'on_market', false)
                                                     expects TestDataFactoryException   (pins S2 forever)
2. createDispositions_stampsOnMarket              -> Assert.areEqual(<On_Market Id>, d.RecordTypeId)
3. createDispositions_stampsOffMarket             -> same for Off_Market
```

Assert (2)/(3) **unconditionally**, not `if (isAvailable())` — a guard there makes the assertion vacuous under exactly the condition of interest. The factory keeps its soft guard so the other ~600 tests stay green; **one** test goes red and names the cause if the record type is not available to the test-running user. Deploy order already puts Apex (D6) after GATE A, so A1 will be done by then.

### S4 (pass 2) — the strengthened A2 wording lives only in D13, not in the gate list DevOps will actually run

`design-requirements-disposition-foundations.md:588–590` still reads *"Verify the count before and after."* The read-back requirement from D13 ("`SELECT RecordTypeId, Disposition_Stage__c` — a seed that ran without error is not evidence") is not there. §8 is the operational checklist; D13 is the decision log. Copy the sentence across.

---

## 🔁 REGRESSION SWEEP — what I checked and found clean

- **D11/Q3 (badge ⇔ gate) is not regressed by the Decision.** It writes exactly when the two differ, so it is a no-op on the invariant. The two ways they *can* diverge are W1 (pass 2) and W2 (pass 2) above, plus the already-documented Flow single-sort residual.
- **`TestDataFactory` changed only as stated.** The S2 edit is confined to `dispositionRecordTypeId`'s guard; `createDispositions` is otherwise untouched. Repo-wide sweep for a stage/record-type mismatch introduced by the On_Market stamp: **zero** — no test or seed sets `Disposition_Stage__c` to `NDA`, `Disposition Offer`, `LOI`, `PSA`, `Call for Offers` or `Completed` anywhere. The pass-1 `ISNEW()` sweep still holds.
- **The seed scripts changed only as stated.** All three use the identical describe-not-query block with the same rationale comment; every seeded stage (`Disposition Readiness`, `BOV Outreach`, `Active Listing`, `Closing`) is On_Market-valid, and each script says so. `seed-disposition-bulk.apex:109–120` incidentally creates two fully-populated wires, so running it post-deploy is a free live exercise of the rollup's true branch — worth doing right before B6.
- **`NdaSelector`'s `Id DESC` is additive** and cannot change which row wins except on a `CreatedDate` tie, where it replaces non-determinism with "highest Id" — which is the later-inserted row, i.e. the intended "most recent". `BovControllerTest`'s `Test.setCreatedDate` disambiguation still passes and can stay.
- **Path text discipline held.** Both Closing steps carry the byte-identical appended sentence; `fieldNames` unchanged; the deviation is disclosed in both files' comments, each pointing at the other. Off_Market's `Disposition Readiness` deviation from pass 1 is still the only other one.
- **No new `flowDefinition` was hand-authored**, and the manifest correctly omits one for `Wire_Verification_Rollup` while listing the Flow itself.

---

## ✅ GOOD PRACTICES — PASS 2

- **The C1 fix is the fix that was agreed, not a near-miss of it** — Decision *and* fault connector (the fix round understood that the Decision alone is insufficient and says so at `:23`), both Paths, and the element description **retracted** its previous claim in place rather than being left to contradict the code. Retracting a superseded justification is rarer than writing a new one and worth naming.
- **W2's grant is read-only, and the reasoning for that is exactly right** — an editable admin grant on a DERIVED anti-fraud flag would let an administrator hand-set the value the validation rule reads. The comment contrasts it with the editable `OneDrive_URL__c` entry directly above. It also re-states the permission-set-deploy-REPLACES warning at the point of use.
- **Gate A4 is written as two separate proofs** ("an admin smoke test proves nothing about the named approvers, and vice versa: **both** must be opened") — that is the correct reading of this repo's recurring persona-testing lesson.
- **W5 counted the sites rather than trusting the brief.** The brief said 4 files; the fix round found 8 creation sites across 3 and correctly identified `seed-disposition-offers.apex` as creating no `Disposition__c` at all.
- **S2's fix names the asymmetry that caused the bug** (Apex `String ==` is case-insensitive; `getRecordTypeInfosByDeveloperName()` is case-sensitive) and confirms the null-argument path is unchanged. That is a fix whose comment would let a reviewer re-derive it.
- **W1 was disproven rather than accommodated.** Running the thing instead of reducing the test counts to dodge it is the right instinct, and reducing them would have deleted real bulk-safety proof. My S1 above narrows *what* was proven; it does not fault the approach.

---

## 📋 FILE-BY-FILE — PASS 2 (changed files only)

| File | Status | 🔴 | 🟡 | 🟢 |
|------|--------|----|----|----|
| `flows/Wire_Verification_Rollup.flow-meta.xml` | 🟡 | 0 | 3 (W1, W2, W3) | 0 |
| `pathAssistants/Disposition_Path_On_Market` · `_Off_Market` | ✅ | 0 | 0 | 0 |
| `permissionsets/DPEG_Admin_Access` | ✅ | 0 | 0 | 0 |
| `permissionsets/DPEG_Disposition_View` · `_Edit` | ✅ | 0 | 0 | 0 |
| `permissionsets/DPEG_Acquisitions` | 🟡 | 0 | (W2, as the evidence) | 0 |
| `classes/NdaSelector.cls` | ✅ | 0 | 0 | 0 |
| `classes/PropertyAssetSelector.cls` | ✅ | 0 | 0 | 0 |
| `classes/TestDataFactory.cls` | 🟢 | 0 | 0 | 2 (S1, S3) |
| `classes/DispositionService.cls` (unchanged, re-examined) | 🟢 | 0 | 0 | 1 (S2) |
| `scripts/seed-disposition{,s,-bulk}.apex` | ✅ | 0 | 0 | 0 |
| `manifest/package.xml` | ✅ | 0 | 0 | 0 |
| `design-requirements-disposition-foundations.md` §8 | 🟢 | 0 | 0 | 1 (S4) |

---

## 🏁 VERDICT — PASS 2

⚠️ **APPROVED WITH WARNINGS.**

The critical is closed properly. The fix is the one that was agreed, it is shaped correctly, it fails safe and silent, nothing else in the tranche writes to a lockable `Disposition__c`, and the descriptions were **retracted and rewritten** rather than left contradicting the code. Eight of nine pass-1 findings are closed outright and the ninth (W3) is an accepted decision documented better than I asked for.

Nothing outstanding blocks the deploy:

- **W2 (pass 2)** is a two-minute correction of a false sentence and should be done before deploy purely because a wrong premise closes a question permanently.
- **W1 (pass 2)** and **S2/S4 (pass 2)** are gate and wording changes to §8 — they belong in the deploy runbook, and B9/B8 are executed by a human anyway.
- **W3 (pass 2)** is a sentence correction plus an optional signal.
- **S1/S3 (pass 2)** are record-keeping and one small test class; neither gates anything.

If the intent is to deploy today: take **W2** and the **B8/B9 gate extensions**, and carry the rest into the Tranche-3 pass.

---

## 👤 USER ACTION REQUIRED — PASS 2

1. **[D] Deploy** — recommended, after the two-minute W2 sentence fix and the B8/B9 gate edits.
2. Run **B9 in three orders**, not two: wire-then-submit, submit-then-wire, and **submit-then-REDUCE-the-wire-then-approve** (the fail-open case, W1 pass 2).
3. Extend **B8** with the `RecordTypeId` read-back as a `DPEG_Disposition_Edit` user — this is the only thing that settles D13 residual 1 for the production create path.
4. Optional, cheap, closes residual 2: the three-method `TestDataFactoryTest` in S3.
