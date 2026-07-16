/**
 * Provider for the Task_Group_Def__mdt custom metadata type (the A–J Transaction
 * task-group definitions).
 *
 * NOT A SELECTOR (design §3 CMDT note, §5, §10 flag 5): Custom Metadata is not
 * subject to FLS or sharing, so `WITH USER_MODE` is inert on `__mdt`, and the
 * sf-apex rule is explicit that CMDT must be read via `getAll()/getInstance()`,
 * never SOQL. This provider therefore returns `getAll().values()` with an
 * in-memory sort, replacing the inline `[SELECT ... FROM Task_Group_Def__mdt]`
 * statements in TransactionTaskController and TaskFanoutService.
 *
 * `getAll()` populates every non-long-text field on each record, so callers get
 * all of Letter__c / Group_Name__c / Owner_Label__c / Conditional__c /
 * Sequence__c / Condition_Field__c regardless of which subset they use.
 *
 * @see agent-output/p4-selector-design.md (§3 CMDT providers, §5, §10 flag 5)
 */
public with sharing class TaskGroupDefProvider {

    /**
     * All Task_Group_Def__mdt records ordered by Sequence__c ascending (nulls
     * first, matching the original `ORDER BY Sequence__c` SOQL). This is the stage
     * order TransactionTaskController.getTaskGroups renders; TaskFanoutService
     * consumes the same list order-independently (it maps by Letter__c).
     *
     * @return Ordered list of group definitions; empty when none are configured.
     */
    public static List<Task_Group_Def__mdt> getAllOrderedBySequence() {
        List<Task_Group_Def__mdt> defs = Task_Group_Def__mdt.getAll().values();
        defs.sort(new SequenceComparator());
        return defs;
    }

    /** Orders by Sequence__c ascending, nulls first (SOQL ASC semantics). */
    private class SequenceComparator implements System.Comparator<Task_Group_Def__mdt> {
        public Integer compare(Task_Group_Def__mdt first, Task_Group_Def__mdt second) {
            Decimal a = first.Sequence__c;
            Decimal b = second.Sequence__c;
            if (a == b) {
                return 0;
            }
            if (a == null) {
                return -1;
            }
            if (b == null) {
                return 1;
            }
            return a > b ? 1 : -1;
        }
    }
}
