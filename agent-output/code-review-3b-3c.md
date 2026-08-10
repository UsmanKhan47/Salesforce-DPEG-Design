# 🔍 CODE REVIEW REPORT — Tranches 3B (disposition LOI) + 3C (disposition PSA)

**Review date:** 2026-08-10
**Branch:** `feature/stage-by-stage-alignment`
**Files reviewed:** 41 (11 Apex + 6 Apex test suites read for assertion quality, 20 declarative, 4 LWC bundles)
**Reference docs read:** `agent-output/stage-by-stage-decisions.md` (D1–D25), `agent-output/code-review-3a-nda.md`, `agent-output/code-review-disposition-foundations.md` (both passes), `agent-output/design-requirements-disposition-loi-psa-nda.md`, `CLAUDE.md`, `ARCHITECTURE.md`, `.claude/rules/{apex-layering,bulk-test}-rule.md`

**Not re-litigated** (per the brief): the 2468-component check-only pass, the ~25 deliberately-red T-A1 tests, the 97-suite/622-test Jest pass, the two-phase sharing-rule deploy (D19.2), the D25 version-counter residual, and the D21/D24 `viewAllRecords` widenings on `Counter_Offer__c` / `PSA_Version__c`.

---

## 📊 SUMMARY

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | 4 |
| 🟡 WARNING | 4 |
| 🟢 SUGGESTION | 5 |
| ⚖️ JUDGEMENT CALL (not a defect) | 3 |

**All six things you asked me to look hardest at came back correct.** `ContractExecutionService`'s disposition arm is right in every particular I could check — the early return genuinely moved inside the acquisition arm, the no-change filter is real and pinned on DML rows, `allOrNone = false` and `SYSTEM_MODE` are argued as two different mechanisms for two different obstacles, and the acquisition arm is a byte-identical extraction. The `RecordStageAdvanceService` gate split resolves per record type with both polarities asserted, the LOI explicit targets are record-type-scoped in **both** directions, `CounterOfferService`'s derived label makes a cross-record-type write structurally impossible, the `PsaVersionSelector` mode split is right and justified at the methods, and both new LWC bundles match `ndaMarkDeclined` line for line.

**And exactly the same thing happened as in 3A: the server side is finished and the user-facing half is not — only this time it is worse, because there is no way to create the records at all.** Three of the four criticals are the *same defect shape the changeset's own files predicted in writing and then did not act on*. The fourth is a live cross-module notification leak that the design specified as a one-element flow change and that nobody made.

---

## 🔴 CRITICAL ISSUES (must fix before deployment)

### C1 — Nothing in the application can create a disposition LOI or a disposition Contract Review. Both features are unreachable by every persona, including an administrator, through the UI.

**Evidence, six independent halves, all pointing the same way:**

| # | File | Finding |
|---|---|---|
| 1 | `classes/DispositionStageEntryService.cls:92`, `:140` | The **only** stage it acts on is `NDA`. Its own header `:6–9` still reads *"TODAY IT DOES EXACTLY ONE THING… Tranches 3B and 3C add the disposition LOI (`LOI` stage) and the disposition PSA (`PSA` stage) **here**."* Neither was added. |
| 2 | `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml:1394–1402` | `LOI__c` `allowCreate=false` |
| 3 | same file `:1412–1420` | `Contract_Review__c` `allowCreate=false` |
| 4 | `flexipages/Disposition_Record_Page.flexipage-meta.xml:292–293` | The only related list is `NDAs__r`. Design §4.8 required **three** — LOI at stage `LOI`, Contract Review at `PSA`, NDA at `NDA`. |
| 5 | `layouts/LOI__c-LOI Layout.layout-meta.xml` and `layouts/Contract_Review__c-Contract Review Layout.layout-meta.xml` | **Neither carries `Disposition__c` at all.** Both record pages render `force:detailPanel`, i.e. the layout, so the parent lookup cannot be set by hand by anyone — a `DPEG_Acquisitions` holder with `allowCreate`, `modifyAllRecords` and both record types visible still has no field to populate. |
| 6 | `permissionsets/DPEG_Disposition_Edit` `:1439`, `:1443` | `recordTypeVisibilities` exist for `NDA__c.Disposition_NDA` and `Contract_Review__c.Disposition_PSA` — and **none for `LOI__c.Disposition_LOI`**. |

Plus `applications/Disposition.app-meta.xml:3–29` carries `View` actionOverrides for `Disposition__c`, `NDA__c` and `Property_Asset__c` only, so even a record reached some other way opens on whichever page the org assigns rather than on `LOI_Record_Page` / `Contract_Review_Record_Page` where the actions live — the exact gap D20/C2 closed for `NDA__c` in the same changeset.

**The only production creators of either object are `OpportunityReviewService.cls:266` and `:333`, both acquisition-only** (repo-wide grep for `new LOI__c` / `new Contract_Review__c` outside tests returns four sites: those two, `ApprovalAuditService:90` and `CounterOfferService:177`/`PsaVersionService:85`, all Id-only stamps).

**This is not an inference — the changeset predicted it twice and proceeded anyway:**

- `DPEG_Disposition_Edit:167–173`: *"⚠ allowCreate IS FALSE, AND THAT IS EXACTLY THE SHAPE THAT FAILED FOR NDA__c ABOVE… if 3B's LOI auto-create turns out to be PARTIAL in the way D19.1 made the NDA one partial, **THIS GRANT MUST MOVE WITH IT** rather than being rediscovered in a second review. **Whoever builds 3B owns that check.**"* 3B built the LOI and did not do the check.
- `DPEG_Disposition_Edit:470–479`: *"⚠ THIS IS THE EXACT SHAPE THAT FAILED FOR NDA__c AT D20/C2… It is followed here only because the premise is **MEASURED, not assumed**: Contract_Review__c is created by OpportunityReviewService on the acquisition side **and by the D16.2 auto create on the disposition side**, both in system mode."* 🔴 **That premise is false.** There is no D16.2 auto-create for `Contract_Review__c`; `DispositionStageEntryService` handles `NDA` only. The word "MEASURED" is doing work no measurement supports.

