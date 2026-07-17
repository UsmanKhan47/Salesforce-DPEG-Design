/**
 * Selector for the custom Unit__c object. Encapsulates ALL SOQL against Unit__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live in
 * Selector classes. Nothing else queries that object.").
 *
 * P4 CLEANUP WAVE F2 (PM) — Module B built the PM selectors but missed RentRollController.
 * This selector relocates the single Unit__c read that backs the rentRoll LWC on the
 * Property Asset record page (PM + Disposition apps).
 *
 * ⚠ Unit__c is the OBJECT — not the retired text field. Unit__c/Rent_Step__c are a
 * read-only mirror of Yardi; Rent_Step__c.Unit__c is a Master-Detail to this object.
 * (Lease_Renewal__c/Work_Order__c carry a separate Unit_Label__c TEXT field — unrelated;
 * the old `Unit__c` text fields on those objects were retired. Do not conflate them.)
 *
 * MODE — `WITH USER_MODE` (API 66). Unit__c is a custom object; P3 measured the
 * custom-field FLS gap = 0 across the org (p4-selector-design.md §5), so USER_MODE
 * enforces the running user's sharing + FLS without breaking the read. There is no
 * guest path for the rent roll, so no SYSTEM_MODE appears here.
 *
 * SUBQUERY — the Rent_Steps__r child rows are pulled INSIDE the Unit__c query, not via
 * a separate selector. A relationship subquery is one SOQL statement scoped to Unit__c;
 * splitting it into a Rent_Step__c selector would (a) turn one query into an N+1 or a
 * separate parent-keyed query the caller must re-stitch, and (b) mis-attribute Unit__c's
 * own child read to another object. The single WITH USER_MODE on the outer query governs
 * the subquery too (a subquery cannot carry its own WITH clause).
 *
 * FIELD SET IS DELIBERATE — mirrors exactly what RentRollController.getRentRoll maps into
 * its DTOs (17 Unit__c fields incl. LastModifiedDate for the last-synced stamp, plus the
 * 7 Rent_Step__c fields). Narrowing it would reintroduce a
 * "row retrieved via SOQL without querying the requested field" SObjectException.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (P4 pilot selector template)
 * @see agent-output/p4-selector-design.md (§2 — RentRollController was not inventoried)
 */
public with sharing class UnitSelector {

    /**
     * Units for one Property Asset, with each Unit's Rent_Steps__r rows nested and
     * ordered — backs RentRollController.getRentRoll. Units come back ordered by
     * Suite_Number__c (text) ASC NULLS LAST; the Rent_Steps__r subquery is ordered by
     * Sort_Order__c ASC NULLS LAST, matching the original inline query exactly.
     *
     * @param propertyAssetId Property_Asset__c Id to read units for.
     * @return Units under the asset (each with its Rent_Steps__r populated), or an empty
     *         list when the input is null or the asset has no units (never null).
     * @example
     * List<Unit__c> units = UnitSelector.selectByPropertyAssetId(assetId);
     */
    public static List<Unit__c> selectByPropertyAssetId(Id propertyAssetId) {
        if (propertyAssetId == null) {
            return new List<Unit__c>();
        }
        return [
            SELECT Id, Suite_Number__c, Tenant_Name__c, Status__c, Square_Feet__c,
                   Lease_Start__c, Lease_End__c, Current_Monthly_Rent__c, Current_Rent_PSF__c,
                   Asking_Rent_PSF__c, Estimated_NNN_PSF__c, NNN_Property_Tax__c,
                   NNN_Insurance__c, NNN_CAM__c, NNN_Monthly_Total__c, NNN_PSF__c,
                   LastModifiedDate,
                   (SELECT Period_Start__c, Period_End__c, Period_Label__c, Monthly_Rent__c,
                           Rent_PSF__c, Type__c, Note__c
                    FROM Rent_Steps__r
                    ORDER BY Sort_Order__c ASC NULLS LAST)
            FROM Unit__c
            WHERE Property_Asset__c = :propertyAssetId
            WITH USER_MODE
            ORDER BY Suite_Number__c ASC NULLS LAST
        ];
    }
}
