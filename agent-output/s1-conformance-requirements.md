# ARCHITECTURE.md §1 — Remaining-Defect Inventory & Additive Migration Plan

**Type:** Requirements / analysis only. **No field metadata created or edited. No deployment.**
**Scope:** the "live violations scheduled for repair" listed in `ARCHITECTURE.md` §1 (callout block "Not amended — a rule that was merely unmet stays unmet"), pinned to their **current** filesystem state as of this analysis.
**Source of truth consulted:** `ARCHITECTURE.md` §1 (rules 2, 4, 6, 9) and `CLAUDE.md`.
**Method:** globbed `force-app/main/default/objects/**/fields/` for every named field, read each `.field-meta.xml` to confirm true object + type, then grepped the whole repo (Apex, LWC, reports, layouts, flexipages, flows, list views, validation rules, field sets, compact layouts, permission sets, profiles, object translations, seed scripts) for every reader.

---

## Headline findings (things §1 did not say / got partially wrong)

1. **Two of the seven "Rule 4 checkboxes" are FORMULA checkboxes, not stored checkboxes.**
   `Work_Order__c.Untouched__c` and `Lease_Renewal__c.Non_Responsive__c` both carry a `<formula>`. They hold **zero stored data**, so they belong to the **formula** migration class (recreate + repoint + delete, no backfill), not the stored-data class.
2. **All three "Rule 2" fields are pure case-only corrections** — the only difference in each target is capitalizing the lowercase joining word. One of them (`Days_on_Market__c`) is *also* a formula field, making it doubly safe.
3. **A fourth Rule 2 violation exists that §1 never listed:** `Opportunity.Cash_on_Cash_Return__c` (Percent) is an exact twin of the in-scope `Underwriting__c.Cash_on_Cash_Return__c` — same name, same lowercase `on`. It is **out of §1's stated scope** but is a real defect. See Open Question 1.
4. **No third scalar-in-Text field exists** beyond `Lease_Term__c` / `Free_Rent__c`. The obvious sibling `Lease_Inquiry__c.Space_Required__c` is already `Number`. `Base_Rent__c` / `TI_Allowance__c` are the §1-blessed quoted-deal-term Text exceptions.
5. **The two Rule 9 formula renames are confirmed Number formulas** (`<formula>` present): `Property_Asset__c.Is_Ready__c` (returns 1/0) and `Unit__c.Occupied_Flag__c` (returns 100/0). The `Occupied_Flag__c → Occupied_Count__c` target is semantically questionable — the formula yields 100/0, not a count. See Open Question 2.
6. **`TestDataFactory.cls` now exists in the repo** and is a reader of 6 of these fields — even though `ARCHITECTURE.md` §2 still says it is "pending Phase 1; does not exist yet." Treat it as an in-scope reader.
7. **Clean reader surface:** no Flow, validation rule, field set, compact layout, quick action, Aura component, email template, or Custom Metadata references any of the 14 fields. Readers are confined to Apex, LWC, reports, layouts, list views, one flexipage, permission sets, profiles (FLS stubs), object translations, and seed scripts.

---

## (a) Confirmed remaining-defect table

Reader count = distinct files that reference the field API name and would need repointing (Apex/LWC + reports + layouts + list views + flexipages + permission sets + seed scripts). It **excludes** the field's own `.field-meta.xml` and `.fieldTranslation-meta.xml` (renamed, not repointed), the ~40 profile FLS stubs (bulk category, see notes), `manifest/package.xml`, and pure-doc artifacts (`ARCHITECTURE.md`, `agent-output/field-inventory.txt`, `docs/`).