**Consequence.** Every other artifact in 3B and 3C is downstream of a record that cannot exist: the two Paths, the four quick actions, the two loop LWCs, the record-type-scoped allow-lists, the two sharing-rule pairs, the gate split, `CounterOfferService`'s inversion fix and `ContractExecutionService`'s disposition arm. A green deploy and a green `RunLocalTests` both pass — the Apex tests create their fixtures through `TestDataFactory.createDispositionLoi` / `createDispositionContractReview`, which is system-mode DML and consults none of the six blockers above. This surfaces in UAT gates **T-D1** and **T-C2** as "there is no New button", not as an error.

**Fix — pick one route and record it, because D16.2 currently reads as though all three were built.**

- **(a) Auto-create, per D15/Q3 + D16.2.** Extend `DispositionStageEntryService` with the `LOI` and `PSA` stage-entry blocks. 🔴 **This is materially cheaper than 3A's was and the reasoning must be re-argued, not inherited** — see J3 below. Neither `LOI` nor `PSA` is an approval entry stage (`Sale_Decision` = Readiness, `Broker_Selection` = BOV Outreach, `Closing_Approval` = Closing), so neither block needs the deferred-queueable half; and `Disposition__c` has **no** `Primary_LOI__c` / `Primary_Contract__c` (repo grep: only `Primary_NDA__c` exists), so there is nothing to back-stamp. `AccessLevel.SYSTEM_MODE` on the child insert is still required, because `allowCreate` is false by design on that route.
- **(b) Manual, per the design's own Q3 recommendation.** Then all five of these move together in one change: `allowCreate=true` on `LOI__c` and `Contract_Review__c`; `recordTypeVisibilities` for `LOI__c.Disposition_LOI`; the two related lists on `Disposition_Record_Page` (their New button pre-fills the parent lookup, which is what makes (5) survivable); the two `View` actionOverrides on `Disposition.app`; and `Disposition__c` onto a layout for both objects so the value is at least *visible* on the created row.

Either way **(5) must be closed** — a lookup that appears on no layout and in no related list is invisible to every user of the record it defines.

---

### C2 — `PsaVersionService` was never taught the `Buyer` inversion. A sell-side PSA writes a `Ball_In_Court__c` that names the wrong party, and three metadata files assert an enforcement that does not exist.

**Files**
- `classes/PsaVersionService.cls:55` — `if (direction != 'Seller' && direction != 'Ours') throw` — `'Buyer'` is refused outright
- `classes/PsaVersionService.cls:87` — `Ball_In_Court__c = fromSeller ? 'Us' : 'Seller'` (repo-wide grep confirms this is the **only** writer of `Contract_Review__c.Ball_In_Court__c`)
- `classes/PsaVersionService.cls:1–8` — the class Javadoc still says *"derive and stamp the parent's Ball_In_Court__c (seller version -> Us, our version -> Seller)"*
- `lwc/psaVersionLog/psaVersionLog.js:12–15` — `DIRECTION` has no `Buyer` key; `:155–157` — `ballBadgeLabel` is the two-way ternary `loiCounterOffer` just replaced; `:84–87` — `directionOptions` unchanged

**The metadata that depends on it all shipped:**
- `objects/PSA_Version__c/fields/Direction__c.field-meta.xml:70–74` adds `Buyer`, and `:35–39` states *"The developer change that teaches `PsaVersionService` to choose a token is **BLOCKED until this file deploys**."*
- `objects/Contract_Review__c/fields/Ball_In_Court__c.field-meta.xml:58–62` adds `Buyer`, and `:33–35` states *"Record-type picklist restriction is UI-ONLY… **`PsaVersionService` is the only writer and is where that is actually enforced.**"*
- `objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml:85–95` exposes `Ball_In_Court__c` = **{Us, Buyer} only**, and `:37–39` repeats the same claim.

**What actually happens on a sale.** A disposition user logs "Our redline" (`direction = 'Ours'`) → `fromSeller = false` → `Ball_In_Court__c = 'Seller'`. On a sale DPEG **is** the seller, so the field now says the ball is with DPEG at the exact moment it passed to the buyer — the field does not read oddly, it **inverts**, which is precisely why `CounterOfferService`'s header calls `Ball_In_Court__c` "the dangerous one" and gives it a test each way. The write succeeds because record-type picklist restriction is not enforced by Apex DML, so the row lands on a value `Disposition_PSA` does not carry and that the UI cannot re-select. Symmetrically, `PSA_Version__c.Direction__c` stores `'Seller'` for a DPEG-sent redline on a sale.

**This is asymmetric with the LOI half of the same programme.** 3B fixed the identical inversion properly — `CounterOfferService.isSaleSide`, `LoiSelector.selectNegotiationContextById`, the `Buyer` token contract, five tests, and the `loiCounterOffer` pill and badge maps. 3C shipped the four metadata files that inversion needs and none of the code.

**Fix — mirror `CounterOfferService` exactly, which is the shape the metadata already assumes:**
1. A `ContractReviewSelector.selectNegotiationContextById(Id)` selecting `Id, RecordTypeId, Disposition__c`, `WITH SYSTEM_MODE` on the `LoiSelector.selectNegotiationContextById` grounds (a new field with no FLS for any profile, and this read must not be able to kill the live acquisition Log Version path), carrying the same DO-NOT-NARROW note.
2. `isSaleSide(Contract_Review__c)` with record-type-then-lookup precedence and constant-first `.equals()`.
3. Accept `'Buyer'` on a disposition parent only; keep `'Seller'` accepted on both as the incumbent wire token; store the **derived** label, never the caller's.
4. `Ball_In_Court__c = fromCounterparty ? 'Us' : counterparty`.
5. `psaVersionLog`: add the `Buyer` key to `DIRECTION` and replace `ballBadgeLabel`'s ternary with a `BALL_LABEL` lookup + party-neutral fallback — the two edits `loiCounterOffer` already carries.
6. Tests: `'Buyer'` on a disposition parent, `'Seller'` on an acquisition parent, and the refusal of `'Buyer'` on an acquisition parent — the `CounterOfferServiceTest` set, transplanted.

Until then, **correct the three metadata comments**, because each one currently tells the next reader the enforcement is in place.

---

