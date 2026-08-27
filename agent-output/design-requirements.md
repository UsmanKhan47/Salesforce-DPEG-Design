# DESIGN REQUIREMENTS — Retire the generic "Advance Stage" button; per-hop named quick actions on the acquisition / review / transaction side

**Date:** 2026-08-27
**Branch:** `qa/lifecycle-simulation-2026-08-27`
**Org:** `usman-dpeg`
**Finishes:** commit `a939e97` (2026-08-26), which did this job for the **disposition** record types of `NDA__c`, `LOI__c`, `Contract_Review__c` and deliberately left acquisition on Advance Stage.
**Deliverable produced by:** salesforce-design. **No metadata was created or modified.**

---

## 0. FINDINGS FIRST — corrections to the brief

I re-ran every inventory the brief asserted (per standing rule: do not design against an unverified surface list). Six corrections, three of them load-bearing.

### F-1 🔴 "The 8 `NO_NEXT_STEP_HINTS` entries become unreachable" — FALSE. Only **ONE** does.

`RecordStageAdvanceService.NO_NEXT_STEP_HINTS` has 8 entries (verified, lines 1483–1516):

| # | Key | Object | Still reachable after this change? |
|---|---|---|---|
| 1 | `Underwriting\|In Progress` | `Underwriting__c` | ❌ **becomes unreachable** — in scope |
| 2 | `Disposition\|Disposition Readiness` | `Disposition__c` | ✅ fully live |
| 3 | `Disposition\|BOV Outreach` | `Disposition__c` | ✅ fully live |
| 4 | `Disposition\|Broker Selection` | `Disposition__c` | ✅ fully live |
| 5 | `Disposition\|Release Materials` | `Disposition__c` | ✅ fully live |
| 6 | `Disposition\|Active Listing` | `Disposition__c` | ✅ fully live |
| 7 | `Disposition\|Offer Selection` | `Disposition__c` | ✅ fully live |
| 8 | `Disposition\|PSA` | `Disposition__c` | ✅ fully live |

**Seven of the eight are on `Disposition__c`, which is NOT one of the seven objects in scope.** `Disposition__c` has no `Advance_Stage` quick action at all — it is already served by four named `Advance_to_*` actions, all of which call `advance()` and therefore still hit these hints. The service's own header calls them "load-bearing here in a way they are on no other object": a disposition refuses at seven of eleven stages, and without the hints the button reads like a defect.

⇒ **The Gate-1 pre-answer #2 is safe, but its cost is 1/8th of what the brief priced.** Only the `Underwriting|In Progress` hint loses its UI path.

**RECOMMENDATION (not a decision): LEAVE all 8 hint entries in place.**
- Retiring the Underwriting entry is an **Apex change** (`RecordStageAdvanceService` + `RecordStageAdvanceServiceTest`), which this change otherwise does not need at all. That trades a zero-risk no-op for an Apex deploy and a test edit.
- The hint remains reachable through `RecordStageAdvanceController.advance` for any non-UI caller, and it is the class's only documentation-in-code that `In Progress → Approved` is approval-owned.
- Touching the other seven would be an active regression on the disposition module.
- If the user wants the dead entry gone, do it as a separate, deliberate Apex change — the same posture `a939e97` took toward the dead `Advance_Stage` page entry it left behind.

### F-2 🔴 The `LOI__c` hop `Submitted → Negotiation` must NOT get a new button — it already has one, and so does its branch partner.

The brief's map lists `Submitted -> Negotiation` as a hop needing a per-stage button. It is already served:

- `LOI__c.Mark_Countered` — **label `Negotiation`** — rendered at `Stage__c = 'Submitted'`
- `LOI__c.Mark_Completed` — **label `Signed`** — rendered at `Stage__c = 'Submitted'`

Both already follow the destination-stage label convention and were built for exactly this branch (the acquisition LOI is the one non-linear sequence; `Signed` is not derivable from `Submitted`, so it is an `advanceTo` explicit target).

Furthermore, the generic Advance Stage button **has never rendered at `Submitted`**: `LOI__c.Is_Advance_Allowed__c` includes `Stage <> "Submitted"`, and both acquisition `Advance_Stage` entries carry `Is_Advance_Allowed__c EQUAL true`.

⇒ Adding a `Move_to_Negotiation` entry at `Submitted` would put **two buttons that both land on `Negotiation`** side by side. **Do not add it.** LOI acquisition needs **three** buttons, not four.

### F-3 🔴 `Underwriting_Record_Page` carries a parenthesised OR that this repo has MEASURED the renderer ignores.

```xml
<booleanFilter>1 AND (2 OR 3)</booleanFilter>   <!-- Underwriting__c.Advance_Stage -->
```

`LOI_Record_Page` and `NDA_Record_Page` both record the measurement: a parenthesised OR **deploys, survives a retrieve, and is then IGNORED BY THE RENDERER — the button stayed visible.** This is the only surviving instance in the six pages in scope.

⇒ The Underwriting button today very likely renders at **every** stage including `In Progress` and the terminal `Completed`, not only at `Requested`/`Approved`. **Splitting it into two pure-AND `valueListItems` fixes a live latent defect as a side effect.** Say so in the implementation note so nobody "preserves existing behaviour" by re-creating the OR.

### F-4 🔴 The `Transaction__c` item is not a like-for-like swap. The layout has **no visibility-rule mechanism at all**.

`layouts/Transaction__c-Transaction Layout.layout-meta.xml` → `<platformActionList>` is a **flat, unconditional list**: `Edit(0)`, `Transaction__c.Advance_Stage(1)`, `Clone(2)`, `Delete(3)`, `LogACall(4)`, `NewEvent(5)`, `NewTask(6)`. There is no `visibilityRule` element on a `platformActionListItem`.

⇒ Putting four per-hop actions on the layout renders **all four simultaneously on every Transaction at every stage** — strictly worse than today. The only mechanism that gives per-stage buttons is **Dynamic Actions on `Transaction_Record_Page`**, which is currently `enableActionsConfiguration = false`. That is hazard (b) head-on. See §4 / WI-7.

### F-5 The Advance_Stage entry counts are 2/2/2/1/1/1, not 6/8/5/1/1/1.

The brief's numbers were raw `grep` line counts (they include header-comment prose and `advanceRecordStage` component references). The actual `valueListItems` to remove:

| Page | `Advance_Stage` valueListItems | Dynamic Actions already ON? |
|---|---|---|
| `NDA_Record_Page` | **2** (acquisition-gated, disposition-gated-dead) | ✅ `true` |
| `LOI_Record_Page` | **2** (acquisition-gated, disposition-gated-dead) | ✅ `true` |
| `Contract_Review_Record_Page` | **2** (acquisition-gated, disposition-gated-dead) | ✅ `true` |
| `Underwriting_Record_Page` | **1** | ✅ `true` |
| `Development_Feasibility_Review_Record_Page` | **1** | ✅ `true` |
| `Construction_Feasibility_Review_Record_Page` | **1** | ✅ `true` |
| `Transaction_Record_Page` | **0** | ❌ **`false`** ← the whole problem |
| `Transaction__c-Transaction Layout` | 1 `platformActionListItem` | n/a |

**9 flexipage entries + 1 layout item.** Hazard (b) is clear for all six flexipages — none needs Dynamic Actions enabled. It bites only on `Transaction_Record_Page`.

### F-6 The self-contradictory dead `Advance_Stage` entry exists on **three** pages, not one.

The brief flagged it on `NDA_Record_Page` only. `LOI_Record_Page` and `Contract_Review_Record_Page` each carry the same shape: a `Disposition_Deal_Actions`-gated entry whose `a939e97` criterion `RecordType.DeveloperName NE Disposition_<X>` contradicts its own disposition-only premise, so it renders nowhere. All three are removed by this change, which is the "separate, deliberate step" `a939e97`'s comments asked for.

### F-7 (minor) `Contract_Review__c` disposition sequence in the brief is stale.

Brief did not state it, but for the record: `CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE` is now `Initial Draft → Negotiation → Signed` (harmonised by the user 2026-08-21), **not** `Initial Draft → Revised → Ready for Execution → Executed`. This matters because it means `Negotiation` and `Signed` are shared across both PSA record types — see the record-type pin requirement in §3.3.

### F-8 ✅ Verified correct in the brief

