/**
 * Rolls the count of completed (closed) Tasks for a Transaction up to
 * Transaction__c.Tasks_Complete__c, which drives the "N / 75" highlights tile.
 * Invoked from TaskRollupTrigger.
 */
public with sharing class TaskRollupService {

    public static void recalc(Set<Id> txnIds) {
        if (txnIds == null || txnIds.isEmpty()) {
            return;
        }
        txnIds.remove(null);
        if (txnIds.isEmpty()) {
            return;
        }

        Map<Id, Integer> complete = new Map<Id, Integer>();
        Map<Id, Integer> overdue = new Map<Id, Integer>();
        Map<Id, Integer> wireOpen = new Map<Id, Integer>();
        for (Id tid : txnIds) {
            complete.put(tid, 0);
            overdue.put(tid, 0);
            wireOpen.put(tid, 0);
        }

        // Checklist tasks relate to the deal via Transaction_Deal__c (not WhatId), so this only
        // sees fan-out tasks — not ad-hoc Activities. Computed counts: closed, past-due-open, and
        // open anti-fraud wire-verification tasks (those drive the dashboard's Wire Sentinel).
        Date today = Date.today();
        for (Task t : TaskSelector.selectByTransactionDealIds(txnIds)) {
            Id d = t.Transaction_Deal__c;
            if (t.IsClosed) {
                complete.put(d, complete.get(d) + 1);
            } else if (t.ActivityDate != null && t.ActivityDate < today) {
                overdue.put(d, overdue.get(d) + 1);
            }
            Boolean isWire = t.Subject != null && t.Subject.toLowerCase().contains('anti-fraud');
            if (isWire && t.Verbal_Verification_Completed__c != true) {
                wireOpen.put(d, wireOpen.get(d) + 1);
            }
        }

        List<Transaction__c> updates = new List<Transaction__c>();
        for (Id tid : txnIds) {
            updates.add(new Transaction__c(Id = tid,
                Tasks_Complete__c = complete.get(tid),
                Tasks_Overdue__c = overdue.get(tid),
                Wire_Open_Risks__c = wireOpen.get(tid)));
        }
        update updates;
    }
}