| # | Field (API) | Object | Type | Rule | Migration class | Proposed target name | Readers |
|---|-------------|--------|------|------|-----------------|----------------------|:------:|
| 1 | `Untouched__c` | `Work_Order__c` | Checkbox **(formula)** | 4 | **formula** | `Is_Untouched__c` | 8 (+1 scratch) |
| 2 | `Past_Target__c` | `Onboarding__c` | Checkbox (stored) | 4 | **stored-data** | `Is_Past_Target__c` | 6 |
| 3 | `Non_Responsive__c` | `Lease_Renewal__c` | Checkbox **(formula)** | 4 | **formula** | `Is_Non_Responsive__c` | 8 |
| 4 | `Never_Expires__c` | `NDA__c` | Checkbox (stored) | 4 | **stored-data** | `Is_Non_Expiring__c` * | 3 |
| 5 | `Renewal_Option__c` | `Lease_Renewal__c` | Checkbox (stored) | 4 | **stored-data** | `Has_Renewal_Option__c` | 5 |
| 6 | `Earnest_At_Risk__c` | `Transaction__c` | Checkbox (stored) | 4 | **stored-data** | `Is_Earnest_At_Risk__c` | 7 |
| 7 | `Wire_Approval_Due__c` | `Transaction__c` | Checkbox (stored) | 4 | **stored-data** | `Is_Wire_Approval_Due__c` | 6 |
| 8 | `Days_on_Market__c` | `Disposition__c` | Number **(formula)** | 2 | **case-only** | `Days_On_Market__c` | 2 |
| 9 | `Projected_Value_at_Peak__c` | `Property_Asset__c` | Currency (stored) | 2 | **case-only** | `Projected_Value_At_Peak__c` | 3 |
| 10 | `Cash_on_Cash_Return__c` | `Underwriting__c` | Percent (stored) | 2 | **case-only** | `Cash_On_Cash_Return__c` | 4 |
| 11 | `Is_Ready__c` | `Property_Asset__c` | Number **(formula)** | 9 | **formula** | `Readiness_Score__c` | 2 |
| 12 | `Occupied_Flag__c` | `Unit__c` | Number **(formula)** | 9 | **formula** | `Occupied_Count__c` * | 2 |
| 13 | `Lease_Term__c` | `Lease_Inquiry__c` | Text(30) | 9 | **stored-data (+type change → Number)** | `Lease_Term_Months__c` * | 3 |
| 14 | `Free_Rent__c` | `Lease_Inquiry__c` | Text(30) | 9 | **stored-data (+type change → Number)** | `Free_Rent_Months__c` * | 3 |
| — | `Cash_on_Cash_Return__c` | `Opportunity` | Percent (stored) | 2 | **case-only** | `Cash_On_Cash_Return__c` | 3 | *(NOT in §1 scope — see OQ1)* |

`*` = target name is a judgment call requiring user confirmation (see Open Questions).

**Final in-scope defect count: 14 field instances** (7 Rule 4 + 3 Rule 2 + 2 Rule 9 formula + 2 Rule 9 scalar-Text). **+1 newly discovered out-of-scope twin** (`Opportunity.Cash_on_Cash_Return__c`).

**Migration-class breakdown (of the 14):**
- **case-only (in-place re-case, data preserved):** 3 — #8, #9, #10 *(4 if OQ1 pulls in the Opportunity twin)*
- **formula (recreate → repoint → delete, no backfill):** 4 — #1, #3, #11, #12
- **stored-data (add → backfill → repoint → retire):** 7 — #2, #4, #5, #6, #7 (checkbox copies) + #13, #14 (Text→Number, needs a parse backfill)

---

## (b) Per-field reader maps

Legend: **[def]** field definition + its `.fieldTranslation-meta.xml` (renamed with the field, not repointed) · **[FLS]** permission set that grants access · **[dyn]** dynamic-SOQL string literal (string must be edited, not just a typed reference) · **[doc]** documentation-only (update for accuracy, non-blocking) · profiles = every `*.profile-meta.xml` carries a `<fieldPermissions readable=false>` stub for the field (bulk category, see §c retire step).

### 1. `Work_Order__c.Untouched__c` — formula → `Is_Untouched__c`
- [def] `objects/Work_Order__c/fields/Untouched__c.field-meta.xml`; `objectTranslations/Work_Order__c-en_US/Untouched__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Property_Management_Access` (line 967)
- Apex `classes/WorkOrderSelector.cls` — lines 43 **[dyn]** (field in a `String[]` used to build SOQL), 51, 55, 99 **[dyn]** (`'WHERE Untouched__c = true ...'`), 110, 115
- Apex `classes/WorkOrderController.cls` — 22, 48, 82
- Apex `classes/WorkOrderSelectorTest.cls` — 46, 83, 97, 137
- Apex `classes/WorkOrderControllerTest.cls` — 107, 109, 112, 114
- Report `reports/Work_Orders/Untouched_Work_Orders.report-meta.xml` — line 20 `<column>`
- Layout `layouts/Work_Order__c-Work Order Layout.layout-meta.xml` — line 88
- List view `objects/Work_Order__c/listViews/Untouched.listView-meta.xml` — line 12 (filter field)
- Scratch `/.superpowers/sdd/task-2-verify.apex` — 8, 10, 13, 15 (dev verify script, non-runtime)
- [doc] `manifest/package.xml`, `agent-output/field-inventory.txt`, `ARCHITECTURE.md`, `docs/superpowers/*work-order-tracker*`

