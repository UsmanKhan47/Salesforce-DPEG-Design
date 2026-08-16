# DESIGN REQUIREMENTS — Live UI Testing Fixes (org `usman-dpeg`, 2026-08-12)

Four independent, small changes reported from live UI testing. This document verifies each
diagnosis against the repo, states what changed as a result of verification, separates admin from
developer work, and gives the exact prompts for the implementation agents.

> **This agent generates no Salesforce metadata.** The `.claude/rules/salesforce-global-rule.md`
> Initial Gate / per-type loop (skill selection → skill load → `salesforce-api-context` MCP →
> pre-write gate → generate → checkpoint) belongs to the implementation agents, and is restated in
> each prompt in §9.

---

## 🎯 WHAT THE USER REQUESTED

Verbatim, from live UI testing:

1. "LOI is still in draft, it must be completed then stage shall change to PSA."
2. "Transaction record page doesn't have our quick actions to move stages."
3. "In the active transactions lwc we must show property name as well."

Plus **(4)**, which the user did NOT report and which is surfaced here as a decision, not as scope:
the Transaction record page shows `Tasks Complete 0 / 82` while the LWC list shows `0 / 75`.

---

## 0. VERIFICATION SUMMARY — what recon changed

All four diagnoses in the incoming brief are **CONFIRMED**. Five findings materially change the
recommended fix and are the reason this is not a straight write-up of the brief.

| # | Brief said | Verified | What changed |
| --- | --- | --- | --- |
| 1 | VR ignores `LOI__c.Stage__c` | ✅ confirmed | Also confirmed: **exactly one writer** reaches `StageName = 'PSA'`, and it is Apex, so the VR fires and its message surfaces. |
| 2 | Transaction has no stage quick actions | ✅ confirmed (zero `Transaction__c` quick actions) | 🔴 **But stage changes are NOT blocked today.** `Transaction_Record_Page` has `hideUpdateButton = false`, so the Path's "Mark as Current Stage" button is live. This is a **consistency gap, not a blocker** — which changes its priority and opens a "defer" option. |
| 2 | Add the quick action | — | 🔴 The record page has `enableActionsConfiguration = false`, so it **inherits the layout's six actions**. Turning on Dynamic Actions to add one button **silently deletes Edit / Clone / Delete / Log a Call / New Event / New Task**. |
| 3 | `Property_Name__c` has other readers? (grep before changing) | ✅ grepped | 🔴 **FIVE report files read it**, all blank today. This flips the recommendation away from the brief's option (b) and *also* away from option (a). |
| 3 | Option (a) = "change the field to a formula" | ❌ **not a field edit** | Salesforce cannot convert Text → Formula. It is a **delete-and-recreate**, which destroys stored data, is blocked by the Apex references, and silently breaks the five reports. See §3. |
| 4 | Real fan-out is ~82 | ✅ and sharper | `TaskFanoutService.cls:131` writes `Tasks_Total__c = createdForTxn` — a **per-record** count gated by that Transaction's own condition fields (`Loan_Required__c` etc.). There is no single correct constant; 82 is as wrong as 75. |

**Evidence index (files read, not inferred):**

- `force-app/main/default/objects/Opportunity/validationRules/Approved_LOI_Before_PSA.validationRule-meta.xml`
- `force-app/main/default/objects/Opportunity/fields/Primary_LOI__c.field-meta.xml` — Lookup → `LOI__c`, `SetNull`
- `force-app/main/default/objects/LOI__c/fields/Stage__c.field-meta.xml` — 10 values across both record types
- `force-app/main/default/classes/StageAdvanceService.cls` — `'LOI' => 'PSA'`; `ALLOWED_EXPLICIT_TARGETS` excludes `PSA`
- `force-app/main/default/approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml` — final approval action sets the flag only, **not** `StageName`
- `force-app/main/default/objects/Transaction__c/fields/Stage__c.field-meta.xml` — 5 restricted values
- `force-app/main/default/objects/Transaction__c/Transaction__c.object-meta.xml` — **no `recordTypes/` folder**
- `force-app/main/default/objects/Transaction__c/fields/Property_Name__c.field-meta.xml` — `Text(120)`
- `force-app/main/default/classes/TransactionSelector.cls` — no `selectStageRequiredById`; `selectActiveRows()` has no `Property__r.Name`
- `force-app/main/default/classes/TransactionController.cls:172` — `r.propertyName = t.Property_Name__c`
- `force-app/main/default/classes/ContractExecutionService.cls:129-131` — sets `Property__c`, never `Property_Name__c`
- `force-app/main/default/classes/TaskFanoutService.cls:131` — `Tasks_Total__c = createdForTxn`
- `force-app/main/default/classes/RecordStageAdvanceService.cls` — full config/dispatch read
- `force-app/main/default/flexipages/Transaction_Record_Page.flexipage-meta.xml`, `.../NDA_Record_Page.flexipage-meta.xml`
- `force-app/main/default/layouts/Transaction__c-Transaction Layout.layout-meta.xml`
- `force-app/main/default/permissionsetgroups/DPEG_Transaction_Team.permissionsetgroup-meta.xml`
- `force-app/main/default/permissionsets/{Disposition_Deal_Driver,Opportunity_Stage_Actions_Access,DPEG_Transaction_Edit}.permissionset-meta.xml`

---

## 1. THE LOI GATE — PSA must require a COMPLETED LOI

### 1.1 Confirmed

`Approved_LOI_Before_PSA` fires on:

```
AND(ISCHANGED(StageName), ISPICKVAL(StageName,'PSA'),
    OR(ISBLANK(Primary_LOI__c), NOT(LOI_Approved__c)))
```

Nothing in the repo references `Primary_LOI__r.Stage__c`. The gate tests the Opportunity's approval
flag and the lookup's presence only, so a deal advances LOI → PSA with its LOI child on `Draft`.

### 1.2 Formula validity — answered

`Primary_LOI__r.Stage__c` **is** valid in a validation-rule formula on Opportunity. Cross-object
references through a Lookup are supported (up to 10 relationships), and `Primary_LOI__c`'s
`<relationshipName>` is `PrimaryOpportunities`, i.e. the child-side name — the parent-side traversal
from Opportunity is the field name plus `__r`, so `Primary_LOI__r.Stage__c` is the correct token.

⚠ **Use `TEXT(Primary_LOI__r.Stage__c) <> 'Completed'`, not `ISPICKVAL`.** Two independent reasons,
both already recorded in this repo:

