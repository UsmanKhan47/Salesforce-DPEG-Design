/**
 * Service for the Transaction checklist write workflow — owns the DML behind
 * TransactionTaskController (P6 controller thinning): toggle a checklist Task's status,
 * complete a regular Task with optional notes, and close a wire-fraud verification Task
 * only after the verbal verification is captured (DPEG brief Section 06).
 *
 * Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2 this DML and the
 * verification business rule are Service work, not Controller work — the controller now
 * only marshals input, delegates here, and maps failures to an AuraHandledException at
 * the LWC boundary (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to TaskSelector — this service holds no inline SOQL. It throws a
 * typed WireVerificationException for the user-actionable "name/phone required" rule
 * (surfaced verbatim by the controller) and the raw platform exceptions (DmlException /
 * QueryException) on a save/read failure. The AuraHandledException boundary lives in the
 * controller, NOT here, so the service stays UI-agnostic (also callable from Flow / Apex).
 *
 * TRANSACTIONALITY: each method issues a single Task update — single-record operations
 * that mirror the pre-thinning controller exactly. There is one DML statement per method,
 * so no explicit Savepoint is needed.
 *
 * @see force-app/main/default/classes/TransactionTaskController.cls (thin caller)
 * @see force-app/main/default/classes/TaskSelector.cls (all SOQL)
 */
public with sharing class TransactionTaskService {

    /**
     * Raised when a wire-verification Task is asked to close without the confirmer's
     * name and phone. User-actionable and user-safe: the controller surfaces its message
     * verbatim. Distinct from an unexpected platform DmlException/QueryException, which
     * the controller maps to a fixed generic message instead.
     */
    public class WireVerificationException extends Exception {}

    /**
     * Toggles a checklist Task between Completed and Not Started.
     *
     * @param taskId the Task to update (required)
     * @param done   true → Completed, false → Not Started
     * @throws System.DmlException on a platform save failure
     */
    public static void setTaskStatus(Id taskId, Boolean done) {
        update new Task(Id = taskId, Status = done ? 'Completed' : 'Not Started');
    }

    /**
     * Completes a regular checklist Task and persists the optional notes/comments captured
     * in the confirm dialog to the Task's Description (Comments). Blank notes leave any
     * existing comments untouched.
     *
     * @param taskId the Task to complete (required)
     * @param notes  optional free-text comment; when blank the Description is not touched
     * @throws System.DmlException on a platform save failure
     */
    public static void completeTask(Id taskId, String notes) {
        Task t = new Task(Id = taskId, Status = 'Completed');
        if (String.isNotBlank(notes)) {
            t.Description = notes.trim();
        }
        update t;
    }

    /**
     * Closes a wire-fraud verification Task only after the verbal verification is captured
     * (DPEG brief Section 06). Records the confirmer's name + phone, stamps the time, and
     * logs the standard verification note to the Task's comments.
     *
     * @param taskId     the wire-verification Task to close (required)
     * @param verifiedBy the confirmer's name (required)
     * @param phone      the phone number the verification was made on (required)
     * @param comments   optional verifier comments, logged above the standard note
     * @throws WireVerificationException when verifiedBy or phone is blank
     * @throws System.QueryException     when taskId resolves to no Task
     * @throws System.DmlException       on a platform save failure
     */
    public static void completeWireVerification(Id taskId, String verifiedBy, String phone, String comments) {
        if (String.isBlank(verifiedBy) || String.isBlank(phone)) {
            throw new WireVerificationException(
                'Confirmed-by name and phone number are required before this wire-verification task can close.');
        }
        Task t = TaskSelector.selectRequiredById(taskId);
        Datetime now = Datetime.now();
        String note = 'Verified by phone with ' + verifiedBy.trim() + ' at ' + phone.trim()
            + ' on ' + now.format('MMM d, yyyy h:mm a') + '.';
        // Save the verifier's own comments (if provided) above the standard verification note.
        String combined = String.isNotBlank(comments) ? (comments.trim() + '\n' + note) : note;
        t.Verbal_Verification_Completed__c = true;
        t.Verified_By__c = verifiedBy.trim();
        t.Verification_Phone__c = phone.trim();
        t.Verified_At__c = now;
        t.Description = String.isBlank(t.Description) ? combined : (t.Description + '\n' + combined);
        t.Status = 'Completed';
        update t;
    }
}