### 2. `Onboarding__c.Past_Target__c` — stored → `Is_Past_Target__c`
- [def] `objects/Onboarding__c/fields/Past_Target__c.field-meta.xml`; `objectTranslations/Onboarding__c-en_US/Past_Target__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Property_Management_Access` (line 542)
- Apex `classes/OnboardingController.cls` — 103, 125
- Apex `classes/OnboardingSelector.cls` — 60
- Apex `classes/OnboardingControllerTest.cls` — 11, 19
- Apex `classes/OnboardingSelectorTest.cls` — 38, 58
- Seed `scripts/seed-onboarding.apex` — 33, 39, 45, 51, 57, 63
- [doc] `docs/superpowers/*property-management-onboarding*`

### 3. `Lease_Renewal__c.Non_Responsive__c` — formula → `Is_Non_Responsive__c`
- [def] `objects/Lease_Renewal__c/fields/Non_Responsive__c.field-meta.xml`; `objectTranslations/Lease_Renewal__c-en_US/Non_Responsive__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Property_Management_Access` (line 422)
- Apex `classes/LeaseRenewalSelector.cls` — 30 **[dyn]**, 38 (comment), 42, 72 **[dyn]** (`'... (Non_Responsive__c = true OR ...)'`), 83 (comment), 89
- Apex `classes/LeaseRenewalController.cls` — 24, 53, 92
- Apex `classes/LeaseRenewalSelectorTest.cls` — 91
- Report `reports/Leasing/Non_Responsive_Renewals.report-meta.xml` — line 23 `<column>`
- Layout `layouts/Lease_Renewal__c-Lease Renewal Layout.layout-meta.xml` — line 41
- List view `objects/Lease_Renewal__c/listViews/Renewal_Pipeline.listView-meta.xml` — line 10 `<columns>`
- List view `objects/Lease_Renewal__c/listViews/Non_Responsive.listView-meta.xml` — line 13 (filter field; the list view is *named* for this field)

### 4. `NDA__c.Never_Expires__c` — stored → `Is_Non_Expiring__c` *(name = OQ4)*
- [def] `objects/NDA__c/fields/Never_Expires__c.field-meta.xml`; `objectTranslations/NDA__c-en_US/Never_Expires__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/DPEG_Acquisitions` (line 1052)
- Apex `classes/TestDataFactory.cls` — 830
- Report `reports/Acquisitions/NDAs_Expiring_This_Month.report-meta.xml` — line 22 `<column>`

### 5. `Lease_Renewal__c.Renewal_Option__c` — stored → `Has_Renewal_Option__c`
- [def] `objects/Lease_Renewal__c/fields/Renewal_Option__c.field-meta.xml`; `objectTranslations/Lease_Renewal__c-en_US/Renewal_Option__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Property_Management_Access` (line 452)
- Apex `classes/TestDataFactory.cls` — 1729
- Layout `layouts/Lease_Renewal__c-Lease Renewal Layout.layout-meta.xml` — line 91
- Seed `scripts/seed-lease-renewals.apex` — 23, 25, 27, 29, 31, 33, 35, 37, 39, 41, 43, 45
- Seed `scripts/seed-lease-renewals-recent.apex` — 60, 62, 64, 66, 68, 70

### 6. `Transaction__c.Earnest_At_Risk__c` — stored → `Is_Earnest_At_Risk__c`
- [def] `objects/Transaction__c/fields/Earnest_At_Risk__c.field-meta.xml`; `objectTranslations/Transaction__c-en_US/Earnest_At_Risk__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Transaction_App_Access` (line 152)
- Apex `classes/TransactionSelector.cls` — 130
- Apex `classes/TransactionController.cls` — 35
- Apex `classes/TransactionControllerTest.cls` — 22, 30, 36, 42, 195, 211
- LWC `lwc/transactionCriticalDates/transactionCriticalDates.js` — line 6 (`import EAR from '@salesforce/schema/Transaction__c.Earnest_At_Risk__c'`)
- LWC Jest mock `lwc/transactionCriticalDates/__tests__/data/getRecord.json` (field key)
- Seed `scripts/seed-transactions.apex` — 24, 31, 38, 45, 52