### C3 — `Contract_Review_Record_Page` is byte-identical to its pre-3C state. A disposition driver sees **no buttons at all** on a disposition PSA, so 3C's entire gate split has no UI that can reach it.

**File:** `flexipages/Contract_Review_Record_Page.flexipage-meta.xml`
- `:7–24` — `actionNames` holds exactly **one** `valueListItems`, `Contract_Review__c.Advance_Stage`, whose rule is `{!$User.Deal_Driver__c} EQUAL true AND {!Record.Negotiation_Status__c} NE 'Executed'`
- `:32–33` — `enableActionsConfiguration` is `true`, so that list **is** the whole action bar
- repo-wide grep for `Disposition_Driver__c` in `flexipages/`: **`NDA_Record_Page` ×2, `LOI_Record_Page` ×3, `Contract_Review_Record_Page` ×0**

A disposition driver holds `Disposition_Deal_Driver`, which grants FLS on `User.Disposition_Driver__c` and **not** on `User.Deal_Driver__c`. A flexipage visibility rule that reads a field the running user cannot read evaluates FALSE. So the criterion can never be true for them.

**This is D20/C1 for the third time, and the first two were closed in this very changeset** — `NDA_Record_Page` in 3A's fix pass, `LOI_Record_Page` at `:128–143` in 3B (with an excellent in-file writeup of why it was right not to guess it earlier). Contract Review was skipped, and the omission is invisible to Apex review precisely because the server side is *correct*: `RecordStageAdvanceService`'s `Disposition_PSA` → `DISPOSITION_DRIVER` mapping, and `RecordStageAdvanceServiceTest.contractReviewGateIsResolvedPerRecordTypeNotPerObject` (`:1402`) which asserts both polarities, are the single change D25 calls the only one Contract Review needed — and nothing on any page can invoke them.

**Fix** — one additive edit, mirroring `LOI_Record_Page`'s duplicate-entry shape:

```xml
<valueListItems>
    <value>Contract_Review__c.Advance_Stage</value>
    <visibilityRule>
        <booleanFilter>1 AND 2</booleanFilter>
        <criteria><leftValue>{!$User.Disposition_Driver__c}</leftValue>
                  <operator>EQUAL</operator><rightValue>true</rightValue></criteria>
        <criteria><leftValue>{!Record.Negotiation_Status__c}</leftValue>
                  <operator>NE</operator><rightValue>Executed</rightValue></criteria>
    </visibilityRule>
</valueListItems>
```

Dynamic Actions is already `true` here, so this is additive — do **not** enable it anywhere it is off, and do **not** write a parenthesised OR (measured in this repo to deploy, survive a retrieve and not be honoured by the renderer). Also grant `DPEG_Disposition_Edit` / `_View` FLS read on `User.Disposition_Driver__c` if the `Disposition_Deal_Driver` set is not in the persona's PSG — that grant is what makes the rule evaluable at all.

---

### C4 — `Counter_Offer_Notify` was not gated. The first disposition LOI counter notifies `Acquisitions_Team`, and the message says the opposite of what happened.

**File:** `flows/Counter_Offer_Notify.flow-meta.xml`
- `:54–63` — the `<start>` element has **no `filters` and no `filterLogic`**: `recordTriggerType Create` on `Counter_Offer__c`, connected straight to `Notify_Counter`
- `:12–16` — `recipientGroup` is the hardcoded `Acquisitions_Team`
- `:47–49` — `fTitle` = `IF(ISPICKVAL(Direction__c, 'Seller'), 'LOI counter received - ball in our court', 'LOI counter sent to seller')`

Design §4.12 and the solution-architect prompt item 12 both required an entry condition `{!$Record.LOI__r.Disposition__c}` **IsNull = true**, and D15 finding #4 records it as a **live leak**: *"Gating that flow is scope CONTAINMENT, not a new notification, and is therefore not covered by D9's deferral."* Post-deploy gate **T-D3** tests exactly this and will fail.

**The second-order effect is worse than the leak.** `fTitle` branches on `Direction__c = 'Seller'`. 3B made the counterparty token on a sale `'Buyer'`, so a **buyer's** counter on a disposition LOI falls to the else branch and announces *"LOI counter sent to seller"* — the acquisitions team is told DPEG sent a counter when the buyer sent one. Gating the flow removes both problems at once; if it is ever re-pointed at a disposition audience, `fTitle` must handle `Buyer` explicitly.

⚠ This item was **not on the scope list I was given**, and that is itself part of the finding: it was in the design, it was in D15, and 3B is what makes it live.

---

## 🟡 WARNINGS

### W1 — Both LOI record-type XML comments now state the opposite of what their own files do

- `objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml:75–81`: *"LOI_Status__c AND **Ball_In_Court__c ARE ENUMERATED IN FULL AND IDENTICALLY ON BOTH RECORD TYPES**, DELIBERATELY… Ball_In_Court__c is left at Us/Seller pending an explicit decision… that inversion is raised as a recommendation and is **deliberately NOT resolved by this file**."*
- `objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml:69–74`: *"Ball_In_Court__c **IS LEFT AT Us/Seller AND THAT IS AN OPEN ITEM, NOT A DECISION**… Adding a Buyer value is raised as a recommendation and is **deliberately not applied by this file**."*

Both false. `Disposition_LOI:110–113` enumerates `Buyer`; `Acquisition_LOI:99–109` deliberately does not, so the two are **not** identical; and `CounterOfferService` derives the label exactly as the comments say it does not. The field's own file (`Ball_In_Court__c:29–36`) is correct and current — these two were written in an earlier pass and not retracted when the decision landed.

This matters more here than ordinary comment rot: these files are the stated authority for the token contract, and a future reader following them would remove `Buyer` from `Disposition_LOI` and silently break `CounterOfferService`'s only sell-side write path. **Fix:** retract-in-place with the dated block this repo already uses everywhere else (`Wire_Complete_Before_Completed:31–45` is the model, and it is excellent).

### W2 — `Disposition_LOI` still exposes `Seller` on `Ball_In_Court__c`, where it names DPEG — the same party `Us` names

`objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml:106–109`. Contrast `Disposition_PSA.recordType-meta.xml:85–95`, which exposes **{Us, Buyer} only** and argues the exclusion at `:30–36` (*"'Seller' would name DPEG — the same party 'Us' already names — and the field would carry no information at all"*). The same argument applies verbatim to the LOI and was not applied.

