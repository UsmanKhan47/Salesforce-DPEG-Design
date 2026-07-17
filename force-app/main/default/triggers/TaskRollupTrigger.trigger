/**
 * Recomputes Transaction__c.Tasks_Complete__c whenever its checklist Tasks change.
 * Checklist Tasks are related to the deal via the Transaction_Deal__c lookup (not WhatId),
 * so they stay out of the Activity timeline. Updates only Transaction__c, so no Task re-entry.
 */
trigger TaskRollupTrigger on Task (after insert, after update, after delete, after undelete) {
    new TaskRollupTriggerHandler().run();
}