- The mechanism: `Advance_Stage` and `Move_to_*` are byte-identical but for `<label>`; both `type=LightningWebComponent`, `lightningWebComponent=advanceRecordStage`. Confirmed.
- **No Apex changes required.** `advance()` takes only a `recordId`; the target is derived server-side from `CONFIG_BY_TYPE` keyed per record type. The LWC "names no object, imports no object's schema and holds no stage value." A new quick action pointing at the same bundle needs zero code.
- **No permission set changes required.** `Advance_Stage` appears in permission sets only inside header comments. Every field the new criteria read is already granted: `NDA__c.Status__c`, `Contract_Review__c.Negotiation_Status__c` (both already read by the existing acquisition entries), `LOI__c.Stage__c` (verified present in `DPEG_Acquisition_Edit` and `DPEG_Acquisition_View`), `LOI__c.Is_Advance_Allowed__c` (already read by the existing entry). Custom permissions carry no FLS.
- Bare `{!Record.RecordType.DeveloperName}` in a flexipage criterion **is** proven at the metadata layer (four-probe check-only control against `usman-dpeg`, 2026-08-21; probe B rejected a bogus field *behind* the RecordType hop **by name**, proving the validator traversed the relationship). It is live on all three pages today. Use it; do not mint formula checkboxes.
- All 8 stage maps in the brief match `RecordStageAdvanceService` exactly.

---

## 1. WHAT THE USER REQUESTED

Remove the generic `Advance Stage` button from all seven stage-controlled objects and replace it with per-stage quick action buttons labelled with the destination stage, following the conventions established by commit `a939e97`. Where a stage has no mapped hop, render nothing — no button and no hint text.

**Scope:** `NDA__c`, `LOI__c`, `Contract_Review__c` (acquisition record types only — the disposition side is already done), `Underwriting__c`, `Development_Feasibility_Review__c`, `Construction_Feasibility_Review__c`, `Transaction__c`.

**Out of scope:** `Disposition__c` (already converted 2026-08-19), `Opportunity` (`StageAdvanceService` is a different service with its own buttons).

---

## 2. 🔵 ADMIN WORK (declarative) — ~100% of this change

No Apex. No LWC. No permission sets. No fields. No validation rules.

| Metadata type | Count | Note |
|---|---|---|
| `QuickAction` — new | **18** | headless LWC actions, `advanceRecordStage` |
| `QuickAction` — reused (no file change) | **6** | new page entries only |
| `QuickAction` — orphaned `Advance_Stage` | **7** | see §5 — recommend retaining files in wave 1 |
| `FlexiPage` — edited | **7** | 6 acquisition/review pages + `Transaction_Record_Page` |
| `Layout` — edited | **1** | `Transaction__c-Transaction Layout` |

---

## 3. PER-OBJECT HOP → ACTION → VISIBILITY TABLE

### Conventions applied throughout (from `a939e97`, verified against the shipped files)

