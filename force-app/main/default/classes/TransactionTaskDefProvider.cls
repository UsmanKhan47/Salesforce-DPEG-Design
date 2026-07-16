/**
 * Provider for the Transaction_Task_Def__mdt custom metadata type (the individual
 * Day-0 checklist task definitions that hang off each Task_Group_Def__mdt group).
 *
 * NOT A SELECTOR (design §3 CMDT note, §5, §10 flag 5): Custom Metadata is not
 * subject to FLS or sharing, so `WITH USER_MODE` is inert on `__mdt`. Per the
 * sf-apex rule, CMDT is read via `getAll()` with an in-memory sort, replacing the
 * inline `[SELECT ... FROM Transaction_Task_Def__mdt ORDER BY ...]` in
 * TaskFanoutService.
 *
 * `getAll()` populates every non-long-text field, so callers get all of
 * Group_Letter__c / Sequence__c / Subject__c / Owner_Label__c / Due_Day_Offset__c
 * / Default_Status__c.
 *
 * @see agent-output/p4-selector-design.md (§3 CMDT providers, §5, §10 flag 5)
 */
public with sharing class TransactionTaskDefProvider {

    /**
     * All Transaction_Task_Def__mdt records ordered by Group_Letter__c then
     * Sequence__c (nulls first), matching the original
     * `ORDER BY Group_Letter__c, Sequence__c` SOQL in TaskFanoutService.
     *
     * @return Ordered list of task definitions; empty when none are configured.
     */
    public static List<Transaction_Task_Def__mdt> getAllOrderedByGroupAndSequence() {
        List<Transaction_Task_Def__mdt> defs = Transaction_Task_Def__mdt.getAll().values();
        defs.sort(new GroupSequenceComparator());
        return defs;
    }

    /** Orders by Group_Letter__c, then Sequence__c — both ascending, nulls first. */
    private class GroupSequenceComparator implements System.Comparator<Transaction_Task_Def__mdt> {
        public Integer compare(Transaction_Task_Def__mdt first, Transaction_Task_Def__mdt second) {
            Integer byGroup = compareStrings(first.Group_Letter__c, second.Group_Letter__c);
            if (byGroup != 0) {
                return byGroup;
            }
            return compareDecimals(first.Sequence__c, second.Sequence__c);
        }

        private Integer compareStrings(String a, String b) {
            if (a == b) {
                return 0;
            }
            if (a == null) {
                return -1;
            }
            if (b == null) {
                return 1;
            }
            return a.compareTo(b);
        }

        private Integer compareDecimals(Decimal a, Decimal b) {
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
