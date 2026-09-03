/**
 * Trigger handler for Task. Two responsibilities, both keyed on a custom lookup so
 * the vast majority of Tasks in the org are untouched:
 *
 *   1. ROLLUPS. Recomputes `Onboarding__c` rollups (Tasks_Total__c /
 *      Tasks_Complete__c / Completion_Pct__c and the eight other counters)
 *      whenever an onboarding checklist Task changes.
 *   2. THE COMPLETION STAMP. In the BEFORE contexts, sets or clears
 *      `Task.Onboarding_Completed_Date__c` — see `OnboardingTaskDomain`.
 *
 * ⚠ AMENDED 2026-09-03 — M5 LEGACY TASK RETIREMENT. THIS HANDLER IS NOW
 * ONBOARDING-ONLY, AND THAT IS THE CHANGE, NOT A SIDE EFFECT.
 * It used to carry a second, Transaction-shaped arm alongside every Onboarding one:
 *   • `collectDealIds` / `recalcDeals` -> `TaskRollupService`, recomputing
 *     `Transaction__c.Tasks_Complete__c` / `Tasks_Overdue__c` / `Wire_Open_Risks__c`
 *     from Tasks carrying `Transaction_Deal__c`; and
 *   • THE WIRE-FRAUD PREREQUISITE GATE (Phase 0, added 2026-08-31) — a BEFORE-UPDATE
 *     refusal driven by `TaskPrerequisiteService`, plus its BEFORE-INSERT clamp.
 * Both arms belonged to the legacy Task-based Transaction checklist. That model has
 * been replaced by `Checklist_Item__c`: the counters are now written by
 * `ChecklistRollupService` (fired from `ChecklistItemTrigger`, not from here) and the
 * prerequisite gate is now `ChecklistItemPrerequisiteService`. Phase 0's own header
 * always said it was "DELIBERATELY TEMPORARY and is discarded when the
 * `Checklist_Item__c` model lands (design §10, M5)". This is M5.
 *
 * 🔴 THE CONTEXT LIST DID NOT SHRINK BY ONE LINE, AND MUST NOT.
 * All six contexts carry an Onboarding responsibility of their own, so none of them
 * became dead when the Transaction arm left:
 *   before insert / before update -> `OnboardingTaskDomain.stampCompletion`
 *   after  insert / update / delete / undelete -> `recalcOnboardings`
 * `beforeInsert` and `beforeUpdate` now hold exactly ONE statement each. That is not
 * an invitation to delete them — removing either silently stops
 * `Onboarding_Completed_Date__c` being stamped on every non-LWC path (standard UI,
 * API, Data Loader), which is the exact defect the before-contexts were added to fix.
 *
 * Checklist Tasks relate to their parent via `Onboarding__c` (not `WhatId`), so they
 * stay off the Activity timeline.
 *
 * ⚠ AMENDED 2026-08-22 — TWO CHANGES WITH ORG-WIDE BLAST RADIUS, STATED PLAINLY
 * RATHER THAN BURIED:
 *
 * (a) `Onboarding__c` IS NOW ROUTED. Before this change the rollups fired from ONE
 *     LWC only (`OnboardingService.completeTask` called
 *     `OnboardingTaskRollupService.recalc` directly), so a checklist item completed
 *     from the standard UI, the API or Data Loader — or DELETED — never moved the
 *     Onboarding's counters. It does now, on all four after-contexts.
 *     🔴 That routing is exactly what turned `OnboardingTaskRollupService`'s bare
 *     `update` into a sharing hazard: it used to run only as a PM completing their
 *     own checklist; it now runs as WHOEVER edits any Task, against a Private-OWD
 *     object they may not own. That service was fixed in the SAME change — read its
 *     header before separating the two.
 *
 * (b) THE TRIGGER GAINED `before insert` / `before update`. It was after-only. Those
 *     two contexts now fire on EVERY Task in the org — Broker Protection pipeline
 *     Tasks, EAC companion Tasks, Disposition closing Tasks, and every hand-created
 *     Activity. The added cost is bounded at ONE null comparison per Task by
 *     `OnboardingTaskDomain.stampCompletion`'s `Onboarding__c == null` early return:
 *     no query, no DML, and no statement that can fail and roll back an unrelated
 *     save. There is no cheaper way to make a completion stamp survive a standard-UI
 *     edit, and the alternative (stamping in the service) leaves every non-LWC path
 *     unstamped — the defect being fixed.
 *
 * Context sourcing (unchanged in shape):
 *   - insert / undelete: collect parent ids from the new records.
 *   - delete:            collect parent ids from the old records.
 *   - update:            collect from BOTH new and old (a re-parent must recompute
 *                        the losing and the gaining parent).
 * The recalc service is called ONCE per context, only when at least one id was
 * collected — so a Task with no `Onboarding__c` costs zero queries and zero DML.
 *
 * The Onboarding projection lives on `OnboardingTaskDomain` because that class
 * already owns the onboarding-checklist rules and the two belong together.
 */