- **Developer name:** `Move_to_<Destination>`, Title_Case_With_Underscores.
- **Label:** the destination stage name **verbatim from the picklist**, alone. (⚠ Development Review's values are lower-cased on their second word — `Feasibility analysis`, `Vendor proposals`. Match the org exactly in **both** the label and the `rightValue`; "correcting" the casing produces a rule that never fires.)
- **File body:** exactly 5 elements — `actionSubtype=Action`, `label`, `lightningWebComponent=advanceRecordStage`, `optionsCreateFeedItem=false`, `type=LightningWebComponent`. **No `<description>`** (0 of 80 quick actions in this repo carry one; the field caps at 255 chars).
- **Comments go INSIDE `<QuickAction>`.** A comment above the root breaks `sf` at source conversion with a misleading "unable to find matching parent xml file" error.
- **Every visibility rule is a pure AND chain.** No parenthesised OR — measured unhonoured by the renderer (see F-3). Where an OR is genuinely needed, use two `valueListItems` with the same `<value>`.
- **Record-type polarity** (from `NDA_Record_Page`'s documented choice, and `LOI_Record_Page` criterion 5 / code review C2):
  - **Acquisition-side entries use `NE Disposition_<X>` (fail OPEN on Master).** A Master/blank-typed row reads blank, `blank NE 'Disposition_X'` is TRUE, so the button survives — which **matches the service**, whose `defaultTypeKey` routes a Master row to the ACQUISITION map. Using `EQUAL Acquisition_<X>` would fail CLOSED and strand every Master-typed row with no button while the server would happily have advanced it. **This is the single most important detail in this document.**
  - Disposition-side entries (already shipped) keep `EQUAL Disposition_<X>` (fail CLOSED). Do not touch them.

---

### 3.1 `NDA__c` — Acquisition (`Status__c`, gate `Acquisition_Deal_Actions`)

Map: `Pending → Received → Signed → Sent`. **`Sent` is TERMINAL.**

| Hop | Action | New / Reused | Label | Visibility criteria (all ANDed) |
|---|---|---|---|---|
| `Pending → Received` | `NDA__c.Move_to_Received` | 🆕 **NEW** | `Received` | 1 `{!$Permission.CustomPermission.Acquisition_Deal_Actions}` EQUAL `true` · 2 `{!Record.RecordType.DeveloperName}` **NE** `Disposition_NDA` · 3 `{!Record.Status__c}` EQUAL `Pending` |
| `Received → Signed` | `NDA__c.Move_to_Signed` | ♻ **REUSE** (+1 entry) | `Signed` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_NDA` · 3 `Status__c` EQUAL `Received` |
| `Signed → Sent` | `NDA__c.Move_to_Sent` | ♻ **REUSE** (+1 entry) | `Sent` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_NDA` · 3 `Status__c` EQUAL `Signed` |
| `Sent` (terminal) | — | — | — | **no button, no hint** (user decision #2) |

**Why reuse rather than mint duplicates:** the destination labels `Signed` and `Sent` are identical on both sides, and the existing files already carry the correct label. Minting `NDA__c.Move_to_Signed_Acq` would be a second file that must receive every future fix — the exact anti-pattern that killed `c/transactionAdvanceStage`.

**🔴 Collision check — this object is the sharpest of the three.** `Sent` and `Signed` are shared by both record types **in opposite directions**:
- After this change `NDA__c.Move_to_Sent` has **three** entries: disposition@`Approved`, disposition@`Not Sent`, acquisition@`Signed`. Mutually exclusive — `Status__c` holds one value, and the third additionally inverts the RT operator.
- `NDA__c.Move_to_Signed` has **two**: disposition@`Sent`, acquisition@`Received`. Disjoint on both axes.
- **Without the RT pin on the acquisition `Move_to_Sent` entry**, a disposition NDA at its terminal `Signed` would be offered a "Sent" button that moves it BACKWARDS. Without the RT pin on `Move_to_Signed`, an acquisition NDA at its terminal `Sent`… would not fire (the acquisition rule keys on `Received`), but the pin stays for symmetry and against future value drift.
- The removed acquisition entry's criterion `Status__c NE 'Declined'` is **subsumed**: an `EQUAL Pending|Received|Signed` test can never be true at `Declined`. No behaviour is lost.

**Entries removed:** 2 (`NDA__c.Advance_Stage` ×2 — the live acquisition-gated one the user saw, and the dead disposition-gated one `a939e97` left for "a separate, deliberate step").

---

### 3.2 `LOI__c` — Acquisition (`Stage__c`, gate `Acquisition_Deal_Actions`)

Map: `Draft → Under Review → Submitted → Negotiation → Signed`. Branches at `Submitted`.

| Hop | Action | New / Reused | Label | Visibility criteria (all ANDed) |
|---|---|---|---|---|
| `Draft → Under Review` | `LOI__c.Move_to_Under_Review` | ♻ **REUSE** (+1 entry) | `Under Review` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_LOI` · 3 `{!Record.Stage__c}` EQUAL `Draft` · 4 `{!Record.Is_Advance_Allowed__c}` EQUAL `true` |
| `Under Review → Submitted` | `LOI__c.Move_to_Submitted` | 🆕 **NEW** | `Submitted` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_LOI` · 3 `Stage__c` EQUAL `Under Review` · 4 `Is_Advance_Allowed__c` EQUAL `true` |
| `Submitted → Negotiation` | `LOI__c.Mark_Countered` | ✅ **ALREADY EXISTS — DO NOTHING** | `Negotiation` | untouched (`Acq perm` + `Stage__c EQUAL Submitted`) |
| `Submitted → Signed` (branch) | `LOI__c.Mark_Completed` | ✅ **ALREADY EXISTS — DO NOTHING** | `Signed` | untouched |
| `Negotiation → Signed` | `LOI__c.Move_to_Signed` | ♻ **REUSE** (+1 entry) | `Signed` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_LOI` · 3 `Stage__c` EQUAL `Negotiation` · 4 `Is_Advance_Allowed__c` EQUAL `true` |
| `Signed` (terminal) | — | — | — | **no button** |

**🔴 `Is_Advance_Allowed__c` is criterion 4 on all three new entries and is NOT redundant padding.** Its formula is:

```
AND(Stage <> Signed, Stage <> Executed, Stage <> Submitted,
    OR(RecordType <> Acquisition_LOI, Stage <> "Under Review", LOI_Status = Approved),
    TEXT(LOI_Status__c) <> "Pending Approval")
```

The `Stage__c EQUAL <x>` test subsumes the first three clauses, but **not** the last two. On an acquisition LOI at `Under Review` the fourth clause reduces to `LOI_Status__c = Approved` — i.e. **the LOI approval gate**. Drop `Is_Advance_Allowed__c` from the `Move_to_Submitted` entry and a deal driver can walk an LOI past `Under Review` while its approval is still pending or was rejected. Today's `Advance_Stage` entry enforces this; the replacement must too.

It **cannot** be written as a direct criterion on `LOI_Status__c`: a visibility rule reading a field the running user cannot read evaluates FALSE. A formula field is evaluated server-side and carries no such dependency. (Same D22/C1 failure mode this page already documents.)

**Collision check:** `Under Review`, `Negotiation` and `Signed` are all shared with `Disposition_LOI`. `Move_to_Under_Review` becomes disposition@`Received` + acquisition@`Draft` (disjoint on stage AND on RT operator). `Move_to_Signed` becomes disposition@`Negotiation` + acquisition@`Negotiation` — **same stage value**, separated **only** by the inverted RT operator (`EQUAL Disposition_LOI` vs `NE Disposition_LOI`). These are provably mutually exclusive, but this is the one place in the whole change where the RT criterion is doing 100% of the work. Call it out in the file comment.

**Entries removed:** 2 (`LOI__c.Advance_Stage` ×2). **`Submit_for_Approval`, `Mark_Countered` and `Mark_Completed` are NOT touched.**

---

### 3.3 `Contract_Review__c` — Acquisition (`Negotiation_Status__c`, gate `Acquisition_Deal_Actions`)

Map: `Draft → Negotiation → Signed → Executed`. Disposition map (already served): `Initial Draft → Negotiation → Signed`, `Signed` TERMINAL.

| Hop | Action | New / Reused | Label | Visibility criteria (all ANDed) |
|---|---|---|---|---|
| `Draft → Negotiation` | `Contract_Review__c.Move_to_Negotiation` | ♻ **REUSE** (+1 entry) | `Negotiation` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_PSA` · 3 `{!Record.Negotiation_Status__c}` EQUAL `Draft` |
| `Negotiation → Signed` | `Contract_Review__c.Move_to_Signed` | ♻ **REUSE** (+1 entry) | `Signed` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_PSA` · 3 `Negotiation_Status__c` EQUAL `Negotiation` |
| `Signed → Executed` | `Contract_Review__c.Move_to_Executed` | 🆕 **NEW** | `Executed` | 1 Acq perm EQUAL true · 2 RT **NE** `Disposition_PSA` · 3 `Negotiation_Status__c` EQUAL `Signed` |
| `Executed` (terminal) | — | — | — | **no button** |

**🔴 The RT pin on `Move_to_Executed` is the highest-consequence single criterion in this change.** `Signed` is **mid-sequence on acquisition and TERMINAL on disposition**. A stage-only rule would render "Executed" on a completed sell-side PSA. And because `Negotiation_Status__c` is a **restricted** picklist whose record-type subset **is** enforced by Apex DML (measured 2026-08-21, `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`), and `Executed` is **not on the `Disposition_PSA` record type**, the click would fail with an opaque platform error rather than the service's user-safe message.

`Move_to_Signed` becomes disposition@`Negotiation` + acquisition@`Negotiation` — the same same-stage/inverted-operator shape as LOI. Same call-out applies.

**Entries removed:** 2 (`Contract_Review__c.Advance_Stage` ×2).

---

### 3.4 `Underwriting__c` (`Stage__c`, gate `Acquisition_Deal_Actions`, no record types)

Map: `Requested → In Progress`, **[approval]**, `Approved → Completed`.

| Hop | Action | New / Reused | Label | Visibility criteria (all ANDed) |
|---|---|---|---|---|
| `Requested → In Progress` | `Underwriting__c.Move_to_In_Progress` | 🆕 **NEW** | `In Progress` | 1 Acq perm EQUAL true · 2 `{!Record.Stage__c}` EQUAL `Requested` |
| `In Progress → Approved` | — | — | — | **NO BUTTON.** Owned by the principal approval process. `Underwriting__c.Submit_for_Approval` already renders at exactly this stage and is untouched. Adding a button here would put a principal-approved underwriting one click away from a deal driver. |
| `Approved → Completed` | `Underwriting__c.Move_to_Completed` | 🆕 **NEW** | `Completed` | 1 Acq perm EQUAL true · 2 `Stage__c` EQUAL `Approved` |
| `Completed` (terminal) | — | — | — | **no button** |

**No record-type criterion** — this object has none.

**🔴 This split silently repairs F-3.** The removed entry's `1 AND (2 OR 3)` is not honoured by the renderer, so the current button likely appears at `In Progress` and `Completed` too. The two replacement entries are pure AND chains keyed on exact stages, so the fix is structural. **Do not attempt to "preserve current behaviour" here.**

**Entries removed:** 1.

---

### 3.5 `Development_Feasibility_Review__c` (`Stage__c`, gate `Acquisition_Deal_Actions`, no record types)

Map: `Requested → Feasibility analysis → Vendor proposals → Share Opinion → Completed`.

| Hop | Action (all 🆕 NEW) | Label (**verbatim**) | Criteria (all ANDed) |
|---|---|---|---|
| `Requested → Feasibility analysis` | `Development_Feasibility_Review__c.Move_to_Feasibility_Analysis` | `Feasibility analysis` | 1 Acq perm EQUAL true · 2 `Stage__c` EQUAL `Requested` |
| `Feasibility analysis → Vendor proposals` | `Development_Feasibility_Review__c.Move_to_Vendor_Proposals` | `Vendor proposals` | 1 Acq perm · 2 `Stage__c` EQUAL `Feasibility analysis` |
| `Vendor proposals → Share Opinion` | `Development_Feasibility_Review__c.Move_to_Share_Opinion` | `Share Opinion` | 1 Acq perm · 2 `Stage__c` EQUAL `Vendor proposals` |
| `Share Opinion → Completed` | `Development_Feasibility_Review__c.Move_to_Completed` | `Completed` | 1 Acq perm · 2 `Stage__c` EQUAL `Share Opinion` |
| `Completed` (terminal) | — | — | **no button** |

⚠ **`Feasibility analysis` and `Vendor proposals` are lower-cased on their second word in the picklist metadata.** The `<label>` and the `<rightValue>` must both match the org exactly. The **developer name** is Title_Case per repo convention (`Move_to_Feasibility_Analysis`) — this deliberate divergence between developer name and label should be noted in the file comment so nobody "fixes" the label.

Removes the `NE Completed` catch-all — the terminal correctly gets nothing. **Entries removed:** 1.

---

### 3.6 `Construction_Feasibility_Review__c` (`Stage__c`, gate `Acquisition_Deal_Actions`, no record types)

Map: `Requested → Site Visit → Condition Assessment → Cost Estimate → Share Opinion → Completed`.

| Hop | Action (all 🆕 NEW) | Label | Criteria (all ANDed) |
|---|---|---|---|
| `Requested → Site Visit` | `Construction_Feasibility_Review__c.Move_to_Site_Visit` | `Site Visit` | 1 Acq perm EQUAL true · 2 `Stage__c` EQUAL `Requested` |
| `Site Visit → Condition Assessment` | `Construction_Feasibility_Review__c.Move_to_Condition_Assessment` | `Condition Assessment` | 1 Acq perm · 2 `Stage__c` EQUAL `Site Visit` |
| `Condition Assessment → Cost Estimate` | `Construction_Feasibility_Review__c.Move_to_Cost_Estimate` | `Cost Estimate` | 1 Acq perm · 2 `Stage__c` EQUAL `Condition Assessment` |
| `Cost Estimate → Share Opinion` | `Construction_Feasibility_Review__c.Move_to_Share_Opinion` | `Share Opinion` | 1 Acq perm · 2 `Stage__c` EQUAL `Cost Estimate` |
| `Share Opinion → Completed` | `Construction_Feasibility_Review__c.Move_to_Completed` | `Completed` | 1 Acq perm · 2 `Stage__c` EQUAL `Share Opinion` |
| `Completed` (terminal) | — | — | **no button** |

⚠ `Move_to_Share_Opinion` and `Move_to_Completed` exist on **both** feasibility objects. Quick actions are object-scoped, so these are **separate files** with identical bodies — that is correct and unavoidable, not duplication to eliminate.

**Entries removed:** 1.

---

### 3.7 `Transaction__c` (`Stage__c`, gate `Transaction_Stage_Actions`, no record types) — **SEPARATE WORK ITEM, SEE §4**

Map: `Open Contract → Due Diligence → Closing Prep → Post-Closing → Closed Won`.

| Hop | Action (all 🆕 NEW) | Label | Criteria (all ANDed) |
|---|---|---|---|
| `Open Contract → Due Diligence` | `Transaction__c.Move_to_Due_Diligence` | `Due Diligence` | 1 `{!$Permission.CustomPermission.Transaction_Stage_Actions}` EQUAL `true` · 2 `Stage__c` EQUAL `Open Contract` |
| `Due Diligence → Closing Prep` | `Transaction__c.Move_to_Closing_Prep` | `Closing Prep` | 1 Txn perm · 2 `Stage__c` EQUAL `Due Diligence` |
| `Closing Prep → Post-Closing` | `Transaction__c.Move_to_Post_Closing` | `Post-Closing` | 1 Txn perm · 2 `Stage__c` EQUAL `Closing Prep` |
| `Post-Closing → Closed Won` | `Transaction__c.Move_to_Closed_Won` | `Closed Won` | 1 Txn perm · 2 `Stage__c` EQUAL `Post-Closing` |
| `Closed Won` (terminal) | — | — | **no button** |

⚠ The gate is `Transaction_Stage_Actions`, **not** `Acquisition_Deal_Actions`. It is a LAYER-4 team-wide capability set (`Transaction_Stage_Actions_Access`, a member of `DPEG_Transaction_Team`), deliberately different in kind from the other two. Do not harmonise.
⚠ Label `Post-Closing` carries a **hyphen**; developer name is `Move_to_Post_Closing`.
⚠ **These criteria are new — the layout mechanism has none today.** Every Transaction user with the layout currently sees the button regardless of permission (the server refuses). This change tightens that, which is a real behavioural narrowing and is correct.

---

## 4. 🔴 WORK ITEM WI-7 — `Transaction__c`, the one item that is not mechanical

**Deploy this separately, AFTER §3.1–3.6 have been deployed and read back green.** It is the only item in the change that touches Dynamic Actions enablement, and it has a live incident precedent.

### The problem
`Transaction_Record_Page` has `enableActionsConfiguration = false`. Its highlights panel therefore inherits the action bar from `Transaction__c-Transaction Layout`'s `<platformActionList>`, which has **no visibility-rule mechanism**. Per-stage buttons are impossible without Dynamic Actions.

### The required change (three parts, one deploy)
1. **`Transaction_Record_Page`**: set `enableActionsConfiguration` → `true` and add an `actionNames` `valueList`.
2. **That `valueList` must carry the ENTIRE action bar, not just the four new buttons.** Turning Dynamic Actions on **discards every inherited action**. The current inherited set, taken from the layout, is:
   `Edit`, `Clone`, `Delete`, `LogACall`, `NewEvent`, `NewTask` — **plus** the four `Move_to_*` actions with their visibility rules, in place of `Advance_Stage`. Ten `valueListItems`. The six standard/global actions carry **no** `visibilityRule`.
3. **`Transaction__c-Transaction Layout`**: remove the `Transaction__c.Advance_Stage` `platformActionListItem` and **re-sequence `sortOrder`** on the survivors (`Edit 0, Clone 1, Delete 2, LogACall 3, NewEvent 4, NewTask 5`).

### 🔴 Why part 3 is mandatory and not cosmetic
`Transaction_Record_Page` is assigned **only** by `applications/Transaction.app-meta.xml`'s `actionOverride`. Record pages are assigned **per-app**. A Transaction record opened from any other app (e.g. via an Opportunity related list in the Acquisitions app) falls back to the object default, which is layout-driven — where `Advance Stage` would still be visible. Leaving it on the layout defeats decision #1.

### 🔴 The precedent, including its failure
`Disposition_Record_Page` did exactly this on 2026-08-19. It then produced a live incident: App Builder **silently dropped `Edit`, `Clone` and `Delete`** from the `actionNames` list — the org sat at nine `valueListItems` where the repo carried twelve — so every Disposition record had **no Edit, Clone or Delete button** until it was found and fixed. That page's header documents it. Read it before doing this.

**⇒ MANDATORY pre-step for WI-7:** query the org's **current** `Transaction_Record_Page` action bar via the Tooling API and diff it against the repo file **before** writing the new list, and read it back **after** deploy. "Deployed successfully" is not proof — a FlexiPage deploy has been observed here to report success on a rolled-back deploy.

### RESIDUAL-1 (accepted, must be stated to the user)
After WI-7, a Transaction opened **outside** the Transaction app renders the layout-driven default page and will have **no stage-advance button at all** (today it has the generic one). Users must open Transactions from the Transaction app to advance them. Closing this properly means either assigning `Transaction_Record_Page` in the other apps' `actionOverrides` or accepting the narrowing. **Not in scope; flagged, not decided.**

---

## 5. THE 7 ORPHANED `Advance_Stage` QUICK ACTION FILES

`NDA__c`, `LOI__c`, `Contract_Review__c`, `Underwriting__c`, `Development_Feasibility_Review__c`, `Construction_Feasibility_Review__c`, `Transaction__c` — all `.Advance_Stage.quickAction-meta.xml`.

**RECOMMENDATION: retain all 7 files through wave 1; delete them in a separate wave 2 after readback confirms every page renders correctly.**

Reasoning:
- With Dynamic Actions ON and no `valueListItem` referencing them, they render **nowhere**. Decision #1 ("not visible anywhere") is satisfied by removing the page/layout references alone.
- Deleting metadata is a **destructive change** (`destructiveChanges.xml`), which is a different and riskier deploy shape than the additive/edit shape of everything else here.
- Keeping them for one wave preserves a one-line rollback: re-add a `valueListItem` and the old button is back. Once deleted, rollback requires recreating files.
- ⚠ They remain visible **in the Setup action picker**, so an admin could re-add one by hand. If the user considers that "visible", it argues for deleting in wave 1 — a judgement call, flagged as **OQ-3** below.
- ⚠ `ContractExecutionServiceTest` and several class/page/permission-set **comments** reference "Advance Stage" by name. None is a metadata dependency; all become documentation staleness. **RESIDUAL-2.**

---

## 6. EXECUTION ORDER

| Wave | Contents | Why this order |
|---|---|---|
| **W1a** | Create the **18 new `QuickAction` files** | A `FlexiPage` `valueListItem` referencing a non-existent quick action fails the deploy. Actions must exist first. Deployable on their own — an unreferenced quick action renders nowhere, so W1a is a **no-op in the UI** and safe to land alone. |
| **W1b** | Edit the **6 flexipages** (`NDA`, `LOI`, `Contract_Review`, `Underwriting`, `Development_Feasibility_Review`, `Construction_Feasibility_Review`) — remove 9 `Advance_Stage` entries, add 20 `Move_to_*` entries | The visible change. **GATE FP-1 applies to every one of these six files.** |
| **W1c** | **Readback + human UI verification** of all six pages (§7) | Must complete before W2 begins. |
| **W2** | **WI-7**: `Transaction_Record_Page` Dynamic Actions + `Transaction__c-Transaction Layout` | Isolated so that if the action bar empties, the blast radius is one object and the cause is unambiguous. |
| **W3** *(optional, user decision)* | Delete the 7 orphaned `Advance_Stage` quick actions (destructive) | Only after W1c + W2 readback are green. |
| **W4** *(optional, user decision)* | Retire the `Underwriting\|In Progress` hint from `RecordStageAdvanceService` + its test | The **only** Apex in this whole change. Recommend **not** doing it. |

---

## 7. POST-DEPLOY VERIFICATION CHECKLIST

### 7.1 Metadata readback (automated — do this immediately after each deploy)

- [ ] Retrieve every touched FlexiPage and **diff against the file just deployed**. Confirm the `actionNames` `valueList` item **count** matches exactly. This is the check that caught the `Disposition_Record_Page` incident.
- [ ] Confirm `enableActionsConfiguration` is still `true` on all six W1b pages, and is `true` on `Transaction_Record_Page` after W2.
- [ ] Confirm **zero** `Advance_Stage` references remain: `rg "Advance_Stage" force-app/main/default/flexipages force-app/main/default/layouts` returns nothing.
- [ ] Confirm no `booleanFilter` in any touched page contains a parenthesis.
- [ ] Confirm the 6 reused actions (`NDA.Move_to_Signed`, `NDA.Move_to_Sent`, `LOI.Move_to_Under_Review`, `LOI.Move_to_Signed`, `CR.Move_to_Negotiation`, `CR.Move_to_Signed`) have **unchanged file bodies** — only page entries were added.
- [ ] Confirm `Transaction__c-Transaction Layout` `sortOrder` values are contiguous 0–5.

### 7.2 🔴 Renderer verification (human, in the UI — NOT provable from a repo)

Metadata validation exercises the metadata layer only. This repo has measured constructs that deploy, survive a retrieve, and are then ignored by the renderer. **Checking only the positive direction makes an ignored rule look identical to a working one.**

**As an acquisition deal driver (holds `Acquisition_Deal_Actions`):**
- [ ] NDA at `Pending` → exactly **`Received`**, and **no `Advance Stage`**
- [ ] NDA at `Received` → exactly **`Signed`**
- [ ] NDA at `Signed` → exactly **`Sent`**
- [ ] NDA at `Sent` (terminal) → **no stage button at all**
- [ ] LOI at `Draft` → **`Under Review`**
- [ ] LOI at `Under Review`, `LOI_Status__c = Approved` → **`Submitted`**
- [ ] 🔴 LOI at `Under Review`, `LOI_Status__c = Pending Approval` → **NO `Submitted` button** (the approval gate — this is the highest-value negative test in the set)
- [ ] LOI at `Submitted` → **`Negotiation`** and **`Signed`** (the two pre-existing branch buttons, unchanged)
- [ ] LOI at `Negotiation` → **`Signed`**
- [ ] LOI at `Signed` (terminal) → nothing
- [ ] Contract Review at `Draft` → **`Negotiation`**; at `Negotiation` → **`Signed`**; at `Signed` → **`Executed`**; at `Executed` → nothing
- [ ] Underwriting at `Requested` → **`In Progress`**
- [ ] 🔴 Underwriting at `In Progress` → **`Submit for Approval` ONLY**, no stage button, no hint text (this is the F-3 fix; today the OR is ignored and a button probably appears)
- [ ] Underwriting at `Approved` → **`Completed`**; at `Completed` → nothing
- [ ] Development Review at each of `Requested` / `Feasibility analysis` / `Vendor proposals` / `Share Opinion` → exactly one correctly-named button; at `Completed` → nothing
- [ ] Construction Review at each of its five source stages → exactly one correctly-named button; at `Completed` → nothing

**🔴 Negative direction — as a DISPOSITION driver (holds `Disposition_Deal_Actions`, NOT `Acquisition_Deal_Actions`):**
- [ ] Disposition NDA at `Prepare` / `Approved` / `Sent` → its three existing buttons, **unchanged**
- [ ] 🔴 Disposition NDA at `Signed` (terminal) → **NO `Sent` button** (would be a backwards move — proves the acquisition `Move_to_Sent` RT pin fires)
- [ ] Disposition LOI at `Received` / `Under Review` / `Negotiation` → unchanged
- [ ] 🔴 Disposition PSA at `Signed` (terminal) → **NO `Executed` button** (proves the `Move_to_Executed` RT pin; `Executed` is not even on that record type)
- [ ] 🔴 Disposition PSA at `Negotiation` → exactly ONE `Signed` button, not two (proves the same-stage/inverted-operator pair on `CR.Move_to_Signed` is mutually exclusive)
- [ ] 🔴 Disposition LOI at `Negotiation` → exactly ONE `Signed` button, not two (same check on `LOI.Move_to_Signed`)

**Master-typed rows (fail-open direction — the check nobody remembers):**
- [ ] A Master-typed NDA / LOI / Contract Review renders the **acquisition** buttons. Live counts on 2026-08-21 were 12 LOI rows with **0** Master-typed, so a fixture may be needed. If a fixture cannot be made, record it as unverified rather than assumed.

**Permission negative:**
- [ ] A System Administrator holding **neither** custom permission sees **no** stage buttons on any of these objects (this is how `Acquisition_Deal_Actions` was verified in 2026-08-12 Phase 2 Step 1).

**Transaction (after W2):**
- [ ] Transaction record in the **Transaction app** → `Edit`, `Clone`, `Delete`, `Log a Call`, `New Event`, `New Task` **all still present** — 🔴 this is the `Disposition_Record_Page` incident check
- [ ] Transaction at each of `Open Contract` / `Due Diligence` / `Closing Prep` / `Post-Closing` → exactly one correctly-named button; at `Closed Won` → none
- [ ] A user **without** `Transaction_Stage_Actions` → no stage button (new tightening)
- [ ] Transaction opened from **outside** the Transaction app → confirm and record RESIDUAL-1 behaviour

**Functional (one end-to-end):**
- [ ] Click one named button and confirm the record actually advances **to the stage on the label**, the Path re-renders without a reload (`getRecordNotifyChange`), and the success toast appears.

---

## 8. ACCEPTED RESIDUALS

| # | Residual | Detail |
|---|---|---|
| **RESIDUAL-1** | Transaction stage buttons exist only inside the Transaction app | See §4. Today's generic button has the same per-app assignment constraint for the *page*, but the *layout* fallback currently supplies the button everywhere. This change removes that fallback. |
| **RESIDUAL-2** | ~12 code/metadata **comments** naming "Advance Stage" go stale | `ContractExecutionServiceTest`, `PsaVersionService`, `lwc/psaVersionLog`, `lwc/loiMarkCompleted`, `Acquisition_Deal_Driver`, `DPEG_Disposition_Edit`, `Disposition_Record_Page`, `LOI__c.Is_Advance_Allowed__c`, the three record-type files. **None is a metadata dependency.** Not worth a sweep in this change; note it. |
| **RESIDUAL-3** | 🔴 **The confirmation dialog still says "Advance Stage"** | `lwc/advanceRecordStage/advanceRecordStage.js` hardcodes `CONFIRM = { message: 'Advance this record to the next stage?', label: 'Advance Stage' }`, deliberately generic because one bundle serves all seven objects and the client cannot know the target. **After this change, that dialog is the ONLY place the exact string the user objected to still appears.** It is pre-existing (unchanged since `a939e97` shipped the disposition side), so it is not a regression — but the user's complaint was about seeing those words. See **OQ-1**. |
| **RESIDUAL-4** | The `Underwriting\|In Progress` hint becomes dead code | See F-1. Recommend leaving it. The user reaches the right control anyway: `Submit_for_Approval` already renders at exactly that stage. |
| **RESIDUAL-5** | `NDA__c.Move_to_Sent`'s legacy `Not Sent` entry stays | Defensive parity with the service map; `Not Sent` is on no record type and zero rows carry it. Untouched by this change. Retire it only when the map entry goes. |

---

## 9. OPEN QUESTIONS

| # | Question | BLOCKING? | Recommendation |
|---|---|---|---|
| **OQ-1** | The confirm dialog still reads **"Advance Stage"** (RESIDUAL-3). Change `CONFIRM.label` to something neutral (`Confirm`) or leave it? | ⚠ **NOT blocking for W1** — but answer before the user re-tests, because they will see this string and may report the change as incomplete. | Change `label` to `'Confirm'` and leave `message` generic. This is a **🟢 salesforce-developer** item: 2-line LWC edit + the matching assertion in `lwc/advanceRecordStage/__tests__/advanceRecordStage.test.js` (lines 168–169). It is the **only** non-declarative work in scope and was **not** explicitly requested — do not do it without a yes. |
| **OQ-2** | `LOI__c` hop `Submitted → Negotiation`: confirm that `Mark_Countered` / `Mark_Completed` are accepted as satisfying that hop (F-2). | 🔴 **BLOCKING** — it decides whether LOI gets 3 or 4 buttons. | Accept. They already carry the right labels and the right explicit-target semantics. Adding a fourth would double-render `Negotiation`. |
| **OQ-3** | Delete the 7 orphaned `Advance_Stage` quick actions in wave 1, or defer to wave 3? | ⚠ Not blocking for W1a/W1b. | Defer to W3. Keeps a one-line rollback through the risky wave. Delete in W3 if the Setup action picker counts as "visible". |
| **OQ-4** | WI-7 narrows Transaction stage-advance to holders of `Transaction_Stage_Actions` (today the layout gives it to everyone who can see the layout). Accepted? | 🔴 **BLOCKING for W2 only** | Accept — it aligns Transaction with the other six objects and the server already refuses ungated clicks. But it is a real change to who sees a button, so confirm. |
| **OQ-5** | RESIDUAL-1: leave Transactions button-less outside the Transaction app, or extend `actionOverrides`? | ⚠ Not blocking. | Leave; flag to the user. Extending `actionOverrides` touches other apps' files, which the parallel-build hub-file protocol says not to do inside another stream's change. |

**Do not dispatch W1b until OQ-2 is answered. Do not dispatch W2 until OQ-4 is answered.**

---

## 10. 🔴 DEPLOY GATES

### GATE FP-1 — FlexiPage deploy replaces the org copy; there is NO version history
Applies to all **seven** pages. Hand-edits made in App Builder have been **lost** in this repo (2026-08-25, two tabs). `Lead_Record_Page` and `Opportunity_Record_Page` were both found drifted from the repo **today**.

For each page, in this order, **seconds before** the deploy — not at plan time:
1. `sf project retrieve start` that page into a scratch location.
2. **Diff the retrieved copy against `HEAD`.** Any delta is a user App Builder edit that this deploy will destroy.
3. If a delta exists → **STOP**, surface it, and rebase the edit onto the retrieved copy rather than the repo copy.
4. Check `SetupAuditTrail` for FlexiPage saves newer than the retrieve.
5. Deploy, then **retrieve again and diff** to prove the change landed. `numberComponentsDeployed` is a **pre-rollback** tally — "689/689, 0 errors" has been observed on a deploy that rolled everything back.

### GATE DA-1 — Dynamic Actions (WI-7 only)
Enabling `enableActionsConfiguration` **discards the entire inherited action bar**. The new `actionNames` list must enumerate `Edit`, `Clone`, `Delete`, `LogACall`, `NewEvent`, `NewTask` **plus** the four `Move_to_*` actions. App Builder has been observed to **silently drop** standard buttons from this list. Query the org's list via the Tooling API before AND after. See §4.

### GATE CT-1 — concurrent sessions share this working tree
Measured 2026-08-16: a second session built a whole feature into this tree mid-run, and shared hub files silently became a union of two features. Before deploying, **diff every touched file against `HEAD`** and confirm nothing unrelated has appeared. Commit retrieves on their own.

### GATE SK-1 — skill/MCP gate (`.claude/rules/salesforce-global-rule.md`)
🔴 **There is NO `sf-quick-action` skill and NO `sf-layout` skill in `.claude/skills/`.** The rule says: *"If no matching skill exists, stop and ask for guidance instead of writing without a skill."*

- `FlexiPage` → **`sf-flexipage`** ✅ exists, load it.
- `QuickAction` → nearest is **`sf-metadata`** (generic). The implementing agent must record `best_matched_skill=sf-metadata` and note the gap, **or** stop and ask. The 6 existing `Move_to_*` files are the de-facto template and should be treated as the authority for file shape.
- `Layout` → same gap; `sf-metadata` fallback.
- `.mcp.json` carries only the `salesforce` server and subagents have **no MCP tools**, so `salesforce-api-context` is unavailable. Record `mcp=unavailable` / `mcp_tools=none` **after a real attempt** and fall back to the skill.
- Per-type order: `QuickAction` → `FlexiPage` → `Layout`. Complete the full a–e loop per type.

### GATE RT-1 — restricted picklists
`LOI__c.Stage__c` and `Contract_Review__c.Negotiation_Status__c` are **restricted** value sets whose **record-type subset is enforced by Apex DML** (measured 2026-08-21). This change adds no picklist values, so RT-1 is satisfied by inspection — but it is the reason the record-type pins in §3.2/§3.3 are correctness requirements and not stylistic preference.

---

## 11. COMPLEXITY ROUTING

| Work item | Tier | Reason |
|---|---|---|
| W1a — 18 quick action files | 🔵 **salesforce-admin** | Mechanical; 6 shipped exemplars exist; no architectural decision embedded. |
| W1b — 6 flexipage edits | 🔵 **salesforce-admin** | The record-type/polarity decisions are **taken in this document**; the admin executes them. Clean seam. |
| W2 (WI-7) — Transaction page + layout | 🔵 **salesforce-admin**, but as a **separate dispatch with GATE DA-1 quoted in full** | It is one page and the recipe is known, including its failure mode. Escalate to 🟤 **salesforce-solution-architect** only if the user wants RESIDUAL-1 closed in the same change — that means editing other apps' `actionOverrides`, which crosses module boundaries. |
| W3 — destructive delete of 7 quick actions | 🔵 **salesforce-admin** + 🔴 **salesforce-devops** for the destructive manifest | Separate wave. |
| W4 / OQ-1 — Apex hint retirement, LWC confirm label | 🟢 **salesforce-developer** | Only if the user says yes. Neither was requested. |
| Deploy | 🔴 **salesforce-devops** | Four separate deploys, gated as above. |
| Code review | 🟣 **salesforce-code-review** | Declarative-only, but the record-type polarity and the same-stage/inverted-operator pairs are exactly what a review should re-derive independently. |

---

## 12. PROMPTS FOR SPECIALIST AGENTS

> **DO NOT DISPATCH until OQ-2 is answered (blocks W1b) and OQ-4 is answered (blocks W2).**

### 🔵 PROMPT FOR `salesforce-admin` — W1a (quick actions)

```
Create 18 new QuickAction metadata files in force-app/main/default/quickActions/.
Do NOT deploy. Do NOT modify any flexipage or layout in this task.

Read these FIRST as the authoritative template — they were shipped 2026-08-26 by commit
a939e97 and every new file must match their shape byte-for-byte apart from the label and
the comment:
  quickActions/NDA__c.Move_to_Approved.quickAction-meta.xml
  quickActions/NDA__c.Move_to_Sent.quickAction-meta.xml
  quickActions/LOI__c.Move_to_Under_Review.quickAction-meta.xml

FILE SHAPE (exactly 5 elements, no <description> — the field caps at 255 chars and 0 of 80
quick actions in this repo carry one):
  <actionSubtype>Action</actionSubtype>
  <label>...</label>
  <lightningWebComponent>advanceRecordStage</lightningWebComponent>
  <optionsCreateFeedItem>false</optionsCreateFeedItem>
  <type>LightningWebComponent</type>

🔴 Any explanatory comment MUST sit INSIDE the <QuickAction> root element. A comment placed
above the root breaks `sf` at source conversion with a misleading "unable to find matching
parent xml file" error.

LABEL CONVENTION: the destination stage name alone, verbatim from the picklist.
DEVELOPER NAME CONVENTION: Move_to_<Destination>, Title_Case_With_Underscores.

CREATE THESE 18 (developer name → label):
  NDA__c.Move_to_Received                                    → "Received"
  LOI__c.Move_to_Submitted                                   → "Submitted"
  Contract_Review__c.Move_to_Executed                        → "Executed"
  Underwriting__c.Move_to_In_Progress                        → "In Progress"
  Underwriting__c.Move_to_Completed                          → "Completed"
  Development_Feasibility_Review__c.Move_to_Feasibility_Analysis → "Feasibility analysis"
  Development_Feasibility_Review__c.Move_to_Vendor_Proposals  → "Vendor proposals"
  Development_Feasibility_Review__c.Move_to_Share_Opinion     → "Share Opinion"
  Development_Feasibility_Review__c.Move_to_Completed         → "Completed"
  Construction_Feasibility_Review__c.Move_to_Site_Visit       → "Site Visit"
  Construction_Feasibility_Review__c.Move_to_Condition_Assessment → "Condition Assessment"
  Construction_Feasibility_Review__c.Move_to_Cost_Estimate    → "Cost Estimate"
  Construction_Feasibility_Review__c.Move_to_Share_Opinion    → "Share Opinion"
  Construction_Feasibility_Review__c.Move_to_Completed        → "Completed"
  Transaction__c.Move_to_Due_Diligence                        → "Due Diligence"
  Transaction__c.Move_to_Closing_Prep                         → "Closing Prep"
  Transaction__c.Move_to_Post_Closing                         → "Post-Closing"
  Transaction__c.Move_to_Closed_Won                           → "Closed Won"

⚠ "Feasibility analysis" and "Vendor proposals" are LOWER-CASED on their second word in the
picklist metadata. Match the org exactly in the <label>. The developer name stays Title_Case
(Move_to_Feasibility_Analysis) — note that deliberate divergence in the file comment so
nobody "corrects" the label later.
⚠ "Post-Closing" carries a hyphen in the label; the developer name uses an underscore.
⚠ Move_to_Share_Opinion and Move_to_Completed exist on BOTH feasibility objects. Quick
actions are object-scoped, so these are separate files with identical bodies. That is
correct — do not try to share them.

DO NOT create Move_to_Signed / Move_to_Sent / Move_to_Under_Review / Move_to_Negotiation on
NDA__c, LOI__c or Contract_Review__c — six such files already exist and are REUSED. Do not
edit them either.

Each file's comment should record: the hop it serves, the map in
RecordStageAdvanceService that defines it, and the fact that the label is a promise the
page's visibility rule keeps (the LWC derives the target server-side; advance() takes only a
recordId, so a mislabelled button is the worst failure mode, never a bad write).

GATE SK-1: there is NO sf-quick-action skill in .claude/skills/. Load `sf-metadata` as the
fallback and record best_matched_skill=sf-metadata. There is no salesforce-api-context MCP
server configured — record mcp=unavailable / mcp_tools=none after a real attempt.
```

### 🔵 PROMPT FOR `salesforce-admin` — W1b (six flexipages)

```
Edit six FlexiPages. Do NOT deploy. Do NOT touch Transaction_Record_Page or any layout in
this task. Do NOT touch Disposition_Record_Page.

Load the `sf-flexipage` skill. Record mcp=unavailable / mcp_tools=none after a real attempt
(no salesforce-api-context MCP server is configured).

🔴 READ FIRST: the header comments of NDA_Record_Page and LOI_Record_Page. They document
every constraint below, in the words of the change that established them.

REMOVE (9 valueListItems total):
  NDA_Record_Page:                              both NDA__c.Advance_Stage entries
  LOI_Record_Page:                              both LOI__c.Advance_Stage entries
  Contract_Review_Record_Page:                  both Contract_Review__c.Advance_Stage entries
  Underwriting_Record_Page:                     the Underwriting__c.Advance_Stage entry
  Development_Feasibility_Review_Record_Page:   the ..._Advance_Stage entry
  Construction_Feasibility_Review_Record_Page:  the ..._Advance_Stage entry
On each of NDA / LOI / Contract Review, one of the two is the live acquisition-gated entry
and the other is the self-contradictory disposition-gated entry that a939e97 explicitly left
for "a separate, deliberate step". This is that step. Remove both.

ADD (20 valueListItems). Full hop → action → criteria table is in
agent-output/design-requirements.md §3.1–§3.6. Reproduce it exactly.

🔴 NON-NEGOTIABLE CONSTRAINTS

1. DO NOT TOUCH enableActionsConfiguration. It is already `true` on all six. Toggling it
   silently EMPTIES the page's entire action bar — it has cost three pages their buttons in
   this repo.

2. EVERY visibility rule is a PURE AND CHAIN. No parentheses anywhere. This repo has MEASURED
   that a parenthesised OR deploys, survives a retrieve, and is then IGNORED BY THE RENDERER.
   ⚠ Underwriting_Record_Page's existing entry uses `1 AND (2 OR 3)`. Its replacement is TWO
   separate pure-AND entries. Do NOT preserve the OR "to keep behaviour identical" — the OR
   is not honoured today, so the current behaviour is itself a latent defect and splitting it
   fixes it. Say so in the page comment.

3. RECORD-TYPE POLARITY — the single most important detail. On NDA__c, LOI__c and
   Contract_Review__c, EVERY new acquisition entry carries
     {!Record.RecordType.DeveloperName}  NE  Disposition_<X>
   NE, not EQUAL. NE fails OPEN on a Master/blank-typed row (blank NE 'Disposition_X' is
   TRUE), which MATCHES RecordStageAdvanceService — its defaultTypeKey routes a Master row to
   the ACQUISITION map. EQUAL Acquisition_<X> would fail CLOSED and strand every Master-typed
   row with no button while the server would happily have advanced it. This is the polarity
   code review forced on LOI_Record_Page criterion 5 (finding C2, 2026-08-21).
   The existing DISPOSITION entries keep EQUAL Disposition_<X> (fail closed). Do not change
   them.
   The bare {!Record.RecordType.DeveloperName} construct IS proven at the flexipage layer —
   four-probe check-only control against usman-dpeg, 2026-08-21, probe B rejected a bogus
   field behind the RecordType hop BY NAME. Do NOT invent formula checkbox fields for this.

4. THE RECORD-TYPE PIN IS LOAD-BEARING, NOT DECORATION, at three specific places:
   - NDA acquisition Move_to_Sent @ Status='Signed': without the pin, a DISPOSITION NDA
     sitting on its TERMINAL 'Signed' gets offered a "Sent" button that moves it BACKWARDS.
   - CR acquisition Move_to_Executed @ Negotiation_Status='Signed': 'Signed' is TERMINAL on
     Disposition_PSA and 'Executed' is not even on that record type. Negotiation_Status__c is
     a RESTRICTED picklist whose record-type subset Apex DML enforces (measured 2026-08-21),
     so the click would fail with an opaque INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST rather
     than a user-safe message.
   - LOI Move_to_Signed and CR Move_to_Signed each end up with an acquisition entry and a
     disposition entry AT THE SAME STAGE VALUE ('Negotiation'), separated ONLY by the
     inverted RT operator. Call this out in the page comment — it is the one place the RT
     criterion does 100% of the exclusion work.

5. LOI ONLY — {!Record.Is_Advance_Allowed__c} EQUAL true is criterion 4 on ALL THREE new LOI
   entries and is NOT redundant padding. Its formula's last clauses reduce, on an acquisition
   LOI at 'Under Review', to `LOI_Status__c = Approved` — i.e. THE LOI APPROVAL GATE. Drop it
   and a deal driver can walk an LOI past Under Review while its approval is pending or was
   rejected. It cannot be written as a direct criterion on LOI_Status__c: a visibility rule
   reading a field the running user cannot read evaluates FALSE.

6. LOI ONLY — DO NOT add an entry for the hop Submitted → Negotiation. It is ALREADY served
   by LOI__c.Mark_Countered (label "Negotiation") and its branch partner LOI__c.Mark_Completed
   (label "Signed"), both already rendered at Stage='Submitted'. Adding one would render two
   buttons that both land on 'Negotiation'. LOI gets THREE new entries, not four. Do not touch
   Mark_Countered, Mark_Completed or Submit_for_Approval.

7. UNDERWRITING ONLY — DO NOT create a button for In Progress → Approved. That hop is owned
   by the principal approval process; Underwriting__c.Submit_for_Approval already renders at
   exactly that stage and stays untouched.

8. TERMINAL STAGES GET NOTHING — no button and no hint text. This is an explicit user
   decision. NDA acquisition 'Sent', LOI 'Signed', CR 'Executed', Underwriting 'Completed',
   both feasibility 'Completed'.

9. NO PERMISSION SET CHANGES. Every field the new criteria read is already granted:
   NDA__c.Status__c and Contract_Review__c.Negotiation_Status__c are already read by the
   entries being removed; LOI__c.Stage__c is verified present in DPEG_Acquisition_Edit and
   DPEG_Acquisition_View; LOI__c.Is_Advance_Allowed__c is already read by the existing entry.
   Custom permissions carry no FLS. Do not open a permission set file.

10. NO APEX. RecordStageAdvanceService derives every target from the record's current stage
    per record type; advance() takes only a recordId. A new quick action pointing at the same
    c/advanceRecordStage bundle needs zero code. If you believe Apex is required, STOP and say
    why rather than writing it.

11. Comments go INSIDE the <FlexiPage> root element, never above it.

Update each page's header comment in the established house style: what changed, why
acquisition was left until now, the polarity choice and its reason, and the explicit note
that RENDERER BEHAVIOUR IS NOT PROVABLE FROM A REPO and requires the human UI checks in
agent-output/design-requirements.md §7.2.
```

### 🔵 PROMPT FOR `salesforce-admin` — W2 / WI-7 (dispatch ONLY after W1c readback is green AND OQ-4 is answered yes)

```
Two files, one deploy: Transaction_Record_Page.flexipage-meta.xml and
"layouts/Transaction__c-Transaction Layout.layout-meta.xml". Do NOT deploy yourself.

🔴 READ FIRST: the header of flexipages/Disposition_Record_Page.flexipage-meta.xml. That page
did exactly this on 2026-08-19 and then produced a live incident — App Builder SILENTLY
DROPPED Edit, Clone and Delete from its actionNames list (org had 9 valueListItems, repo had
12), so every Disposition record had no Edit/Clone/Delete button until it was found.

WHY THIS IS NOT LIKE W1b: Transaction_Record_Page has enableActionsConfiguration = FALSE, so
its action bar is inherited from the LAYOUT's <platformActionList> — which has NO
visibilityRule mechanism at all. Per-stage buttons are impossible without Dynamic Actions.

PART 1 — Transaction_Record_Page:
  set enableActionsConfiguration -> true
  add an actionNames valueList with TEN valueListItems.

🔴 Turning Dynamic Actions on DISCARDS the entire inherited action bar. The list must carry
the whole bar, not just the new buttons:
  Edit                              (StandardButton, NO visibilityRule)
  Clone                             (StandardButton, NO visibilityRule)
  Delete                            (StandardButton, NO visibilityRule)
  LogACall                          (QuickAction,    NO visibilityRule)
  NewEvent                          (QuickAction,    NO visibilityRule)
  NewTask                           (QuickAction,    NO visibilityRule)
  Transaction__c.Move_to_Due_Diligence  visibilityRule "1 AND 2":
      1 {!$Permission.CustomPermission.Transaction_Stage_Actions} EQUAL true
      2 {!Record.Stage__c} EQUAL "Open Contract"
  Transaction__c.Move_to_Closing_Prep   same c1; c2 {!Record.Stage__c} EQUAL "Due Diligence"
  Transaction__c.Move_to_Post_Closing   same c1; c2 {!Record.Stage__c} EQUAL "Closing Prep"
  Transaction__c.Move_to_Closed_Won     same c1; c2 {!Record.Stage__c} EQUAL "Post-Closing"

  ⚠ The gate is Transaction_Stage_Actions, NOT Acquisition_Deal_Actions. It is a LAYER-4
    team-wide capability set (Transaction_Stage_Actions_Access, member of DPEG_Transaction_
    Team), deliberately different in kind from the other two module gates. Do not harmonise.
  ⚠ No record-type criterion — Transaction__c has no record types.
  ⚠ Pure AND chains only. No parentheses.
  ⚠ 'Closed Won' is TERMINAL — no button.
  ⚠ These criteria are NEW. The layout has none today, so every user with the layout
    currently sees the button and the server refuses ungated clicks. This is a deliberate,
    user-approved tightening.

PART 2 — "Transaction__c-Transaction Layout":
  remove the Transaction__c.Advance_Stage platformActionListItem and RE-SEQUENCE sortOrder on
  the survivors: Edit 0, Clone 1, Delete 2, LogACall 3, NewEvent 4, NewTask 5.

🔴 PART 2 IS MANDATORY, NOT COSMETIC. Transaction_Record_Page is assigned ONLY by
applications/Transaction.app-meta.xml's actionOverride, and record pages are assigned
PER-APP. A Transaction opened from any other app falls back to the object default, which is
layout-driven — where Advance Stage would still be visible. Leaving it on the layout defeats
the whole request.

⚠ ACCEPTED RESIDUAL to record in the page comment: after this change, a Transaction opened
OUTSIDE the Transaction app has NO stage-advance button at all. Flagged to the user; not
being fixed here (fixing it means editing other apps' actionOverrides, which crosses a
module boundary).

GATE SK-1: load `sf-flexipage` for the page. There is NO sf-layout skill — record
best_matched_skill=sf-metadata for the Layout type and note the gap. Record mcp=unavailable /
mcp_tools=none after a real attempt.

GATE DA-1 for whoever deploys: query the org's CURRENT Transaction_Record_Page action bar via
the Tooling API and diff it against the repo file BEFORE writing, and read the deployed list
back AFTER. Confirm the org ends with TEN valueListItems. "Deployed successfully" is not
proof — numberComponentsDeployed is a pre-rollback tally.
```

### 🔴 PROMPT FOR `salesforce-devops` (four separate deploys — do not bundle)

```
Deploy in four waves, with a readback between each. Do not proceed to the next wave until the
previous wave's readback is green.

W1a  the 18 new quickActions          — safe alone; an unreferenced quick action renders
                                        nowhere, so this is a UI no-op
W1b  the 6 flexipages                 — GATE FP-1 on every file
W1c  READBACK + hand the human UI checklist (design-requirements.md §7.2) to the user
W2   Transaction_Record_Page + Transaction layout — GATE FP-1 + GATE DA-1
W3   (only if user approves OQ-3) destructive delete of the 7 Advance_Stage quickActions

GATE FP-1 — a FlexiPage deploy REPLACES the org copy and there is NO version history. Hand
edits have been lost here (2026-08-25). Lead_Record_Page and Opportunity_Record_Page were
both found drifted from the repo TODAY. For EVERY page, SECONDS BEFORE the deploy:
  1. retrieve that page to a scratch location
  2. diff the retrieved copy against HEAD — any delta is a user App Builder edit this deploy
     will destroy
  3. if a delta exists, STOP and surface it; rebase onto the RETRIEVED copy, not the repo one
  4. check SetupAuditTrail for FlexiPage saves newer than the retrieve
  5. deploy, then retrieve again and diff to prove it landed

GATE CT-1 — concurrent sessions share this working tree (measured 2026-08-16: another session
built a whole feature into it mid-run, and shared hub files silently became a union of two
features). Diff every touched file against HEAD before deploying and confirm nothing
unrelated has appeared. Commit retrieves on their own.

After W1b and after W2, confirm mechanically:
  rg "Advance_Stage" force-app/main/default/flexipages force-app/main/default/layouts
returns NOTHING.
```

---

## 13. TRACEABILITY

| Source | Requirement | Satisfied by | Note |
|---|---|---|---|
| User complaint | "I was on an acquisition NDA record and still saw 'Advance Stage'" | §3.1 | The exact reported case. |
| Decision #1 | Advance Stage not visible anywhere | §3.1–§3.7 + §4 part 3 | ⚠ **Partially**: the confirmation DIALOG still says "Advance Stage" — RESIDUAL-3 / OQ-1. |
| Decision #2 | No-next-step stages show nothing | §3, every terminal row | ✅ Cost is 1 dead hint entry, not 8 — F-1. |
| Brief | "Follow a939e97's conventions exactly" | §3 conventions block | ✅ Label, developer name, file shape, comment placement, polarity all inherited. |
| Brief | "Expect no Apex changes" | F-8 | ✅ Confirmed. Zero Apex, zero LWC, zero permission sets, zero fields. |
| Brief | "Prefer extending an existing action over minting a duplicate" | §3, 6 reuses | ✅ 6 reused, 18 new, 1 hop needed nothing at all (F-2). |
| Brief hazard (a) | FlexiPage deploy replaces org copy | GATE FP-1 | ✅ |
| Brief hazard (b) | Dynamic Actions enablement empties the bar | F-5 + GATE DA-1 | ✅ Six pages already have it ON; only Transaction is affected. |
| Brief hazard (c) | Shared stage names across record types | §3.1/§3.2/§3.3 + polarity block | ✅ Every rule on those three objects pins the record type, with NE polarity per the documented fail-open choice. |
| Brief hazard (d) | NDA's two Advance_Stage entries | F-6 | ✅ And the same dead entry exists on LOI and CR too — all six removed. |
| Brief hazard (e) | Removing entries has emptied bars before | §7.1 + §7.2 + wave split | ✅ |
| Brief | "Transaction layout is its own work item" | §4 / WI-7 | ✅ And it is materially harder than the brief implied — F-4. |
