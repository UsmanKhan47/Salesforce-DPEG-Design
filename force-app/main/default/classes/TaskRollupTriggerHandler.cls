/**
 * Trigger handler for Task. Two responsibilities, both keyed on a custom lookup so
 * the vast majority of Tasks in the org are untouched:
 *
 *   1. ROLLUPS. Recomputes `Transaction__c` rollups (Tasks_Complete__c /
 *      Tasks_Overdue__c / Wire_Open_Risks__c) whenever a deal's checklist Tasks
 *      change, and `Onboarding__c` rollups (Tasks_Total__c / Tasks_Complete__c /
 *      Completion_Pct__c and the eight other counters) whenever an onboarding
 *      checklist Task changes.
 *   2. THE COMPLETION STAMP. In the BEFORE contexts, sets or clears
 *      `Task.Onboarding_Completed_Date__c` — see `OnboardingTaskDomain`.
 *   3. THE WIRE-FRAUD PREREQUISITE GATE (added 2026-08-31, Phase 0 of the Transaction
 *      FSD gap closure). In BEFORE UPDATE only, refuses a checklist Task that is
 *      transitioning into a completed status while the Task named by its
 *      `Blocked_By__c` is still open — B3 behind B2, I8 behind I7 — and maintains the
 *      denormalised `Is_Prerequisite_Met__c` that backs the validation-rule backstop.
 *      See `TaskPrerequisiteService`; all of the reasoning lives in that header.
 *      In BEFORE INSERT it CLAMPS ONLY (`clampOnInsert`) — no sibling lookup, because
 *      that would add `ceil(rows/200)` SOQL to the Day-0 fan-out cascade for a check
 *      that finds nothing; the insert REFUSAL comes from the validation rule reading
 *      the clamped value. That arithmetic is spelled out at `enforceOnUpdate`.
 *      🔴 INERT FOR ONBOARDING AND FOR EVERY OTHER TASK IN THE ORG: one blank check on
 *      `Blocked_By__c` (two in before update, `new` and `old`), then an early return —
 *      no query, no DML. Only two Tasks per Transaction ever carry the field.
 *      ⚠ PHASE 0 IS DELIBERATELY TEMPORARY and is discarded when the
 *      `Checklist_Item__c` model lands (design §10, M5). Do not build on it.
 *
 * Checklist Tasks relate to their parent via `Transaction_Deal__c` /
 * `Onboarding__c` (not `WhatId`), so they stay off the Activity timeline.
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
 *     two contexts now fire on EVERY Task in the org — the 82-row Transaction Day-0
 *     fan-out, Broker Protection pipeline Tasks, EAC companion Tasks, Disposition
 *     closing Tasks, and every hand-created Activity. The added cost is bounded at
 *     ONE null comparison per Task by `OnboardingTaskDomain.stampCompletion`'s
 *     `Onboarding__c == null` early return: no query, no DML, and no statement that
 *     can fail and roll back an unrelated save. There is no cheaper way to make a
 *     completion stamp survive a standard-UI edit, and the alternative (stamping in
 *     the service) leaves every non-LWC path unstamped — the defect being fixed.
 *
 * Context sourcing (unchanged in shape, now applied to both parents):
 *   - insert / undelete: collect parent ids from the new records.
 *   - delete:            collect parent ids from the old records.
 *   - update:            collect from BOTH new and old (a re-parent must recompute
 *                        the losing and the gaining parent).
 * Each recalc service is called ONCE per context, only when at least one id was
 * collected — so a Task with neither lookup costs zero queries and zero DML.
 *
 * The Transaction id collection is a mechanical projection of a lookup field, not a
 * per-object business rule, so it stays here in the handler. The Onboarding
 * projection lives on `OnboardingTaskDomain` because that class already owns the
 * onboarding-checklist rules and the two belong together.
 */
public with sharing class TaskRollupTriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        OnboardingTaskDomain.stampCompletion((List<Task>) newList, null);
        // Clamp only — no sibling lookup on insert. One blank check per Task, zero queries; the
        // arithmetic for why the lookup is update-only is at TaskPrerequisiteService.enforceOnUpdate.
        TaskPrerequisiteService.clampOnInsert((List<Task>) newList);
    }

    protected override void beforeUpdate() {
        OnboardingTaskDomain.stampCompletion((List<Task>) newList, (Map<Id, Task>) oldMap);
        // Return value deliberately discarded: the refusals are applied to the records via
        // addError inside the service, and the map exists only so a unit test can assert the
        // decision without depending on addError outside a trigger. See that method's Javadoc.
        TaskPrerequisiteService.enforceOnUpdate((List<Task>) newList, (Map<Id, Task>) oldMap);
    }

    protected override void afterInsert() {
        recalcDeals(collectDealIds((List<Task>) newList));
        recalcOnboardings(OnboardingTaskDomain.collectOnboardingIds((List<Task>) newList));
    }

    protected override void afterUpdate() {
        Set<Id> dealIds = collectDealIds((List<Task>) newList);
        dealIds.addAll(collectDealIds((List<Task>) oldList));
        recalcDeals(dealIds);

        Set<Id> onboardingIds = OnboardingTaskDomain.collectOnboardingIds((List<Task>) newList);
        onboardingIds.addAll(OnboardingTaskDomain.collectOnboardingIds((List<Task>) oldList));
        recalcOnboardings(onboardingIds);
    }

    protected override void afterDelete() {
        recalcDeals(collectDealIds((List<Task>) oldList));
        recalcOnboardings(OnboardingTaskDomain.collectOnboardingIds((List<Task>) oldList));
    }

    protected override void afterUndelete() {
        recalcDeals(collectDealIds((List<Task>) newList));
        recalcOnboardings(OnboardingTaskDomain.collectOnboardingIds((List<Task>) newList));
    }

    /**
     * Projects the non-null Transaction_Deal__c lookups of a Task collection
     * into a de-duplicated Set of deal ids.
     * @param tasks Tasks from one trigger context (may be null defensively).
     * @return The distinct, non-null deal ids referenced by those Tasks.
     */
    private Set<Id> collectDealIds(List<Task> tasks) {
        Set<Id> dealIds = new Set<Id>();
        if (tasks == null) {
            return dealIds;
        }
        for (Task t : tasks) {
            if (t.Transaction_Deal__c != null) {
                dealIds.add(t.Transaction_Deal__c);
            }
        }
        return dealIds;
    }

    /**
     * Recomputes rollups for the supplied deals, only when the set is non-empty.
     * @param dealIds Transaction__c ids to recompute.
     */
    private void recalcDeals(Set<Id> dealIds) {
        if (!dealIds.isEmpty()) {
            TaskRollupService.recalc(dealIds);
        }
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
     * ⚠ Deliberately gates the ONBOARDING branch only. `recalcDeals` is untouched.
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
