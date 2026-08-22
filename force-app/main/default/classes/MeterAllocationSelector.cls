/**
 * Selector for `Meter_Allocation__c` - encapsulates ALL SOQL against the split of a shared
 * meter across several spaces, per ARCHITECTURE.md section 2 and
 * `.claude/rules/apex-layering-rule.md`.
 *
 * FSD 5.10.3: allocations exist ONLY where one meter serves several spaces. A meter serving
 * a single space has none, and an empty result here is therefore normal data rather than a
 * missing-configuration signal.
 *
 * MODE - USER_MODE throughout. Allocations are read to be shown to a reviewer; no
 * automation path consumes them. The "do the allocations add up" question is answered
 * declaratively by `Meter__c.Total_Allocated_Pct__c`, a roll-up summary, so no Apex
 * aggregation of these rows exists or should be added.
 *
 * SHARING - `with sharing`. `Meter_Allocation__c` is ControlledByParent of the Private
 * `Meter__c`.
 */
public with sharing class MeterAllocationSelector {

    /**
     * Every allocation recorded against the given meters, largest share first.
     *
     * @param meterIds Meter Ids; null/empty returns an empty list.
     * @return Matching allocations ordered by meter then descending percentage; never null.
     */
    public static List<Meter_Allocation__c> selectByMeterIds(Set<Id> meterIds) {
        if (meterIds == null || meterIds.isEmpty()) {
            return new List<Meter_Allocation__c>();
        }
        return [
            SELECT Id, Name, Meter__c, Unit__c, Unit__r.Suite_Number__c,
                   Allocation_Basis__c, Allocation_Pct__c, Square_Feet__c
            FROM Meter_Allocation__c
            WHERE Meter__c IN :meterIds
            WITH USER_MODE
            ORDER BY Meter__c ASC, Allocation_Pct__c DESC NULLS LAST, Id ASC
        ];
    }
}
