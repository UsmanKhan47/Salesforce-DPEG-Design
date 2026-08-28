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
 * ── 🔴 2026-08-28: AUTHORIZE IN THE APPLICATION, THEN WRITE IN SYSTEM MODE ────
 * All three write methods below now (1) call
 * TransactionActionPermissionService.assertTaskActionAccess() and (2) run their DML as
 * `Database.update(record, true, AccessLevel.SYSTEM_MODE)`. Before this change they used
 * plain user-mode DML, which requires Task object EDIT — and NOBODY in this org has it.
 * Danish Rehman (and every other non-admin persona) sits on `Minimum Access - Salesforce`;
 * every checklist completion failed with the controller's generic
 * "This task could not be updated." Only a System Administrator could complete a task, and
 * only because "Modify All Data" implies Task CRUD.
 *
 * 🔴 IT CANNOT BE FIXED WITH A PERMISSION SET — PROVEN, NOT ASSUMED.
 * `ObjectPermissions.SobjectType` is a RESTRICTED PICKLIST of 3,007 values and `Task`,
 * `Event` and `Activity` are NOT among them (Account/Contact/Lead/Opportunity/Case/Contract
 * all are). A direct API insert of an ObjectPermissions row for Task returns
 * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST. Worse, a permission set XML carrying a Task
 * <objectPermissions> block DEPLOYS GREEN and is then silently discarded — measured
 * 2026-08-28 on usman-dpeg; see the removal note in
 * permissionsets/DPEG_Task_Edit.permissionset-meta.xml. Task CRUD is PROFILE-ONLY on this
 * platform, and profile changes are ruled out for this org. So the authorization had to move
 * into the application.
 *
 * ── 🔴 WHY THIS CLASS STAYS `with sharing`, AND MUST ─────────────────────────
 * `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS. IT DOES NOT LIFT SHARING — that is a
 * separate mechanism and a separate decision (ARCHITECTURE.md §2, the SYSTEM_MODE note).
 * Keeping `with sharing` is what makes this a CRUD workaround rather than a security hole:
 * Task row access still applies, so a user can only complete tasks they can actually reach.
 * Measured 2026-08-28: all 82 Transaction checklist Tasks in usman-dpeg are OWNED BY the
 * user completing them, so record access is satisfied by ownership alone.
 * ⚠ DO NOT ADD `without sharing` HERE. If a future report says "user X still cannot complete
 * task Y", the question to ask is whether X has EDIT-level record access to Y — read access
 * is enough to SEE the row in the checklist and NOT enough to update it. The answer to that
 * is a sharing/ownership fix, never a mode change in this class.
 *
 * ── THE GATE ─────────────────────────────────────────────────────────────────
 * The authorization token is the `Transaction_Task_Actions` custom permission, granted by
 * `DPEG_Task_Edit` (a member of the `DPEG_Transaction_Team` permission set group, verified
 * live 2026-08-28), with the same "Modify All Data" administrator bypass every sibling gate
 * carries. It is DELIBERATELY SEPARATE from `Transaction_Stage_Actions` (user decision):
 * advancing a stage and completing a checklist item are independently grantable.
 *
 * ⚠ THE APEX AND THE PERMISSION BELONG IN THE SAME DEPLOY. `FeatureManagement.checkPermission`
 * returns false for an undeployed permission — it never throws — so shipping this class
 * without customPermissions/Transaction_Task_Actions and the DPEG_Task_Edit grant denies the
 * WHOLE Transactions team instead of granting them. Correct direction (it fails closed), but
 * silent.
 *
 * ⚠ SCOPE IS TRANSACTION ONLY. DispositionTaskService has the identical user-mode-DML defect
 * against the same un-grantable Task object; it needs its own permission decision from the
 * user and is deliberately NOT changed here.
 *
 * @see force-app/main/default/classes/TransactionTaskController.cls (thin caller)
 * @see force-app/main/default/classes/TransactionActionPermissionService.cls (the gate)
 * @see force-app/main/default/classes/TaskSelector.cls (all SOQL)
 * @see force-app/main/default/customPermissions/Transaction_Task_Actions.customPermission-meta.xml
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
     * @throws TransactionActionPermissionService.AccessDeniedException when the running user
     *         does not hold `Transaction_Task_Actions` and is not an administrator
     * @throws System.DmlException on a platform save failure
     */
    public static void setTaskStatus(Id taskId, Boolean done) {
        // Authorization FIRST. This check is what REPLACES the Task Edit CRUD the platform will
        // not let us grant — nothing below it may run for an unauthorized caller.
        TransactionActionPermissionService.assertTaskActionAccess();
        // SYSTEM_MODE justification (ARCHITECTURE.md §2): Task object Edit is un-grantable by
        // permission set on this platform, so USER_MODE here refuses EVERY non-admin user
        // unconditionally. Authorization was established one line above by the custom
        // permission; this bypasses object CRUD/FLS ONLY. Sharing still applies (the class is
        // `with sharing`), so the user must still hold record access to this Task.
        // allOrNone = true: one record, and a silent partial failure would tell the user the
        // task completed when it did not.
        Database.update(
            new Task(Id = taskId, Status = done ? 'Completed' : 'Not Started'),
            true,
            AccessLevel.SYSTEM_MODE
        );
    }

    /**
     * Completes a regular checklist Task and persists the optional notes/comments captured
     * in the confirm dialog to the Task's Description (Comments). Blank notes leave any
     * existing comments untouched.
     *
     * @param taskId the Task to complete (required)
     * @param notes  optional free-text comment; when blank the Description is not touched
     * @throws TransactionActionPermissionService.AccessDeniedException when the running user
     *         does not hold `Transaction_Task_Actions` and is not an administrator
     * @throws System.DmlException on a platform save failure
     */
    public static void completeTask(Id taskId, String notes) {
        TransactionActionPermissionService.assertTaskActionAccess();
        Task t = new Task(Id = taskId, Status = 'Completed');
        if (String.isNotBlank(notes)) {
            t.Description = notes.trim();
        }
        // SYSTEM_MODE justification: as setTaskStatus above — un-grantable Task Edit CRUD,
        // authorization already asserted, sharing deliberately still enforced.
        Database.update(t, true, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Closes a wire-fraud verification Task only after the verbal verification is captured
     * (DPEG brief Section 06). Records the confirmer's name + phone, stamps the time, and
     * logs the standard verification note to the Task's comments.
     *
     * ⚠ ORDER: the permission gate runs BEFORE the name/phone rule. An unauthorized caller
     * gets a refusal, not coaching on a business rule they cannot act on.
     *
     * @param taskId     the wire-verification Task to close (required)
     * @param verifiedBy the confirmer's name (required)
     * @param phone      the phone number the verification was made on (required)
     * @param comments   optional verifier comments, logged above the standard note
     * @throws TransactionActionPermissionService.AccessDeniedException when the running user
     *         does not hold `Transaction_Task_Actions` and is not an administrator
     * @throws WireVerificationException when verifiedBy or phone is blank
     * @throws System.QueryException     when taskId resolves to no Task
     * @throws System.DmlException       on a platform save failure
     */
    public static void completeWireVerification(Id taskId, String verifiedBy, String phone, String comments) {
        TransactionActionPermissionService.assertTaskActionAccess();
        if (String.isBlank(verifiedBy) || String.isBlank(phone)) {
            throw new WireVerificationException(
                'Confirmed-by name and phone number are required before this wire-verification task can close.');
        }
        // ⚠ THE READ STAYS `WITH USER_MODE` (TaskSelector.selectRequiredById) — DELIBERATE.
        // The CRUD gap this change works around is on EDIT, not READ: every persona already
        // reads Tasks (the checklist itself renders for them through the same selector), so
        // this is a read the user asked for and it needs no exemption.
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
        // SYSTEM_MODE justification: as setTaskStatus above. This write also touches the custom
        // verification fields, whose FLS lives on DPEG_Task_Edit — those ARE grantable, but the
        // object-level Edit they sit behind is not, so the exemption is unavoidable regardless.
        Database.update(t, true, AccessLevel.SYSTEM_MODE);
    }
}
