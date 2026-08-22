/**
 * Selector for `Vendor_Contract__c` - encapsulates ALL SOQL against the fixed-monthly
 * vendor arrangements (trash, maintenance) that have no meter and no consumption, per
 * ARCHITECTURE.md section 2 and `.claude/rules/apex-layering-rule.md`.
 *
 * FSD 5.10.3 gives this object one sentence: it is "the fixed-monthly shape for trash and
 * maintenance, which have no meter and no consumption". It therefore has NO variance
 * decomposition and NO consumption arithmetic - it is deliberately outside the utility bill
 * pipeline, and nothing in `UtilityBillDomain` or `UtilityVarianceAlertBatch` touches it.
 *
 * MODE - USER_MODE throughout: every read here backs a list a user opened.
 *
 * SHARING - `with sharing`. `Vendor_Contract__c` is Private OWD in its own right (it is not
 * a detail of the meter), so sharing is the real access control on these rows.
 */
public with sharing class VendorContractSelector {

    /**
     * Vendor contracts at the given properties.
     *
     * @param propertyAssetIds Property_Asset__c Ids; null/empty returns an empty list.
     * @param activeOnly       When true, excludes contracts whose End_Date__c is in the
     *                         past. A null End_Date__c is treated as open-ended and is
     *                         always included - an absent end date means "still running",
     *                         not "expired".
     * @return Matching contracts ordered by property then service type; never null.
     */
    public static List<Vendor_Contract__c> selectByPropertyAssetIds(
            Set<Id> propertyAssetIds, Boolean activeOnly) {
        if (propertyAssetIds == null || propertyAssetIds.isEmpty()) {
            return new List<Vendor_Contract__c>();
        }
        Date today = Date.today();
        if (activeOnly == true) {
            return [
                SELECT Id, Name, Property_Asset__c, Property_Asset__r.Property_Name__c,
                       Unit__c, Unit__r.Suite_Number__c, Provider_Name__c, Service_Type__c,
                       Monthly_Amount__c, Start_Date__c, End_Date__c
                FROM Vendor_Contract__c
                WHERE Property_Asset__c IN :propertyAssetIds
                  AND (End_Date__c = NULL OR End_Date__c >= :today)
                WITH USER_MODE
                ORDER BY Property_Asset__c ASC, Service_Type__c ASC NULLS LAST, Id ASC
            ];
        }
        return [
            SELECT Id, Name, Property_Asset__c, Property_Asset__r.Property_Name__c,
                   Unit__c, Unit__r.Suite_Number__c, Provider_Name__c, Service_Type__c,
                   Monthly_Amount__c, Start_Date__c, End_Date__c
            FROM Vendor_Contract__c
            WHERE Property_Asset__c IN :propertyAssetIds
            WITH USER_MODE
            ORDER BY Property_Asset__c ASC, Service_Type__c ASC NULLS LAST, Id ASC
        ];
    }
}