`CounterOfferService` never writes `Seller` to `Ball_In_Court__c` on a sale, so the only way in is a hand edit or an inline edit — which the field *is* exposed for. **Fix:** narrow `Disposition_LOI`'s `Ball_In_Court__c` to `{Us, Buyer}`, matching `Disposition_PSA`. If `Seller` must stay, say why in the file, because "the incumbent wire token" is a `Direction__c` argument and does not transfer to `Ball_In_Court__c`, which no client sends.

### W3 — `manifest/package.xml` lists none of 3A, 3B or 3C. Third tranche running.

`manifest/package.xml:2272–2280` — the `RecordType` block still ends at Tranche 2 (`Disposition__c.Off_Market`, `Disposition__c.On_Market`, the two Metrics, the two Opportunity types). Grep for `Acquisition_LOI`, `Disposition_LOI`, `Acquisition_PSA`, `Disposition_PSA`, `LOI_Path_Acquisition`, `Contract_Review_Path_Acquisition`, `Mark_Countered_By_DPEG`, `loiMarkCounteredByDpeg`: **zero matches**. The `PathAssistant`, `QuickAction`, `LightningComponentBundle` and sharing-rule entries are stale in the same way.

Tranche 2's S4 closed this; 3A's S1 re-raised it; it has now regressed twice more. If DevOps deploys `--manifest` the tranche silently under-deploys. **Either refresh it or state once and for all, in the decisions file, that the plan is per-component `--source-dir`** — which the two-phase sharing-rule order (D19.2 / T-H1) does imply. Right now it is neither.

### W4 — `ContractReviewTriggerHandler`'s Javadoc still describes behaviour removed on 2026-08-05 and does not mention the arm 3C added

`classes/ContractReviewTriggerHandler.cls:1–9`: *"when a Contract Review's negotiation status becomes Executed, the PSA is handed off to the Transactions team (stamp the Opp, **create the Transaction**, arm the Day-0 fan-out, notify…)"*. Transaction creation moved to `openTransactionsOnAboutToClose` on 2026-08-05, and the service's own header (`:16–20`) says so emphatically. The handler is the first file a reader opens to find out what fires on this object, and it is now the only file in the chain that does not mention the disposition arm.

One paragraph. Flagged because the documentation standard everywhere else in this changeset is genuinely exceptional, which makes the one stale file more misleading, not less.

---

## 🟢 SUGGESTIONS

- **S1 — Translations were not extended.** `objectTranslations/LOI__c-en_US/Stage__c.fieldTranslation-meta.xml:5–24` still lists five values; the five new disposition stages are absent, as is `Buyer` on `LOI__c/Ball_In_Court__c`, `Contract_Review__c/Ball_In_Court__c`, `Counter_Offer__c/Direction__c` and `PSA_Version__c/Direction__c`. Deploys clean either way; identical to 3A's S2 and design §4.14.
- **S2 — `loiCounterOffer.directionOptions` still reads buy-side on a disposition LOI** (`:166–169`, *"Seller countered us" / "Our counter to seller"*). The deferral is argued well at `:128–138` and names the right fix (a server-supplied side flag on the existing `getCounterOffers` response, rather than a client-side `Disposition__c` read that would make the live acquisition card depend on an FLS grant acquisitions personas deliberately lack). Worth doing in the same pass as C2, since `psaVersionLog` needs the identical treatment and one shape can serve both.
- **S3 — No disposition layouts were built** (design §4.7). `Submitted_Date__c`, `Approved_By__c`, `Approved_Date__c`, `Approval_Comments__c` and `LOI_Status__c` remain on the single `LOI__c-LOI Layout` and therefore on every disposition LOI, contradicting `Disposition_LOI:52–58`'s claim that *"a separate disposition layout omits them."* The assignment half is a post-deploy gate (T-A3) and not deployable, but the layout files themselves are — and see C1(5) for the half that is not cosmetic.
- **S4 — the terminal `Executed` transition is confirmed with generic wording.** Design Q7 asked for two named buttons at `Counter Received from Buyer` (counter again / execute); what shipped is `Mark_Countered_By_DPEG` plus the generic `Advance Stage` for the `Executed` hop. The reasoning at `RecordStageAdvanceService:489–491` is sound (`Executed` is derivable, so a second route buys nothing) and I would not add a bundle just for symmetry — but executing an LOI is the one irreversible click on this path and it is confirmed with *"Advance this record to the next stage?"* If any action on this object earns a named confirm, it is that one.
- **S5 — `ContractReviewTriggerHandler` routes `afterUpdate` only**, so a Contract Review **inserted** directly at `Negotiation_Status__c = 'Executed'` runs neither arm (`handleExecution` handles `oldMap == null` but is never called on insert). Pre-existing and not a 3C regression — but it matters more now, because a disposition PSA has no automated creator and, whichever route C1 takes, will be created by hand or by a data load.

---

## ⚖️ JUDGEMENT CALLS — not filed as defects

### J1 — The `Contract_Review__c` Master-type fallback is the quietest failure in the tranche, and the class header says so honestly. Give it a gate rather than a code change.

`RecordStageAdvanceService:149–154` states it plainly: because both PSA types share one sequence, a Master-type row *advances correctly*, the toasts are right and nothing looks wrong — only the **gate** is wrong (`DEAL_DRIVER`), so an unmigrated sell-side PSA is simply un-advanceable by the disposition persona and perfectly advanceable by an acquisitions one. Contrast a Master-type disposition NDA, which is functionally dead and therefore self-reporting.

I would not change the fallback — it is the conservative direction and grants the new buttons to nobody new during the deploy window. But gate **T-B** currently verifies "zero rows remain on Master" as a count. For `Contract_Review__c` specifically, add a persona step: after migration, open a disposition PSA **as the disposition persona** and confirm Advance Stage both appears (C3) and works. Nothing else in the system will notice this one.

### J2 — D21's rejected alternative got materially cheaper in 3B, and is now worth revisiting rather than deferring indefinitely

