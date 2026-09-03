/**
 * The single Task trigger for this org (one-trigger-per-object). It does two things,
 * both delegated to TaskRollupTriggerHandler — read that class's header for the
 * blast-radius argument behind each context in the list below.
 *
 *   AFTER contexts  — recompute Onboarding__c rollups for the onboarding checklist
 *                     (via the Onboarding__c lookup). Checklist Tasks relate through
 *                     that custom lookup, not WhatId, so they stay out of the Activity
 *                     timeline. Only the PARENT object is updated downstream, so there
 *                     is no Task re-entry.
 *   BEFORE contexts — stamp Task.Onboarding_Completed_Date__c (OnboardingTaskDomain).
 *                     NO DML AND NO SOQL: it sets a value on the record the platform
 *                     is already saving.
 *
 * ⚠ AMENDED 2026-08-22. This header previously described an AFTER-ONLY rollup.
 * `before insert` / `before update` were added for the completion stamp. The before
 * contexts fire on every Task in the org; the cost is one null comparison for a Task
 * with no Onboarding__c.
 *
 * 🔴 AMENDED 2026-09-03 — M5 LEGACY TASK RETIREMENT. TWO EARLIER HEADER CLAIMS ARE NOW
 * GONE RATHER THAN STALE, AND THE GOVERNOR PROFILE MOVED BACK, NOT FORWARD.
 * Until this date this header described (a) a SECOND rollup parent, Transaction__c via
 * Transaction_Deal__c, and (b) the Phase 0 wire-fraud prerequisite gate
 * (TaskPrerequisiteService, Story 28), which spent ONE SELECTOR READ PER 200-ROW CHUNK
 * in `before update` whenever a Task in that chunk carried Blocked_By__c. Both belonged
 * to the legacy Task-based Transaction checklist, which has been replaced by
 * Checklist_Item__c (counters -> ChecklistRollupService; prerequisite gate ->
 * ChecklistItemPrerequisiteService, both fired from ChecklistItemTrigger).
 * ⇒ EVERY BEFORE CONTEXT IS ONCE AGAIN ZERO SOQL AND ZERO DML. Anyone re-adding a
 * lookup to a before context must re-derive the arithmetic that made it unacceptable
 * before, not cite this header as permission.
 *
 * 🔴 THE CONTEXT LIST BELOW DID NOT CHANGE AT M5 AND MUST NOT BE "SIMPLIFIED".
 * All six contexts carry an Onboarding responsibility. The two before contexts each
 * hold exactly one statement now; deleting either stops Onboarding_Completed_Date__c
 * being stamped on every non-LWC path, which is the defect they were added to fix.
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
