/**
 * Day-0 fan-out: creates the standard Transaction task checklist (the A-J groups) as
 * standard Task records when a Transaction's contract is executed. Driven by the
 * Task_Group_Def__mdt + Transaction_Task_Def__mdt custom metadata. Called from the
 * Transaction_Task_Fanout record-triggered Flow.
 */
public with sharing class TaskFanoutService {

    // Test injection points (CMDT can't be inserted in tests, but can be built in memory).
    @TestVisible static List<Task_Group_Def__mdt> groupDefsOverride;
    @TestVisible static List<Transaction_Task_Def__mdt> taskDefsOverride;
    @TestVisible static Boolean bypassDedupe = false;

    @InvocableMethod(label='Fan Out Transaction Tasks'
        description='Creates the standard task checklist for a Transaction when its contract is executed.')
    public static void fanOut(List<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return;
        }

        List<Task_Group_Def__mdt> groupDefs = groupDefsOverride != null ? groupDefsOverride : [
            SELECT Letter__c, Group_Name__c, Owner_Label__c, Conditional__c, Condition_Field__c
            FROM Task_Group_Def__mdt
        ];
        Map<String, Task_Group_Def__mdt> groupByLetter = new Map<String, Task_Group_Def__mdt>();
        Set<String> condFields = new Set<String>();
        for (Task_Group_Def__mdt g : groupDefs) {
            groupByLetter.put(g.Letter__c, g);
            if (String.isNotBlank(g.Condition_Field__c)) {
                condFields.add(g.Condition_Field__c);
            }
        }

        List<Transaction_Task_Def__mdt> taskDefs = taskDefsOverride != null ? taskDefsOverride : [
            SELECT Group_Letter__c, Sequence__c, Subject__c, Owner_Label__c, Due_Day_Offset__c, Default_Status__c
            FROM Transaction_Task_Def__mdt
            ORDER BY Group_Letter__c, Sequence__c
        ];

        // Dynamic query so arbitrary conditional gating fields (e.g. Loan_Required__c) can be read.
        String fieldList = 'Id, OwnerId, Contract_Executed_Date__c, Tasks_Fanned_Out__c';
        for (String cf : condFields) {
            fieldList += ', ' + cf;
        }
        Map<Id, Transaction__c> txns = new Map<Id, Transaction__c>(
            (List<Transaction__c>) Database.query(
                'SELECT ' + fieldList + ' FROM Transaction__c WHERE Id IN :transactionIds'));

        List<Task> toInsert = new List<Task>();
        List<Transaction__c> toFlag = new List<Transaction__c>();

        for (Transaction__c t : txns.values()) {
            if (t.Tasks_Fanned_Out__c == true && !bypassDedupe) {
                continue;
            }
            Integer createdForTxn = 0;
            for (Transaction_Task_Def__mdt d : taskDefs) {
                Task_Group_Def__mdt g = groupByLetter.get(d.Group_Letter__c);
                if (g == null) {
                    continue;
                }
                // Conditional group gate (e.g. Financing only when Loan Required).
                if (g.Conditional__c == true) {
                    Boolean met = false;
                    if (String.isNotBlank(g.Condition_Field__c)) {
                        Object v = t.get(g.Condition_Field__c);
                        met = (v == true);
                    }
                    if (!met) {
                        continue;
                    }
                }
                Task tk = new Task();
                // Relate via the custom lookup (not WhatId) so checklist tasks stay out of the Activity timeline.
                tk.Transaction_Deal__c = t.Id;
                tk.OwnerId = t.OwnerId;
                tk.Subject = d.Subject__c;
                tk.Task_Group__c = g.Letter__c + '. ' + g.Group_Name__c;
                tk.Task_Sequence__c = d.Sequence__c;
                tk.Conditional__c = (g.Conditional__c == true);
                tk.Task_Owner_Label__c = String.isNotBlank(d.Owner_Label__c) ? d.Owner_Label__c : g.Owner_Label__c;
                tk.Status = String.isNotBlank(d.Default_Status__c) ? d.Default_Status__c : 'Not Started';
                if (t.Contract_Executed_Date__c != null) {
                    Integer offset = d.Due_Day_Offset__c != null ? Integer.valueOf(d.Due_Day_Offset__c) : 0;
                    tk.ActivityDate = t.Contract_Executed_Date__c.addDays(offset);
                }
                toInsert.add(tk);
                createdForTxn++;
            }
            toFlag.add(new Transaction__c(Id = t.Id, Tasks_Fanned_Out__c = true, Tasks_Total__c = createdForTxn));
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        if (!toFlag.isEmpty()) {
            update toFlag;
        }
    }
}