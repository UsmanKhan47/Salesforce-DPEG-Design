/**
 * The single Task trigger for this org (one-trigger-per-object). It does three things,
 * all delegated to TaskRollupTriggerHandler — read that class's header for the
 * blast-radius argument behind each context in the list below.
 *
 *   AFTER contexts  — recompute parent rollups for BOTH checklist parents:
 *                     Transaction__c (via Transaction_Deal__c) and Onboarding__c
 *                     (via Onboarding__c). Checklist Tasks relate through those
 *                     custom lookups, not WhatId, so they stay out of the Activity
 *                     timeline. Only the two PARENT objects are updated downstream,
 *                     so there is no Task re-entry.
 *   BEFORE insert   — stamp Task.Onboarding_Completed_Date__c (OnboardingTaskDomain)
 *                     and clamp Task.Is_Prerequisite_Met__c (TaskPrerequisiteService).
 *                     NO DML AND NO SOQL: both set values on the record the platform
 *                     is already saving.
 *   BEFORE update   — the two stamps above, PLUS the wire-fraud prerequisite gate,
 *                     which DOES SPEND ONE SOQL PER CHUNK — see the warning below.
 *
 * ⚠ AMENDED 2026-08-22. This header previously described an AFTER-ONLY,
 * Transaction__c-ONLY rollup. Both halves of that description are now false:
 * `before insert` / `before update` were added for the completion stamp, and
 * `Onboarding__c` is routed alongside `Transaction__c`. The before contexts fire on
 * every Task in the org; the cost is one null comparison for a Task with no
 * Onboarding__c.
 *
 * 🔴 AMENDED 2026-08-31 — AND THIS ONE CHANGES THE GOVERNOR PROFILE, SO READ IT BEFORE
 * QUOTING THE LINE ABOVE. Until this date the entry above said the BEFORE contexts cost
 * "No DML, no SOQL". THAT IS NO LONGER TRUE OF `before update`: the Phase 0 wire-fraud
 * prerequisite gate (TaskPrerequisiteService, Story 28) issues ONE SELECTOR READ PER
 * 200-ROW CHUNK whenever at least one Task in that chunk carries a Blocked_By__c on
 * either the new or the stored record. It is still ZERO for every other Task in the org
 * — the filter is two blank checks and an early return, and only two Tasks per
 * Transaction (B3 and I8) ever carry the field — and it is still zero DML in every
 * before context. `before insert` remains genuinely free of SOQL, deliberately: adding a
 * lookup there would cost ~41 queries on the Day-0 fan-out cascade. The arithmetic and
 * the named budget are at TaskPrerequisiteService.enforceOnUpdate and are pinned by
 * TaskPrerequisiteServiceTest's readCount assertions.
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
