# USER DECISIONS - 2026-08-22 - BINDING, DO NOT RE-OPEN

Decided by the user AFTER this design was written. Where they conflict with anything below, these win.

| # | Decision |
|---|---|
| D-UM-1 | REJECT standard Asset. Build a custom Meter__c instead. Two verified blockers: objects/Asset/** is force-ignored (.forceignore line 250 = silent drop, zero errors), and Asset.sharingModel is ControlledByParent whose parent is AccountId/ContactId - meter account numbers and service IDs would inherit Account visibility, and a ControlledByParent object CANNOT carry sharing rules, so there is no declarative repair. |
| D-UM-2 | Meter__c uses Private OWD plus criteria sharing, matching Unit__c and Work_Order__c. Meter Number becomes a normal field (standard SerialNumber no longer applies). A self-lookup models master/sub-meter. |
| D-UM-3 | The FSD 5.10.3 deviation must be documented WITH its justification (ControlledByParent cannot scope per property). ARCHITECTURE.md section 1 requires custom-object use to be justified. |
| D-UM-4 | No .forceignore surgery is needed for this build. That risk is now confined to the AR stream. |
| D-UM-5 | Correction to the original brief: the .lv-* list chrome DOES NOT EXIST in the PM bundles. The real pattern is lightning-card + slot=title + .hdr/.hdr-icon/.hdr-title + c-list-datatable + .view-all-footer (see workOrderList.html). LWC CSS is bundle-scoped regardless. |
| D-UM-6 | UT-001 DEPENDS ON THE ONBOARDING STREAM. Its trigger Task is hard-coded to one property in a seed script, so it cannot fire anywhere until the Build-1 fan-out exists. Sequence accordingly. |
| D-UM-7 | GroupNotifier hardcodes Acquisitions_Deal_Update - see D-ON-7. Same fix applies to variance alerting. |
| D-UM-8 | Keep the flagged blocking open questions OPEN (Register Size semantics; variance alert threshold/recipient/channel, which FSD 5.10 never specifies). Present them; do not silently default them. |

---

# DESIGN REQUIREMENTS — FSD 5.10 Utility & Meter Tracking (DPEG Property Management)

**Design agent run:** 2026-08-22 · Source spec: FSD v1.1 §1.2 row 10, §3, §5.10.1–5.10.5, UAT UT-001
**Output file:** `agent-output/design-utility-meter.md` (deliberately NOT `design-requirements.md` — two other design agents are running concurrently)
**Branch:** `feature/disposition-redesign`

`skill_selection=pending | best_matched_skill=none | intent=app`
`mcp=unavailable | mcp_tools=none` — `.claude/rules/salesforce-global-rule.md` mandates the `salesforce-api-context` MCP for every metadata type, but `.mcp.json` configures only the `salesforce` server and subagents carry no MCP tools. **Each implementing agent must still run the per-type loop (a–e) itself**, record `mcp=unavailable` after a real attempt, and fall back to the per-type skill. This design document does not satisfy that gate on their behalf.

---

## 0. 🔴 CONTRADICTED PREMISES — READ BEFORE ANYTHING ELSE

The brief is accurate on the greenfield claim (verified: **zero** occurrences of `Utility_Bill__c`, `Charge_Line__c`, `Vendor_Contract__c`, `Meter_Allocation__c` anywhere in the repo, including `docs/`, `scripts/` and `manifest/`) and accurate that **no permission set grants `Asset`** (verified: zero `<object>Asset</object>` across all 34 permission sets). Five other premises are wrong or materially incomplete.

### 0.1 🔴 BLOCKER — `objects/Asset/**` is force-ignored. S1 cannot deploy at all as briefed.

`.forceignore:250`

```
force-app/main/default/objects/Asset/**
```

It sits in **Bucket B — "standard objects that already exist in the org, with ZERO DPEG customization"**. Every custom field, record type and object-level change written under `objects/Asset/` will be **silently dropped from every deploy with zero errors and zero warnings**. The rationale line above it ("ZERO DPEG customization") stops being true the moment this build adds its first field — exactly as it stopped being true for `Account` on 2026-08-10.

The same file already documents the fix and both failed attempts, at `.forceignore:224–248` (the Account narrative). Load-bearing points, quoted from it:

- The blanket ignore "was silently dropping the entire `objects/Account/**` tree — including the two new record types — from EVERY deploy attempt with zero error or warning."
- Removing the line outright was **too broad**: `Account/fields/**` held ~11 pre-existing broken standard-field declarations that this org's edition cannot resolve.
- **A gitignore-style negation does NOT work**: `objects/Account/**` prunes the child directory *node*, "and per gitignore semantics a negation cannot re-include a path whose parent directory was already excluded; the negated recordTypes files simply never appeared in the deploy's file list, with no error at all."

`Asset` is worse than `Account` for this, because this build needs to add files under `Asset/fields/` — so the Account resolution (ignore the whole `fields/**` subfolder) is **not available here**. And `.forceignore:96` names "Asset lifecycle" explicitly among the features "not present in this org's edition", so several of the 50 retrieved standard field files under `objects/Asset/fields/` are near-certain to fail: `AssetLevel`, `AverageUptimePerDay`, `ConsequenceOfFailure`, `CurrentMrr`, `CurrentLifecycleEndDate`, `DigitalAssetStatus`, `HasLifecycleManagement`, `MeanTimeBetweenFailures`, `MeanTimeToRepair`, `Reliability`, `SumDowntime`, `SumUnplannedDowntime`, `TotalLifecycleAmount`, `UptimeRecordStart`, `UptimeRecordEnd`, `Uuid`.

**Required sequence (gate — nothing else in S1 starts until this is green):**

1. Remove `.forceignore:250`.
2. Check-only dry-run with **Asset alone** in the payload (the Account precedent proves an isolated single-object dry-run reproduces this cleanly).
3. For each failing standard `Asset/fields/X.field-meta.xml`: either **delete the file from the repo** (preferred — it describes a standard field, so not deploying it changes nothing in the org) or add it as an **exact-file** ignore, matching the surgical style already used at `.forceignore:548–557` for Contact/Lead/Opportunity/Task/Event/User. Do **not** re-add a directory-level ignore.
4. Deploy ONE custom Asset field, then **read it back** (describe) before generating the rest. Per the standing "no MCP → escalate shape as a gate" practice, a green deploy is not proof here — `.forceignore` failures report success.

⚠ Related trap in the same area: `layouts/Asset-Asset Layout.layout-meta.xml` **exists and is NOT force-ignored** (the layouts exclusion block lists `AssetAction-*`, `AssetActionSource-*`, `AssetStatePeriod-*` but no plain `Asset-*`). So the layout deploys today while its object's fields do not. Any layout edit referencing a new custom field must land **after** the field, or the deploy fails on a field that "doesn't exist".

### 0.2 🔴 `Asset` sharing is `ControlledByParent`. The meter register cannot be scoped to the property.

| Object | `sharingModel` | Source |
|---|---|---|
| `Asset` | **ControlledByParent** (and `externalSharingModel` ControlledByParent) | `objects/Asset/Asset.object-meta.xml:127` |
| `Property_Asset__c` | **Private** | `objects/Property_Asset__c/Property_Asset__c.object-meta.xml:164` |
| `Account` | **ReadWrite** | `objects/Account/Account.object-meta.xml:250` |
| `Unit__c` | ControlledByParent | `objects/Unit__c/Unit__c.object-meta.xml:164` |

Consequences the FSD did not consider when it said "use the standard Asset object per the architecture rule":

- Asset's sharing parent is `AccountId` (falling back to `ContactId`). It is **not** `Property_Asset__c` and cannot be made so — `Property_Asset__c` is not a valid sharing parent for a standard object.
- If `Asset.AccountId` is set to the **utility provider** Account, the meter register inherits Account's **public ReadWrite** OWD. Every meter — including account numbers and service identifiers — becomes visible and editable to everyone who can see Accounts. That silently un-scopes data whose property parent was deliberately set Private.
- If `Asset.AccountId` and `ContactId` are both **blank**, a ControlledByParent record with no parent is a known owner-private failure shape on this org (the same class of failure already recorded for account-less Contacts, which surfaced as `insufficient access rights on cross-reference id` on another user's save). The meter register would be invisible to every PM user except the one who created each row.
- Asset **cannot** carry sharing rules (ControlledByParent objects don't), so there is no declarative repair.

**This is a decision gate, not a detail.** See Open Question OQ-1.

### 0.3 The named PM components do not use the `.lv-*` chrome.

Brief: *"Follow the repo's established LWC list-view chrome standard (shared `.lv-*` SLDS classes — see existing PM components like `workOrderList`, `renewalList`, `rentRoll`)."*

Measured: **zero** `lv-` occurrences across `lwc/workOrderList/**`, `lwc/renewalList/**`, `lwc/rentRoll/**`. The `.lv-*` classes live in Acquisition/Disposition bundles (`dispositionOfferSelect`, `bovReplaceBrokerModal`, `portfolioDealSiblings`, `recentPortfolioDeals`, `callForOffersList`, …). And because LWC CSS is **bundle-scoped**, `.lv-*` is not shared in any real sense — each bundle re-declares it.

The actual PM list chrome, from `lwc/workOrderList/workOrderList.html`:

- `<lightning-card>` with a `slot="title"` block using `.hdr` / `.hdr-icon` (inline SVG, `stroke="#7A9ED4"`) / `.hdr-title` carrying a live `({count})`
- `<c-list-datatable key-field="id" column-widths-mode="fixed" hide-checkbox-column>` — the shared custom datatable, which supports a custom `type: 'pill'` with `wrapStyle` / `dotStyle` typeAttributes
- an error block: `slds-text-color_error` + `lightning-icon utility:error` + `role="alert"`
- `<div slot="footer" class="view-all-footer">` with a `NavigationMixin.GenerateUrl` link and an `onclick` `Navigate`

**New PM components must copy `workOrderList`, not the `.lv-*` bundles.**

⚠ If any new datatable uses row actions, note the recorded defect: `event.detail.action.name` arrives as the raw `{fieldName:'actionName'}` object, so a per-row action name never matches — read `event.detail.row.actionName` instead, and do not let a Jest test fake a string-shaped payload.

### 0.4 The PM module's existing "vendor" precedent is Text, not an Account lookup.

Brief: *"`Account` (for the utility provider)"*. FSD 5.10.4 does say `Provider | Lookup (Account)`. But the only comparable field already shipped in PM is `Work_Order__c.Vendor__c` — **Text(120)** (`objects/Work_Order__c/fields/Vendor__c.field-meta.xml:10`), not a relationship. There is no utility-provider Account population, no Account record type for vendors (the two that exist are `Broker_Firm` and `Investor_Entity`), and no data-governance rule for who creates them. See OQ-2.

### 0.5 🔴 There is no onboarding task TEMPLATE. UT-001's trigger task exists on exactly one property.

The brief is right that `scripts/seed-onboarding-tasks.apex:37` contains the task — verified verbatim:

```apex
new List<Object>{'Vendor & Expense Management','Set up utility accounts & transfers','In Progress','Endya Williams','Email',Date.newInstance(2026,7,2),null,true},
```

But that script is a **one-property seed**, not a template. It hard-codes `WHERE Property_Asset__r.Property_Name__c = 'Park North'` (line 3) and deletes/recreates that property's Tasks. Verified absent:

- **Zero** Flows reference `Onboarding__c` (`flows/` grep: no files).
- The only checklist-template Custom Metadata types are `Transaction_Task_Def__mdt` and `Task_Group_Def__mdt` — both Transaction-scoped. There is no `Onboarding_Task_Def__mdt`.
- No Apex class creates onboarding checklist Tasks (the 14 Onboarding-related classes are selector/rollup/controller/service/test only).

⇒ **On a genuinely new property, the utility-transfer task does not exist, so UT-001 never fires.** Also note the seed's own header comment says "45 onboarding checklist Tasks" while FSD 5.1.5 specifies 47. See OQ-9.

---

## 1. WHAT THE FSD ACTUALLY ASKS FOR

Verbatim scope from §5.10, with nothing added:

- A **meter register on the standard `Asset` object** per property and space; parent/child Asset models a master meter with sub-meters (§5.10.3).
- Nine meter fields (§5.10.4 table).
- **Utility Bill** (custom, child of Meter) — one per meter per billing month; **bill date and read date captured separately**; previous and current readings stored; consumption calculated **using the register size with rollover handling** (§5.10.5).
- **Charge Line** (custom, child of Utility Bill) — per-component amounts (§5.10.3).
- **Vendor Contract** (custom) — fixed-monthly shape for trash and maintenance, no meter, no consumption (§5.10.3).
- **Meter Allocation** (custom, child of Meter) — only where one meter serves several spaces; holds the split basis (§5.10.3).
- **Variance broken into two components before any alert fires** (§5.10.2, §5.10.5):
  - *Usage Variance* = change in consumption valued at the **prior** unit rate
  - *Rate Variance* = change in unit rate valued at the **current** consumption
- UT-001: onboarding utility-transfer task completed → meter capture screen opens; meters saved against property and spaces.

**Not in the FSD, and therefore not designed in as requirements:** alert thresholds, alert recipients, alert channel, validation rules, required-field rules, approval processes, dashboards/reports for 5.10 (§6 has no utility tile), any Yardi sync, any import mechanism. §5.10 is the **only** functional area in the FSD with no "Automation & Alerts" subsection, despite §5.10.2 promising variance-triggered alerts. Everything in that list appears below only as an **open question** or an explicitly-labelled **proposal**.

**No Yardi dependency, confirmed by the FSD itself** (§5.10.1: "Yardi cannot store meter-level data… it can only track what has been paid"; §5.10.2: "this functionality is independent of the Yardi replication and can be developed first"). Design accordingly: **no mirror object, no `Yardi_*_Id__c` external id, no last-synced timestamp, no read-only field posture.** This is Category B in FSD §3 — built in Salesforce, Salesforce is system of record. It is the only PM area of the ten that is fully native and editable end-to-end.

---

## 2. 🔵 ADMIN / DECLARATIVE WORK

### S1 — Meter register on standard `Asset`

**Prerequisite:** §0.1 gate green. Nothing below deploys until then.

**Reused standard fields — no new field needed:**

| FSD field | Standard field | Note |
|---|---|---|
| Meter Number | `SerialNumber` | Text(80). FSD 5.10.4 names it explicitly. |
| Master meter → sub-meter | `ParentId` (Parent Asset) | Self-lookup, already present. `RootAssetId` is platform-maintained. |
| Meter display name | `Name` | Required Text(255) — see OQ-3. |

**New custom fields on `Asset` (11):**

| API name | Type | Detail |
|---|---|---|
| `Utility_Type__c` | Picklist, **restricted** | Electricity, Water, Sewer, Gas, Trash |
| `Property_Asset__c` | Lookup(`Property_Asset__c`) | Matches the shipped PM precedent (`Unit__c.Property_Asset__c`, `Work_Order__c.Property_Asset__c`). `deleteConstraint` **SetNull** — see OQ-4. |
| `Unit__c` | Lookup(`Unit__c`) | Blank = the meter serves the whole building (FSD 5.10.4) |
| `Utility_Account_Number__c` | Text(80) | Match key to the payables invoice. ⚠ **Not** `Utility_Account__c` — ARCHITECTURE §1 reserves the bare object-shaped name for a lookup, so that name would be camouflaged as a relationship to a non-existent `Utility_Account__c` object. |
| `Service_Identifier__c` | Text(80) | Label "Service Identifier (ESID)". Durable service-point id, survives meter swaps. Named generically because ESID is Texas-electric-specific; water/gas carry different identifiers. |
| `Provider__c` | Lookup(`Account`) | See OQ-2 (governance) and OQ-5 (naming deviation) |
| `Paid_By__c` | Picklist, **restricted** | Tenant, Management, Shared |
| `Paid_By_Reason__c` | Text(255) | "reason management pays" (FSD 5.10.4). See OQ-6 — picklist vs free text. |
| `Register_Digits__c` | Number(2,0) | The dial's digit count; rollover modulus = 10^digits. ⚠ FSD says "Register Size"; that phrase is ambiguous between digit count and modulus. See OQ-7 — **this is the single highest-risk ambiguity in the whole section**, because it silently changes every consumption number. |
| `Service_Status__c` | Picklist, **restricted** | Active, Disconnected (Vacant), Transferred, Inactive |
| `Variance_Alert_Sent_DateTime__c` | DateTime | Only if OQ-10 selects the batch alert pattern. Idempotency marker — omit entirely otherwise. |

⚠ **Do not touch standard `Asset.Status`.** The repo file is a bare `<type>Picklist</type>` declaration with no `<valueSet>` (`objects/Asset/fields/Status.field-meta.xml`). A retrieve **unions** local and remote picklist values, so any local edit there is unreliable, and restricted-picklist values on this project **are enforced by DML** (measured 4×). `Service_Status__c` as a separate custom field avoids the whole class of problem and satisfies ARCHITECTURE §1 ("a field expressing current state → suffix `Status__c`").

**Asset RecordType — recommended:** one record type `Utility_Meter`. It separates meters from any future Asset use, lets the meter page layout / compact layout be meter-specific, and is the only way to keep an unrelated future Asset population from inheriting the meter fields.
⚠ **Deploy record types BEFORE any Apex that writes their picklist values** — restricted picklist enforcement at DML is proven on this project, and a record type that does not yet exist turns into a runtime failure, not a compile failure.
⚠ Record types live at `objects/Asset/recordTypes/` — the §0.1 gate covers them and the Account precedent proves negation will not rescue them.

**Layout / page:** `Asset-Asset Layout.layout-meta.xml` already deploys (§0.1). Add the new fields there **after** the fields land. A meter-specific FlexiPage record page is preferable to the classic layout, but note the recorded gotcha: **record pages are assigned per-app** via `actionOverrides`, so an Asset record page added to `Property_Management.app-meta.xml` will not apply in Acquisition/Transaction/Disposition — that is desirable here and should be stated, not discovered.

### S2 — `Utility_Bill__c` (new custom object)

Child of the meter, one row per meter per billing month.

| API name | Type | Detail |
|---|---|---|
| *(Name)* | AutoNumber `UB-{00000}` | Matches `Unit__c`'s `UNIT-{0000}` precedent |
| `Meter__c` | **Lookup(`Asset`)** | See OQ-5 (naming) and OQ-8 (lookup vs master-detail) |
| `Bill_Date__c` | Date | FSD 5.10.5 — billing period |
| `Read_Date__c` | Date | FSD 5.10.5 — consumption period, deliberately separate |
| `Previous_Reading__c` | Number(16,4) | Precision unverified — OQ-11 |
| `Current_Reading__c` | Number(16,4) | " |
| `Consumption__c` | Number(16,4), **stored, Apex-written** | Rollover-aware. Rationale in §3. |
| `Total_Charges_Amount__c` | Roll-Up Summary SUM of `Charge_Line__c.Charge_Amount__c` | Requires the S3 master-detail |
| `Rate_Per_Unit__c` | Formula (Currency) | `Total_Charges_Amount__c / Consumption__c`, **guarded** for null/zero consumption |
| `Prior_Utility_Bill__c` | Lookup(`Utility_Bill__c`), Apex-written | Self-lookup to the immediately preceding bill for the same meter by `Read_Date__c`. Load-bearing — see §3.2. |
| `Usage_Variance_Amount__c` | Formula (Currency) | `(Consumption__c − Prior_Utility_Bill__r.Consumption__c) * Prior_Utility_Bill__r.Rate_Per_Unit__c` |
| `Rate_Variance_Amount__c` | Formula (Currency) | `(Rate_Per_Unit__c − Prior_Utility_Bill__r.Rate_Per_Unit__c) * Consumption__c` |
| `Total_Variance_Amount__c` | Formula (Currency) | `Total_Charges_Amount__c − Prior_Utility_Bill__r.Total_Charges_Amount__c` |
| `Total_Variance_Pct__c` | Formula (Percent) | Guarded for a zero/null prior total |

Naming notes against ARCHITECTURE §1: currency totals take the `Amount` suffix (`Offer_Amount__c` precedent); the per-unit figure is a **rate**, so it names its unit (`Rent_PSF__c` precedent) rather than taking `Amount`; `_Pct__c` is the sanctioned Number suffix; `Bill_Date__c` / `Read_Date__c` are date-only so they take `Date`, never `DateTime`.

`sharingModel`: see OQ-1. (For a **custom** object the OWD is `<sharingModel>` inside the object metadata and **does** deploy — unlike standard-object OWD, which is UI-only on this project.)

### S3 — `Charge_Line__c` (new custom object)

| API name | Type | Detail |
|---|---|---|
| *(Name)* | AutoNumber `CL-{000000}` | |
| `Utility_Bill__c` | **Master-Detail**, `reparentableMasterDetail=false` | Both sides custom — safe, and the only way to get the S2 roll-up summary |
| `Charge_Type__c` | Picklist | ⚠ **Recommend UNRESTRICTED** — see OQ-12 |
| `Charge_Amount__c` | Currency(16,2) | ARCHITECTURE §1 forbids a bare `Fee__c`/`Cost__c`; `Charge_Amount__c` names the unit |

Seed value list from the FSD's own examples (electricity: energy, pass-through, taxes; water: surface water, wastewater, stormwater, grease trap, fire): Energy, Pass-Through, Taxes, Surface Water, Wastewater, Stormwater, Grease Trap, Fire, Base Charge, Other.

`sharingModel` is forced to `ControlledByParent` by the master-detail — no decision to make.

### S4 — `Vendor_Contract__c` (new custom object)

The FSD gives this object one sentence and **no field table**. Everything below except the four italicised items is inferred; see OQ-13 before building.

| API name | Type | Detail |
|---|---|---|
| *(Name)* | AutoNumber `VC-{00000}` | |
| `Property_Asset__c` | Lookup(`Property_Asset__c`) | |
| `Unit__c` | Lookup(`Unit__c`) | Optional — blank = whole property |
| `Provider__c` | Lookup(`Account`) | Consistent with S1 |
| *`Service_Type__c`* | Picklist | FSD names only **Trash** and **Maintenance** — OQ-13 |
| *`Monthly_Amount__c`* | Currency(16,2) | ARCHITECTURE §1: "the period for a periodic amount" — matches `Monthly_Rent__c` |
| `Start_Date__c` / `End_Date__c` | Date | |

⚠ ARCHITECTURE / FSD §2 principle 4 says "standard objects first", and the org **has** standard `Contract`. The FSD asserts a custom object without evaluating it. Standard `Contract` is a poor fit (it is `AccountId`-scoped with its own activation/status lifecycle and `ContractTerm` semantics, not property-scoped), so the custom object is the right call — but the reasoning should be recorded in the object description rather than left as an unexamined assertion, because principle 4 says "each is justified".

### S5 — `Meter_Allocation__c` (new custom object)

| API name | Type | Detail |
|---|---|---|
| *(Name)* | AutoNumber `MA-{00000}` | |
| `Meter__c` | Lookup(`Asset`) | Child of Meter per FSD 5.10.3 |
| `Unit__c` | Lookup(`Unit__c`) | The space receiving the split |
| `Allocation_Basis__c` | Picklist, restricted | Square Footage, Fixed Percentage, Equal Split, Tenant-to-Tenant Settlement, Management-Paid Vacant — these are exactly the five arrangements FSD 5.10.1 names |
| `Allocation_Pct__c` | Percent, Number(5,2) | `_Pct__c` per ARCHITECTURE §1 type-suffix discipline |
| `Square_Feet__c` | Formula (Number) → `Unit__r.Square_Feet__c` | Derive rather than duplicate — `Unit__c.Square_Feet__c` already exists and is the single source of truth |

⚠ **The "allocations sum to 100%" invariant cannot be declarative.** A roll-up summary requires master-detail, and `Meter__c` is a lookup to a standard object (OQ-8). If the invariant is wanted it must be Apex domain validation — and the FSD does not ask for it. See OQ-14.
⚠ **No effective-dating.** The FSD gives none, but without `Effective_Start_Date__c` / `Effective_End_Date__c` a historical bill cannot be re-allocated on the basis that was in force at the time — allocations demonstrably change (vacancy, tenant turnover). See OQ-15.

### S8a — UI (declarative half)

- FlexiPage `Utility_Bill_Record_Page` (variance panel + charge lines related list).
- A `Utilities` app page assembling the meter register + recent bills, or the components dropped onto `Property_Asset_Record_Page` — see OQ-16.
- New tabs: **hub request only**, see §5.

---

## 3. 🟢 DEVELOPER / APEX + LWC WORK

All classes `with sharing` unless a class-header justification is written. All SOQL in selectors, `WITH USER_MODE` for user-requested reads and `WITH SYSTEM_MODE` **justified per-method in the class header** for automation-path reads (ARCHITECTURE §2). Trigger files are one line. Domain classes hold zero SOQL and zero DML.

### 3.1 Layering map

| Layer | Class | Responsibility |
|---|---|---|
| Trigger | `UtilityBillTrigger` | `new UtilityBillTriggerHandler().run();` — nothing else |
| Handler | `UtilityBillTriggerHandler` extends `TriggerHandler` | `beforeInsert` / `beforeUpdate` → consumption; `afterInsert` / `afterUpdate` / `afterDelete` → prior-bill re-link |
| Domain | `UtilityBillDomain` | **Pure** in-memory: rollover-aware consumption over `List<Utility_Bill__c>` given a `Map<Id, Decimal>` of register digits passed in. No SOQL, no DML. |
| Service | `UtilityVarianceService` | Orchestrates: load register digits + neighbouring bills via selectors, call the domain, register the prior-bill re-link |
| Service | `UtilityMeterService` | Bulk upsert of meters from the capture screen — **one DML for N meters** |
| Selector | `AssetSelector` (**new**) | `selectMetersByPropertyAssetIds`, `selectRegisterDigitsByIds` |
| Selector | `UtilityBillSelector` (new) | `selectByMeterIds`, `selectPriorByMeterAndReadDate`, `selectRecentForList` |
| Selector | `ChargeLineSelector` (new) | `selectByBillIds` |
| Selector | `MeterAllocationSelector` (new) | `selectByMeterIds` |
| Selector | `VendorContractSelector` (new) | `selectByPropertyAssetIds` |
| Controller | `UtilityMeterController` | Thin. `@AuraEnabled` only; catches → `AuraHandledException` with a fixed generic message, platform detail to `System.debug` — copy `WorkOrderController.cls:16–23` exactly. |
| Controller | `UtilityBillController` | " |
| DTO | inner classes on the controllers | Matching the `WorkOrderController.Row` precedent |
| Batch | `UtilityVarianceAlertBatch` + `UtilityVarianceAlertSchedule` | Only if OQ-10 selects it |

⚠ `AssetSelector.selectRegisterDigitsByIds` is a **trigger-path read performed on the user's behalf** → `WITH SYSTEM_MODE`, justified at its own declaration in the class header. `USER_MODE` throws rather than degrades, and a Metadata-API-deployed custom field arrives with **no FLS for anyone including System Administrator** — inside a trigger that escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the user's own save. `SYSTEM_MODE` lifts CRUD/FLS only; sharing is a separate question, and here it is moot because Asset is ControlledByParent (§0.2).

⚠ 40-character cap on Apex class names — every name above is comfortably inside it, but the test classes (`UtilityVarianceAlertScheduleTest` = 31) should be re-counted before creation.

### 3.2 The variance engine (S6)

Given current bill **B** and prior bill **P**:

```
Usage Variance = (Consumption_B − Consumption_P) × Rate_P
Rate  Variance = (Rate_B        − Rate_P)        × Consumption_B
```

**Invariant, and it holds exactly:**

```
(C_B − C_P)·R_P + (R_B − R_P)·C_B
  = C_B·R_P − C_P·R_P + R_B·C_B − R_P·C_B
  = R_B·C_B − R_P·C_P
  = Total_B − Total_P
```

The two components are additive and reconcile to the raw dollar change with no residual. **A test must assert this equality on decimals** — it is the cheapest possible proof that the decomposition is correct, and it is the one thing that will catch a sign error.

**Where each piece is computed — and why it is split:**

| Piece | Where | Why |
|---|---|---|
| `Consumption__c` | **Apex (before-insert / before-update), stored** | Rollover needs `Meter__r.Register_Digits__c`. A cross-object formula *could* express `IF(Current < Previous, Current + POWER(10, digits) − Previous, Current − Previous)`, but a stored value can be **overridden** for an estimated read, a corrected read or a mid-period meter swap, and it can be audited. A formula can be none of those. |
| `Prior_Utility_Bill__c` | **Apex, stored** | No declarative way to find "the preceding bill for this meter". |
| `Rate_Per_Unit__c`, the three variance fields, `Total_Variance_Pct__c` | **Formula** | Once the two stored inputs exist, formulas are strictly better: correcting a *prior* bill's readings or charges recomputes every downstream variance automatically, with no recompute batch and no staleness. |

⚠ **The subtle bug to design against: a back-dated bill invalidates the stored prior-bill chain.** If bills for Jan and Mar exist and a Feb bill is inserted afterwards, Mar's `Prior_Utility_Bill__c` still points at Jan. The handler must re-link on `afterInsert`, `afterUpdate` (when `Read_Date__c` or `Meter__c` changed) **and `afterDelete`** — a deleted middle bill orphans the pointer just as badly. This is the single most likely defect in S6 and should be a named test.

⚠ **Rollover vs meter swap are different events that look identical.** A rollover (99,980 → 20 on a 5-digit register) and a swap (old meter retired at 87,412, new meter starts at 20) both present as current < previous. Rollover arithmetic applied to a swap produces a fabricated 5-digit consumption spike that will then fire a variance alert. The FSD's own `Service_Identifier__c` ("durable service-point ID; survives meter swaps") is the hint that swaps are real and expected. See OQ-17.

⚠ **Guard division by zero everywhere.** `Rate_Per_Unit__c` divides by `Consumption__c`, which is legitimately zero for a vacant space and null before the first read. `Total_Variance_Pct__c` divides by the prior total. Trash meters have **no consumption at all** by definition (FSD 5.10.3 routes them to S4, but `Utility_Type__c` still offers Trash).

### 3.3 UT-001 hand-off (S7) — the minimal-blast-radius design

**Verified entry point.** The one and only completion path is:

```
lwc/onboardingChecklist  →  OnboardingController.completeTask
                         →  OnboardingService.completeTask(Id taskId, String notes)   (OnboardingService.cls:39)
                         →  TaskSelector.selectForOnboardingCompletion (USER_MODE)
                         →  update t
                         →  OnboardingTaskRollupService.recalc
```

Two things follow that the brief did not anticipate:

1. **`TaskRollupTriggerHandler` is the wrong place.** It is Transaction-scoped: it projects only `Task.Transaction_Deal__c` and calls `TaskRollupService.recalc`. The Onboarding rollup is **not trigger-driven at all** — it is called imperatively from `OnboardingService` line 49.
2. **🔴 Do NOT widen `TaskSelector.selectForOnboardingCompletion`.** It selects exactly `Id, Onboarding__c, Onboarding_Status__c, Status, Description` `WITH USER_MODE` (`TaskSelector.cls:263–271`). Adding `Subject` or `Onboarding_Category__c` to identify the utility task is an **FLS change**: only **one** permission set in the entire repo grants `Task.Onboarding_Category__c` — `DPEG_Task_Edit` (line 111). `USER_MODE` throws rather than degrades, so any persona without that set would get `System.QueryException: No such column` and **the whole onboarding checklist completion feature would break for them**, on a change that looks like it only touches a new module.

**The design that avoids all of it: detect client-side. Zero Apex change.**

`OnboardingController` already returns both signals to the LWC — `ChecklistGroup.category` (line 208) and `ChecklistItem.name = t.Subject` (line 234). So `lwc/onboardingChecklist` already holds, in memory, everything needed to recognise the utility-transfer row. After its existing `completeTask()` promise resolves for a row whose category is `Vendor & Expense Management` and whose subject matches the utility-transfer constant, it opens the capture modal with the Onboarding's `Property_Asset__c`.

- Nothing about `OnboardingService`, `OnboardingController`, `TaskSelector` or the rollup changes. Their tests stay green untouched.
- ⚠ It is still a **behaviour change to a shipped feature** (`onboardingChecklist` gains a post-completion modal) and it **crosses a module boundary** (Onboarding → Utilities). Per the standing rule, that must be confirmed with the user before implementation, not assumed. `lwc/onboardingChecklist/__tests__/onboardingChecklist.test.js` exists and will need a new case plus a check that the *non*-utility completion path still closes silently.
- ⚠ Subject-string matching is brittle (a re-worded checklist item silently kills UT-001). Keep the string in **one exported constant** with a comment pointing at `scripts/seed-onboarding-tasks.apex:37`. See OQ-9 for the durable-marker alternative.
- Second, independent entry point required regardless: a **"Capture Meters" button on the Property Asset record page**, so the register is reachable when no onboarding record exists — which, per §0.5, is the normal case today.

### 3.4 LWC inventory

| Bundle | Type | Notes |
|---|---|---|
| `utilityMeterCapture` | Feature (modal) | One row per `Unit__c` + a "whole building" row; columns per S1. Saves via one imperative Apex call → one DML. |
| `meterRegister` | Feature (list) | Meters for a property, master/sub grouped via `ParentId`. `workOrderList` chrome. |
| `utilityBillList` | Feature (list) | Recent bills + variance pill (uses `c-list-datatable`'s `pill` type, same as `workOrderList`'s SLA pill). |
| `utilityBillVariance` | Presentational | Usage / Rate / Total breakdown on the bill record page. Props in, events out, no Apex. |

- **SLDS 2 design tokens (`--slds-g-*`), not hardcoded colours.** ⚠ `workOrderList` currently hardcodes hex values inline (`#B01818`, `#EBF9F1`, …). Copy its *structure*, not its palette. Run the SLDS linter before deploy.
- **Jest + `@sa11y/jest` required for every new bundle** (ARCHITECTURE §5). ⚠ Note the gap: `workOrderList`, `renewalList` and `rentRoll` have **no** `__tests__` directory at all. The new components must not inherit that.
- ⚠ **`<description>` in a `.js-meta.xml` is capped at 255 characters and ONLY a deploy catches it** — Jest, the SLDS linter and code review all previously passed a 258-character one.
- LDS-first (ARCHITECTURE §5): the bill record page uses `getRecord`; imperative Apex only for the multi-object list and capture-screen writes.

### 3.5 Tests

- **251+ records** for `UtilityBillTriggerHandler`, `UtilityVarianceService`, `UtilityMeterService` per `.claude/rules/bulk-test-rule.md`. None of these objects are `ContentVersion`/`ContentNote`/`ContentDocument`, so the content-publication carve-out does **not** apply and the 251 mandate stands in full.
- Named scenarios beyond bulk: the additive invariant (§3.2); rollover (`prev 99,980 → curr 20`, 5 digits ⇒ 40); **back-dated insert re-links the successor**; **delete of a middle bill re-links**; zero-consumption divide guard; null prior bill (first-ever bill produces no variance, not a spurious 100%).
- **`TestDataFactory` additions only — never `SeeAllData`.** New: `createUtilityMeter`, `createUtilityBill`, `createChargeLine`, `createVendorContract`, `createMeterAllocation`, following the existing `createPropertyAsset` (line 1373) / `createUnit` (line 1415) / `createOnboarding` (line 3041) shape with the `(parentId, Boolean doInsert)` signature.
  ⚠ **Verification gate:** whether `Asset` insert requires `AccountId` or `ContactId` in this org is **unverified** and cannot be checked without org access. If it does, `createUtilityMeter` must chain `createAccount` (line 566) — and that decision is entangled with OQ-1, because whatever Account the factory picks is also the sharing parent.
- ⚠ A targeted `--tests` run executes the **org's** copy of a class — include every new test class in the deploy payload, or a run can silently execute fewer methods than the repo contains and still report 100%.

---

## 4. 🔗 EXECUTION ORDER

1. **`.forceignore` narrowing + isolated Asset dry-run + one-field readback** (§0.1). Hard gate — everything in S1 blocks on it, and it edits a file shared with the two concurrent builds (§5).
2. **OQ-1 (Asset sharing) answered.** It determines `Asset.AccountId` population, the new objects' `sharingModel`, whether sharing rules are needed, and the `TestDataFactory` shape.
3. Asset custom fields → Asset `Utility_Meter` record type → Asset layout/FlexiPage. *(Record type before any Apex that writes its values.)*
4. Custom objects S2 → S3 → S5 → S4, each with fields. `Charge_Line__c`'s master-detail must exist before S2's roll-up summary field.
5. `Prior_Utility_Bill__c` self-lookup, then the variance formulas (they reference it — a formula referencing a missing field fails the deploy).
6. Selectors → Domain → Services → Handler → Trigger → Controllers.
7. `TestDataFactory` additions, then test classes.
8. LWCs + Jest, then FlexiPages that host them.
9. Alerting (only after OQ-10).
10. **HUB FILE EDITS LAST**, consolidated by the main agent across all three concurrent builds (§5).

⚠ Sharing rules, if OQ-1 selects them, **deploy one at a time** on this project.
⚠ A dry-run **skips byte-identical components** and reports them `Unchanged` — a green dry-run on a re-run is not proof anything was validated.
⚠ `numberComponentsDeployed` is a **pre-rollback** tally; "N/N deployed, 0 errors" has been observed on a deploy that rolled back everything via `codeCoverageWarnings`.

---

## 5. HUB FILE REQUESTS

**Nothing in this build edits any file below.** Handed to the main agent for the single consolidated pass across all three concurrent builds.

⚠ **A PermissionSet deploy REPLACES that set's entire `fieldPermissions` collection.** The consolidation must be a single additive edit against the full current file, not three sequential partial deploys — otherwise the last build silently wipes the first two.

### 5.1 `.forceignore` (shared, blocking, must go FIRST not last)

- Delete line 250 `force-app/main/default/objects/Asset/**`.
- Add exact-file ignores for whichever standard `Asset/fields/*.field-meta.xml` fail the isolated dry-run (or delete those files), in the `.forceignore:548–557` surgical style.
- Do **not** attempt a `!` negation — the Account narrative at `.forceignore:231–248` documents it as a proven failure with no error at all.

### 5.2 `applications/Property_Management.app-meta.xml`

- `<tabs>standard-Asset</tabs>` *(standard object — no tab file to create)*
- `<tabs>Utility_Bill__c</tabs>`
- `<tabs>Vendor_Contract__c</tabs>`
- `<tabs>Utilities</tabs>` *(only if OQ-16 selects a dedicated app page)*
- `<actionOverrides>` View → `Utility_Bill_Record_Page` for `Utility_Bill__c`, and → the meter record page for `Asset`
  ⚠ Record pages are assigned **per-app**; this deliberately scopes both pages to Property Management only.

### 5.3 `tabs/` — new files needed

- `Utility_Bill__c.tab-meta.xml`
- `Vendor_Contract__c.tab-meta.xml`
- `Utilities.tab-meta.xml` *(FlexiPage tab, only if OQ-16 selects it)*
- **No** `Asset` tab file — `standard-Asset` is referenced directly.
- `Charge_Line__c` and `Meter_Allocation__c` need **no** tabs (child-only, reached through their parents).

### 5.4 `permissionsets/DPEG_App_PropertyMgmt`

Add `tabSettings` (Visible) for: `standard-Asset`, `Utility_Bill__c`, `Vendor_Contract__c`, and `Utilities` if built. No object/field access — this set grants app + tab visibility only, per its own `<description>`.

### 5.5 `permissionsets/DPEG_PropertyMgmt_Edit`

- `objectPermissions` (C/R/U; delete per OQ-18): **`Asset`** ← the brief is right that no set grants it today; provisioning it is part of this build. Plus `Utility_Bill__c`, `Charge_Line__c`, `Vendor_Contract__c`, `Meter_Allocation__c`.
- `fieldPermissions` `editable=true` for **all 11 new Asset fields** and every new field on the four new objects, **plus the standard Asset fields the register uses**: `Asset.SerialNumber`, `Asset.ParentId`, `Asset.Name`, `Asset.AccountId` (if OQ-1 selects it).
  🔴 A Metadata-API-deployed custom field arrives with **no FLS for any profile, System Administrator included**. Without these entries every `USER_MODE` selector throws `No such column` and every LWC renders empty.
- `recordTypeVisibilities` for `Asset.Utility_Meter`.
- ⚠ Formula and roll-up fields must be `editable=false` — `editable=true` on a non-editable field **will not deploy**. And `lightning-record-edit-form` FLS-checks every key in its payload including programmatic ones, so a non-editable field silently vanishes with a success toast.

### 5.6 `permissionsets/DPEG_PropertyMgmt_View`

Read-only mirror of 5.5 (`readable=true`, `editable=false` throughout).

### 5.7 `permissionsets/DPEG_Admin_Access`

FLS for every new field. This set is the recorded usual casualty of a missed FLS grant on this project.

### 5.8 `permissionsets/DPEG_Apex_Access`

`<apexClass>` entries for every class in §3.1 **and** their test classes.

### 5.9 Manual, non-deployable post-deploy step

Populate **`DPEG_Property_Mgmt_Team`** membership. `groups/DPEG_Property_Mgmt_Team.group-meta.xml` is four lines and carries **no members** — `Group` metadata never does. An empty group means the variance alert sends to nobody, and `GroupNotifier` degrades that to a `System.debug` warning, so **it fails silently**. This must be an explicit go-live checklist item, not an assumption.

---

## 6. ❓ OPEN QUESTIONS — answer before implementation

Ordered by blast radius. OQ-1, OQ-7 and OQ-10 are blocking.

| # | Question | Why it matters |
|---|---|---|
| **OQ-1** 🔴 | **Asset sharing.** `Asset` is `ControlledByParent`; its parent is `AccountId`/`ContactId`, never `Property_Asset__c` (which is Private). Do we (a) set `AccountId` = utility provider and accept that meters inherit Account's **public ReadWrite** OWD; (b) leave `AccountId` blank and risk owner-only visibility; (c) create a per-property Account purely as a sharing parent; or (d) **reject standard Asset** and use a custom `Utility_Meter__c` object with `sharingModel=Private`, contradicting FSD 5.10.3? | Determines the security posture of the entire register, the `TestDataFactory` shape, and whether S1 is even the right object. Option (d) is the only one that lets meter data inherit the property's Private scoping. |
| **OQ-7** 🔴 | **"Register Size" — digit count or modulus?** Is a 5-dial meter `Register_Digits__c = 5` (modulus 100,000) or `Register_Size__c = 100000`? | Gets this wrong and every rollover consumption figure is wrong by orders of magnitude, silently, on the exact numbers the variance alert keys on. |
| **OQ-10** 🔴 | **Alerting — threshold, recipient, channel, timing.** FSD §5.10 has **no** Automation/Alerts subsection despite §5.10.2 promising variance alerts. **Proposal (explicitly a proposal, not spec):** fire when `ABS(Total_Variance_Amount__c) ≥ $250` **AND** `ABS(Total_Variance_Pct__c) ≥ 20%` (both, so small bills don't spam); recipient `DPEG_Property_Mgmt_Team` public group; channel in-app `Messaging.CustomNotification` via the existing `GroupNotifier`; fired by a **scheduled batch** (`UtilityVarianceAlertBatch`, SCOPE 200, send-first-stamp-second, idempotency marker `Variance_Alert_Sent_DateTime__c`) copying the `NdaExpiryAlertBatch` / `CallForOffersAlertBatch` trio — **not** a trigger, because a monthly bill import would fire hundreds of alerts inside one bulk load. ⚠ `GroupNotifier` hardcodes notification type `Acquisitions_Deal_Update` (master label "Acquisitions - Deal Update"), so a PM alert would arrive **branded as an Acquisitions notification** unless a `Property_Mgmt_Update` notiftype is added and the type is parameterised. ⚠ If **email** is wanted instead, note there is **zero Apex outbound email in this org** — the only existing path is a workflow `<alerts>` + `EmailTemplate` fired by a Flow. | Nothing in S6/S8 alerting can be built without these four answers. |
| OQ-2 | **Utility provider Accounts.** Who creates them, do they need an Account record type (only `Broker_Firm` and `Investor_Entity` exist), and is a lookup wanted at all given the PM precedent stores vendors as Text (`Work_Order__c.Vendor__c`)? | Governance + a possible new Account record type, which is itself a hub-adjacent change. |
| OQ-3 | **`Asset.Name` convention.** Name is a required Text(255) and cannot be a formula. Proposal: `"<Utility Type> · <Serial> · <Suite or Building>"`, composed by the capture screen. Confirm. | Every meter row's readability in every list, lookup and report. |
| OQ-4 | **Lookup delete behaviour.** `SetNull` proposed for all `Property_Asset__c` / `Unit__c` / `Meter__c` lookups. `Restrict` would prevent orphaning but this repo's field headers forbid it. Confirm SetNull is acceptable. | Deleting a Unit would silently orphan its meters. |
| OQ-5 | **Naming deviations from ARCHITECTURE §1.** §1 says a relationship field's API name **is** the target object's name, with a role-name exception stated only for `User`/`Contact`. This design proposes `Provider__c` → `Account` and `Meter__c` → `Asset` on business-meaning grounds (`Asset__c` would read as a sibling of `Property_Asset__c` and mislead). Approve the deviation and update ARCHITECTURE.md §1's exception clause in the same PR, or rename to `Account__c` / `Asset__c`. | A convention deviation shipped without a doc update becomes the next reader's trap. |
| OQ-6 | **`Paid_By_Reason__c`** — free Text(255), or a picklist of the reasons management pays (Vacant Space, Common Area, Landlord Obligation, Shared Meter, Other)? | A picklist is reportable; text is not. FSD says only "reason management pays". |
| OQ-8 | **`Utility_Bill__c.Meter__c` and `Meter_Allocation__c.Meter__c` — lookup or master-detail?** Whether a custom object may be master-detail-child of standard `Asset` at API 67.0 is **unverified** (no MCP, no org access). Lookup is proposed as the safe default; it forgoes roll-up summaries onto the meter and any cascade delete. | Determines whether "allocations sum to 100%" and "bills per meter" can be declarative. If master-detail is wanted, treat the XML shape as a gate: one-field dry-run + readback, never a guess. |
| OQ-9 | **UT-001's trigger task does not exist on new properties** (§0.5). Options: (a) build an onboarding task template (out of 5.10 scope — it is a 5.1 gap); (b) accept UT-001 demos only on Park North; (c) add a durable `Task` marker field instead of subject-string matching. | Without an answer, UT-001 cannot be demonstrated on a real new property regardless of how well 5.10 is built. |
| OQ-11 | **Reading precision.** `Number(16,4)` proposed for `Previous_Reading__c` / `Current_Reading__c`. Real meter reads are usually whole numbers, but gas/water sometimes carry a multiplier. | Decimal places are painful to change after data lands. |
| OQ-12 | **`Charge_Line__c.Charge_Type__c` restricted or not?** FSD says components "appear irregularly". **Restricted picklists ARE enforced by DML on this project (measured 4×)**, so an import carrying a component name not in the list **hard-fails the row**. Proposal: unrestricted; alternative is restricted + `Other` + a `Charge_Type_Other_Label__c` text field. | The difference between a monthly import that absorbs a new charge component and one that rejects the bill. |
| OQ-13 | **`Vendor_Contract__c` fields.** The FSD gives this object one sentence and no field table. Confirm the seven proposed fields, the `Service_Type__c` value list (FSD names only Trash and Maintenance), and whether it needs `Paid_By__c`, a status, or a payables account number. | Everything in S4 beyond `Monthly_Amount__c` and `Service_Type__c` is inference. |
| OQ-14 | **Do allocations have to sum to 100%?** Not in the FSD. With a lookup (OQ-8) it cannot be a roll-up and needs Apex domain validation. | Adding it unasked is scope creep; omitting it permits silently under/over-allocated meters. |
| OQ-15 | **Are `Meter_Allocation__c` records effective-dated?** Not in the FSD. Without dates, a historical bill cannot be re-allocated on the basis in force at the time. | Allocations demonstrably change (vacancy, turnover) — this is a data-model decision that is expensive to retrofit. |
| OQ-16 | **Where does the UI live** — components on the existing `Property_Asset_Record_Page`, or a dedicated `Utilities` app page + tab? | Changes the tab/app hub requests in §5.2–5.3. |
| OQ-17 | **How is a meter swap signalled?** A swap and a rollover are arithmetically identical (current < previous), and rollover math on a swap fabricates a huge consumption spike that then fires a variance alert. The FSD's `Service_Identifier__c` ("survives meter swaps") implies swaps are expected. Options: a `Meter_Swapped__c` checkbox on the bill, retiring the old Asset and creating a new one, or a manual `Consumption__c` override. | The most likely source of false variance alerts in production. |
| OQ-18 | **Delete permission** on the four new objects and on `Asset` for `DPEG_PropertyMgmt_Edit`. | Meter history is the point of the register; casual delete undermines it. |

---

## 7. 📝 PROMPTS FOR SPECIALIST AGENTS

Not to be dispatched until Gate 1 confirmation **and** OQ-1, OQ-7, OQ-10 are answered.

### 🔵 PROMPT FOR salesforce-admin

```
Build the declarative half of FSD 5.10 Utility & Meter Tracking, per
agent-output/design-utility-meter.md sections 2 and 4.

BLOCKING PREREQUISITE — do this first and stop if it fails:
force-app/main/default/objects/Asset/** is force-ignored at .forceignore:250, so
NOTHING you write under objects/Asset/ will deploy, and it will report success.
Read .forceignore lines 220-250 (the Account narrative) before touching it — it
documents this exact failure and two failed fixes, including that a gitignore-style
"!" negation CANNOT rescue a path under a dir/** ignore. Remove line 250, run an
isolated check-only dry-run with Asset ALONE in the payload, and surgically
exact-file-ignore (or delete) whichever retrieved standard Asset/fields/*.field-meta.xml
files fail — matching the style at .forceignore:548-557. Then deploy ONE custom
Asset field and READ IT BACK before generating the rest.

Then build, in this order:
1. 11 custom fields on Asset (design section 2, S1 table). Reuse standard
   SerialNumber (meter number) and ParentId (master/sub meter). Do NOT edit
   standard Asset.Status — use the custom Service_Status__c.
2. Asset record type Utility_Meter, deployed BEFORE any Apex.
3. Utility_Bill__c, Charge_Line__c, Meter_Allocation__c, Vendor_Contract__c with
   the fields listed in S2-S5. Charge_Line__c -> Utility_Bill__c is master-detail,
   reparentable=false. Consumption__c and Prior_Utility_Bill__c are STORED and
   Apex-written — create them as plain fields, not formulas.
4. The roll-up summary and the four variance formulas, AFTER Prior_Utility_Bill__c
   exists. Guard every division against null/zero.
5. Asset layout / FlexiPage additions, AFTER the fields land.

CONSTRAINTS:
- API version 67.0 (sfdx-project.json sourceApiVersion).
- ARCHITECTURE.md §1 naming: currency totals take the "Amount" suffix, rates name
  their unit, dates take "Date" (never "DateTime" on a date-only field), "_Pct__c"
  for a percent Number. No bare Rent__c / Cost__c / Fee__c style names.
- Restricted picklists on this project ARE enforced by DML. Charge_Line__c.
  Charge_Type__c is deliberately UNRESTRICTED (see OQ-12).
- Set <sharingModel> per the answer to OQ-1.
- Do NOT create validation rules, required-field flags, approval processes, or
  reports — none are in the FSD.
- Do NOT edit applications/Property_Management.app-meta.xml, any permissionsets/*,
  or any tabs/* — list what you need in a HUB FILE REQUESTS section instead; two
  other builds are running concurrently.
- .claude/rules/salesforce-global-rule.md: run the per-type skill/API-context loop
  for each metadata type. The salesforce-api-context MCP is NOT configured in this
  repo — record mcp=unavailable after a real attempt and fall back to the skill.
- Do not deploy. Create metadata files only.
```

### 🟢 PROMPT FOR salesforce-developer

```
Build the programmatic half of FSD 5.10 Utility & Meter Tracking, per
agent-output/design-utility-meter.md section 3. Do not start until the admin
agent's Asset fields and the Utility_Meter record type exist.

APEX (layering map in design section 3.1, enforced by .claude/rules/apex-layering-rule.md):
- UtilityBillTrigger (one line) -> UtilityBillTriggerHandler extends TriggerHandler
- UtilityBillDomain: PURE rollover/consumption math over List<Utility_Bill__c>,
  register digits passed IN as a Map. Zero SOQL, zero DML.
- UtilityVarianceService, UtilityMeterService (bulk, one DML for N meters)
- AssetSelector (new), UtilityBillSelector, ChargeLineSelector,
  MeterAllocationSelector, VendorContractSelector — ALL SOQL lives here.
  AssetSelector.selectRegisterDigitsByIds is a trigger-path read on the user's
  behalf -> WITH SYSTEM_MODE, justified at its own declaration in the class header
  (ARCHITECTURE.md §2). Everything else WITH USER_MODE.
- UtilityMeterController / UtilityBillController: thin, @AuraEnabled only, mapping
  failures to AuraHandledException with a fixed generic message and platform detail
  to System.debug. Copy WorkOrderController.cls lines 16-23 exactly.

VARIANCE (design 3.2):
  Usage Variance = (Consumption_B - Consumption_P) * Rate_P
  Rate  Variance = (Rate_B - Rate_P) * Consumption_B
These are exactly additive to (Total_B - Total_P). Assert that invariant in a test.
Apex writes Consumption__c (rollover-aware) and Prior_Utility_Bill__c; the variance
fields themselves are admin-built formulas.
CRITICAL: re-link Prior_Utility_Bill__c on afterInsert, afterUpdate (when Read_Date__c
or Meter__c changed) AND afterDelete — a back-dated or deleted bill orphans the chain.

UT-001 (design 3.3) — MINIMAL BLAST RADIUS, READ THIS:
Do NOT touch TaskRollupTriggerHandler (Transaction-scoped only). Do NOT widen
TaskSelector.selectForOnboardingCompletion — it is USER_MODE with 5 fields, and only
ONE permission set in the repo (DPEG_Task_Edit) grants Task.Onboarding_Category__c,
so adding it would throw "No such column" and break onboarding completion for every
persona lacking that set. OnboardingController ALREADY returns category (line 208)
and Subject as item.name (line 234) to the LWC, so detect entirely client-side in
lwc/onboardingChecklist after its existing completeTask() promise resolves. Zero
Apex change. Keep the subject string in one exported constant referencing
scripts/seed-onboarding-tasks.apex:37. Also add a standalone "Capture Meters" entry
point on the Property Asset record page.

LWC: utilityMeterCapture, meterRegister, utilityBillList, utilityBillVariance.
Copy the STRUCTURE of lwc/workOrderList (lightning-card + slot="title" .hdr/.hdr-icon/
.hdr-title with a live count, c-list-datatable with column-widths-mode="fixed" and
hide-checkbox-column, slds error block with role="alert", slot="footer" .view-all-footer
with NavigationMixin). Do NOT copy its hardcoded hex colours — use SLDS 2 design
tokens (--slds-g-*) and run the SLDS linter. Note: the .lv-* classes named in some
briefs do NOT exist in any PM bundle. If you add datatable row actions, read
event.detail.row.actionName — event.detail.action.name arrives as the raw
{fieldName:...} object and never matches. Keep every .js-meta.xml <description>
under 255 characters (only a deploy catches an overrun).

TESTS: 251+ records for the handler and both services (.claude/rules/bulk-test-rule.md;
no content objects are involved so no carve-out applies). Additive TestDataFactory
methods only, following the createPropertyAsset / createUnit (parentId, doInsert)
shape. Never SeeAllData. Named cases: the additive variance invariant; rollover
(prev 99,980 -> curr 20 at 5 digits = 40); back-dated insert re-links the successor;
delete of a middle bill re-links; zero-consumption divide guard; first-ever bill
produces no variance. Jest + @sa11y/jest for every new bundle. Verify whether Asset
insert requires AccountId/ContactId in this org before finalising the factory.

Do not deploy. Do not edit permissionsets/*, tabs/*, or Property_Management.app-meta.xml.
```