D21 accepted org-wide `viewAllRecords` on `Counter_Offer__c` — disposition personas can read every acquisition counter offer, i.e. DPEG's negotiating position on live purchases — and named the narrow long-term shape as *"a stored discriminator checkbox on `Counter_Offer__c` set by `CounterOfferService` (which already computes `isSaleSide`…) plus a criteria rule."*

At D21 that read as speculative. It is not any more: `CounterOfferService.isSaleSide` (`:227–236`) now exists, is `@TestVisible`, is tested four ways, and runs on **every** counter save. The change is one checkbox field, one line in `saveCounterOffer`, one criteria rule and a backfill of existing rows — and `Counter_Offer__c` has, by construction, no disposition rows to backfill yet, which makes right now the cheapest this will ever be. The same argument applies to option (b) for `PSA_Version__c` in the D23 block, once C2 puts an `isSaleSide` in `PsaVersionService` too. I am not asking for it in this pass; I am saying the window is open and it closes as soon as sell-side counters start accumulating.

### J3 — The Q3 auto-create decision is half-built, and the half that shipped was the expensive one

D15/Q3 and D16.2 chose auto-create for all three disposition children over the design's related-list recommendation, with the cost stated: a new trigger on a record three approvals lock, `SYSTEM_MODE` DML, and a deferred queueable for the parent stamp. 3A paid all of that for the NDA.

The LOI and PSA blocks are the **cheap two** and nobody seems to have noticed:

- `LOI` and `PSA` are neither `Disposition Readiness`, `BOV Outreach` nor `Closing`, so **no approval keys on either stage** — the lock argument that forced `DispositionNdaStampQueueable` does not apply.
- `Disposition__c` has **no** `Primary_LOI__c` or `Primary_Contract__c` (repo grep: `Primary_NDA__c` is the only one), so there is **no parent back-stamp to defer at all**.
- The idempotency key is simpler than the NDA's: there is no `Party_Role__c` equivalent, so "already has a disposition LOI" is the whole test.

So option (a) in C1 is roughly two blocks in an existing service plus its bulk test, reusing a pattern already proven at 251 records in `DispositionStageEntryServiceTest`. If the answer is instead the manual route (b), that is a legitimate reversal of D15/Q3 for two of the three objects — but **write it into the decisions file**, because D16.2 currently reads as though auto-create for all three shipped, and that is the belief `DPEG_Disposition_Edit:474–475` acted on.

---

## ✅ VERIFIED CORRECT — the six things you asked about

1. **`ContractExecutionService`'s disposition arm is right in every particular, including the trap you named.** The `executedOppIds.isEmpty()` early return genuinely **moved into the acquisition arm** — it is now `stampOpportunities:190`, and `handleExecution:158–180` runs both arms unconditionally through two independent `if`s (never `if/else`, justified at `:168–169` and at the class header `:37–46`: a row with both parents runs both, a row with neither runs neither). The no-change filter at `:316` drops rows already at `Closing` **before** the DML, so a re-executed PSA on a disposition locked under `Closing_Approval` is a genuine no-op rather than a swallowed `ENTITY_IS_LOCKED`; `allOrNone = false` at `:332` covers the two obstacles the filter cannot (a lock on a row that *is* moving, and `All_NDAs_Signed_Before_Progression` refusing entry to `Closing` on an off-market sale with an unsigned NDA); and `AccessLevel.SYSTEM_MODE` covers CRUD/FLS. The header `:251–297` argues all three as **separate mechanisms that do not substitute for one another**, and explicitly rejects the queueable on the correct evidence — a Contract Review save releases no disposition approval, so a pending approval outlives any queueable, which is exactly the W1 mistake `DispositionNdaStampQueueable` made. **The acquisition arm is a byte-identical extraction**: same `Datetime.now()` Day-0 guard, same `allOrNone = true`, same batched `GroupNotifier.notify` after the loop. `DispositionSelector.selectStagesByIds:175–185` is `WITH SYSTEM_MODE` with a full two-part justification (`:142–165`) that argues the FLS half *and* separately argues why sharing is **not** escaped here, contrasting itself with `InboundEmailStagingSelector.RoutingReads` — the exact check ARCHITECTURE.md demands after the 2026-08-08 incident, and the second class in the repo to do it unprompted.

2. **The gate split resolves per record type, and the five other objects are untouched.** `gateFor:997–1002` short-circuits only on `config.byRecordType.size() == 1`; `Contract_Review__c` carries two `StageTypeConfig`s (`:837–846`) differing in **exactly one argument**, both pointing at the **same** `CONTRACT_REVIEW_NEXT_STAGE` map object by reference so divergence is unexpressible. `contractReviewGateIsResolvedPerRecordTypeNotPerObject:1402` asserts **both polarities** with both permission caches seeded to opposite answers, so a constant answer cannot pass; `gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject:1494` pins the cost as `Underwriting__c` 0 / LOI 1 / NDA 1 / Contract Review 1 — which is also the falsifier for "the five other objects are unaffected", since a regression that loaded the row for everything turns the `0` red. `ContractReviewSelector.selectStageRequiredById:143–148` selects `RecordTypeId` with the DO-NOT-NARROW note, and `load():1138–1142` names it as the easiest of the three to talk yourself out of *because* the two types share a sequence.
   **The LOI explicit targets are record-type-scoped in both directions and both are tested.** `LOI_ACQUISITION_EXPLICIT_TARGETS` = {Counter, Completed} on `Acquisition_LOI`, `LOI_DISPOSITION_EXPLICIT_TARGETS` = {Countered by DPEG, Counter Received from Buyer} on `Disposition_LOI`, and `advanceTo:936–947` resolves the sequence from the **loaded** record before testing membership. `acquisitionLoiRefusesADispositionStageAsAnExplicitTarget:973` and `dispositionLoiRefusesTheAcquisitionExplicitTargets:935` are the two halves, with `dispositionLoiAcceptsTheNegotiationLoopTargets:1022` as the complement that stops the refusals passing vacuously. Master/pre-migration rows fall back to `RT_ACQUISITION_LOI`, so live acquisition behaviour is preserved through the deploy window; a **real, named** record type with no map is refused rather than defaulted (`sequenceKeyFor:1084–1086`).

