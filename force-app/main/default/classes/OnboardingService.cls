/**
 * Service for the Onboarding checklist write workflow — owns the DML behind
 * OnboardingController.completeTask (P6 controller thinning): mark a checklist Task
 * complete from the interactive checkbox, append any note, and roll the change up onto
 * the parent Onboarding__c so the rings / bars / KPIs reflect it.
 *
 * Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2 this DML and the
 * complete-and-rollup orchestration are Service work, not Controller work — the controller
 * now only marshals input, delegates here, and maps failures to an AuraHandledException at
 * the LWC boundary (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to TaskSelector; the rollup recompute (which owns its own
 * Onboarding__c DML) is delegated to OnboardingTaskRollupService. This service holds no
 * inline SOQL. It throws the raw platform exceptions (QueryException on a missing Task,
 * DmlException on a save failure); the AuraHandledException boundary lives in the
 * controller, NOT here, so the service stays UI-agnostic (also callable from Flow / Apex).
 *
 * TRANSACTIONALITY: the Task update and the rollup update are two DML statements with no
 * explicit Savepoint — intentionally matching the pre-thinning controller behaviour. When
 * the rollup fails, the AuraHandledException the controller re-throws is unhandled at the
 * @AuraEnabled entry point, so the platform rolls back the whole transaction (including
 * the Task completion). No half-applied state survives a failed rollup.
 *
 * @see force-app/main/default/classes/OnboardingController.cls (thin caller)
 * @see force-app/main/default/classes/TaskSelector.cls (all SOQL)
 * @see force-app/main/default/classes/OnboardingTaskRollupService.cls (rollup recompute)
 */
public with sharing class OnboardingService {

    /**
     * Completes one onboarding checklist Task, appends an optional note, and recomputes the
     * parent Onboarding__c rollups.
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
        t.ActivityDate = Date.today();
        if (String.isNotBlank(notes)) {
            t.Description = String.isBlank(t.Description) ? notes : (t.Description + '\n\n' + notes);
        }
        update t;
        if (t.Onboarding__c != null) {
            OnboardingTaskRollupService.recalc(new Set<Id>{ t.Onboarding__c });
        }
    }
}
