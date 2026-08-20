/**
 * Owns the BOV broker REPLACEMENT — swapping which submission a disposition's broker appointment
 * rests on. Added 2026-08-19 with the disposition flow redesign (DEV-6), backing
 * `BovController.replaceSelectedBroker` and `c/bovReplaceBrokerModal`.
 *
 * ⚠ IT IS THE FIRST `Bov*Service` IN THE REPO. Until this change the module had a controller
 * (`BovController`) and a selector (`BovSubmissionSelector`) and no service at all, because every
 * BOV operation was a read. This one is not: it writes two objects, enforces an exclusivity
 * invariant and deliberately invalidates an approval, which is service work by every line of
 * .claude/rules/apex-layering-rule.md. The controller stays thin.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * WHAT A REPLACEMENT IS, IN THREE WRITES THAT MUST NOT COME APART
 * ══════════════════════════════════════════════════════════════════════════════
 *   1. the INCUMBENT  -> `Submission_Status__c = 'Backup'` and `Approval_Status__c` CLEARED
 *   2. the CHALLENGER -> `Submission_Status__c = 'Selected'` and `Approval_Status__c` CLEARED
 *   3. the DISPOSITION -> `Selected_Broker__c` = the challenger's `Broker_Firm__c`
 *
 * 🔴 CLEARING `Approval_Status__c` IS THE POINT OF THE WHOLE FEATURE, NOT HOUSEKEEPING. It is what
 * makes the new broker require a FRESH `Broker_Finalize_Approval`. Leave the incumbent's 'Approved'
 * in place and the record reads as an approved broker who is no longer appointed; leave the
 * challenger blank-but-appointed without clearing, and — worse — a challenger that had been
 * approved on some earlier round would arrive pre-approved, appointing a broker nobody signed off
 * this time. Both submissions are cleared for that reason, not just one.
 *
 * ⚠ THE STAGE IS DELIBERATELY NOT TOUCHED, AND THE GUARD THAT MAKES THAT SAFE LIVES ELSEWHERE. A
 * replacement performed AFTER the sale has already advanced past `Broker Selection` must NOT drag
 * it backwards; when the challenger's fresh approval completes,
 * `BovSubmissionTriggerHandler` will find the parent off `BOV Outreach` and stamp the broker name
 * WITHOUT moving the stage. That guard is the reason this service needs no stage logic at all —
 * read it before "improving" either half.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * ATOMICITY: A SAVEPOINT, BECAUSE A HALF-REPLACEMENT IS WORSE THAN A REFUSAL
 * ══════════════════════════════════════════════════════════════════════════════
 * The submissions and the Disposition are two objects and therefore two DML statements. The state
 * this service must never leave behind is "the submissions swapped but `Selected_Broker__c` still
 * names the old firm" — which is the value `Broker_Listing__c` copies on entry to `Active Listing`,
 * so a stale name propagates into the listing record and outlives the mistake. Under one savepoint
 * the only two reachable end states are "nothing happened, and here is why" and "all three
 * happened".
 *
 * 🔴 A LOCKED DISPOSITION THEREFORE REFUSES THE WHOLE REPLACEMENT, AND THAT IS CORRECT RATHER THAN
 * UNFORTUNATE. If `Broker_Selection_Approval` is pending (off-market, stage `Broker Selection`) the
 * record carries `recordEditability = AdminOnly` and write 3 throws ENTITY_IS_LOCKED. The right
 * answer is exactly what happens: the replacement is refused in full, the platform's own "this
 * record is locked" text is surfaced verbatim, and the user recalls the approval first. Replacing
 * the broker underneath a pending approval OF that broker is not an operation this business has.
 *
 * ── SOQL / DML BUDGET ───────────────────────────────────────────────────────
 * 1 SOQL (all submissions for the disposition) + 2 DML. No SOQL or DML in any loop.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * Per-transaction-singleton @AuraEnabled operation, invoked once per modal click: one disposition,
 * no loop over records, no trigger. The `.claude/rules/bulk-test-rule.md` 251-record mandate does
 * not apply — same shape and same exemption as `DispositionApprovalService`. Record that reasoning
 * in the test class header so review does not demand 251. ⚠ The submission write is still a single
 * BULK DML over however many submissions the disposition has.
 *
 * @see force-app/main/default/classes/BovController.cls (thin caller)
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (what the FRESH approval does)
 * @see force-app/main/default/classes/BovSubmissionSelector.cls (the one read)
 */