public with sharing class TaskRollupTriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        OnboardingTaskDomain.stampCompletion((List<Task>) newList, null);
    }

    protected override void beforeUpdate() {
        OnboardingTaskDomain.stampCompletion((List<Task>) newList, (Map<Id, Task>) oldMap);
    }

    protected override void afterInsert() {
        recalcOnboardings(OnboardingTaskDomain.collectOnboardingIds((List<Task>) newList));
    }

    protected override void afterUpdate() {
        Set<Id> onboardingIds = OnboardingTaskDomain.collectOnboardingIds((List<Task>) newList);
        onboardingIds.addAll(OnboardingTaskDomain.collectOnboardingIds((List<Task>) oldList));
        recalcOnboardings(onboardingIds);
    }

    protected override void afterDelete() {
        recalcOnboardings(OnboardingTaskDomain.collectOnboardingIds((List<Task>) oldList));
    }

    protected override void afterUndelete() {
        recalcOnboardings(OnboardingTaskDomain.collectOnboardingIds((List<Task>) newList));
    }

    /**
     * Recomputes rollups for the supplied Onboardings, only when the set is
     * non-empty — so a Task with no `Onboarding__c` costs nothing at all.
     *
     * 🔴 AND ONLY WHEN THE FAN-OUT HAS NOT TAKEN OWNERSHIP. `fanOutNow` inserts
     * CHUNK_SIZE x 45 = 4,500 Tasks in ONE statement, which the platform fires
     * after-insert against in 200-row batches: 23 firings, each spending its own SOQL
     * and DML to recompute counters for rows the same statement is still creating.
     * The fan-out sets `OnboardingTaskRollupService.suppressTriggerRecalc(true)`
     * around its DML and then calls `recalc` ONCE for the whole chunk, so the numbers
     * still land — they just cost 1 SOQL + 1 DML instead of 23 + 23. The flag is
     * false on every other path, so a standard-UI edit, an API write, Data Loader, a
     * delete and an undelete all still roll up exactly as before; that is what
     * `TaskRollupTriggerHandlerTest` pins.
     *
     * ⚠ This guard used to be described as gating "the ONBOARDING branch only", with
     * `recalcDeals` named as the ungated sibling. There is no sibling any more (M5),
     * so the guard now short-circuits the whole after-context. Nothing else in this
     * handler is suppressible, and nothing else should become suppressible by reading
     * this flag — a future second consumer needs its own flag and its own argument.
     *
     * @param onboardingIds Onboarding__c ids to recompute.
     */
    private void recalcOnboardings(Set<Id> onboardingIds) {
        if (OnboardingTaskRollupService.isTriggerRecalcSuppressed()) {
            return;
        }
        if (!onboardingIds.isEmpty()) {
            OnboardingTaskRollupService.recalc(onboardingIds);
        }
    }
}
