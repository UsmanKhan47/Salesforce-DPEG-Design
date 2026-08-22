/**
 * Service for the Onboarding checklist write workflow — owns the DML behind
 * OnboardingController.completeTask (P6 controller thinning): mark a checklist Task
 * complete from the interactive checkbox and append any note.
 *
 * Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2 this DML is Service
 * work, not Controller work — the controller now only marshals input, delegates here,
 * and maps failures to an AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to TaskSelector; this service holds no inline SOQL. It throws
 * the raw platform exceptions (QueryException on a missing Task, DmlException on a save
 * failure); the AuraHandledException boundary lives in the controller, NOT here, so the
 * service stays UI-agnostic (also callable from Flow / Apex).
 *
 * ═══ 🔴 AMENDED 2026-08-22 — TWO LINES REMOVED, AND THE TRANSACTIONALITY ARGUMENT
 * THAT USED TO LIVE HERE NO LONGER APPLIES ═══
 *
 * 1. `t.ActivityDate = Date.today();` IS GONE. That line was the defect: `ActivityDate`
 *    **is** the checklist item's DUE DATE — `OnboardingController.getChecklist` renders
 *    it as `due` and derives `overdue` from it, and `OnboardingTaskRollupService` counts
 *    Overdue / Stalled / Due-in-7d from it — so completing an item silently destroyed
 *    the deadline it was being measured against. The completion date now lands on its
 *    own field, `Task.Onboarding_Completed_Date__c`, stamped by
 *    `OnboardingTaskDomain.stampCompletion` in the Task BEFORE contexts. Late completion
 *    is derivable as `Onboarding_Completed_Date__c - ActivityDate`.
 *    ⚠ This service does NOT stamp that field itself, deliberately. Stamping here would
 *    cover the LWC path only and leave the standard UI, the API and Data Loader
 *    unstamped — which is the same single-path defect, relocated.
 *
 * 2. THE EXPLICIT `OnboardingTaskRollupService.recalc(...)` CALL IS GONE.
 *    `TaskRollupTriggerHandler` now routes `Onboarding__c` on all four after-contexts,
 *    so the `update t` below fires the recompute by itself. Keeping the explicit call
 *    would recompute twice per click.
 *
 * 3. THE OLD HEADER'S TRANSACTIONALITY BLOCK IS REMOVED RATHER THAN EDITED. It described
 *    "two DML statements with no explicit Savepoint" and argued that a failed rollup
 *    rolls back the Task completion via the unhandled AuraHandledException at the
 *    @AuraEnabled entry point. There is now ONE DML statement here, and the rollup runs
 *    INSIDE it as trigger work — so a rollup failure rolls the Task update back natively,
 *    by the platform's own trigger semantics, with no argument needed. The conclusion
 *    (no half-applied state survives a failed rollup) still holds; the reasoning that
 *    produced it does not, and a stale reason is worse than none.
 *
 * @see force-app/main/default/classes/OnboardingController.cls (thin caller)
 * @see force-app/main/default/classes/TaskSelector.cls (all SOQL)
 * @see force-app/main/default/classes/OnboardingTaskDomain.cls (the completion stamp)
 * @see force-app/main/default/classes/TaskRollupTriggerHandler.cls (the rollup trigger)
 */
public with sharing class OnboardingService {

    /**
     * Completes one onboarding checklist Task and appends an optional note. The parent
     * Onboarding__c rollups and the completion-date stamp are applied by the Task
     * trigger on the same save — see the class header.
     *
     * ⚠ `ActivityDate` IS NOT TOUCHED. The item's original due date must survive its
     * completion; that is the whole point of the change.
     *
     * @param taskId the checklist Task to complete (required)
     * @param notes  optional free-text note; when blank the Description is not touched
     * @throws System.QueryException when taskId resolves to no Task
     * @throws System.DmlException   on a platform save failure
     */
    public static void completeTask(Id taskId, String notes) {
        Task t = TaskSelector.selectForOnboardingCompletion(taskId);
        t.Onboarding_Status__c = 'Complete';
        t.Status = 'Completed';
        if (String.isNotBlank(notes)) {
            t.Description = String.isBlank(t.Description) ? notes : (t.Description + '\n\n' + notes);
        }
        update t;
    }
}
