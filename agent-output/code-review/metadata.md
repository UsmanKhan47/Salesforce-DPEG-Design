# Metadata Code Review — Custom Field Naming (§1) + FLS/Descriptions

**Review date:** 2026-07-21
**Reviewer:** salesforce-code-review subagent
**Scope:** Custom FIELD API-name conformance to ARCHITECTURE.md §1 rules 1–9; permission-set FLS stubs (light); custom-object `<description>` coverage. Apex/LWC/tests/flows/flexipages/scripts/profiles excluded.
**Method:** Enumerated all custom field-meta files by `<type>` via grep (Checkbox 38, Currency 60, DateTime 14, Date 54, Text/Number/LongText/Html 219), sample-read every field flagged below. 33 custom objects, ~460 custom fields surveyed.

---

## Headline

§1 field-naming conformance **HOLDS within the 33 custom objects** — every field the §1 repair claims it fixed is verified fixed in the repo (see "Verified clean" below). The drift that remains lives almost entirely on **custom fields attached to STANDARD objects** (Opportunity, Lead, Contact, User, Activity), which the 2026-07-15 audit ("463 custom fields across the 33 custom objects") **never had in scope**. One in-scope custom-object miss also exists (`Transaction__c.EM_Wired__c`, rule 9b).

No CRITICAL metadata defects. Rule 9(a) — the one hard-prohibition tier (Text/Number field named identically to a custom object, camouflaged as a lookup) — **holds with zero violations**.

---

## 🔴 CRITICAL

✅ None. Rule 9(a) holds: all 33 object-named field files are Lookup/MasterDetail; no Text/Number field impersonates an object. The `Unit__c` Text→`Unit_Label__c` fix is confirmed (only `Rent_Step__c.Unit__c` remains as the real MasterDetail; no `Work_Order__c.Unit__c` / `Lease_Renewal__c.Unit__c` Text fields).

---

## 🟡 WARNING

### W1 — Four DateTime fields carry a `_Date` suffix (Rule 6 — "Never suffix a DateTime field with Date")
This **contradicts the doc's blanket claim** ("Rule 6 — ✅ done … all 8 `_Date`-suffixed DateTime fields … verified absent"). The claim holds only because the audit was custom-objects-only; these four are on standard objects and were never counted.

| File | `<type>` | Issue | Fix |
|------|----------|-------|-----|
| `objects/Opportunity/fields/UW_Approval_Date__c.field-meta.xml` | DateTime | name asserts date-only | → `UW_Approval_DateTime__c` |
| `objects/Opportunity/fields/LOI_Prep_Approval_Date__c.field-meta.xml` | DateTime | name asserts date-only | → `LOI_Prep_Approval_DateTime__c` |
| `objects/Opportunity/fields/Contract_Executed_Date__c.field-meta.xml` | DateTime | "Day 0 trigger field"; note the sibling `Transaction__c.Contract_Executed_Date__c` **is** a true Date — same name, two types across objects | → `Contract_Executed_DateTime__c` |
| `objects/Lead/fields/First_Seen_Date__c.field-meta.xml` | DateTime | "starts 90-day broker protection window" — a DateTime masquerading as Date under a legally-meaningful window calc is a latent-bug surface | → `First_Seen_DateTime__c` |

Real risk: a report-builder or dev reading `*_Date` will assume no time component and can mishandle timezone/rounding. All four hold data (window anchors, Day-0 trigger) → rename needs the additive backfill pattern, not an in-place edit.

### W2 — `Transaction__c.EM_Wired__c` is a Text money-display formula named as a Boolean (Rule 9b — name must not assert a type it lacks)
`objects/Transaction__c/fields/EM_Wired__c.field-meta.xml` — `<type>Text</type>`, formula returns a formatted string (`"$5M"` / `"$500K"`). The name reads as a rule-4 boolean past-participle ("was EM wired?"), and the object also has `EM_Wired_Date__c` (a real Date), so a reader will assume `EM_Wired__c` is the flag and `EM_Wired_Date__c` its timestamp — both wrong. This is an **in-scope custom-object** miss of the rule-9 sweep. Fix: rename to a display-intent name, e.g. `EM_Wired_Display__c` / `Earnest_Money_Display__c`.

