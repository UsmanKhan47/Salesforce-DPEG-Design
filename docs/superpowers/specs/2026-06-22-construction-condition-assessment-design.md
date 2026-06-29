# Construction Condition Assessment (restructure of Construction Feasibility Review)

**Date:** 2026-06-22
**Status:** Approved (design)

## Goal

Rework the existing `Construction_Feasibility_Review__c` in place into a **Construction Condition
Assessment**: new stage path, a domain-accurate field set, and a tab-per-stage record page. API name
stays the same, so the auto-create trigger (Commercial Opp → *Construction Review*), Deal Summary
card, permission set, and tab keep working. Extends [[development-construction-review-build]].

## Relabel
- Object label "Construction Feasibility Review" → **Construction Condition Assessment**
  (plural "Construction Condition Assessments"); API name + `CFR-{0000}` numbering unchanged.
- Path `Construction_Feasibility_Path` masterLabel → **Construction Condition Assessment Path**.

## Stages (`Stage__c`, restricted)
`Requested` (default) → `Site Visit` → `Condition Assessment` → `Cost Estimate` → `Share Opinion`
→ `Completed`. Old values (Scope & Cost Review, GC / Vendor Proposals, Opinion to Acquisition,
Go / Conditional, No-Go) removed. Path step + guidance per stage.

## Fields

**Remove (no real data):** Pad_Site_Readiness__c, Permitting_Status__c, Hard_Cost_Estimate__c,
Entitlement_Status__c, Bids_Received__c, Bids_Target__c, GC_Scope__c, General_Contractor__c,
Est_Cost_Impact__c.

**Keep:** Opportunity__c, Stage__c, Deal_Type__c, Asset_Type__c, Summary__c.

**Add 25** (grouped by stage = record-page tab):

| Stage tab | Fields (type) |
|-----------|---------------|
| Site Visit | `Site_Visit_Scheduled_Date__c` (Date), `Site_Visit_Completed_Date__c` (Date), `Site_Visit_By__c` (Text 120), `Site_Access_Notes__c` (Long Text), `Site_Visit_Photos__c` (URL) |
| Condition Assessment | `Roof_Condition__c` (Good/Fair/Poor/Needs Replacement), `Roof_Age_Years__c` (Number 3,0), `Structural_Site_Settling__c` (None/Minor/Significant), `HVAC_MEP_Condition__c` (Good/Fair/Poor/Needs Replacement), `Parking_Pavement_Condition__c` (Good/Fair/Poor), `Building_Envelope_Facade__c` (Good/Fair/Poor), `Addition_Work_Required__c` (Checkbox), `Addition_Work_Description__c` (Long Text), `Upgrades_Required__c` (Long Text), `Code_Compliance_Concerns__c` (Long Text), `Overall_Condition_Rating__c` (Excellent/Good/Fair/Poor) |
| Cost Estimate | `Estimated_Roof_Cost__c`, `Estimated_MEP_Cost__c`, `Estimated_Upgrade_Cost__c`, `Estimated_Addition_Cost__c` (Currency ×4) |
| Share Opinion | `Recommendation__c` (Go/Conditional/No-Go), `Opinion_Summary__c` (Long Text), `Conditions__c` (Long Text, label "Conditions (if Conditional)"), `Estimated_Timeline_Impact__c` (Text 255), `Opinion_Delivered_Date__c` (Date) |

## Record page
Rebuild tabs per the established pattern: every stage is a tab in path order. `Site Visit`,
`Condition Assessment`, `Cost Estimate`, `Share Opinion` show their fields in **2-column**
fieldSections; `Requested` and `Completed` show a `flexipage:richText` guidance line. `Details`
and `Notes & Attachments` kept.

## Dependents
- Permission set `DPEG_Acquisitions`: remove the 9 old field FLS, add FLS for the 25 new fields
  (formula/keep fields unchanged).
- Deal Summary LWC (`dealDocStatus.js`): add the new Construction stages to the stage→color map.
- No Apex changes (service still inserts at `Requested`; controller still reads `Stage__c`).

## Delivery
Deploy schema + path + flexipage + permset + LWC, dry-run validating; then a destructive delete of
the 9 old fields (after nothing references them). Verify on `DPEG-Acq-3`. Not a git repo — spec not committed.

---
*Note: the separately-requested **LOI stages + approval process** is parked and will be built right
after this, per the earlier design (manual submit, single named approver, approve→LOI Submitted /
reject→Underwriting).*
