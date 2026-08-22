/**
 * The single Task trigger for this org (one-trigger-per-object). It does two things,
 * both delegated to TaskRollupTriggerHandler — read that class's header for the
 * blast-radius argument behind each context in the list below.
 *
 *   AFTER contexts  — recompute parent rollups for BOTH checklist parents:
 *                     Transaction__c (via Transaction_Deal__c) and Onboarding__c
 *                     (via Onboarding__c). Checklist Tasks relate through those
 *                     custom lookups, not WhatId, so they stay out of the Activity
 *                     timeline. Only the two PARENT objects are updated downstream,
 *                     so there is no Task re-entry.
 *   BEFORE contexts — stamp / clear Task.Onboarding_Completed_Date__c on onboarding
 *                     checklist items. No DML, no SOQL: the value is set on the
 *                     record the platform is already saving.
 *
 * ⚠ AMENDED 2026-08-22. This header previously described an AFTER-ONLY,
 * Transaction__c-ONLY rollup. Both halves of that description are now false:
 * `before insert` / `before update` were added for the completion stamp, and
 * `Onboarding__c` is routed alongside `Transaction__c`. The before contexts fire on
 * every Task in the org; the cost is one null comparison for a Task with no
 * Onboarding__c.
 */
trigger TaskRollupTrigger on Task (
    before insert,
    before update,
    after insert,
    after update,
    after delete,
    after undelete
) {
    new TaskRollupTriggerHandler().run();
}