### W3 — Five Checkbox fields violate Rule 4 (Boolean must be `Is_`/`Has_` or `<Subject>_<PastParticiple>`) — all on standard objects
| File | Current name | Fix |
|------|--------------|-----|
| `objects/User/fields/Deal_Driver__c.field-meta.xml` | bare noun phrase | `Is_Deal_Driver__c` |
| `objects/Opportunity/fields/Initiate_Underwriting__c.field-meta.xml` | imperative verb (action checkbox) | `Is_Underwriting_Initiated__c` (or accept as action-trigger convention) |
| `objects/Opportunity/fields/Bundle_LOI__c.field-meta.xml` | verb/noun phrase | `Is_Bundle_LOI__c` / `Has_Bundle_LOI__c` |
| `objects/Contact/fields/NDA_On_File__c.field-meta.xml` | prepositional phrase | `Has_NDA_On_File__c` |
| `objects/Lead/fields/Duplicate_Flag__c.field-meta.xml` | `_Flag` suffix, bare noun | `Is_Duplicate__c` |

Pre-existing, out of the audit's stated scope; naming-clarity only, no functional break.

### W4 — `Lead.Days_in_System__c` — Rule 2 lowercase segment
`objects/Lead/fields/Days_in_System__c.field-meta.xml` — segment `in` starts lowercase. Same defect class as the fixed `Days_on_Market__c`, but on a standard object so it was never swept. Fix: `Days_In_System__c`. (Only lowercase-segment field remaining in the entire repo — every other one is fixed.)

---

## 🟢 SUGGESTION

