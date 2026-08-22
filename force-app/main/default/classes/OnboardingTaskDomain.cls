/**
 * Domain rules for onboarding checklist Tasks (Tasks carrying a non-null
 * `Onboarding__c` lookup). Pure in-memory logic on collections: ZERO SOQL, ZERO
 * DML, per `.claude/rules/apex-layering-rule.md` ("Domain Purity Rule").
 *
 * ═══ 🔴 THE DEFECT THIS CLASS EXISTS TO FIX ═══
 * Completing a checklist item used to overwrite `Task.ActivityDate` with today.
 * `ActivityDate` **is** the DUE DATE everywhere else in this module —
 * `OnboardingController.getChecklist` renders it as `due` and derives `overdue`
 * from it, and `OnboardingTaskRollupService` counts Overdue / Stalled / Due-in-7d
 * from it. So every completion silently destroyed the deadline it was measured
 * against, and "was this finished late?" became permanently unanswerable.
 *
 * The fix is a SEPARATE field, `Task.Onboarding_Completed_Date__c`, stamped here.
 * `ActivityDate` is never written by this class. Late completion is then derivable
 * as `Onboarding_Completed_Date__c - ActivityDate` (> 0 ⇒ late). No `Days_Late__c`
 * field is proposed — it was not requested and the subtraction is free.
 *
 * ⚠ WHY NOT THE STANDARD `Task.CompletedDateTime`: this repo already measured and
 * rejected it — `DispositionTaskController.cls:63-65`, "Task.CompletedDateTime is
 * auto-stamped on close and never cleared on reopen." A reopened checklist item
 * would keep a stale completion date forever. It is also driven by `Task.Status`,
 * whereas this checklist is driven by `Task.Onboarding_Status__c`.
 *
 * ⚠ WHY A TRIGGER RATHER THAN THE SERVICE: `OnboardingService.completeTask` is the
 * LWC checklist path only. Stamping there leaves the standard UI, the API, Data
 * Loader and every future caller unstamped. In a before-context the stamp is part
 * of the same save on every path, with no extra DML.
 *
 * @see force-app/main/default/classes/TaskRollupTriggerHandler.cls (sole caller)
 * @see force-app/main/default/classes/OnboardingService.cls (LWC path, no longer stamps)
 */
public with sharing class OnboardingTaskDomain {

    /** The checklist status that means "done". Restricted picklist value on Task.Onboarding_Status__c. */
    @TestVisible private static final String STATUS_COMPLETE = 'Complete';

    /**
     * Stamps (or clears) `Onboarding_Completed_Date__c` on checklist Tasks that are
     * entering or leaving `Onboarding_Status__c = 'Complete'`.
     *
     * Mutates `newList` in place — it is a BEFORE-context collection, so the
     * platform persists the change with the caller's own save. No DML here.
     *
     * Rules, in order:
     *   - `Onboarding__c == null`  ⇒ skip. THE ORG-WIDE COST CONTROL: this method
     *     runs on every Task in the org (Transaction Day-0 checklist Tasks, Broker
     *     Protection pipeline Tasks, EAC companion Tasks, Disposition closing
     *     Tasks, every hand-created Activity), and for all of them the added cost is
     *     one null comparison with no query, no DML and no way to fail.
     *   - ENTERING Complete (insert: any Complete; update: prior != Complete) and
     *     the date is blank ⇒ stamp `Date.today()`. Blank-check first so a
     *     deliberate back-dated value supplied in the same save survives.
     *   - LEAVING Complete (update only, prior == Complete, new != Complete) ⇒ clear
     *     the date. A reopened item must not keep a completion date — that is the
     *     precise failure that disqualified `CompletedDateTime`.
     *
     * @param newList Trigger.new (Tasks). Null/empty-safe.
     * @param oldMap  Trigger.oldMap on before update; NULL on before insert.
     */
    public static void stampCompletion(List<Task> newList, Map<Id, Task> oldMap) {
        if (newList == null || newList.isEmpty()) {
            return;
        }
        for (Task t : newList) {
            if (t.Onboarding__c == null) {
                continue;
            }
            Boolean isComplete = STATUS_COMPLETE.equals(t.Onboarding_Status__c);
            Boolean wasComplete = false;
            if (oldMap != null) {
                Task prior = oldMap.get(t.Id);
                wasComplete = prior != null && STATUS_COMPLETE.equals(prior.Onboarding_Status__c);
            }

            if (isComplete && !wasComplete) {
                if (t.Onboarding_Completed_Date__c == null) {
                    t.Onboarding_Completed_Date__c = Date.today();
                }
            } else if (!isComplete && wasComplete) {
                t.Onboarding_Completed_Date__c = null;
            }
        }
    }

    /**
     * Projects the non-null `Onboarding__c` lookups of a Task collection into a
     * de-duplicated Set of Onboarding ids, for the rollup routing in
     * `TaskRollupTriggerHandler`.
     *
     * Pure projection, no SOQL, no DML.
     *
     * @param tasks Tasks from one trigger context; null-safe.
     * @return The distinct, non-null Onboarding ids those Tasks reference; empty, never null.
     */
    public static Set<Id> collectOnboardingIds(List<Task> tasks) {
        Set<Id> onboardingIds = new Set<Id>();
        if (tasks == null) {
            return onboardingIds;
        }
        for (Task t : tasks) {
            if (t.Onboarding__c != null) {
                onboardingIds.add(t.Onboarding__c);
            }
        }
        return onboardingIds;
    }
}