### 7. `Transaction__c.Wire_Approval_Due__c` — stored → `Is_Wire_Approval_Due__c`
- [def] `objects/Transaction__c/fields/Wire_Approval_Due__c.field-meta.xml`; `objectTranslations/Transaction__c-en_US/Wire_Approval_Due__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Transaction_App_Access` (line 247)
- Apex `classes/TransactionSelector.cls` — 131
- Apex `classes/TransactionController.cls` — 38
- Apex `classes/TransactionControllerTest.cls` — 22, 30, 36, 42, 194, 212
- Apex `classes/TestDataFactory.cls` — 1252 (comment), 1253
- Seed `scripts/seed-transactions.apex` — 24, 31, 38, 45, 52

### 8. `Disposition__c.Days_on_Market__c` — case-only (formula) → `Days_On_Market__c`
- [def] `objects/Disposition__c/fields/Days_on_Market__c.field-meta.xml`; `objectTranslations/Disposition__c-en_US/Days_on_Market__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Disposition_Dashboard_Access` (line 21)
- Report `reports/Dispositions/Avg_Days_on_Market.report-meta.xml` — line 5 `<field>`
- Note: field name resolution is case-insensitive, so the report/perm-set references keep working after re-case; edit them only for consistency. **The target casing `Days_On_Market__c` already exists (correctly) on `Broker_Listing__c`** — no collision (different object), and it confirms the target casing is an established org convention.

### 9. `Property_Asset__c.Projected_Value_at_Peak__c` — case-only → `Projected_Value_At_Peak__c`
- [def] `objects/Property_Asset__c/fields/Projected_Value_at_Peak__c.field-meta.xml`; `objectTranslations/Property_Asset__c-en_US/Projected_Value_at_Peak__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/DPEG_Acquisitions` (line 1402)
- Apex `classes/SellMeterController.cls` — 87
- Apex `classes/PropertyAssetSelector.cls` — 55 (comment), 62

### 10. `Underwriting__c.Cash_on_Cash_Return__c` — case-only → `Cash_On_Cash_Return__c`
- [def] `objects/Underwriting__c/fields/Cash_on_Cash_Return__c.field-meta.xml`; `objectTranslations/Underwriting__c-en_US/Cash_on_Cash_Return__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/DPEG_Acquisitions` (line 1622)
- Apex `classes/TestDataFactory.cls` — 952
- Apex `scripts/backfill_opp_underwriting.apex` — 15 (`Primary_Underwriting__r.Cash_on_Cash_Return__c`), 31 (RHS reads Underwriting)
- Flexipage `flexipages/Opportunity_Record_Page.flexipage-meta.xml` — line 313 (`Record.Primary_Underwriting__r.Cash_on_Cash_Return__c` — **spanning** reference through the `Primary_Underwriting__r` lookup)
- **Twin field warning:** a bare grep for `Cash_on_Cash_Return__c` also hits `Opportunity.Cash_on_Cash_Return__c` (see the extra row / OQ1). Disambiguate by object context; both need the identical re-case.

### 11. `Property_Asset__c.Is_Ready__c` — formula → `Readiness_Score__c`
- [def] `objects/Property_Asset__c/fields/Is_Ready__c.field-meta.xml`; `objectTranslations/Property_Asset__c-en_US/Is_Ready__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Disposition_Dashboard_Access` (line 41)
- Report `reports/Dispositions/Sell_Readiness_By_Type.report-meta.xml` — line 13 `<field>` (used as a grouping/aggregate)
- No Apex/LWC readers.

### 12. `Unit__c.Occupied_Flag__c` — formula → `Occupied_Count__c` *(name/math = OQ2)*
- [def] `objects/Unit__c/fields/Occupied_Flag__c.field-meta.xml`; `objectTranslations/Unit__c-en_US/Occupied_Flag__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Property_Management_Access` (line 816)
- Report `reports/Property_Management/Occupancy_by_Property.report-meta.xml` — line 5 `<field>` (aggregated for occupancy %)
- No Apex/LWC readers. Formula returns `100 / 0`.

