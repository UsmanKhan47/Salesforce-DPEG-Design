/**
 * Backs the dispositionClosingTasks LWC on the Disposition record page. Renders the
 * three-step closing checklist (find-or-created on first view) and toggles a step's
 * completion.
 *
 * All SOQL is delegated to TaskSelector per ARCHITECTURE.md §2 — this controller holds no
 * inline SOQL.
 *
 * Thin controller (P6 controller thinning). The find-or-create and toggle DML live in
 * DispositionTaskService per .claude/rules/apex-layering-rule.md; the controller only
 * marshals input, delegates, shapes the returned Tasks into ordered view DTOs, and maps
 * failures to an AuraHandledException at the LWC boundary (ARCHITECTURE.md §5): platform
 * detail goes to the debug log (admin-only) and the user gets a fixed, generic message.
 */
public with sharing class DispositionTaskController {

    // Fixed, generic user-safe message for a failed write (the toggle). Never interpolate
    // platform text or exception detail into it (ARCHITECTURE.md §5).
    private static final String WRITE_FAILURE_MESSAGE =
        'This change could not be saved. Refresh the page and try again, or contact your administrator.';
    // Fixed, generic user-safe message for a failed checklist load. getClosingTasks
    // self-seeds (may insert), but from the user's perspective it loads the checklist, so
    // a failure surfaces as a load failure.
    private static final String READ_FAILURE_MESSAGE =
        'This checklist could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public class ClosingTask {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public Integer sequence;
        @AuraEnabled public Boolean done;
        @AuraEnabled public Datetime completedDate;
    }

    /**
     * Returns the three Disposition Closing tasks for a disposition, creating any that
     * don't exist yet (find-or-create) so the checklist self-seeds on first view. The
     * find-or-create DML lives in DispositionTaskService; the controller shapes the
     * returned Tasks into ordered view rows. NOT cacheable because the service may insert
     * — the LWC calls it imperatively.
     */
    @AuraEnabled
    public static List<ClosingTask> getClosingTasks(Id dispositionId) {
        try {
            Map<String, Task> bySubject = DispositionTaskService.findOrCreateClosingTasks(dispositionId);
            List<ClosingTask> rows = new List<ClosingTask>();
            for (Integer i = 0; i < DispositionTaskService.SUBJECTS.size(); i++) {
                Task t = bySubject.get(DispositionTaskService.SUBJECTS[i]);
                if (t == null) {
                    continue;
                }
                ClosingTask r = new ClosingTask();
                r.id = t.Id;
                r.subject = t.Subject;
                r.sequence = i + 1;
                r.done = t.IsClosed;
                // Guard: Task.CompletedDateTime is auto-stamped on close and never cleared
                // on reopen, so derive the completed date from IsClosed instead.
                r.completedDate = t.IsClosed ? t.LastModifiedDate : null;
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionTaskController.getClosingTasks on ' + dispositionId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    // Toggles a closing task between Completed and Not Started (mirrors TransactionTaskController).
    @AuraEnabled
    public static void setTaskDone(Id taskId, Boolean done) {
        try {
            DispositionTaskService.setTaskDone(taskId, done);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionTaskController.setTaskDone on ' + taskId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