- **`Activity.Verified_At__c` (DateTime)** — Rule 9 wants a `_DateTime` suffix; inconsistent with `Wire__c.Verified_DateTime__c` (correct). → `Verified_DateTime__c`.
- **Borderline Rule 4 checkboxes:** `Opportunity.Underwriting_Complete__c` ("Complete" is an adjective, not the past-participle "Completed"); `Activity.Conditional__c` and `Task_Group_Def__mdt.Conditional__c` (bare adjective). All read clearly as booleans; low value to churn.
- **`Contract_Review__c.Latest_Version__c` (Number)** — a running count named like a boolean/identifier; Rule 9 prefers `_Count`/`_Number`. Description + label ("Latest Version #") mitigate. → `Version_Count__c`.
- **Date-only fields missing the `Date` suffix (Rule 6, soft — "Deadline"/"Due"/"Checkin" already convey date):** `Disposition__c.Next_Broker_Checkin__c`, `Disposition__c.Submission_Deadline__c`, `LOI__c.Counter_Response_Due__c`, `Transaction__c.Feasibility_Deadline__c`, `Opportunity.Broker_First_Seen__c`.
- **Object descriptions: 22 of 33 custom objects have no `<description>`** (matches the doc's stated count exactly — no drift). The 11 that DO: Work_Order, Work_Order_Activity, Renewal_Activity, PSA_Version, Lease, Lease_Renewal, Lease_Inquiry, Lease_Activity, Deal_Message, Broker_Assignment, Critical_Date. Documentation gap, not a defect.

---

## Verified clean — do NOT re-flag (documented exceptions & completed §1 repair)

- **Rule 9 quoted-deal-term Text exceptions** — all carry justifying `<description>`s, compliant with rule 9 exception (3):
  - `Lease_Inquiry__c.Base_Rent__c` (Text, desc: `"$34.00 / sq ft NNN"`)
  - `Lease_Inquiry__c.TI_Allowance__c` (Text)
  - `Lease_Renewal__c.Current_Rent__c` (Text, desc: `"$26.00 / sq ft NNN"`)
- **§1 custom-object repair verified in-repo:**
  - Booleans renamed & present: `Is_Untouched__c` (WO), `Is_Non_Responsive__c` / `Has_Renewal_Option__c` (Lease_Renewal), `Is_Past_Target__c` (Onboarding), `Is_Non_Expiring__c` (NDA), `Is_Earnest_At_Risk__c` / `Is_Wire_Approval_Due__c` (Transaction).
  - `Readiness_Score__c` (Number formula, was `Is_Ready__c`); `Occupied_Pct__c` (Number formula, was `Occupied_Flag__c`).
  - `Lease_Term_Months__c` / `Free_Rent_Months__c` (Number, was Text; description cites rule 9).
  - `Unit_Label__c` on Work_Order & Lease_Renewal (was Text `Unit__c`).
  - No old lowercase-cased duplicates remain (`Days_on_Market__c`, `Cash_on_Cash_Return__c`, `Projected_Value_at_Peak__c` all gone) — clean in-place re-casing, no old/new pairs.
- **`Disposition__c.Package_Sent__c`** — Date named like a boolean past-participle, **no description**. This is the **documented known-open** item (§1: "still open — not in the §1 repair scope"). Confirmed present as stated; NOT a new finding.

---

## Permission sets (light)

Clean. Grepped the 8 team-owned permission sets for the pre-repair field names (`Untouched__c`, `Non_Responsive__c`, `Past_Target__c`, `Never_Expires__c`, `Renewal_Option__c`, `Earnest_At_Risk__c`, `Wire_Approval_Due__c`, `Is_Ready__c`, `Occupied_Flag__c`, `Lease_Term__c`, `Free_Rent__c`, plus the lowercase-cased trio): **zero stale stubs** — every reference is to the NEW renamed field (e.g. `Transaction__c.Is_Earnest_At_Risk__c`, `Work_Order__c.Is_Untouched__c`), so the permission sets were correctly repointed. No `Unit__c` Text-field FLS grants. No obvious FLS on a required/MasterDetail field surfaced in the light pass. (The ~123 stale `<fieldPermissions>` stubs the doc mentions live in `profiles/*` which are `.forceignore`d — out of scope, not audited.)

---

## Wave-a re-casing files — committed vs dangling

**Status: DANGLING (uncommitted working-tree modifications).** Per the session git snapshot these are `M` (modified, not staged, not committed):
- `objects/Disposition__c/fields/Days_On_Market__c.field-meta.xml`
- `objects/Opportunity/fields/Cash_On_Cash_Return__c.field-meta.xml`
- `objects/Underwriting__c/fields/Cash_On_Cash_Return__c.field-meta.xml` (the Opportunity + Underwriting twins both present)
- `objects/Property_Asset__c/fields/Projected_Value_At_Peak__c.field-meta.xml`
- 3 matching `objectTranslations/*` files (Days_On_Market, Projected_Value_At_Peak, Cash_On_Cash_Return)

The corrected casing is present in the repo (verified: `Days_On_Market__c` in the Number set; no lowercase survivors). **Caveat for deployment (out of this review's scope):** per the doc's own Rule 2 finding, a case-only rename is a Metadata-API no-op — it will not re-case the field in the org without a delete-and-recreate. The repo TEXT is correct; the org effect is a separate devops concern.

---

## Verdict (this metadata slice)

**APPROVED WITH WARNINGS.** §1 conformance is genuinely complete inside the 33 custom objects and the documented exceptions check out. The residual drift is a scoped gap — standard-object custom fields (never in the audit) plus one custom-object rule-9b miss (`EM_Wired__c`) — all naming-clarity defects with no functional break, none blocking. Recommend a follow-up "standard-object custom-field naming" sweep (mirrors the §1 program's scope boundary) and correcting the doc's blanket "Rule 6 verified absent" claim, which the four DateTime-`_Date` fields falsify.