3. **`CounterOfferService`'s label is derived and a cross-record-type write is structurally impossible.** The stored `Direction__c` is `fromCounterparty ? counterparty : 'Ours'` (`:166`) and `Ball_In_Court__c` is `fromCounterparty ? 'Us' : counterparty` (`:182`) — both functions of the parent row alone, never of the caller's token, so a caller sending `'Seller'` on a sale gets `'Buyer'` stored. `'Buyer'` is refused on an acquisition parent (`:281`) because there it would name DPEG. Since the only value that could cross (`Buyer` onto an `Acquisition_LOI`, which `Acquisition_LOI:99–109` restricts out) is unreachable by construction, the UI-only nature of picklist restriction costs nothing here.
   **The lookup leg of `isSaleSide` is genuinely load-bearing, and the ordering is right.** Record type is authoritative (`:229–234`, constant-first `.equals()` because Apex `==` on String is case-insensitive while the describe map is case-sensitive); `Disposition__c` is the fallback for the window in which **every LOI in the org sits on Master** — which is today, before T-A1/T-A2 — and without it every disposition LOI created in that window would be labelled with buy-side vocabulary, i.e. the exact bug. `isSaleSide_recordTypeBeatsTheDispositionLookup:286` pins all four combinations in memory with no DML. The divergence from `RecordStageAdvanceService` (unknown named type falls through here, refuses there) is argued at `:221–224` and is correct: refusing there prevents an off-set **stage**; refusing here would block a counter over a naming question the lookup can answer.

4. **The `PsaVersionSelector` split is right and both justifications sit at their methods.** `countByContractReviewId:148–157` is `WITH SYSTEM_MODE`, and `:72–102` gives the reason no other query in this repo has: **an FLS denial throws, a sharing denial filters, and a filtered `COUNT()` is still a number** — so `Latest_Version__c = priorCount + 1` writes a wrong value rather than failing. It then states plainly, at `:104–129`, that `SYSTEM_MODE` closes the CRUD/FLS half and **not** the sharing half, names the measured facts (`PSA_Version__c` is `sharingModel Private`, its sharing-rules file is an empty `<SharingRules/>`), and names the remedy it deliberately did not take (`private without sharing` inner class, the `LeadSelector.GuestReads` shape) rather than widening the class. `selectByContractReviewId:49–59` stays `USER_MODE` with `:36–41` explaining that the two differ **in kind, not in strictness** — it renders every row it returns, so a denial there is a real provisioning gap. That is the correct reading of ARCHITECTURE.md §2 in both directions, and `countReadsAcrossAccessNarrowing_isTheModeFalsifier` pins the accepted residual.

5. **Live acquisition behaviour — I swept for regressions and found none in the Apex or the metadata.** `LOI__c.Stage__c` appends five values and removes none, with the acquisition five first and byte-identical, so `LOI_Path_Acquisition` renders exactly as `LOI_Path` did. `Is_Advance_Allowed__c`'s new `TEXT(Stage__c) <> "Executed"` clause is provably inert on acquisition (`Executed` is not on `Acquisition_LOI`'s value set) and the file states it was verified against the value sets rather than assumed — and, better, the file explains that copying the entry in 3B would have produced the **opposite** defect (a button on a finished disposition LOI), which is `NE 'Signed'`-not-excluding-`Declined` one object later. `Acquisition_LOI` / `Acquisition_PSA` restrict out only values acquisition rows cannot hold. `OpportunityReviewService`'s LOI block keeps its `AccessLevel.SYSTEM_MODE` insert (`:369`) and its deferred `LoiPrimaryStampQueueable` (`:385–387`) untouched, and the stamp is a null-guarded assignment inside the existing build loop. `LOI_Path`, `NDA_Path` and `Contract_Review_Negotiation_Path` are all correctly `<active>false</active>` with the six record-type paths active. `acquisitionExecutionLeavesUnrelatedDispositionsAlone:371` and `mixedChunkRunsBothArmsIndependently:407` are purpose-built regression guards, and every pre-existing acquisition test in `ContractExecutionServiceTest` was left byte-identical on purpose (`:14–18`).

6. **Both new LWC bundles match `ndaMarkDeclined` line for line.** `loiMarkCounteredByDpeg.js:72–102` and `loiMarkCounterReceived.js:67–97`: `guardStageAction` first (permission → confirm → act, never reversed), `try/catch` around the imperative call, `error.body.message` surfaced verbatim with a fixed per-bundle fallback, and `getRecordNotifyChange` **only** on the success path (`:88` / `:83`) — mandatory here because the write is imperative Apex behind LDS's back. `TARGET_STAGE` is a hardcoded module constant in both, which is the property that makes the server-side allow-list meaningful, and both headers say so. Each Jest suite covers success, both error shapes, denied, cancelled, and asserts the permission call carries `recordId`.

---

## ✅ OTHER GOOD PRACTICES FOUND

