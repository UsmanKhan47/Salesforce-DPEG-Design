/**
 * Owns the BOV broker APPOINTMENT — which submission a disposition's broker appointment rests on,
 * whether that is the first one or the fifth. Added 2026-08-19 with the disposition flow redesign
 * (DEV-6), backing `BovController.replaceSelectedBroker` and `c/bovReplaceBrokerModal`.
 *
 * ⚠ THIS SENTENCE SAID "THE BOV BROKER REPLACEMENT" UNTIL 2026-08-21 AND THE WIDENING IS THE
 * POINT, NOT A TIDY. The method's name is still `replaceSelectedBroker` — renaming a live
 * @AuraEnabled-reachable signature to match a header is churn — but its scope is now both entry
 * points on `c/bovComparisonMatrix` ("Select Broker" and "Replace Broker"). A reader who takes the
 * old first line literally would go looking for the appointment code somewhere else and not find
 * it, because there isn't any: see `replaceSelectedBroker`'s own javadoc for why a second server
 * path was rejected.
 *
 * ⚠ IT IS THE FIRST `Bov*Service` IN THE REPO. Until this change the module had a controller
 * (`BovController`) and a selector (`BovSubmissionSelector`) and no service at all, because every
 * BOV operation was a read. This one is not: it writes two objects, enforces an exclusivity
 * invariant and deliberately invalidates an approval, which is service work by every line of
 * .claude/rules/apex-layering-rule.md. The controller stays thin.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * WHAT A REPLACEMENT IS, IN FOUR WRITES THAT MUST NOT COME APART
 * ══════════════════════════════════════════════════════════════════════════════
 *   1. the INCUMBENT  -> `Submission_Status__c = 'Backup'` and `Approval_Status__c` CLEARED
 *   2. the CHALLENGER -> `Submission_Status__c = 'Selected'` and `Approval_Status__c` CLEARED
 *   3. the DISPOSITION -> `Selected_Broker__c` = the challenger's `Broker_Firm__c`
 *   4. the HISTORY ROW -> one `BOV_Broker_Change__c` recording who was replaced by whom, why,
 *      and when (2026-08-20, Tranche 2 Workstream B / design D4.3)
 *
 * ⚠ WRITE 4 WAS ADDED AFTER THE OTHER THREE AND THIS BLOCK USED TO READ "THREE WRITES". It is
 * corrected rather than appended to, because a header that undercounts its own DML is how a budget
 * line stops being a contract.
 *
 * 🔴 WRITE 4 IS DELIBERATELY LAST, INSIDE THE SAME SAVEPOINT. A history row recording a
 * replacement that then failed is worse than no history at all: it is a durable, reportable,
 * append-only assertion that a broker changed, sitting next to a disposition where none did. Being
 * last means it can only exist if writes 1-3 already succeeded; being inside the savepoint means
 * writes 1-3 are undone if IT fails. Do not "optimise" it into the same block as the submission
 * update, and do not move it out of the try.
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
 * The submissions, the Disposition and the history row are three objects and therefore three DML
 * statements. The state this service must never leave behind is "the submissions swapped but
 * `Selected_Broker__c` still names the old firm" — which is the value `Broker_Listing__c` copies on
 * entry to `Active Listing`, so a stale name propagates into the listing record and outlives the
 * mistake. Since 2026-08-20 there is a second such state: a `BOV_Broker_Change__c` row asserting a
 * swap that did not survive its own transaction. Under one savepoint the only two reachable end
 * states are "nothing happened, and here is why" and "all four writes happened".
 *
 * 🔴 A LOCKED DISPOSITION THEREFORE REFUSES THE WHOLE REPLACEMENT, AND THAT IS CORRECT RATHER THAN
 * UNFORTUNATE. If `Broker_Selection_Approval` is pending (off-market, stage `Broker Selection`) the
 * record carries `recordEditability = AdminOnly` and write 3 throws ENTITY_IS_LOCKED. The right
 * answer is exactly what happens: the replacement is refused in full, the platform's own "this
 * record is locked" text is surfaced verbatim, and the user recalls the approval first. Replacing
 * the broker underneath a pending approval OF that broker is not an operation this business has.
 *
 * ── SOQL / DML BUDGET ───────────────────────────────────────────────────────
 * 1 SOQL (all submissions for the disposition) + 3 DML. No SOQL or DML in any loop.
 * ⚠ THIS LINE SAID "1 SOQL + 2 DML" UNTIL 2026-08-20 and was corrected in the same change that
 * added the third DML (the `BOV_Broker_Change__c` history insert). The three are: the bulk
 * submission update, the parent stamp, the history insert. The SOQL stayed at ONE — the history
 * row's broker Contact (`Broker__c`) and firm snapshot (`Broker_Firm__c`) are both carried by the
 * existing `selectStatusesByDispositionId` read rather than by a second query against Contact.
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
 * @see force-app/main/default/classes/BovBrokerChangeSelector.cls (who READS the history this
 *      method writes — and why that read is USER_MODE while this write is not)
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

    /**
     * ⚠ THE REASON IS REQUIRED BY THE SERVER, NOT ONLY BY THE MODAL'S COMBOBOX. `c/bovReplaceBrokerModal`
     * marks it required and keeps its Confirm button disabled without one, but this class's own
     * doctrine — stated two paragraphs down for the incumbent check — is that the server must not
     * depend on a client affordance for correctness. A history row with a blank `Reason__c` is the
     * one row this whole workstream exists to prevent: it records that a broker changed while
     * answering none of the questions the record is read to answer.
     *
     * ⚠ THE VALUE ITSELF IS NOT VALIDATED HERE, DELIBERATELY. `BOV_Broker_Change__c.Reason__c` is a
     * RESTRICTED picklist and restricted picklists ARE enforced by Apex DML, so an off-list value is
     * refused by the platform with its own message (surfaced verbatim by the DmlException catch). A
     * copy of the value set in Apex would be a second copy to keep in step with the field metadata —
     * the same divergence the modal avoids by sourcing its options from `getPicklistValues` instead
     * of a hardcoded array.
     */
    private static final String REASON_REQUIRED_MESSAGE =
        'Choose a reason for the broker change.';

    /**
     * The ONE `BOV_Broker_Change__c.Reason__c` value this class names, added 2026-08-21 with the
     * Select Broker picker.
     *
     * 🔴 NAMING ONE VALUE IS NOT THE SAME AS COPYING THE VALUE SET, AND THE DISTINCTION IS THE
     * WHOLE ARGUMENT. `REASON_REQUIRED_MESSAGE`'s note above refuses to hold a copy of
     * `Reason__c`'s options in Apex, because a second copy diverges the day an admin adds a value
     * in Setup and nothing fails to reveal it. That reasoning is unchanged and this constant does
     * not violate it: this class does not enumerate the options, does not validate membership, and
     * still lets the platform refuse an off-list value with its own message. It names exactly one
     * value because exactly one value has a SEMANTIC RULE attached that only the server can check
     * — see FIRST_APPOINTMENT_ONLY_MESSAGE. If a future value gains its own rule, name that one
     * too; do not build the array.
     */
    @TestVisible
    private static final String REASON_INITIAL_APPOINTMENT = 'Initial Appointment';

    /**
     * 🔴 THE ANSWER TO "WHAT HAPPENS IF SOMEONE USES SELECT BROKER ON A DISPOSITION THAT ALREADY
     * HAS ONE" — AND THE REASON THE TWO CLIENT ENTRY POINTS CANNOT DISAGREE WITH EACH OTHER.
     *
     * `c/bovComparisonMatrix` renders EITHER "Select Broker" OR "Replace Broker", never both,
     * decided from a cacheable wire that can be seconds stale. So the reachable race is: an
     * analyst opens Select Broker on a disposition with no incumbent, a colleague appoints one in
     * another tab, and the first analyst confirms. Without this check the swap would succeed as an
     * ordinary REPLACEMENT while its history row said `Initial Appointment` — a durable,
     * append-only, reportable claim that this was a first appointment when it demoted somebody.
     * That is the same class of defect as a blank `Reason__c`: a row that records THAT a broker
     * changed while answering none of the questions it is read to answer.
     *
     * ⚠ ONLY ONE DIRECTION IS ENFORCED, DELIBERATELY. This refuses `Initial Appointment` when
     * there IS an incumbent. It does NOT refuse the five predecessor-presupposing values when
     * there is none — doing so would require this class to know which values those are, which is
     * exactly the value-set copy the class refuses to hold. The asymmetry costs one unattributable
     * shape (someone hand-crafting a call that logs "Performance Issue" on a first appointment)
     * and buys zero divergence from the field metadata.
     *
     * ⚠ IT NAMES THE OTHER BUTTON, NOT A FIELD OR A STATE. The user's fix is a UI action they can
     * see, and refreshing is what makes it appear.
     */
    private static final String FIRST_APPOINTMENT_ONLY_MESSAGE =
        'This disposition already has a selected broker, so this is a replacement rather than a '
        + 'first appointment. Refresh the page and use Replace Broker, which records why the '
        + 'broker is changing.';

    private static final String REPLACED_MESSAGE =
        'Broker replaced. The new broker must be approved before the sale can proceed.';

    /**
     * 🔴 A DISTINCT SENTENCE, AUTHORED HERE, AND THE CLIENT MUST NOT RE-AUTHOR IT.
     * `c/bovReplaceBrokerModal`'s header forbids restating the service's returned text at length,
     * and that argument applies with more force now that there are TWO of them: a client that
     * picked its own wording would be choosing between "appointed" and "replaced" from the SAME
     * stale wire that produced the button, and could therefore announce an appointment that was
     * actually a replacement. The server branches on what it actually did — `outgoing == null` —
     * which is measured inside the transaction and cannot be stale.
     *
     * ⚠ "replaced" was WRONG on a first appointment; the second sentence was always right and is
     * preserved verbatim in substance. `Approval_Status__c` is cleared on the challenger either
     * way (see the promote write below), so the fresh-approval consequence is identical.
     */
    private static final String APPOINTED_MESSAGE =
        'Broker appointed. The broker must be approved before the sale can proceed.';

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
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 THAT DEGRADATION IS NOW A FIRST-CLASS FEATURE, NOT A TOLERATED EDGE (2026-08-21)
     * ══════════════════════════════════════════════════════════════════════════════
     * `c/bovComparisonMatrix` gained a "Select Broker" button beside "Replace Broker", and it
     * reaches THIS METHOD. **There is no `appointSelectedBroker` and there must never be one.** A
     * second server path would be a second implementation of single-Selected exclusivity, a second
     * `Approval_Status__c` revocation, a second savepoint and a second history writer — four
     * invariants that could each drift out of step with these, on an object whose whole point is
     * that exactly one row is Selected. The two client buttons are two ENTRY POINTS to one
     * mechanism, which is why "what if a broker is already appointed when Select Broker is used?"
     * has the answer it has: it IS a replacement, performed by this code, with the same demotion,
     * the same approval revocation and the same history row — because it is literally the same
     * method. The only thing the two entry points may differ on is `reason`, and the ONE
     * server-checkable rule about that is enforced below (FIRST_APPOINTMENT_ONLY_MESSAGE).
     *
     * ⚠ TWO RETURN STRINGS, CHOSEN BY `outgoing == null` — see APPOINTED_MESSAGE. The caller does
     * not tell this method which operation it thinks it is performing.
     *
     * ── THE HISTORY ROW, AND WHAT IS DELIBERATELY NOT A PARAMETER ────────────────
     * ⚠ THERE IS NO `effectiveDate` PARAMETER, AND ITS ABSENCE IS A DECISION.
     * `BrokerAssignmentService.replaceBroker` — the five-parameter method this signature otherwise
     * mirrors — takes one, because a LISTING has a tenure whose start and end dates are business
     * facts a user may backdate. A BOV broker swap has no tenure: `Entry_DateTime__c` is the write
     * time, full stop. Adding an effective date here would invent a second, editable answer to
     * "when did this happen" on an append-only log whose value is that it cannot be re-narrated.
     *
     * @param dispositionId    the Disposition__c whose broker is being replaced (required)
     * @param newSubmissionId  the BOV_Submission__c to appoint (required, must be its child)
     * @param reason           a `BOV_Broker_Change__c.Reason__c` picklist value (required — see
     *                         REASON_REQUIRED_MESSAGE for why the server enforces it too).
     *                         `Initial Appointment` is accepted ONLY when there is no incumbent.
     * @param notes            free text for the history row (optional; null and blank both fine)
     * @return an authored confirmation — APPOINTED_MESSAGE when there was no incumbent,
     *         REPLACED_MESSAGE when there was — that also WARNS a fresh approval is required
     * @throws BovSubmissionException for a user-actionable rule violation, or carrying a platform
     *         block's own message when any of the three writes is refused
     * @throws DispositionActionPermissionService.AccessDeniedException when the running user is not
     *         a disposition driver
     * @example
     * String msg = BovSubmissionService.replaceSelectedBroker(
     *     dispositionId, submissionId, 'Performance Issue', 'Missed two marketing deadlines.');
     */
    public static String replaceSelectedBroker(Id dispositionId, Id newSubmissionId,
                                               String reason, String notes) {
        DispositionActionPermissionService.assertDispositionActionAccess();
        if (dispositionId == null || newSubmissionId == null) {
            throw new BovSubmissionException(NO_RECORD_MESSAGE);
        }
        if (String.isBlank(reason)) {
            throw new BovSubmissionException(REASON_REQUIRED_MESSAGE);
        }

        List<BOV_Submission__c> submissions =
            BovSubmissionSelector.selectStatusesByDispositionId(dispositionId);

        BOV_Submission__c challenger;
        // 🔴 THE FIRST DEMOTED SUBMISSION, KEPT ONLY FOR THE HISTORY ROW'S "OUTGOING" COLUMNS.
        // The swap itself needs no such reference — it demotes EVERY Selected row (see this
        // method's self-healing note above). The history row has one Outgoing slot, so in the
        // abnormal two-incumbents case it records whichever row the selector returns FIRST, and
        // that row is fully determined rather than arbitrary. That case is a repair of a broken
        // invariant, not a normal replacement; recording one incumbent is better than recording
        // none, and both demotions remain visible on the submissions themselves.
        //
        // ⚠ CORRECTED 2026-08-21 — THE OLD SENTENCE IS QUOTED SO NOBODY RE-DERIVES IT: "it records
        // the HIGHEST-SCORING one, which is the first row the selector returns (ORDER BY
        // BOV_Score__c DESC NULLS LAST) and therefore deterministic rather than arbitrary." The
        // CONCLUSION (deterministic) is still true; the REASON given for it stopped being
        // sufficient. `BOV_Score__c` is being recreated as a formula that returns null until the
        // disposition has an asking price, so in practice every score TIES AT NULL — and a SOQL
        // sort whose only key ties does not promise an order at all. `selectStatusesByDispositionId`
        // now orders `BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC`, so the row recorded
        // here is the highest-scoring incumbent when scores differ and the OLDEST one when they do
        // not. Read that method's header before changing either half.
        BOV_Submission__c outgoing;
        List<BOV_Submission__c> writes = new List<BOV_Submission__c>();
        for (BOV_Submission__c submission : submissions) {
            if (submission.Id == newSubmissionId) {
                challenger = submission;
                continue; // written below, after the already-selected check
            }
            if (STATUS_SELECTED.equals(submission.Submission_Status__c)) {
                if (outgoing == null) {
                    outgoing = submission;
                }
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
        // 🔴 BEFORE ANY WRITE, AND AFTER THE INCUMBENT IS KNOWN — those two together are what make
        // it correct. The client decides which button to show from a cacheable wire; only this
        // point in this transaction knows whether there is actually somebody to demote. See
        // FIRST_APPOINTMENT_ONLY_MESSAGE for the race it closes and for why the converse is
        // deliberately not enforced.
        if (outgoing != null && REASON_INITIAL_APPOINTMENT.equals(reason)) {
            throw new BovSubmissionException(FIRST_APPOINTMENT_ONLY_MESSAGE);
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

            // ── 🔴 THE HISTORY ROW, LAST, INSIDE THE SAME SAVEPOINT ──────────
            // Last because a row asserting "CBRE was replaced by JLL" that outlives a rolled-back
            // replacement is a durable, reportable lie about a sale — strictly worse than the
            // absence of history. Inside the savepoint because the converse is also true: a
            // replacement that happened with no record of who did it or why is what this
            // append-only log exists to make impossible. Both directions, one savepoint.
            //
            // ── SYSTEM_MODE, for the same reason as the submission write above ──
            // BOV_Broker_Change__c is a 2026-08-20 object and EVERY field on it arrives with NO
            // permissions for ANY profile, System Administrator included (its own object header
            // says so). More fundamentally, an audit row that a user can suppress by lacking FLS on
            // one of its columns is not an audit row — the actor must not be able to decline to be
            // recorded. Note the deliberate asymmetry with `BovBrokerChangeSelector`, which reads
            // this object in USER_MODE: that read is a DISPLAY the user asked for and may degrade
            // to "unavailable", whereas this write is performed on their behalf and may not.
            // allOrNone = true, matching the swap above.
            //
            // ⚠ ONE REFUSAL PATH IS WORTH KNOWING ABOUT: `Outgoing_Broker__c` / `Incoming_Broker__c`
            // carry an ACTIVE, NON-OPTIONAL lookup filter (the `Contact.Broker` RECORD TYPE) which
            // the platform enforces on Apex DML. (⚠ 2026-08-20: this read `Contact.Is_Broker__c =
            // true`; the broker definition moved to the record type. The refusal path itself is
            // unchanged — only what triggers it moved.) A broker Contact since moved off that type
            // therefore refuses the whole replacement, with the filter's own error message surfaced
            // verbatim by the DmlException catch below. That is deliberately not worked around
            // here: silently nulling the lookup to get the insert through would discard the very
            // linkage the row exists to hold, and re-flagging the Contact is the real fix.
            Database.insert(new BOV_Broker_Change__c(
                Disposition__c = dispositionId,
                // Null on both outgoing columns when there was no incumbent — "replace" degrading
                // to "appoint" is a normal state, not an error, and the row still records the
                // appointment. See this method's own no-incumbent note.
                Outgoing_BOV_Submission__c = (outgoing == null) ? null : outgoing.Id,
                Outgoing_Broker__c = (outgoing == null) ? null : outgoing.Broker__c,
                // 🔴 THE FIRM IS STAMPED, NOT LEFT TO THE LOOKUP. Both Contact lookups are
                // deleteConstraint SetNull and scripts/seed-broker-contacts.apex mass-deletes every
                // broker Contact, so the lookups can go blank later with no error at all. This
                // Text column is what survives that. It is sourced from the SUBMISSION's
                // Broker_Firm__c rather than by re-querying Contact because
                // BovSubmissionBrokerStampService keeps that column equal to
                // `Broker__c.Broker_Firm__c` on every save — same value, no second SOQL.
                Outgoing_Broker_Firm__c = (outgoing == null) ? null : outgoing.Broker_Firm__c,
                Incoming_BOV_Submission__c = challenger.Id,
                Incoming_Broker__c = challenger.Broker__c,
                Incoming_Broker_Firm__c = challenger.Broker_Firm__c,
                Reason__c = reason,
                Notes__c = notes,
                // The write time IS the event time — see the javadoc on why there is no
                // effectiveDate parameter to disagree with it.
                Entry_DateTime__c = System.now(),
                Logged_By__c = UserInfo.getUserId()
            ), true, AccessLevel.SYSTEM_MODE);
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
        // 🔴 BRANCHED ON WHAT HAPPENED, NOT ON WHAT WAS ASKED FOR. `outgoing` is the incumbent this
        // transaction actually demoted; there is no "which button did you click" parameter and
        // there must not be one, or the sentence could disagree with the four writes above it.
        return (outgoing == null) ? APPOINTED_MESSAGE : REPLACED_MESSAGE;
    }
}
