/**
 * Trigger handler for `Utility_Bill__c`, extending the project's `TriggerHandler` base per
 * `.claude/rules/apex-layering-rule.md` ("Every trigger handler must extend the project's
 * `TriggerHandler` base class").
 *
 * Routing only - no SOQL, no DML, no arithmetic. Each override does one thing: work out
 * WHICH records or meters are affected and hand them to `UtilityBillService`.
 *
 * === WHY SIX CONTEXTS AND NOT TWO ===
 *   before insert / before update  write `Consumption__c` on the same save, so there is no
 *                                  second DML and no window where the record is stored
 *                                  without its consumption.
 *   after insert                   a new bill can be BACK-DATED between two existing ones,
 *                                  which invalidates the successor's stored prior pointer.
 *   after update                   only when `Read_Date__c` moved - that is the only edit
 *                                  that can reorder a chain (`Meter__c` is a non-reparentable
 *                                  master-detail and cannot change at all).
 *   after delete                   `Prior_Utility_Bill__c` is `SetNull`, so deleting a MIDDLE
 *                                  bill silently BLANKS its successor's pointer and the
 *                                  successor's variance quietly vanishes. Without this
 *                                  override that is a permanent, invisible data defect.
 *   after undelete                 a restored bill has to re-enter the sequence it left. No
 *                                  `before undelete` context exists on the platform, so this
 *                                  is the only place it can be repaired.
 *
 * Bulk-safe by construction: every override passes whole collections down. The recursion the
 * re-link's own DML would otherwise cause is stopped by `UtilityBillService.suppressRelink`.
 */
public with sharing class UtilityBillTriggerHandler extends TriggerHandler {

    /** Compute `Consumption__c` before the row is written. */
    protected override void beforeInsert() {
        UtilityBillService.applyConsumption((List<Utility_Bill__c>) newList, null);
    }

    /** Recompute `Consumption__c` unless the user typed one - see `isManualOverride`. */
    protected override void beforeUpdate() {
        UtilityBillService.applyConsumption(
            (List<Utility_Bill__c>) newList, (Map<Id, Utility_Bill__c>) oldMap);
    }

    /** A new bill may be back-dated into the middle of an existing chain. */
    protected override void afterInsert() {
        UtilityBillService.relinkChains(
            UtilityBillService.meterIdsToRelink((List<Utility_Bill__c>) newList, null));
    }

    /** Only a moved `Read_Date__c` can reorder a chain; the service filters on that. */
    protected override void afterUpdate() {
        UtilityBillService.relinkChains(UtilityBillService.meterIdsToRelink(
            (List<Utility_Bill__c>) newList, (Map<Id, Utility_Bill__c>) oldMap));
    }

    /** A deleted middle bill blanks its successor's pointer via SetNull. Repair the chain. */
    protected override void afterDelete() {
        UtilityBillService.relinkChains(
            UtilityBillService.meterIdsToRelink((List<Utility_Bill__c>) oldList, null));
    }

    /** A restored bill has to take its place in the sequence again. */
    protected override void afterUndelete() {
        UtilityBillService.relinkChains(
            UtilityBillService.meterIdsToRelink((List<Utility_Bill__c>) newList, null));
    }
}
