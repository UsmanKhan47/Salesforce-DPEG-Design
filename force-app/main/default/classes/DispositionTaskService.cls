/**
 * Service for the Disposition closing-checklist write workflows.
 *
 * Owns the business logic behind DispositionTaskController (P6 controller thinning): the
 * find-or-create of the three standard closing Tasks scoped to a Disposition, and the
 * complete/re-open toggle. Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md
 * §2, this DML is Service work, not Controller work — the controller now only marshals
 * input, delegates here, shapes the returned Tasks into view DTOs, and maps failures to
 * an AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to TaskSelector — this service holds no inline SOQL. It throws
 * the raw platform DmlException on a save failure; the AuraHandledException boundary
 * lives in the controller, NOT here, so the service stays UI-agnostic.
 *
 * @see force-app/main/default/classes/DispositionTaskController.cls (thin caller)
 * @see force-app/main/default/classes/TaskSelector.cls (all SOQL)
 */
public with sharing class DispositionTaskService {

    /**
     * The closing checklist, in order. Single source of truth: the controller's row
     * shaping references this for the display sequence, and this service scopes the
     * find-or-create to a Disposition by WhatId + these Subjects. TestVisible so both the
     * controller and its tests rely on the same list rather than a duplicated copy.
     */
    @TestVisible
    public static final List<String> SUBJECTS = new List<String>{
        'PSA Executed',
        'Title Company Engaged',
        'Closing Statement Received'
    };

    /**
     * Returns the three closing Tasks for a Disposition, creating any that don't exist
     * yet (find-or-create) so the checklist self-seeds on first view. Built the same way
     * as the transaction tasks: standard Task records scoped by WhatId + Subject,
     * completion via Status. Idempotent — a second call creates no duplicates.
     *
     * Returns the Tasks keyed by Subject so the controller can shape them into ordered
     * view rows without re-querying. The re-read after the insert picks up the guarded
     * field set (Id, Subject, IsClosed, LastModifiedDate) the controller's completed-date
     * guard depends on.
     *
     * @param dispositionId the Disposition__c the checklist belongs to (Task WhatId)
     * @return the closing Tasks for the Disposition, keyed by Subject
     * @throws System.DmlException on a platform save failure (e.g. an invalid WhatId)
     */
    public static Map<String, Task> findOrCreateClosingTasks(Id dispositionId) {
        Set<String> existing = new Set<String>();
        for (Task t : TaskSelector.selectByWhatIdAndSubjects(dispositionId, SUBJECTS)) {
            existing.add(t.Subject);
        }

        List<Task> toCreate = new List<Task>();
        for (Integer i = 0; i < SUBJECTS.size(); i++) {
            if (!existing.contains(SUBJECTS[i])) {
                toCreate.add(new Task(
                    WhatId = dispositionId,
                    Subject = SUBJECTS[i],
                    Status = 'Not Started',
                    Priority = 'Normal'
                ));
            }
        }
        if (!toCreate.isEmpty()) {
            insert toCreate;
        }

        // Re-read (incl. any just-inserted) with the guarded field set
        // (Id, Subject, IsClosed, LastModifiedDate) the controller's completedDate guard
        // depends on. SOQL lives in TaskSelector; the IsClosed ? : guard stays in the controller.
        Map<String, Task> bySubject = new Map<String, Task>();
        for (Task t : TaskSelector.selectByWhatIdAndSubjects(dispositionId, SUBJECTS)) {
            bySubject.put(t.Subject, t);
        }
        return bySubject;
    }

    /**
     * Toggles a closing task between Completed and Not Started (mirrors
     * TransactionTaskController's completion toggle).
     *
     * @param taskId the Task to toggle
     * @param done   true to mark Completed, otherwise Not Started
     * @throws System.DmlException on a platform save failure (e.g. a missing Task Id)
     */
    public static void setTaskDone(Id taskId, Boolean done) {
        update new Task(Id = taskId, Status = done == true ? 'Completed' : 'Not Started');
    }
}