### 13. `Lease_Inquiry__c.Lease_Term__c` — Text→Number → `Lease_Term_Months__c` *(unit/parse = OQ3)*
- [def] `objects/Lease_Inquiry__c/fields/Lease_Term__c.field-meta.xml`; `objectTranslations/Lease_Inquiry__c-en_US/Lease_Term__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Property_Management_Access` (line 342)
- Apex `classes/TestDataFactory.cls` — 1567 (`Lease_Term__c = '60'`), plus header comments 50, 1564
- Seed `scripts/seed-lease-inquiries.apex` — 68, 69, 71, 72 (`Lease_Term__c = '7 years'`, `'5 years'`)
- **Data-drift confirmed in-repo:** seed uses `'7 years'`/`'5 years'`; factory uses `'60'`. Two unit conventions in one field — exactly the §1 rule-9(3) example.

### 14. `Lease_Inquiry__c.Free_Rent__c` — Text→Number → `Free_Rent_Months__c` *(unit/parse = OQ3)*
- [def] `objects/Lease_Inquiry__c/fields/Free_Rent__c.field-meta.xml`; `objectTranslations/Lease_Inquiry__c-en_US/Free_Rent__c.fieldTranslation-meta.xml`
- [FLS] `permissionsets/Property_Management_Access` (line 317)
- Apex `classes/TestDataFactory.cls` — 1568 (`Free_Rent__c = '2'`)
- Seed `scripts/seed-lease-inquiries.apex` — 68, 69, 71, 72 (`Free_Rent__c = '4 months'`, `'2 months'`)

### Extra (out of §1 scope): `Opportunity.Cash_on_Cash_Return__c` — case-only → `Cash_On_Cash_Return__c`
- [def] `objects/Opportunity/fields/Cash_on_Cash_Return__c.field-meta.xml` — **no** fieldTranslation file exists for this one.
- [FLS] `permissionsets/DPEG_Acquisitions` (line 1117)
- Apex `scripts/backfill_opp_underwriting.apex` — 31 (`o.Cash_on_Cash_Return__c = uw...`)
- Flexipage `Opportunity_Record_Page` line 313 surfaces the **Underwriting** field via `Primary_Underwriting__r`, not this Opportunity field — do not conflate.

---

## (c) Additive step sequence per migration class

> **Standing constraints baked in (from project experience):**
> - **Additive only** for any field holding data — never rename in place (rename = delete+create = data loss). Split the deploy so the physical column never blanks.
> - **New fields deploy with no FLS** (sf-deployed custom fields get zero FLS) — the new field MUST be added to the same permission set(s) as the old, or every reader hits "No such column / insufficient access" until FLS is granted.
> - **Reports do NOT block field deletion** — they break silently. Every report reader below must be repointed *before* the old field is deleted.
> - **Required-field / formula FLS:** none of the 14 fields is `required`, so there is no required-field FLS blocker. Formula fields take **read-only** FLS (`editable=false`) — grant the new formula field readable-only, never writable.
> - **Substring safety:** always match the full `__c`-anchored token when repointing. The two Text→Number targets (`Lease_Term_Months__c`, `Free_Rent_Months__c`) *contain* the old base token, so during the coexistence window a naive replace of `Lease_Term` / `Free_Rent` (un-anchored) would corrupt both. No old name in this set is a substring of any *other existing* field, so cross-field corruption risk is low — but anchor anyway.
> - **Retire step also touches profiles:** every `*.profile-meta.xml` (~40, including standard ones like "Chatter Free User") carries a `<fieldPermissions readable=false>` stub for each of these fields. Deleting the old field requires removing its stub from **every** profile and permission set, or the delete deploy fails referencing a non-existent field.

### Class A — case-only (fields #8, #9, #10, and OQ1's Opportunity twin)
Field API names are **case-insensitive**, so this is genuinely an in-place re-case; **data and relationships are preserved and readers keep resolving** even if not edited.
1. Re-case `<fullName>` inside the `.field-meta.xml` and rename the file (e.g. `Days_on_Market__c.field-meta.xml` → `Days_On_Market__c.field-meta.xml`).
2. Rename the matching `.fieldTranslation-meta.xml` file + its `<name>` to the new casing (Opportunity twin has none — skip).
3. Re-case the `<field>` in the permission set FLS entry.
4. Re-case readers for consistency (optional but recommended): report `<field>`/`<column>`, Apex, flexipage spanning ref. *All resolve case-insensitively today, so this is cosmetic, not correctness.*
5. Update `manifest/package.xml` member casing.
6. **Windows/git caveat:** a rename differing only in case on a case-insensitive filesystem can be dropped by git — stage the rename explicitly (`git mv` with a two-step temp name if needed) and verify the diff shows the rename.
7. Deploy in one shot (no coexistence window needed — same underlying column).

