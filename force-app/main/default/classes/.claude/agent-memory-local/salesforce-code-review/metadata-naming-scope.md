---
name: metadata-naming-scope
description: The §1 field-naming repair was scoped to the 33 CUSTOM objects only — naming drift on custom fields attached to STANDARD objects is out-of-scope pre-existing debt, not a regression; verified-clean §1 fields not to re-flag
metadata:
  type: feedback
---

The ARCHITECTURE.md §1 field-naming repair audited **"463 custom fields across the 33
custom objects"** — it explicitly EXCLUDED custom fields on **standard** objects
(Opportunity, Lead, Contact, User, Activity, plus `__mdt`).

**Why it matters:** §1 conformance genuinely HOLDS inside the 33 custom objects (verified
2026-07-21), but real rule-2/4/6/9 drift persists on standard-object custom fields. Treat
that drift as **out-of-scope pre-existing debt → WARNING/SUGGESTION, never CRITICAL or a
regression**. The doc's blanket "Rule 6 — verified absent" claim is the one that
over-reaches: four DateTime fields still carry a `_Date` suffix, all on standard objects —
`Opportunity.UW_Approval_Date__c`, `Opportunity.LOI_Prep_Approval_Date__c`,
`Opportunity.Contract_Executed_Date__c`, `Lead.First_Seen_Date__c`.

**How to apply:**
- Standard-object naming misses to expect (don't treat as new): rule-4 checkboxes
  `User.Deal_Driver__c`, `Opportunity.Initiate_Underwriting__c`, `Opportunity.Bundle_LOI__c`,
  `Contact.NDA_On_File__c`, `Lead.Duplicate_Flag__c`; rule-2 `Lead.Days_in_System__c`;
  rule-9 `Activity.Verified_At__c` (should be `_DateTime`).
- **One in-scope custom-object miss** worth a real WARNING: `Transaction__c.EM_Wired__c` —
  a Text money-display *formula* (`"$5M"`) named like a rule-4 boolean past-participle, and
  the object also has a real `EM_Wired_Date__c`. Rule 9(b) type-assertion trap the sweep missed.
- **Verified clean — do NOT re-flag:** the quoted-deal-term Text exceptions
  (`Lease_Inquiry__c.Base_Rent__c`/`.TI_Allowance__c`, `Lease_Renewal__c.Current_Rent__c`)
  all carry justifying `<description>`s; `Disposition__c.Package_Sent__c` (Date-named-boolean,
  no description) is the doc's documented known-OPEN item, not a new finding; `Readiness_Score__c`,
  `Occupied_Pct__c`, `Lease_Term_Months__c`, `Unit_Label__c` renames are all present and correct.
- Rule 9(a) (Text/Number named identically to a custom object) is the only CRITICAL-tier field
  rule and it HOLDS repo-wide — all 33 object-named field files are Lookup/MD.
- Object `<description>` coverage: 11 set / 22 unset of 33 — matches the doc; SUGGESTION only.
- Team-owned permission sets have NO stale stubs for §1-deleted fields (refs were repointed to
  the new names). The ~123 stubs the doc cites are in `profiles/*` (`.forceignore`d) — not ours.

Related: [[review-scope-and-false-positives]]