- **The retraction discipline was applied to the hardest case in the programme and applied correctly.** Both `All_NDAs_Signed_Before_Progression:110–128` and `Wire_Complete_Before_Completed:31–49` quote their superseded "nothing but user edits writes `Disposition_Stage__c`" sentence, mark it RETRACTED, name the new writer, and — the part that is rare — the NDA rule's block goes on to check off *both* obligations its own prior paragraph imposed ("the machine write IS fail-soft, and the sibling claim was corrected in the same change"). A prior version of a comment predicting the exact change that would falsify it, and the change then honouring that prediction in writing, is the strongest documentation pattern I have seen on this programme.
- **`OpportunityReviewService` re-argued the guarded-vs-unconditional question three times and reached the same answer three ways** (`:27–138`), explicitly warning that the agreement is *"a conclusion, not a premise"*. The 3C argument is the sharpest: `PSA` is a sequenced gate with exactly one route in (measured — `advance()` from `LOI`, not in `ALLOWED_EXPLICIT_TARGETS`, no approval field update, no flow), and the insert **shares one all-or-none transaction with four sibling children and runs first**, so a throw takes their `Primary_*` stamps and the LOI queueable with it. It also records the one thing it could not determine (whether `SYSTEM_MODE` would accept an unavailable record type — the 2026-08-09 measurement was on a bare `insert`) and points at the unconditional test as the mitigation, instead of asserting.
- **`ContractExecutionServiceTest.dispositionAlreadyAtClosingIsSkippedByTheNoChangeFilter:448` measures the skip on DML ROWS, and says why that is the only way.** A skipped row and a successful write leave the database identical, so asserting the stage would prove nothing. The expected `3` is derived in the header, the derivation names what contributes (verified: no record-triggered flow on `Disposition__c`; `DispositionTrigger` acts only at the `NDA` stage), and the failure message tells the next reader to re-derive the arithmetic before adjusting the constant. That is the right shape for a governor/DML-count assertion.
- **`bulkExecution251DispositionPsasMoveEverySale:527` uses 251 DISTINCT parents and explains why that is the whole design** — 251 children under one disposition would collapse to one selector row and one update, look like a bulk test and prove nothing. It also states, correctly, that the `.claude/rules/bulk-test-rule.md` exemption does **not** apply because `handleExecution` is trigger-driven, contrasting it with `RecordStageAdvanceService` which is exempt.
- **The failure messages are written for the person who will read them at 2am.** `executedDispositionPsaMovesTheSaleToClosing:342` does not say "expected Closing" — it names the single most likely cause (*"the acquisition arm's `executedOppIds.isEmpty()` early return having been moved back to the top of handleExecution, where an all-disposition chunk … returns before this arm is reached"*), which is precisely the trap your brief flagged. `Assert` messages throughout this changeset name the regression, not the value.
- **`LoiSelector`'s `SYSTEM_MODE` decision was driven by a reproduced failure, not by pattern-matching.** `:181–186` records that a check-only run on 2026-08-09 produced `System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'` and **took down the acquisition counter-offer path**, which has nothing to do with dispositions — a new field arrives with no FLS for any profile. That is the right kind of evidence for a mode change and it is cited at the method, where §2 says the inventory lives.
- **`TestDataFactory` is thorough and consistent across all four objects.** Per-record-type seed stages chosen because the LOI value sets are disjoint (`:1357–1363`), `Submitted_Date__c` seeded only on the acquisition type, guarded `isAvailable()` stamps matching the production shape, constant-first `.equals()` allow-lists with the case-sensitivity trap documented, and `createDispositionLois` deliberately leaving `Opportunity__c` null so `isSaleSide`'s two clauses stay distinguishable (`:1420–1423`). `TestDataFactoryTest` now carries 15 methods, four of them unconditional record-type read-backs that are meant to be red until T-A1.
- **The two sharing-rule files establish rather than assume.** Both verify the OWD in the repo and **say that it was checked in the repo only**; both explain the two-rules-by-population split (object CRUD is the ceiling, so a second Read rule to the same group would be redundant; Principals reach `DPEG_Disposition_View` through the PSG and may not be in `DPEG_Acquisitions_Team`); both name the 40-character developer-name cap as the reason for "Disp"; and `Contract_Review__c`'s explains, from first principles, why the D17 shape is available here and was not at D21 — record types plus a stored discriminator. The `PSA_Version__c`-is-a-lookup-not-a-master-detail analysis (`:94–114`) is correct and is the kind of thing that is usually assumed wrong.
- **`RecordStageAdvanceService`'s config seam absorbed a shape it was not designed for.** 3C needed **no new sequence at all** — both types point at one map object — and `:765–774` records that not one line below `CONFIG_BY_TYPE` changed across 3A, 3B and 3C. The `SINGLE_TYPE_KEY` doc comment even retracts its own former second use ("or because its types deliberately share one sequence") on the grounds that sharing a sequence is not sharing a gate. A constant whose comment corrects itself is a good sign.
- **`ARCHITECTURE.md` §6 currency:** I checked before writing a §6 finding and there isn't one — the `RecordStageAdvanceService` row carries the record-type-aware amendments and the six-object correction.

---

## 📋 FILE-BY-FILE

| File | Status | 🔴 | 🟡 | 🟢 |
|------|--------|----|----|----|
| `classes/ContractExecutionService.cls` | ✅ | 0 | 0 | 0 |
| `classes/ContractReviewTriggerHandler.cls` | 🟡 | 0 | 1 (W4) | 1 (S5) |
| `classes/DispositionSelector.cls` | ✅ | 0 | 0 | 0 |
| `classes/RecordStageAdvanceService.cls` | ✅ | 0 | 0 | 0 |
| `classes/ContractReviewSelector.cls` · `LoiSelector.cls` | ✅ | 0 | 0 | 0 |
| `classes/CounterOfferService.cls` | ✅ | 0 | 0 | 0 |
| `classes/PsaVersionSelector.cls` | ✅ | 0 | 0 | 0 |
| `classes/PsaVersionService.cls` | 🔴 | 1 (C2) | 0 | 0 |
| `classes/OpportunityReviewService.cls` | ✅ | 0 | 0 | 0 |
| `classes/DispositionStageEntryService.cls` | 🔴 | (C1, joint) | 0 | 0 |
| `classes/TestDataFactory.cls` · `TestDataFactoryTest.cls` | ✅ | 0 | 0 | 0 |
| `classes/*Test.cls` (6 suites) | ✅ | 0 | 0 | 0 |
| `objects/LOI__c/recordTypes/Acquisition_LOI` · `Disposition_LOI` | 🟡 | 0 | 2 (W1, W2) | 0 |
| `objects/Contract_Review__c/recordTypes/Acquisition_PSA` · `Disposition_PSA` | 🔴 | (C2 — claims an enforcement that is absent) | 0 | 0 |
| `objects/LOI__c/fields/Stage__c` · `Ball_In_Court__c` · `Is_Advance_Allowed__c` · `Disposition__c` | ✅ | 0 | 0 | 0 |
| `objects/Contract_Review__c/fields/Ball_In_Court__c` · `Disposition__c` | 🔴 | (C2, joint) | 0 | 0 |
| `objects/{Counter_Offer__c,PSA_Version__c}/fields/Direction__c` | 🔴 | (C2, joint) | 0 | 0 |
| `objects/Disposition__c/validationRules/*` (two retractions) | ✅ | 0 | 0 | 0 |
| `pathAssistants/LOI_Path{,_Acquisition,_Disposition}` | ✅ | 0 | 0 | 0 |
| `pathAssistants/Contract_Review_{Negotiation_Path,Path_Acquisition,Path_Disposition}` | ✅ | 0 | 0 | 0 |
| `flexipages/LOI_Record_Page.flexipage-meta.xml` | ✅ | 0 | 0 | 0 |
| `flexipages/Contract_Review_Record_Page.flexipage-meta.xml` | 🔴 | 1 (C3) | 0 | 0 |
| `flexipages/Disposition_Record_Page.flexipage-meta.xml` | 🔴 | (C1, joint) | 0 | 0 |
| `flows/Counter_Offer_Notify.flow-meta.xml` | 🔴 | 1 (C4) | 0 | 0 |
| `quickActions/LOI__c.Mark_Countered_By_DPEG` · `.Mark_Counter_Received` | ✅ | 0 | 0 | 0 |
| `lwc/loiMarkCounteredByDpeg` · `lwc/loiMarkCounterReceived` (+ Jest) | ✅ | 0 | 0 | 0 |
| `lwc/loiCounterOffer` | 🟢 | 0 | 0 | 1 (S2) |
| `lwc/psaVersionLog` | 🔴 | (C2, joint) | 0 | 0 |
| `lwc/dispositionSidebar` | ✅ | 0 | 0 | 0 |
| `sharingRules/LOI__c` · `Contract_Review__c` | ✅ | 0 | 0 | 0 |
| `permissionsets/DPEG_Disposition_Edit` · `_View` | 🔴 | (C1, joint) | 0 | 0 |
| `layouts/LOI__c-LOI Layout` · `Contract_Review__c-Contract Review Layout` | 🔴 | (C1, joint) | 0 | 1 (S3) |
| `applications/Disposition.app-meta.xml` | 🔴 | (C1, joint) | 0 | 0 |
| `objectTranslations/**` | 🟢 | 0 | 0 | 1 (S1) |
| `manifest/package.xml` | 🟡 | 0 | 1 (W3) | 0 |

---

## 🏁 VERDICT

❌ **CHANGES REQUIRED** — four critical issues.

To be plain about the proportion, because it matters here: **the Apex in 3B and 3C is excellent, and every one of the six things you asked me to check came back correct.** `ContractExecutionService`'s disposition arm is the best-reasoned piece of code in this programme — three obstacles, three mechanisms, each argued as not substituting for the others, with the queueable explicitly rejected on the evidence that caught W1 in 3A. The gate split proves that gate and sequence are independent axes and pins it with a both-polarities test that a constant answer cannot pass. The record-type-scoped allow-lists close the hole in **both** directions with a test each way. `PsaVersionSelector`'s `COUNT()` analysis — an FLS denial throws, a sharing denial filters, and a filtered count is still a number — is a genuinely original observation, and it names the half it does **not** close instead of implying it did.

**The blocker is that this tranche repeats 3A's exact shape and compounds it.** In 3A the server side was finished and the user-facing half was not started. Here the same thing happened — `Contract_Review_Record_Page` is untouched, `Counter_Offer_Notify` is ungated — **and on top of it the records the whole tranche operates on cannot be created by anyone.** No auto-create, no `allowCreate`, no related list, no `recordTypeVisibilities` on the LOI, and the `Disposition__c` lookup on no layout of either object. Every one of the four criticals is invisible to a green deploy and to `RunLocalTests`.

What makes C1 worth pausing on rather than just fixing: **the changeset warned about it twice, in its own files, in writing, and then wrote "MEASURED" over a premise that was never measured.** `DPEG_Disposition_Edit:167–173` told 3B to own the check; `:470–479` justified withholding create on a disposition auto-create that does not exist. That is not carelessness, it is a decision document (D16.2) being read as a statement of fact about the codebase. Worth one line in `stage-by-stage-decisions.md` distinguishing *decided* from *built*, because three separate agents have now acted on it.

C2 is the second-order version of the same thing: 3C shipped four metadata files that each assert `PsaVersionService` enforces the sell-side token, and did not touch `PsaVersionService`. The LOI half of that identical inversion was fixed properly in 3B, in the same branch, three days' work apart — so the fix has a working template and should be a short pass.

C3 and C4 are one file each: a duplicate `valueListItems` entry and a flow entry condition.

None of the four touches the Apex you asked me to scrutinise, and none of them requires re-testing it.

---

## 👤 USER ACTION REQUIRED

Critical issues must be fixed. Do you want to:

- **[F] Fix issues.** Suggested split:
  - **C1** is a decision first, a build second — answer (a) auto-create or (b) manual, then send the file list to `salesforce-solution-architect` (permission set, flexipage related lists, layouts, app actionOverrides, `recordTypeVisibilities`) or `salesforce-developer` (the two `DispositionStageEntryService` blocks + bulk test).
  - **C2** → `salesforce-developer`: `ContractReviewSelector.selectNegotiationContextById`, `PsaVersionService.isSaleSide` + the two writes, `psaVersionLog`'s two display maps, tests both ways on both parents, and the three metadata comments corrected.
  - **C3** and **C4** → `salesforce-solution-architect`: one `valueListItems` entry on `Contract_Review_Record_Page`, one entry condition on `Counter_Offer_Notify`. Both are ten-minute edits.
  - Ride along: **W1** (two retract-in-place blocks), **W2** (narrow `Disposition_LOI`'s `Ball_In_Court__c`), **W4** (one paragraph). **W3** and **S1–S5** can wait for the deploy runbook.
  Then request a re-review of the changed files only.
- **[S] Skip deployment for now.** 3B/3C are not deployed and not merged (D14), and all four criticals surface in UAT (T-C2, T-D1, T-D3, T-F1) as "there is no New button" / "there are no buttons" / "the acquisitions team got a notification about a sale" rather than as errors — which is exactly why they need to be closed before the deploy window rather than inside it.

⚠ Whichever you choose, **C1 changes what the two-phase deploy has to contain.** If it is answered with auto-create, `classes` gains a change that must land after the record types; if it is answered manually, `DPEG_Disposition_Edit` moves again — and a `PermissionSet` deploy replaces its whole grant list, so the org reconciliation cited at `:409–423` must be re-run against the final file, not the one measured on 2026-08-09.