### Class B — formula (fields #1, #3, #11, #12)
Formula fields store nothing, so **no backfill** — but a *name* change (not case) is still delete+create, and readers break the instant the old field is deleted. Sequence:
1. **Add** the new formula field (`Is_Untouched__c`, `Is_Non_Responsive__c`, `Readiness_Score__c`, `Occupied_Count__c`) with the **identical** `<formula>` and type; create its `.fieldTranslation-meta.xml`.
2. **Grant FLS** (readable-only) on the new field in the same permission set(s) as the old.
3. **Repoint every reader** to the new name: Apex (typed refs **and** dynamic-SOQL string literals — #1 line 99, #3 line 72), reports, layouts, list views (note #1 and #3 each have a list view *named* for the field — decide whether to rename the list view too), Jest/tests.
4. Deploy add + repoint together; verify green.
5. **Retire** the old field: delete `.field-meta.xml` + `.fieldTranslation`, strip its FLS from every permission set **and every profile stub**, remove from `package.xml`.

### Class C — stored-data checkbox (fields #2, #4, #5, #6, #7)
1. **Add** new checkbox (`Is_Past_Target__c`, `Is_Non_Expiring__c`, `Has_Renewal_Option__c`, `Is_Earnest_At_Risk__c`, `Is_Wire_Approval_Due__c`) with matching `<defaultValue>`; create `.fieldTranslation`.
2. **Grant FLS** on the new field in the same permission set(s).
3. **Backfill:** one-off Apex/data step copying `new = old` for every existing record (checkbox → straight boolean copy). Bulk-safe (251+ per the bulk-test rule if a test is later written; the backfill itself just needs a bulkified `update`).
4. **Repoint every reader:** Apex (controllers/selectors/tests), LWC (#6 — `transactionCriticalDates.js` import + Jest mock JSON), layouts, seed scripts (rewrite seed literals to the new field).
5. Deploy add + backfill + repoint; verify counts on both fields match.
6. **Retire** old field: delete def + translation, strip FLS from all permission sets + profile stubs, remove from `package.xml`.

### Class D — scalar Text→Number (fields #13, #14) — highest-risk
1. **Add** new Number field (`Lease_Term_Months__c`, `Free_Rent_Months__c`), scale 0; create `.fieldTranslation`.
2. **Grant FLS** in `Property_Management_Access`.
3. **Backfill with a parse** (this is the hard part — the Text holds mixed conventions):
   - `Lease_Term__c`: `'7 years'`→84, `'5 years'`→60 (× 12); `'60'`→60 (bare = months, per TestDataFactory); reject/park anything unparseable.
   - `Free_Rent__c`: `'4 months'`→4, `'2 months'`→2; `'2'`→2 (bare = months).
   - Canonical unit = **months** (pending OQ3 confirmation). Log any row that does not match the two known patterns rather than silently defaulting.
4. **Repoint readers** to the Number field and **change the values written**: seed scripts must pass integers (`84`, not `'7 years'`); TestDataFactory must pass `60`/`2` as Number, not String; drop the now-inaccurate "TEXT" header comments.
5. Deploy; verify parsed counts.
6. **Retire** old Text field: delete def + translation, strip FLS everywhere + profile stubs, remove from `package.xml`.
   - **Do NOT** touch `Base_Rent__c` / `TI_Allowance__c` (Lease_Inquiry) or `Current_Rent__c` (Lease_Renewal) — §1-blessed quoted-deal-term Text.

---

## (d) Already DONE / deliberately excluded

**Verified complete (absent from repo) — exclude:**
- **Rule 6 — 8 DateTime `_Date`-suffixed fields:** `Work_Order__c.Reported_Date__c`, `.SLA_Due_Date__c`, `.Completed_Date__c`, `.First_Touched_Date__c`, and `Entry_Date__c` on `Deal_Message__c` / `Lease_Activity__c` / `Renewal_Activity__c` / `Work_Order_Activity__c`. (Confirmed absent; the org now uses `..._DateTime__c`, e.g. `Work_Order__c.First_Touched_DateTime__c`, `Reported_DateTime__c` seen live in `WorkOrderSelector`/verify scripts.)
- **Rule 9 — `Unit__c` (Text) → `Unit_Label__c`:** old `Unit__c` gone from `Lease_Renewal__c` and `Work_Order__c`; `Unit_Label__c` (Text) present and in active use in seed scripts (`seed-lease-renewals*.apex`). `Rent_Step__c.Unit__c` correctly remains the real MasterDetail.

**Deliberately excluded (not defects):**
- `Lease_Inquiry__c.Base_Rent__c`, `Lease_Inquiry__c.TI_Allowance__c`, `Lease_Renewal__c.Current_Rent__c` — §1-blessed quoted-deal-term Text (carry `'$34.00 / sq ft NNN'` etc.). Their `<description>` already documents the rationale; the `Current_Rent__c` / `Proposed_Rate__c` pairing is the intended pattern.
- `Lease_Inquiry__c.Space_Required__c` — already `Number(9,0)`. Evaluated as the possible "third scalar-in-Text" and ruled out. **No third scalar-in-Text field exists.**

**Out of scope but flagged (not silently included):**
- `Opportunity.Cash_on_Cash_Return__c` — a genuine Rule 2 twin of #10, never listed in §1. See OQ1.

---

## (e) Open questions for the user

1. **Include the out-of-scope twin?** `Opportunity.Cash_on_Cash_Return__c` is an exact Rule 2 twin of the in-scope Underwriting field (same lowercase `on`). It is a trivial case-only fix. Recommend folding it into the same bundle so the org does not keep one twin defect. **Proceed to fix it too? (yes/no)**
2. **`Occupied_Flag__c` target name & formula.** The doc says `Occupied_Count__c`, but the formula returns `100 / 0` (not a count), and the `Occupancy_by_Property` report averages it into an occupancy %. Options: (a) keep `Occupied_Count__c` and change the formula to return `1 / 0` (then fix the report's aggregate), or (b) rename to `Occupied_Pct__c` (rule 9's `_Pct__c` suffix) and keep the 100/0 math. **Which?**
3. **Text→Number canonical unit & parse.** Confirm canonical unit = **months** for both `Lease_Term_Months__c` and `Free_Rent_Months__c`. Confirm bare numbers in TestDataFactory (`'60'`, `'2'`) are months (not years). Confirm behavior for unparseable/blank values during backfill (park + log vs. hard-fail).
4. **Rule 4 target names — confirm wording**, especially where multiple conforming forms exist:
   - `Never_Expires__c` → `Is_Non_Expiring__c` vs `Has_No_Expiry__c` (both Rule-4-valid; the field means "this NDA never expires").
   - `Wire_Approval_Due__c` → `Is_Wire_Approval_Due__c` (Is_ prefix on "a wire approval is due").
   - `Untouched__c` → `Is_Untouched__c`, `Past_Target__c` → `Is_Past_Target__c`, `Non_Responsive__c` → `Is_Non_Responsive__c`, `Renewal_Option__c` → `Has_Renewal_Option__c`, `Earnest_At_Risk__c` → `Is_Earnest_At_Risk__c` — confirm these are acceptable.
5. **List views named after fields.** `Work_Order__c/listViews/Untouched.listView` and `Lease_Renewal__c/listViews/Non_Responsive.listView` are *named* for the fields being renamed. Rename the list views to match, or leave the list-view API names as-is (only repoint the internal `<field>`/`<columns>`)?
6. **Case-only reader churn.** For the 3–4 case-only fields, field resolution is case-insensitive so readers keep working untouched. Re-case every reader for cosmetic consistency, or edit only the field def + translation + perm set + package.xml (leaving reader casing alone)?
7. **`TestDataFactory.cls` reality.** `ARCHITECTURE.md` §2 still says this class does not exist ("pending Phase 1"), but it is in the repo and reads 6 of these fields. Confirm it is in scope for repointing, and note that §2 should be corrected in the same PR (per §6 "keep this document current").
8. **Bundle vs. sequence.** Recommend deploying by class in waves: (A) case-only first (lowest risk, no coexistence window), then (B) formula, then (C) checkboxes, then (D) Text→Number last (needs the parse backfill). Confirm this ordering, and whether each field is its own PR or grouped by owning module (Property_Management_Access carries 7 of the 14).