- `RecordStageAdvanceService`'s own header: *"'Prepare/Review' carries a literal slash, which is why
  the future validation rules must use `TEXT(...)` compares rather than `ISPICKVAL`."*
- `ISPICKVAL` on a cross-object picklist is the fragile form; `TEXT()` is the repo convention
  (`StageAdvanceService`'s `Dead/Pass` note is the same trap).

**Null behaviour, and why it forces a design choice:** when `Primary_LOI__c` is blank,
`TEXT(Primary_LOI__r.Stage__c)` evaluates to `''`. `'' <> 'Completed'` is TRUE, so a naive new rule
would ALSO fire on the blank-lookup case — the case the *existing* rule already owns. The user would
see two error messages for one problem.

### 1.3 Which writers this rule will actually meet

Per the standing rule that a VR is not a uniform control, the writers were enumerated:

| Writer of `Opportunity.StageName = 'PSA'` | Fires the VR? | Message reaches the user? |
| --- | --- | --- |
| `StageAdvanceService.advance()` — `NEXT_STAGE` maps `'LOI' => 'PSA'`; reached by the `Opportunity.Advance_to_PSA` quick action | **YES** | **YES** — `setStage` catches `DmlException` and rethrows `getDmlMessage(0)`, so the VR text lands in the toast with no code change |
| `StageAdvanceService.advanceTo()` | **unreachable** | `ALLOWED_EXPLICIT_TARGETS` = {Development Review, Construction Review, About to Close, Dead/Pass} — `PSA` is deliberately absent |
| `LOI_Approval` final approval action | **N/A** | The action is `Set_LOI_Approved_Flag` (a field update on the flag). It does **not** write `StageName`. |
| INSERT at `PSA` | **NO** | `ISCHANGED` is false on insert — a pre-existing, deliberate hole shared with `Approved_LOI_Before_PSA` and `NDA_Signed_Before_Underwriting`. Out of scope. |

**Conclusion: exactly one live route, it is Apex, the rule fires, and the message surfaces.** No
swallowed-`DmlException` path exists here (unlike `ApprovalAuditService`).

### 1.4 🔴 Existing deals already at PSA — stated explicitly

**They are unaffected, permanently, and nothing errors.** A validation rule evaluates only on save,
and both the existing rule and the new one are `ISCHANGED(StageName)`-scoped. The user's ZZFLOWTEST
deal — at `PSA` with a `Draft` LOI — will:

- **not** be blocked from being saved, edited, or advanced onward (`PSA → Closed Won` is a different
  transition and is not gated by this rule);
- **not** appear in any error, report, or list view as non-conforming;
- be caught **only** if it is moved off `PSA` and back onto it.

If a clean-up of already-PSA deals with non-`Completed` LOIs is wanted, that is a **separate,
optional data task** (a report + manual LOI advance). It is deliberately **not** in this scope and
must not be added by an implementation agent.

### 1.5 Option (a) vs (b) — RECOMMENDATION: **(b), a new separately-named rule**

| | (a) extend `Approved_LOI_Before_PSA` | (b) new rule `Completed_LOI_Before_PSA` |
| --- | --- | --- |
| Message | One message must cover three different remedies (link an LOI / run the approval / advance the LOI's stage) — becomes a paragraph, or becomes vague | Each rule names one remedy |
| Existing file | Its 255-char `<description>` and its long XML comment both describe the *approval* rule specifically and would need rewriting | Untouched — zero regression surface on a live, deployed gate |
| Failure diagnosis | Cannot tell which clause fired | Falsifiable independently; each rule can be deactivated on its own |
| Repo precedent | — | Matches `NDA_Signed_Before_Underwriting` / `All_NDAs_Signed_Before_Progression` — separate named rules with distinct messages |
| Deploy risk | Rewrites a rule that is currently correct | Purely additive |

**Recommend (b).** Both rules are `ISCHANGED(StageName) && ISPICKVAL(StageName,'PSA')`-scoped, so
they cost the same evaluation and neither can fire on a transition the other does not also see.

**🔴 GATE 1 DECISION D1-b — does the new rule exempt the blank-lookup case?**
Recommended formula (**exempts it**, so the two messages never both fire):

```
AND(
    ISCHANGED(StageName),
    ISPICKVAL(StageName, 'PSA'),
    NOT(ISBLANK(Primary_LOI__c)),
    TEXT(Primary_LOI__r.Stage__c) <> 'Completed'
)
```

- With `NOT(ISBLANK(Primary_LOI__c))`: a blank lookup produces **one** message (the existing rule's).
- Without it: a blank lookup produces **two** messages. Salesforce displays all failing VR messages,
  so this is noisy but not wrong. Some teams prefer the belt-and-braces version.

Recommended error message (≤255 chars, names the remedy):

> `This deal cannot enter PSA until the primary LOI is Completed. Advance the LOI to Completed on its own record page first.`

`errorDisplayField` = `StageName`, matching the sibling rule.

⚠ **`LOI__c.Stage__c` carries TEN values across two record types.** `'Executed'` is the *disposition*
LOI's terminal stage. `Primary_LOI__c` is stamped only by `OpportunityReviewService`, which creates
acquisition LOIs, so a disposition LOI cannot legitimately reach this lookup — but if one ever did,
`<> 'Completed'` would block it. Recorded as a known, accepted boundary; do **not** widen the rule to
`AND(<> 'Completed', <> 'Executed')` speculatively.

---

## 2. TRANSACTION STAGE ACTIONS

### 2.1 Confirmed, and one correction to the premise

- Zero `Transaction__c` entries in `force-app/main/default/quickActions/` — confirmed.
- `Transaction__c.Stage__c` is a **restricted** picklist with **5** active values, in this order:
  `Open Contract` (default) → `Due Diligence` → `Closing Prep` → `Post-Closing` → `Closed Won`.
  ⚠ There is **no `Closed Lost`** value, despite `activeTransactionsList.js:15` carrying a pill entry
  for it — a dead map entry, noted, not in scope.
- `Transaction__c` has **NO record types** (no `recordTypes/` folder). It therefore behaves like
  `Broker_Listing__c`: single sequence, `SINGLE_TYPE_KEY`, no record-type stamp, no `isAvailable()`
  guard, and `gateFor()` / `sequenceKeyFor()` short-circuit on `byRecordType.size() == 1` so it pays
  **zero** extra queries in `hasStageActionAccess`.
- `Transaction__c` is **not** in `RecordStageAdvanceService.CONFIG_BY_TYPE` — confirmed.
- `TransactionSelector` has **no** `selectStageRequiredById` — confirmed. It needs one.

**🔴 CORRECTION — stage changes are not blocked today.** `Transaction_Record_Page` carries an active
`runtime_sales_pathassistant:pathAssistant` with `hideUpdateButton = false`, and
`pathAssistants/Transaction_Path.pathAssistant-meta.xml` is `active = true` on `Stage__c`. So the
Path's "Mark as Current Stage" button works right now. This request is about **routing the write
through the gated Apex path** for consistency with the other seven stage-controlled objects — the
same governance goal `RecordStageAdvanceService` exists for ("the Path's 'Mark Status as Complete'
button can be removed from these record pages and every stage change routed through Apex"). It is
not restoring a lost capability.

### 2.2 🔴 THE STAGE SEQUENCE — one genuine ambiguity

Proposed map (picklist order; `<sorted>false</sorted>` means element order *is* Path order):

```apex
'Open Contract' => 'Due Diligence',
'Due Diligence' => 'Closing Prep',
'Closing Prep'  => 'Post-Closing',
'Post-Closing'  => 'Closed Won'      // 'Closed Won' terminal
```

**🔴 GATE 1 DECISION D2-a — is `Closed Won` really after `Post-Closing`?**
The picklist order and the Path's step order both say yes. But the Path's own step text says
`Closed Won` = *"Transaction closed and funded"* and `Post-Closing` = *"Complete the post-closing
checklist and file recorded documents"* — funding precedes post-closing work in a real deal, which
argues for `Closing Prep → Closed Won → Post-Closing`. **A derived map cannot be wrong quietly here:
whichever order is chosen becomes the only order the button offers.** Confirm with the user before
implementation. Reordering the picklist itself is a *separate* change and is not proposed.

### 2.3 🔴 THE GATE — the load-bearing decision

`RecordStageAdvanceService.passesGate` has two enum members, `DEAL_DRIVER` and `DISPOSITION_DRIVER`,
and its `when else` branch returns `false`. **There is no "no gate" option without editing
`passesGate` to add a member that returns `true`, which inverts the class's fail-closed design.**

Measured facts that constrain the choice:

- `DPEG_Transaction_Team` = `DPEG_Base_Access`, `DPEG_Apex_Access`, `DPEG_Transaction_Edit`,
  `DPEG_Task_Edit`, `DPEG_Opportunity_View`, `DPEG_Property_View`, `DPEG_Reports_Access`,
  `DPEG_App_Transaction`, `DPEG_Account_View`, `DPEG_Contact_View`. It holds **neither**
  `Acquisition_Deal_Driver` nor `Disposition_Deal_Driver`.
- `DPEG_Transaction_Edit` already grants `Transaction__c.Stage__c` `editable = true` — so **layer 3
  is already complete** and no FLS work is needed for the write itself.
- `DPEG_Apex_Access` is in `DPEG_Transaction_Team` and already grants `RecordStageAdvanceController`
  — so **layer 4 (capability) is already satisfied** and no new capability set is required. That
  class is *permanently* un-narrowable (it holds both the cacheable `hasStageActionAccess` question
  and the `advance`/`advanceTo` actions, and Apex class access is per-CLASS), which is exactly why
  it stays in the catch-all and why the Transaction team can already reach it.

| Option | What it does | Verdict |
| --- | --- | --- |
| **Reuse `DEAL_DRIVER`** | Gates Transaction stage on `User.Deal_Driver__c` + `Acquisition_Deal_Driver` | ❌ **Wrong population, in both directions.** No Transaction-team member holds it, so the feature would be dead for the only persona that owns it (the exact defect Tranche 3C recorded for the disposition PSA). Granting it to them instead would hand them **all six Opportunity deal actions** — the boundary merge `DispositionActionPermissionService`'s header rejects as option 1. |
| **New `TRANSACTION_DRIVER`** | Third two-factor gate: `User.Transaction_Driver__c` FLS via a new `Transaction_Deal_Driver` layer-5 set, AND the flag `true` | ✅ **RECOMMENDED** — see below |
| **No gate** | Add an enum member returning `true` | ❌ Inverts `passesGate`'s fail-closed contract and makes an unwired gate indistinguishable from a granted one — the specific hazard that header calls out. |
| **Defer item (2)** | Ship (1), (3), (4); leave the Path button as the stage writer | ⚠ **Legitimate, and the user should be offered it** — see D2-b |

**Why `TRANSACTION_DRIVER`, argued from the seven-layer model (ARCHITECTURE §2, "Permission Set
Architecture"):**

- The model puts **capability** at layer 4 and **authorization** at layer 5, and states they "must
  never be merged in either direction". A Transaction stage gate has both halves; the capability
  half already exists (`DPEG_Apex_Access` → `RecordStageAdvanceController`), so only the layer-5
  flag set is missing. Adding it *completes* the model rather than extending it.
- `Disposition_Deal_Driver`'s own XML comment already answers the tempting shortcut — putting the
  FLS on `DPEG_Transaction_Edit` (layer 3) "would hand factor (a) to that set's whole population as
  a side effect of editing transactions, leaving a one-factor gate". `DPEG_Transaction_Edit` is also
  a broad set redeployed often, and a `PermissionSet` deploy **replaces** its grant list — the exact
  hazard measured twice on this project.
- `Disposition_Deal_Driver` (2026-08-09) is the working precedent for exactly this shape: one new
  `User` checkbox, one one-grant permission set, one mirrored service, one enum member, one
  `passesGate` branch. It cost no changes below the config in `RecordStageAdvanceService` — and
  Tranche 3B/3C then proved the seam absorbs additions without touching `advance()`, `advanceTo()`,
  `sequenceFor()`, `gateFor()`, `load()` or `setStage()`.

**Cost, stated honestly:** 1 `User` field, 1 permission set, 1 service class (+ its test), 1
`UserSelector` method, 1 enum member, 1 `passesGate` branch — **plus two undeployable org steps**
(assign `Transaction_Deal_Driver`; set `Transaction_Driver__c = true` on each transaction user).
An admin smoke test proves nothing about this gate: a bare System Administrator has no FLS on a
Metadata-API-deployed `User` field either, which is why the Modify All Data bypass must run
**before** the flag read.

⚠ `UserSelector` must gain a **separate** `selectTransactionDriverFlagForCurrentUser()`. Do **not**
merge it into an existing flag query — that class's header records that a merged
`SELECT Deal_Driver__c, Disposition_Driver__c` would make `USER_MODE` throw for a single-flag
persona, and each service converts a throw to `false`, silently denying a legitimate driver.

**🔴 GATE 1 DECISION D2-b — build the third gate, or defer item (2)?**
Because the Path button already works, deferring costs the user nothing functional today. Building
it buys consistency, a server-side assert, and validation-rule messages surfacing in the toast
instead of being swallowed by LDS. **Recommend building it**, but the user should make this call
knowingly given the two undeployable org steps.

### 2.4 🔴 SURFACING THE ACTION — the trap

`Transaction_Record_Page`'s `force:highlightsPanel` has `enableActionsConfiguration = false`, so its
action bar is **inherited verbatim** from `layouts/Transaction__c-Transaction Layout`'s
`platformActionList`, which holds six items: `Edit`, `Clone`, `Delete`, `LogACall`, `NewEvent`,
`NewTask`.

**Setting `enableActionsConfiguration = true` to add `Transaction__c.Advance_Stage` DISCARDS all six
unless they are re-listed in `actionNames`.** No deploy error, no failing test — readback is the only
proof. This has already bitten this project on three pages.

Two admissible routes:

| Route | Effect |
| --- | --- |
| **(i) Dynamic Actions** — `enableActionsConfiguration = true`, `actionNames` = the six inherited actions **plus** `Transaction__c.Advance_Stage` with a `{!$User.Transaction_Driver__c} EQUAL true` visibility rule | ✅ **RECOMMENDED.** Matches `NDA_Record_Page` exactly, and is the only route that can hide the button from non-drivers. `⚠` The four Activity-composer actions can never live in `actionNames`; only these six. |
| **(ii) Layout `quickActionList`** — add the action to the layout, leave `enableActionsConfiguration = false` | Preserves the six by construction, but **cannot** be visibility-gated, so every Transaction user sees a button that will refuse them. Rejected. |

**🔴 GATE 1 DECISION D2-c — hide the Path update button?** With the quick action live,
`hideUpdateButton = false` leaves **two routes to the same write**, one gated and one not — the
governance hole `RecordStageAdvanceService` exists to close. Recommend flipping it to `true` in the
same change. ⚠ This removes an ungated capability Transaction users have today, so it needs explicit
sign-off, not a drive-by edit.

---

## 3. PROPERTY NAME ON THE ACTIVE TRANSACTIONS LWC

### 3.1 Confirmed — a data bug, not a missing column

- `lwc/activeTransactionsList/activeTransactionsList.js:29` already declares the `Property` column;
  line 99 renders `t.propertyName || '—'`.
- `TransactionController.cls:172` → `r.propertyName = t.Property_Name__c`.
- `TransactionSelector.selectActiveRows()` selects `Property_Name__c` — a `Text(120)` field.
- `ContractExecutionService.cls:129-131` creates the Transaction with `Property__c` (the **lookup**)
  and never `Property_Name__c`.

⇒ Every application-created Transaction has a blank `Property_Name__c`. The column renders `—`.

### 3.2 🔴 OTHER READERS — grepped, and this changes the answer

`Transaction__c.Property_Name__c` is read by **five report files**, every one of which shows the same
blank column today:

- `reports/Transactions/Open_Transactions.report-meta.xml`
- `reports/Transactions/Closing_In_30_Days.report-meta.xml`
- `reports/Transactions/Financing_Active.report-meta.xml`
- `reports/Transactions/Transactions_By_Stage.report-meta.xml`
- `reports/Transactions/Completion_By_Deal.report-meta.xml`

It is also **written by** `scripts/seed-transactions.apex` (5 hardcoded names) and granted by
`DPEG_Transaction_Edit` / `DPEG_Transaction_View`. It is **not** on the Transaction layout, **not**
on `Transaction_Record_Page`, and **not** in any flow or list view.

### 3.3 🔴 Option (a) is not what the brief assumed

**Salesforce cannot convert a Text field to a Formula field.** Formula is not in the field-type
conversion matrix. Option (a) is therefore a **delete-and-recreate**, and this repo has already paid
that cost once (the §1 rule-2 re-casing repair). It would:

1. **destroy stored data** — `seed-transactions.apex` populates 5 rows; any hand-entered value dies;
2. **be blocked** — `TransactionSelector` and `TransactionController` reference the field in Apex,
   which blocks deletion by field-Id, forcing a remove-refs → delete → recreate → re-add-refs pass;
3. **silently break the five reports** — reports name fields directly and do not block deletion;
   the column simply disappears with no error (measured behaviour on this project);
4. **possibly render blank anyway** on the exact rows that have data today — the seeded rows set
   `Property_Name__c` but not `Property__c`, so a `Property__r.Name` formula returns blank for them.
   The fix would *invert* on the demo data.

**⚠ Verification gate before any destructive option:**
`SELECT COUNT() FROM Transaction__c WHERE Property_Name__c != null` on `usman-dpeg`.

### 3.4 RECOMMENDATION — option **(c)**, a new formula field

| | (a) convert to formula | (b) query `Property__r.Name` in the selector | **(c) new `Property_Display_Name__c` formula field** |
| --- | --- | --- | --- |
| Fixes the LWC | ✅ | ✅ | ✅ |
| Fixes the 5 reports | ✅ (after re-adding the column) | ❌ **leaves all five blank** | ✅ (after repointing the column) |
| Destructive | 🔴 yes — delete/recreate, data loss, blocked by Apex refs | ✅ no | ✅ no |
| Self-maintaining | ✅ | ✅ | ✅ |
| Leaves a trap | no | 🔴 yes — a stale blank Text field two surfaces still read | ⚠ yes, but *named* and queued for retirement |
| Repo precedent | the §1 repair (expensive, deliberate) | — | `Broker_Assignment__c.Property_Display_Name__c` = Formula(Text) `Property_Asset__r.Property_Name__c` — **same name, same shape** |

**Recommend (c).** It is this repo's standing additive pattern (add → repoint → retire, never
rename), it is non-destructive, and it is the only option that fixes all six surfaces without a
delete-and-recreate.

Definition: `Property_Display_Name__c`, **Formula (Text)**, formula `Property__r.Name`,
`formulaTreatBlanksAs` = `BlankAsBlank`, label `Property`.

⚠ **A formula field returns blank when `Property__c` is null.** `ContractExecutionService` copies
`Opportunity.Property__c`, and `Property__c` is created only by `LeadConvertService` — so a
manually-built deal has no Property and this column will still show `—`. That is correct (there is
genuinely no property) and is the same residual `PropertyAssetService` and `DealFolderService` both
record.

**Optional coalesce, offered as D3-b:** the controller can render
`BLANKVALUE(Property_Display_Name__c, Property_Name__c)` — preserving the five seeded/hand-entered
names *and* filling the automated rows. Recommended for the LWC only; the reports should be
repointed to the formula field cleanly.

**🔴 GATE 1 DECISION D3-a — (c) new formula field, or (b) selector-only?**
(b) is genuinely smaller (2 files, no metadata) and is the right call **only if** the user accepts
that the five Transaction reports stay blank. Recommend (c).

**🔴 GATE 1 DECISION D3-c — repoint the five reports in this change, or defer?**
Recommend repointing them here: the reports are the reason (c) beats (b), and doing (c) without
repointing them delivers no more than (b) did.

---

## 4. `Tasks (75)` vs `0 / 82` — THE FOURTH ISSUE

### 4.1 Confirmed, and sharper than reported

- `activeTransactionsList.js:6` — `const TASKS_TOTAL = 75;`
- `activeTransactionsList.js:34` — column label literally `'Tasks (75)'`
- `activeTransactionsList.js:91,92,105` — the percentage, the completion test and the `N / M` text
  all use that constant.
- The record page reads `Tasks_Display__c`, a formula:
  `TEXT(BLANKVALUE(Tasks_Complete__c,0)) & " / " & TEXT(BLANKVALUE(Tasks_Total__c,0))`.
- 🔴 `TaskFanoutService.cls:131` writes `Tasks_Total__c = createdForTxn` — **the count actually
  created for that Transaction**, gated by that Transaction's own condition fields
  (`Loan_Required__c` etc., from `Task_Group_Def__mdt.Condition_Field__c`).

**⇒ There is no correct constant.** 82 is as wrong as 75, because the total is per-record by design:
a deal with no loan gets fewer tasks. Any hardcoded denominator will be wrong for some rows.

### 4.2 RECOMMENDATION

Read `Tasks_Total__c` per row.

1. `TransactionSelector.selectActiveRows()` — add `Tasks_Total__c` to the SELECT.
2. `TransactionController.TxnRow` — add `@AuraEnabled public Integer tasksTotal`, mapped with the
   same null-coalescing shape line 176 already uses for `tasksComplete`.
3. `activeTransactionsList.js` — delete `TASKS_TOTAL`; use `t.tasksTotal` per row.
4. **The column label cannot be a fixed number.** Change `'Tasks (75)'` → `'Tasks'`.

⚠ **Handle `Tasks_Total__c = null`.** It is null on a Transaction created but not yet fanned out
(`Tasks_Fanned_Out__c = false`). Guard the division — with a null/zero total, render `0 / —` (or the
existing `—`) and a 0%-width bar. **Never divide by zero and never silently substitute a constant**,
which would reintroduce exactly this defect.

⚠ FLS: `DPEG_Transaction_Edit` and `DPEG_Transaction_View` both already grant
`Transaction__c.Tasks_Total__c` readable — verified. `selectActiveRows()` is `WITH USER_MODE`, which
**throws** rather than degrades, so this was worth confirming before adding the field.

---

## 5. 🔵 ADMIN WORK (`salesforce-admin`)

| # | Item | Type | Notes |
| --- | --- | --- | --- |
| A1 | `objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml` | ValidationRule | §1.5 formula + message. Do NOT touch `Approved_LOI_Before_PSA`. |
| A2 | `objects/User/fields/Transaction_Driver__c.field-meta.xml` | CustomField (Checkbox) | **Only if D2-b = build.** Mirror `User.Disposition_Driver__c` exactly. |
| A3 | `permissionsets/Transaction_Deal_Driver.permissionset-meta.xml` | PermissionSet | **Only if D2-b = build.** Layer 5: **exactly one** `fieldPermissions` entry (`User.Transaction_Driver__c`, `readable=true`, `editable=false`). No objectPermissions, no classAccesses. Rationale in an XML comment **inside** the root element. |
| A4 | `quickActions/Transaction__c.Advance_Stage.quickAction-meta.xml` | QuickAction | **Only if D2-b = build.** Byte-shape of `NDA__c.Advance_Stage`: `actionSubtype Action`, `type LightningWebComponent`, `lightningWebComponent advanceRecordStage`, label `Advance Stage`. |
| A5 | `flexipages/Transaction_Record_Page.flexipage-meta.xml` | FlexiPage | **Only if D2-b = build.** 🔴 Set `enableActionsConfiguration = true` and list **all seven**: `Edit`, `Clone`, `Delete`, `LogACall`, `NewEvent`, `NewTask`, `Transaction__c.Advance_Stage`. Gate only the last on `{!$User.Transaction_Driver__c} EQUAL true`. |
| A6 | `flexipages/Transaction_Record_Page.flexipage-meta.xml` → `hideUpdateButton` = `true` | FlexiPage | **Only if D2-c = yes.** Same file as A5 — one edit. |
| A7 | `objects/Transaction__c/fields/Property_Display_Name__c.field-meta.xml` | CustomField (Formula Text) | **Only if D3-a = (c).** `Property__r.Name`, `BlankAsBlank`. |
| A8 | FLS for `Property_Display_Name__c` in `DPEG_Transaction_Edit` + `DPEG_Transaction_View` | PermissionSet | **Only if D3-a = (c).** 🔴 Grant it where the SIBLING fields live. A Metadata-API field arrives with **no** FLS for any profile, and `selectActiveRows()` is `WITH USER_MODE` — which throws, so the whole LWC dies without this. ⚠ A `PermissionSet` deploy **replaces** its grant list: add the entry to the file, never org-side. Formula fields take `readable` only. |
| A9 | Repoint 5 reports from `Property_Name__c` → `Property_Display_Name__c` | Report ×5 | **Only if D3-c = yes.** Files listed in §3.2. |

---

## 6. 🟢 DEVELOPMENT WORK (`salesforce-developer`)

| # | Item | File | Notes |
| --- | --- | --- | --- |
| D1 | `TransactionSelector.selectStageRequiredById(Id)` | `classes/TransactionSelector.cls` | **Only if D2-b = build.** Static, `WITH USER_MODE`, `SELECT Id, Stage__c FROM Transaction__c WHERE Id = :recordId` — fetch-for-use, throws `QueryException` on a miss. ⚠ Do **not** select `RecordTypeId`: the object has none, so the field is not compilable on it. |
| D2 | `TRANSACTION_NEXT_STAGE` + `CONFIG_BY_TYPE` entry + `load()` branch | `classes/RecordStageAdvanceService.cls` | **Only if D2-b = build.** Single-sequence `StageConfig('Transaction','Stage__c', new StageTypeConfig(TRANSACTION_DRIVER, TRANSACTION_NEXT_STAGE))`. No explicit targets — the path is linear. |
| D3 | `StageActionGate.TRANSACTION_DRIVER` + `passesGate` branch | `classes/RecordStageAdvanceService.cls` | **Only if D2-b = build.** ⚠ Declare the enum member **only** in the same change as D4 + A2 + A3 — an unwired member falls into `when else` and denies silently. |
| D4 | `TransactionActionPermissionService` | new `classes/TransactionActionPermissionService.cls` | **Only if D2-b = build.** Line-for-line mirror of `DispositionActionPermissionService`: Modify All Data bypass **first**, then the flag read; reuse `OpportunityActionPermissionService.NO_PERMISSION_MESSAGE`; `@TestVisible` cache + `clearCache()` + `simulateLookupFailure`. |
| D5 | `UserSelector.selectTransactionDriverFlagForCurrentUser()` | `classes/UserSelector.cls` | **Only if D2-b = build.** 🔴 A **separate** query — do not merge with the other flag reads. |
| D6 | `Property__r.Name` / `Property_Display_Name__c` in `selectActiveRows()` + `Tasks_Total__c` | `classes/TransactionSelector.cls` | Items (3) and (4) — one edit to one query. |
| D7 | `TxnRow.tasksTotal`; `propertyName` source change | `classes/TransactionController.cls` | Items (3) and (4). |
| D8 | Drop `TASKS_TOTAL`, use `t.tasksTotal`, relabel the column `'Tasks'`, null-guard the division | `lwc/activeTransactionsList/activeTransactionsList.js` | Item (4). Update `__tests__/activeTransactionsList.test.js` accordingly. |

**No new LWC bundle is required for item (2).** `lwc/advanceRecordStage` + `lwc/recordStageGuard`
are object-agnostic: the guard calls `RecordStageAdvanceController.hasStageActionAccess(recordId)`
and the server dispatches on `Id.getSObjectType()`. Adding `Transaction__c` to `CONFIG_BY_TYPE` is
all the client needs — this is exactly the seam Tranches 3B and 3C proved.

**No permission-set change is required for Apex reachability.** `DPEG_Transaction_Team` already
holds `DPEG_Apex_Access`, which grants `RecordStageAdvanceController` — and that class is
permanently un-narrowable (per-CLASS access; it holds both the cacheable question and the actions),
so it stays in the catch-all. Do **not** create a `Transaction_Stage_Actions_Access` capability set;
there is nothing for it to carry.

---

## 7. 🔗 EXECUTION ORDER

The four items are **independent** and can ship in any order or separately. Within each:

1. **Item (1)** — A1 alone. No dependency.
2. **Item (2)** — A2 + A3 must deploy **before or with** D3/D4/D5 (the enum member and the service
   reference the field, and the field's FLS grant must exist or every driver is denied). A4 and A5
   deploy after D2 (the quick action targets a component that dispatches to a config that must
   exist). Then the two **undeployable org steps**: assign `Transaction_Deal_Driver`; set
   `Transaction_Driver__c = true` per user. A6 last, once the quick action is verified working.
3. **Item (3)** — A7 then A8 then D6/D7 then A9. 🔴 A8 before D6: `WITH USER_MODE` throws on an
   ungranted field, so deploying the query first breaks the whole LWC.
4. **Item (4)** — D6 + D7 + D8 together (one selector edit shared with item 3).

---

## 8. ⚠ DECISIONS REQUIRED AT GATE 1

| ID | Question | Recommendation |
| --- | --- | --- |
| **D1-b** | Does `Completed_LOI_Before_PSA` exempt the blank-`Primary_LOI__c` case (one message) or not (two messages)? | **Exempt it** — `NOT(ISBLANK(Primary_LOI__c))` |
| **D2-a** | 🔴 Is the Transaction sequence `… Closing Prep → Post-Closing → Closed Won` (picklist order) or `… Closing Prep → Closed Won → Post-Closing` (what the Path's own step text implies)? | **Ask the user** — no safe default |
| **D2-b** | 🔴 Build the third `TRANSACTION_DRIVER` two-factor gate, or defer item (2) entirely given the Path button already works? | **Build it**, with the cost stated (1 field + 1 permission set + 1 service + 2 undeployable org steps) |
| **D2-c** | Set `hideUpdateButton = true`, removing the ungated Path route? | **Yes** — otherwise two routes, one gated |
| **D3-a** | 🔴 New `Property_Display_Name__c` formula field (c), or selector-only `Property__r.Name` (b)? Option (a) is a delete-and-recreate and is **not recommended**. | **(c)** |
| **D3-b** | Coalesce `BLANKVALUE(Property_Display_Name__c, Property_Name__c)` in the LWC to preserve the 5 seeded names? | **Yes** for the LWC only |
| **D3-c** | Repoint the 5 Transaction reports in this change? | **Yes** — it is the reason (c) beats (b) |

**Verification gate before any work on item (3):** run
`SELECT COUNT() FROM Transaction__c WHERE Property_Name__c != null` on `usman-dpeg`.

---

## 9. 📝 PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md and .claude/rules/salesforce-global-rule.md first. Follow the Initial Gate
and the per-type loop (skill selection -> skill load -> salesforce-api-context MCP attempt ->
pre-write gate -> generate -> checkpoint), ONE metadata type at a time. Do NOT deploy — create
metadata files only. API version 67.0. Package directory force-app/main/default. No field prefix.
Build ONLY what is listed. Do not add validation rules, permission sets, page layouts, tests or
"nice to have" items that are not listed here.

ITEM 1 — VALIDATION RULE (always build)
Create objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml:
  active: true
  errorConditionFormula:
      AND(
          ISCHANGED(StageName),
          ISPICKVAL(StageName, 'PSA'),
          NOT(ISBLANK(Primary_LOI__c)),
          TEXT(Primary_LOI__r.Stage__c) <> 'Completed'
      )
  errorDisplayField: StageName
  errorMessage: This deal cannot enter PSA until the primary LOI is Completed. Advance the LOI to
                Completed on its own record page first.
  description: <= 255 chars, summarising the above; put the long rationale in an XML COMMENT
               INSIDE the root <ValidationRule> element (a comment ABOVE the root breaks `sf` at
               source conversion — Approved_LOI_Before_PSA is the precedent in this same folder).
Use TEXT(...) rather than ISPICKVAL on the cross-object stage — RecordStageAdvanceService's header
requires it for LOI stage compares.
🔴 Do NOT modify the existing Approved_LOI_Before_PSA rule. The two are deliberately separate so
their messages name different remedies.
🔴 Do NOT add anything that touches records already at PSA. A validation rule only fires on change;
grandfathered rows are out of scope by design.

ITEM 2 — TRANSACTION STAGE ACTION (ONLY IF the user approved D2-b = build; use the sequence the
user chose at D2-a)
(a) objects/User/fields/Transaction_Driver__c.field-meta.xml — Checkbox, defaultValue false.
    Mirror objects/User/fields/Disposition_Driver__c.field-meta.xml exactly (label/description
    style).
(b) permissionsets/Transaction_Deal_Driver.permissionset-meta.xml — LAYER 5 AUTHORIZATION SET.
    EXACTLY ONE fieldPermissions entry: User.Transaction_Driver__c, readable=true, editable=false.
    NO objectPermissions, NO classAccesses, NO userPermissions, NO other fieldPermissions.
    Model it on permissionsets/Disposition_Deal_Driver.permissionset-meta.xml, including the long
    XML comment INSIDE the root element explaining: why it is its own set (two-factor gate; folding
    the FLS into DPEG_Transaction_Edit would hand factor (a) to that set's whole population), why
    the FLS grant is load-bearing (USER_MODE throws rather than degrades; Metadata-API fields ship
    with no FLS), and that assignment is an org action, not deployable metadata.
(c) quickActions/Transaction__c.Advance_Stage.quickAction-meta.xml — copy the exact shape of
    quickActions/NDA__c.Advance_Stage.quickAction-meta.xml: actionSubtype Action, label
    "Advance Stage", lightningWebComponent advanceRecordStage, optionsCreateFeedItem false,
    type LightningWebComponent.
(d) flexipages/Transaction_Record_Page.flexipage-meta.xml — the force:highlightsPanel currently has
    enableActionsConfiguration=false, so it INHERITS the six actions from
    layouts/Transaction__c-Transaction Layout.layout-meta.xml: Edit, Clone, Delete, LogACall,
    NewEvent, NewTask.
    🔴 SETTING enableActionsConfiguration=true DISCARDS ALL SIX SILENTLY. You MUST list all six in
    actionNames plus Transaction__c.Advance_Stage. Only the last one carries a visibilityRule:
    {!$User.Transaction_Driver__c} EQUAL true. Use flexipages/NDA_Record_Page.flexipage-meta.xml as
    the structural model. Do not add the Activity-composer actions to actionNames — they cannot
    live there.
(e) ONLY IF the user approved D2-c: in the same flexipage, set the pathAssistant component's
    hideUpdateButton from false to true.

ITEM 3 — PROPERTY NAME (ONLY IF the user chose D3-a = option (c))
(f) objects/Transaction__c/fields/Property_Display_Name__c.field-meta.xml — Formula, returnType
    Text, formula: Property__r.Name, formulaTreatBlanksAs BlankAsBlank, label "Property".
    Precedent for the name and shape: Broker_Assignment__c.Property_Display_Name__c.
    🔴 Do NOT modify or delete Transaction__c.Property_Name__c. It holds seeded data, is referenced
    by Apex (which blocks deletion by field-Id), and is read by five report files.
(g) Add Property_Display_Name__c to permissionsets/DPEG_Transaction_Edit and
    permissionsets/DPEG_Transaction_View, readable=true (formula fields take readable only).
    🔴 This is mandatory, not optional: TransactionSelector.selectActiveRows() is WITH USER_MODE,
    which THROWS rather than degrades, so an ungranted field kills the whole Active Transactions
    LWC. Add it IN the permission set files — a PermissionSet deploy REPLACES its grant list, so an
    org-side-only grant is wiped by the next deploy of that file.
(h) ONLY IF the user approved D3-c: repoint the Property column from Transaction__c.Property_Name__c
    to Transaction__c.Property_Display_Name__c in these five report files:
      reports/Transactions/Open_Transactions.report-meta.xml
      reports/Transactions/Closing_In_30_Days.report-meta.xml
      reports/Transactions/Financing_Active.report-meta.xml
      reports/Transactions/Transactions_By_Stage.report-meta.xml
      reports/Transactions/Completion_By_Deal.report-meta.xml

POST-DEPLOY ORG STEPS (not deployable metadata — record them, do not attempt them):
  - Assign Transaction_Deal_Driver to each Transaction-team user.
  - Set User.Transaction_Driver__c = true on each of those users.
  - An administrator smoke test proves NOTHING about this gate (a bare admin has no FLS on a
    Metadata-API-deployed User field). Acceptance-test as a real transaction-driver persona.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md, .claude/rules/apex-layering-rule.md and .claude/rules/bulk-test-rule.md
first. API version 67.0. Do NOT deploy. Build ONLY what is listed — no extra methods, no extra
fields, no error handling or logging beyond the patterns the sibling classes already use.

ITEM 2 — ADD Transaction__c TO THE GENERIC STAGE-ADVANCE ENGINE
(ONLY IF the user approved D2-b = build. Use the stage sequence the user chose at D2-a.)

(1) classes/TransactionSelector.cls — add:
      public static Transaction__c selectStageRequiredById(Id recordId)
    A single static, fully-literal, WITH USER_MODE query: SELECT Id, Stage__c FROM Transaction__c
    WHERE Id = :recordId. Fetch-for-use: let it throw System.QueryException on a miss, matching
    NdaSelector/LoiSelector/UnderwritingSelector.selectStageRequiredById.
    🔴 Do NOT select RecordTypeId. Transaction__c has NO record types, so RecordTypeId is not a
    compilable field on it — that is why the other record-type-free selectors omit it too.

(2) classes/RecordStageAdvanceService.cls — FOUR edits, and nothing below CONFIG_BY_TYPE should
    change (advance(), advanceTo(), sequenceFor(), gateFor(), setStage() stay byte-identical; that
    property was demonstrated by Tranches 3B and 3C and is the seam's whole point):
    a. new private static final Map<String,String> TRANSACTION_NEXT_STAGE, documented, holding the
       user-approved sequence. 'Closed Won' has NO entry (terminal).
    b. new CONFIG_BY_TYPE entry using the SINGLE-SEQUENCE StageConfig constructor:
         Transaction__c.SObjectType => new StageConfig(
             'Transaction', 'Stage__c',
             new StageTypeConfig(StageActionGate.TRANSACTION_DRIVER, TRANSACTION_NEXT_STAGE))
       No explicit targets — the path is linear, so advanceTo() is structurally unreachable here.
       Note in a comment that Transaction__c has no record types, so it pays no describe and
       hasStageActionAccess costs ZERO extra queries via the byRecordType.size()==1 short-circuit.
    c. new StageActionGate enum member TRANSACTION_DRIVER, documented in the enum's doc comment
       alongside DEAL_DRIVER and DISPOSITION_DRIVER (which field, which permission set, which
       population).
    d. new passesGate branch: when TRANSACTION_DRIVER ->
       TransactionActionPermissionService.hasTransactionActionAccess().
    e. new load() branch: if (objectType == Transaction__c.SObjectType) return
       TransactionSelector.selectStageRequiredById(recordId);
    🔴 Declare the enum member ONLY in the same change as (3), (4) and the admin agent's field +
    permission set. An unwired member falls into `when else` and denies silently for everyone.
    Also update the class header: it says "SIX child objects" in several places — it is now SEVEN,
    and Transaction__c is the first one from the Transactions module rather than
    acquisitions/disposition.

(3) new classes/TransactionActionPermissionService.cls — mirror
    classes/DispositionActionPermissionService.cls line for line, changing only the field, the
    permission set name and the class name:
      - hasTransactionActionAccess() / assertTransactionActionAccess()
      - 🔴 Modify All Data bypass runs BEFORE the flag read. Reversing those two statements locks
        every administrator out; a Metadata-API-deployed User field arrives with no FLS for any
        profile, so UserSelector throws for a bare admin exactly as for a bare Standard User.
      - catch QueryException from the flag read -> return false (that throw IS factor (a) failing).
      - the PermissionSetAssignment read stays OUTSIDE the try/catch: a fault must not read as a
        denial.
      - reuse OpportunityActionPermissionService.NO_PERMISSION_MESSAGE; do not re-declare it.
      - @TestVisible cachedHasTransactionActionAccess, simulateLookupFailure, clearCache().
      - with sharing, zero SOQL, zero DML.

(4) classes/UserSelector.cls — add selectTransactionDriverFlagForCurrentUser(), a SEPARATE query
    selecting only Transaction_Driver__c, WITH USER_MODE.
    🔴 Do NOT merge it into an existing flag query. That class's header records why: a merged
    SELECT makes USER_MODE throw for a single-flag persona, and each service converts a throw to
    false — silently denying a legitimate driver.

(5) NO new LWC bundle. lwc/advanceRecordStage + lwc/recordStageGuard are object-agnostic and the
    server dispatches on Id.getSObjectType(). NO new capability permission set:
    DPEG_Transaction_Team already holds DPEG_Apex_Access, which grants RecordStageAdvanceController
    — a class that is permanently un-narrowable because Apex class access is per-CLASS and it holds
    both the cacheable hasStageActionAccess question and the advance/advanceTo actions.

ITEMS 3 + 4 — PROPERTY NAME AND THE TASK DENOMINATOR (one shared selector edit)

(6) classes/TransactionSelector.cls — in selectActiveRows() add Tasks_Total__c, and add
    Property_Display_Name__c (if the user chose D3-a = (c)) or Property__r.Name (if D3-a = (b)).
    Leave Property_Name__c in the SELECT if the user approved the D3-b coalesce; drop it otherwise.

(7) classes/TransactionController.cls —
    - TxnRow gains @AuraEnabled public Integer tasksTotal, mapped with the same null-coalescing
      shape line 176 already uses for tasksComplete.
    - r.propertyName sources from the new field. If D3-b = yes, coalesce:
      Property_Display_Name__c first, falling back to Property_Name__c (this preserves the five
      values scripts/seed-transactions.apex writes).

(8) lwc/activeTransactionsList/activeTransactionsList.js —
    - DELETE `const TASKS_TOTAL = 75;`
    - use t.tasksTotal per row for the percentage, the `done >= total` completion test and the
      `${done} / ${total}` text.
    - change the column label from 'Tasks (75)' to 'Tasks'. It CANNOT be a fixed number:
      TaskFanoutService writes Tasks_Total__c per record, gated by that Transaction's own condition
      fields, so the total genuinely differs between rows.
    - 🔴 NULL GUARD: Tasks_Total__c is null before the Day-0 fan-out runs. Never divide by zero and
      never substitute a constant. With a null/zero total render the existing em-dash placeholder
      and a 0%-width bar.
    - update lwc/activeTransactionsList/__tests__/activeTransactionsList.test.js for the new
      tasksTotal field and the relabelled column, including a case where tasksTotal is null.

TESTING
- .claude/rules/bulk-test-rule.md's 251-record mandate does NOT apply to (2), (3) or (4): the stage
  service is a per-transaction-singleton @AuraEnabled operation (same exemption as
  StageAdvanceService and the two existing permission services), and the controller reads are
  cacheable dashboard queries. State that reasoning in each test class header so review does not
  demand 251.
- Write tests ONLY for the classes you create or change here. The salesforce-unit-testing agent
  runs after you.
```

---

## 10. WHAT IS DELIBERATELY NOT IN SCOPE

Recorded so no implementation agent adds them:

- Back-filling / correcting deals already at `PSA` with a non-`Completed` LOI (§1.4).
- Retiring `Transaction__c.Property_Name__c` (§3.4 — an additive change now, a retirement later).
- The dead `'Closed Lost'` entry in `activeTransactionsList.js`'s `STAGE` pill map (§2.1) — no such
  picklist value exists, but removing it is unrelated to any reported issue.
- Reordering `Transaction__c.Stage__c`'s picklist values (§2.2 asks which order is *correct*; it
  does not propose changing the picklist).
- Any Transaction record type, Path rewrite, or `Status__c` ↔ `Stage__c` reconciliation.
- Any change to `Approved_LOI_Before_PSA`, `StageAdvanceService`, or the insert-at-PSA hole.
