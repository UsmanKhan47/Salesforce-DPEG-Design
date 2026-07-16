/**
 * Selector for Work_Order_Activity__c — all SOQL against the work-order activity
 * timeline per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module B1. Design: agent-output/p4-selector-design.md §3 #2, §4.
 *
 * MODE: USER_MODE (custom object, FLS gap 0 — P3). Timeline ordering tie-breaks
 * on Name DESC because same-transaction rows share Entry_DateTime__c (the
 * frozen-clock gotcha, carried over verbatim from WorkOrderController.getActivity).
 * Entry_DateTime__c is the post-D3-migration timeline stamp (ARCHITECTURE.md §1
 * rule 9); the old *_Date__c field is dropped.
 *
 * Both a single-parent (selectByWorkOrderId) and a bulk (selectByWorkOrderIds)
 * form are provided: the bulk Set<Id> method is mandated for child-by-parent
 * reads by .claude/rules/bulk-test-rule.md / ARCHITECTURE.md §2, and selects
 * Work_Order__c so callers can group children by parent.
 */
public with sharing class WorkOrderActivitySelector {

    /**
     * Timeline entries for one Work Order, newest first. Backs
     * WorkOrderController.getActivity.
     *
     * @param workOrderId Parent Work_Order__c Id.
     * @return Ordered Work_Order_Activity__c for the parent; empty list when the
     *         input is null.
     */
    public static List<Work_Order_Activity__c> selectByWorkOrderId(Id workOrderId) {
        if (workOrderId == null) {
            return new List<Work_Order_Activity__c>();
        }
        return [
            SELECT Id, Work_Order__c, Kind__c, Detail__c, Actor__c, Entry_DateTime__c
            FROM Work_Order_Activity__c
            WHERE Work_Order__c = :workOrderId
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
        ];
    }

    /**
     * Timeline entries for many Work Orders in one query — group the result by
     * Work_Order__c to build per-parent timelines. Bulk form per ARCHITECTURE.md §2.
     *
     * @param workOrderIds Parent Work_Order__c Ids.
     * @return Ordered Work_Order_Activity__c across all parents; empty list when the
     *         input is null or empty.
     */
    public static List<Work_Order_Activity__c> selectByWorkOrderIds(Set<Id> workOrderIds) {
        if (workOrderIds == null || workOrderIds.isEmpty()) {
            return new List<Work_Order_Activity__c>();
        }
        return [
            SELECT Id, Work_Order__c, Kind__c, Detail__c, Actor__c, Entry_DateTime__c
            FROM Work_Order_Activity__c
            WHERE Work_Order__c IN :workOrderIds
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
        ];
    }
}