public with sharing class BovSubmissionService {

    /**
     * Raised when a replacement cannot proceed and the reason is user-actionable and safe to
     * surface verbatim.
     *
     * ⚠ ONE EXCEPTION TO "AUTHORED HERE", DELIBERATELY: a DML block re-wraps the PLATFORM's own
     * message in this type, because "This record is locked" and a validation rule's text are the
     * only things that identify WHICH gate refused. Same choice `RecordStageAdvanceService.setStage`
     * and `DispositionApprovalService.selectOffer` make.
     */
    public class BovSubmissionException extends Exception {}

    /** `Submission_Status__c` is RESTRICTED to exactly these two values. */
    @TestVisible
    private static final String STATUS_SELECTED = 'Selected';
    @TestVisible
    private static final String STATUS_BACKUP = 'Backup';

    private static final String NO_RECORD_MESSAGE = 'No record was provided.';

    private static final String NOT_ON_DISPOSITION_MESSAGE =
        'That broker response does not belong to this disposition.';

    private static final String ALREADY_SELECTED_MESSAGE =
        'That broker is already the selected broker for this disposition.';

    private static final String REPLACED_MESSAGE =
        'Broker replaced. The new broker must be approved before the sale can proceed.';

    /**
     * Replaces the appointed broker with another submission on the same disposition.
     *
     * ⚠ THE INCUMBENT IS RESOLVED FROM THE FULL SIBLING SET, NOT FROM A "WHERE Selected" QUERY, and
     * that is what makes the operation SELF-HEALING: if an earlier partial failure left two
     * submissions Selected, both are demoted here. A read scoped to the selected row would find one
     * of them, repair half the invariant, and leave `Broker_Finalize_Approval`'s entry criterion
     * (`Submission_Status__c = 'Selected'`) still matching two records. The same read is also the
     * membership check that proves `newSubmissionId` belongs to THIS disposition — a hand-crafted
     * call cannot promote another sale's broker.
     *
     * ⚠ A DISPOSITION WITH NO CURRENT INCUMBENT IS NOT AN ERROR. "Replace" degrades cleanly to
     * "appoint": nothing to demote, the challenger is promoted, the broker name is stamped. The
     * modal only offers the button when exactly one submission is Selected, but the server must not
     * depend on a client affordance for correctness.
     *
     * @param dispositionId    the Disposition__c whose broker is being replaced (required)
     * @param newSubmissionId  the BOV_Submission__c to appoint (required, must be its child)
     * @return an authored confirmation that also WARNS a fresh approval is required
     * @throws BovSubmissionException for a user-actionable rule violation, or carrying a platform
     *         block's own message when either write is refused
     * @throws DispositionActionPermissionService.AccessDeniedException when the running user is not
     *         a disposition driver
     * @example
     * String msg = BovSubmissionService.replaceSelectedBroker(dispositionId, submissionId);
     */
    public static String replaceSelectedBroker(Id dispositionId, Id newSubmissionId) {
        DispositionActionPermissionService.assertDispositionActionAccess();
        if (dispositionId == null || newSubmissionId == null) {
            throw new BovSubmissionException(NO_RECORD_MESSAGE);
        }

        List<BOV_Submission__c> submissions =
            BovSubmissionSelector.selectStatusesByDispositionId(dispositionId);

        BOV_Submission__c challenger;
        List<BOV_Submission__c> writes = new List<BOV_Submission__c>();
        for (BOV_Submission__c submission : submissions) {
            if (submission.Id == newSubmissionId) {
                challenger = submission;
                continue; // written below, after the already-selected check
            }
            if (STATUS_SELECTED.equals(submission.Submission_Status__c)) {
                writes.add(new BOV_Submission__c(
                    Id = submission.Id,
                    Submission_Status__c = STATUS_BACKUP,
                    // 🔴 The incumbent's approval is REVOKED, not preserved. An 'Approved' status on
                    // a demoted broker reads as an appointment nobody made.
                    Approval_Status__c = null
                ));
            }
        }
        if (challenger == null) {
            throw new BovSubmissionException(NOT_ON_DISPOSITION_MESSAGE);
        }
        if (STATUS_SELECTED.equals(challenger.Submission_Status__c)) {
            // Refused rather than treated as a no-op: the user asked for a CHANGE, and silently
            // clearing this broker's own approval status would be a change they did not ask for.
            throw new BovSubmissionException(ALREADY_SELECTED_MESSAGE);
        }
        writes.add(new BOV_Submission__c(
            Id = challenger.Id,
            Submission_Status__c = STATUS_SELECTED,
            // 🔴 CLEARED, NOT LEFT ALONE. A challenger approved on an earlier round would otherwise
            // arrive pre-approved and appoint a broker nobody signed off this time.
            Approval_Status__c = null
        ));

        Savepoint beforeReplacement = Database.setSavepoint();
        try {
            // ── SYSTEM_MODE, and `Approval_Status__c` is what forces it ──────
            // It is a 2026-08-19 field: a Metadata-API-deployed custom field arrives with NO FLS for
            // any profile, System Administrator included, and the permission sets then grant it READ
            // ONLY (an approval process is its only other writer). A USER_MODE write would be
            // refused for everyone. It does NOT bypass validation rules, which is correct.
            // allOrNone = true: a half-applied exclusivity swap is the one outcome worse than a
            // refused click, and it is what the savepoint exists to prevent across the two objects.
            Database.update(writes, true, AccessLevel.SYSTEM_MODE);

            // ── ORDINARY DML for the parent, deliberately ────────────────────
            // `Selected_Broker__c` is a long-standing field the disposition personas hold, and using
            // plain `update` keeps this write under the SAME rules every other Disposition write in
            // the module obeys. If the record is locked by a pending approval this throws — see the
            // class header for why refusing the whole replacement is the correct answer there.
            update new Disposition__c(
                Id = dispositionId,
                Selected_Broker__c = challenger.Broker_Firm__c
            );
        } catch (DmlException e) {
            Database.rollback(beforeReplacement);
            // Surfaced verbatim: "This record is locked" and a validation rule's own text are the
            // only things that name the gate. Same getNumDml() guard as
            // RecordStageAdvanceService.setStage — a DmlException with no row detail is a real shape
            // (MIXED_DML_OPERATION, LIMIT_EXCEEDED) on which getDmlMessage(0) itself throws.
            throw new BovSubmissionException(
                e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        } catch (Exception e) {
            Database.rollback(beforeReplacement);
            System.debug(LoggingLevel.ERROR, 'BovSubmissionService.replaceSelectedBroker rolled '
                + 'back on ' + dispositionId + '/' + newSubmissionId + ': ' + e.getMessage()
                + ' | ' + e.getStackTraceString());
            // Raw, for the controller to mask with its fixed generic message.
            throw e;
        }
        return REPLACED_MESSAGE;
    }
}
