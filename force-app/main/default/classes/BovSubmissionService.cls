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
 * WHAT A REPLACEMENT IS, IN FOUR-OR-FIVE WRITES THAT MUST NOT COME APART
 * ══════════════════════════════════════════════════════════════════════════════
 *   1. the INCUMBENT  -> `Submission_Status__c = 'Backup'` and `Approval_Status__c` CLEARED
 *   2. the CHALLENGER -> `Submission_Status__c = 'Selected'` and `Approval_Status__c` CLEARED
 *   3. the DISPOSITION -> `Selected_Broker__c` = the challenger's `Broker_Firm__c`
 *   3a. the NEW LISTING -> one `Broker_Listing__c` opening the incoming broker's OWN clock, and
 *      ONLY when the sale already has a listing (2026-09-01, Tranche 4 item 5 / design D-9, D-10,
 *      D-16). CONDITIONAL — see `replaceSelectedBroker`; on most replacements it does not happen.
 *   4. the HISTORY ROW -> one `BOV_Broker_Change__c` recording who was replaced by whom, why,
 *      and when (2026-08-20, Tranche 2 Workstream B / design D4.3)
 *
 * ⚠ WRITE 4 WAS ADDED AFTER THE OTHER THREE AND THIS BLOCK USED TO READ "THREE WRITES". It is
 * corrected rather than appended to, because a header that undercounts its own DML is how a budget
 * line stops being a contract.
 * ⚠ AND IT USED TO READ "FOUR WRITES" UNTIL 2026-09-01, corrected again in the same spirit. Write
 * 3a is numbered rather than renumbering write 4, because write 4's identity — "the LAST DML,
 * inside the savepoint" — is asserted by a test and argued three paragraphs down. 🔴 WRITE 3a GOES
 * BEFORE IT AND MUST STAY THERE.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT WRITE 3a IS **NOT**: IT DOES NOT RESET THE MARKETING CLOCK, AND MUST NEVER BE MADE TO.
 * ══════════════════════════════════════════════════════════════════════════════
 * The story asked for "the Active Listing clock to restart when the broker is replaced". Taken
 * literally that means rewriting `Disposition__c.Listing_Date__c` — and that is REFUSED, by user
 * decision at Gate 1 and by two class headers that already refuse it in terms:
 *   `DispositionTractionService:166-172` — "Using the child's date would silently reset the clock
 *   the moment a broker was replaced — i.e. exactly when the clock matters most."
 *   `BrokerListingController:164-168` — "...which, now that this card carries a Replace Broker
 *   button, is one click away rather than hypothetical."
 * `Disposition__c.Listing_Date__c` also feeds `Disposition__c.Days_On_Market__c`, the
 * `Dispositions/Avg_Days_on_Market` report and the `Broker Alert Due` KPI, all of which would
 * change meaning WITH NO METADATA DIFF AT ALL.
 *
 * ✅ Days-on-Market is TWO facts and this write separates them rather than picking one: how long
 * the PROPERTY has been on the market (a market fact, survives a broker change — the parent's
 * clock, still the traction band's only input) and how long THIS BROKER has had it (a performance
 * fact, restarts — `Broker_Listing__c.Days_On_Market_Live__c` on the new row, surfaced by
 * `BrokerListingController.ListingRow.daysWithThisBroker`). Both are on the card, side by side.
 *
 * ✅ AND THE APPEND NEEDED NO SCHEMA CHANGE, because the repo designed for it in advance:
 * `BrokerListingSelector.selectMostRecentByDispositionId` is already
 * `ORDER BY CreatedDate DESC LIMIT 1` — "the current listing among several" — so `c/brokerListing`
 * follows the new row for free. `DispositionStageEntryService.openBrokerListings`' header says so
 * explicitly and names this action as the thing that would supply `Contact_Name__c`.
 *
 * ⚠ THE SUPERSEDED ROW IS LEFT ALONE AND STAYS VISIBLE. `Broker_Listing__c.Listing_Status__c` is
 * RESTRICTED to `On Track` / `At Risk` / `Hard Stop`, so there is no `Superseded` value to write,
 * and story 5's "exactly one active listing per on-market sale" is still unenforced by any rule,
 * trigger or flow. Adding that value is a restricted-picklist change that triggers this repo's
 * standing grep-repo-and-query-org sweep. OUT OF SCOPE, and reported rather than papered over.
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
 * 1-2 SOQL + 3-4 DML. No SOQL or DML in any loop.
 * ⚠ THIS LINE SAID "1 SOQL + 2 DML" UNTIL 2026-08-20 and was corrected in the same change that
 * added the third DML (the `BOV_Broker_Change__c` history insert). The three are: the bulk
 * submission update, the parent stamp, the history insert. The SOQL stayed at ONE — the history
 * row's broker Contact (`Broker__c`) and firm snapshot (`Broker_Firm__c`) are both carried by the
 * existing `selectStatusesByDispositionId` read rather than by a second query against Contact.
 * ⚠ AND IT SAID "1 SOQL + 3 DML" UNTIL 2026-09-01, corrected in the same change that added write
 * 3a, in the same style and for the same reason. BOTH numbers became RANGES rather than growing,
 * and the range is the contract:
 *   SOQL 1 on any REFUSED call (the submission read alone — every refusal happens before the
 *        second read), 2 on any call that gets as far as writing.
 *   DML  3 when the sale has no `Broker_Listing__c` yet, 4 when it has one.
 * The second SOQL is `BrokerListingSelector.selectByDispositionIds` and it is deliberately placed
 * AFTER the last refusal so a rejected click still costs one query. `Contact_Name__c` rides the
 * existing submission read (added to that SELECT in the same change) rather than adding a third.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * Per-transaction-singleton @AuraEnabled operation, invoked once per modal click: one disposition,
 * no loop over records, no trigger. The `.claude/rules/bulk-test-rule.md` 251-record mandate does
 * not apply — same shape and same exemption as `DispositionApprovalService`. Record that reasoning
 * in the test class header so review does not demand 251. ⚠ The submission write is still a single
 * BULK DML over however many submissions the disposition has.
 * ⚠ RE-EXAMINED 2026-09-01 RATHER THAN INHERITED, BECAUSE WRITE 3a PUTS A FOURTH OBJECT IN THE
 * TRANSACTION and an exemption that is not re-argued when its subject changes is how one stops
 * being true. The exemption HOLDS, on the same ground and not on precedent: the shape that would
 * break it is a LOOP over records, and there is still none — one disposition, one challenger, at
 * most one listing row, per click. Adding a fourth object multiplies the DML count by a constant,
 * not by the record count, which is exactly the property the 251 rule exists to test for.
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

    /**
     * The `Broker_Listing__c.Listing_Status__c` a broker's FIRST DAY opens at (2026-09-01, write
     * 3a). `Listing_Status__c` is RESTRICTED to `On Track` / `At Risk` / `Hard Stop`.
     *
     * ⚠ IT IS A SECOND COPY OF A LITERAL THAT ALSO LIVES IN
     * `DispositionStageEntryService.LISTING_INITIAL_STATUS`, AND THAT IS ACCEPTED RATHER THAN
     * UNNOTICED. The original is `@TestVisible private` — promoting it to `public` to share it
     * would export a stage-entry internal to an unrelated service and invite every other caller to
     * reach into that class for constants. Naming ONE value is not the same as holding a copy of
     * the VALUE SET, which is the distinction this class already draws at
     * `REASON_INITIAL_APPOINTMENT`: nothing here enumerates the options or validates membership,
     * and an off-list value would still be refused by the platform at DML with its own message.
     * 🔴 IF A `Superseded` VALUE IS EVER ADDED TO THAT PICKLIST, BOTH COPIES ARE IN THE SWEEP.
     * That is a restricted-picklist change and triggers this repo's standing
     * grep-the-repo-and-query-the-org rule; this comment is here so the second copy is found.
     */
    @TestVisible
    private static final String LISTING_INITIAL_STATUS = 'On Track';

    private static final String NO_RECORD_MESSAGE = 'No record was provided.';

    private static final String NOT_ON_DISPOSITION_MESSAGE =
        'That broker response does not belong to this disposition.';

    private static final String ALREADY_SELECTED_MESSAGE =
        'That broker is already the selected broker for this disposition.';

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE PREFERRED-BROKER REFUSAL THAT WAS HERE ON 2026-08-24 HAS BEEN **REMOVED**, SAME DAY.
     *    RETRACTED IN PLACE RATHER THAN DELETED, BECAUSE IT WAS CORRECT TWICE AND WRONG ONCE AND
     *    THE NEXT READER WILL OTHERWISE RE-ADD IT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHAT WAS HERE: a `PREFERRED_CANNOT_BE_APPOINTED_MESSAGE` constant and, in
     * `replaceSelectedBroker`, an unconditional
     * `if (challenger.Is_Preferred_Broker__c == true) throw ...` placed before the already-Selected
     * check. Design gate Q-5 asked whether the client filter on `c/bovComparisonMatrix` should be
     * backed by a server rule; it was first answered YES and is now answered **NO**.
     *
     * WHY IT WAS ADDED (and this reasoning was sound under the design as it then stood): preferred
     * rows were EXCLUDED from ranking and could never be `Selected`, so appointing one through this
     * method produced a state the rest of the system did not model.
     *
     * 🔴 WHY IT IS WRONG NOW: under the user's option-2 decision a preferred row **is** the
     * appointed, `Selected` incumbent in the normal case. The matrix's picker excludes preferred
     * rows not because promoting one is forbidden, but because **promoting a broker to itself is
     * not an operation**. A blanket server refusal therefore blocked the intended STEADY STATE, not
     * an error state — and the genuine case it was reaching for is already covered, one check
     * below, by `ALREADY_SELECTED_MESSAGE`.
     *
     * ⚠ ONE RESIDUAL IS LEFT OPEN BY THE REMOVAL AND IS NAMED RATHER THAN HIDDEN, because it is the
     * half of the original argument that did NOT depend on the retracted premise. If
     * `replaceSelectedBroker` is called with a preferred row that is NOT currently the incumbent —
     * an older preferred row superseded by a newer one (`BovAutoSelectionService.isNewer`) — it is
     * now promoted AND stamped `Is_Manually_Appointed__c = true`, which is a PERMANENT lock leg. The
     * consequence is a trapdoor: unflagging that row later will NOT hand the sale back to scoring,
     * because the manual-appointment lock outlives the flag, and nothing explains why. It is not
     * reachable from the UI (the picker filters preferred rows out) and it requires a deliberate
     * API call, which is why it is accepted rather than guarded. 🔴 IF IT EVER NEEDS CLOSING, THE
     * FIX IS THE NARROW FORM, NOT THE BLANKET ONE: refuse only when the challenger is preferred AND
     * is not already `Selected`. Do not restore the unconditional version.
     */

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
            // ══════════════════════════════════════════════════════════════════════════════════
            // 🔴 `&& NOT PREFERRED` ADDED 2026-08-24 WITH THE TWO-SLOT MODEL, AND IT IS A BEHAVIOUR
            //    CHANGE, NOT A TIDY. WITHOUT IT THIS METHOD SILENTLY DEMOTES THE PREFERRED BROKER.
            // ══════════════════════════════════════════════════════════════════════════════════
            // A Disposition now holds TWO independent appointment slots — the preferred broker a
            // human named, and the scored/appointed one (see `BovAutoSelectionService`'s header).
            // Replace Broker operates on the SECOND slot only: it is reached from the comparison
            // matrix's ranked list, its `Reason__c` value set is about a broker's PERFORMANCE on the
            // listing, and the preferred slot is changed a different way entirely (Add Preferred
            // Broker, which retires the outgoing row via `BovPreferredBrokerService`).
            //
            // Under the old unconditional test this loop demoted EVERY Selected row, so a single
            // Replace Broker click on a sale that also had a preferred broker would have knocked
            // the preferred broker out of its slot — with no history row naming it, because the
            // single `Outgoing` slot below would have recorded the other row. That is a change the
            // user did not ask for and could not undo from this button.
            // `replaceBroker_leavesAPreferredBrokerAlone` is the falsifier.
            if (STATUS_SELECTED.equals(submission.Submission_Status__c)
                && submission.Is_Preferred_Broker__c != true) {
                if (outgoing == null) {
                    outgoing = submission;
                }
                writes.add(new BOV_Submission__c(
                    Id = submission.Id,
                    Submission_Status__c = STATUS_BACKUP,
                    // 🔴 The incumbent's approval is REVOKED, not preserved. An 'Approved' status on
                    // a demoted broker reads as an appointment nobody made.
                    Approval_Status__c = null,
                    // The outgoing row is no longer the model's pick either. Cleared here for the
                    // same reason `BovAutoSelectionService` clears it on its own demotions: two rows
                    // claiming to be system-selected is the state the exclusivity guard exists to
                    // make unreachable.
                    Is_System_Selected__c = false
                ));
            }
        }
        if (challenger == null) {
            throw new BovSubmissionException(NOT_ON_DISPOSITION_MESSAGE);
        }
        // ⚠ NO PREFERRED-BROKER REFUSAL HERE — REMOVED 2026-08-24, gate Q-5 answered NO. The
        // retraction and the one residual it leaves open are at the top of this class, where the
        // deleted constant used to be. The check immediately below is what now covers the genuine
        // case: a preferred row is normally the incumbent, and "promote a broker to itself" is not
        // an operation.
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
            Approval_Status__c = null,
            // ── 🔴 ADDED 2026-08-24, AND IT IS LOAD-BEARING FOR A FEATURE IN ANOTHER FILE ──
            // The permanent "a human deliberately chose this broker" marker, and the third leg of
            // `BovAutoSelectionService`'s LOCK predicate. Without it, the line IMMEDIATELY ABOVE
            // would defeat the lock: clearing `Approval_Status__c` on both rows (which is correct,
            // and is why the replacement needs a fresh approval) leaves every OTHER lock leg false,
            // so automatic re-selection would UNLOCK and silently undo this user's deliberate pick
            // on the very next BOV save. The two assignments are a pair; do not remove one.
            // ⚠ ZERO NEW DML AND ZERO NEW SOQL — it rides the existing bulk write below. It is
            // never cleared: `Is_Manually_Appointed__c` is READ-ONLY FLS in both disposition
            // permission sets by design, and the lock is meant to be permanent for this sale.
            Is_Manually_Appointed__c = true,
            // ── 🔴 ADDED 2026-08-24. A MANUAL APPOINTMENT IS NOT A SCORING PICK. ──
            // `Is_System_Selected__c` names the row `BovAutoSelectionService` chose. This challenger
            // was chosen by a human clicking Replace Broker, and the very next line above LOCKS
            // auto-selection out of this sale permanently — so nothing will ever come along and set
            // the flag correctly afterwards. Written as an explicit FALSE rather than left alone
            // because the challenger may be a row that WAS system-selected on an earlier round;
            // leaving a stale true here would leave two rows claiming to be the model's pick.
            Is_System_Selected__c = false
        ));

        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 THE ONE CONDITION THAT MAKES WRITE 3a SAFE, AND IT IS NOT OPTIONAL (design D-10).
        //    "DOES THIS SALE ALREADY HAVE A LISTING?" — nothing else, no stage read.
        // ══════════════════════════════════════════════════════════════════════════════════════
        // Replace Broker is reachable from TWO surfaces, both markup-composed in
        // `c/dispositionMain`: `c/brokerListing` at **Active Listing** (:69) and
        // `c/bovBrokerPanel` at **BOV Outreach** (:42). At BOV Outreach there is no listing and the
        // marketing period has not started, so appending one there is not merely premature —
        // 🔴 IT WOULD PERMANENTLY POISON THE STAGE-ENTRY AUTO-CREATE.
        // `DispositionStageEntryService.openBrokerListings`' idempotency test is SIMPLE PRESENCE
        // ("this disposition already has a broker listing", any listing, not keyed on the broker).
        // A listing created during BOV Outreach therefore makes the Active Listing auto-create a
        // PERMANENT NO-OP for that sale, leaving it with a listing whose `List_Date__c` predates
        // the listing and whose `Broker_Firm__c` was never stamped from `Selected_Broker__c`.
        // Silent, months later, and unrecoverable without hand repair.
        //
        // ⚠ "A LISTING EXISTS" IS EXACTLY EQUIVALENT TO "THE SALE REACHED ACTIVE LISTING" and is
        // preferred to reading the stage, deliberately: the stage can move on past Active Listing
        // (Closing, Closed) and a stage equality test would then stop appending, while the listing
        // is still the live one the card shows. The presence test is the same fact the auto-create
        // itself keys on, so the two can never disagree about what "listed" means.
        //
        // ⚠ PLACED AFTER THE LAST REFUSAL SO A REJECTED CLICK STILL COSTS ONE QUERY — see the
        // class header's budget range. It is a READ and needs no savepoint; nothing above creates
        // a listing, so its answer cannot be invalidated by writes 1-3.
        //
        // ⚠ AN EXISTING SELECTOR METHOD, NOT A NEW ONE. `selectByDispositionIds` selects
        // `Id, Disposition__c` only — "does one exist?", nothing more — and is `WITH SYSTEM_MODE`,
        // so it cannot throw an FLS denial into a user's replacement. It IS sharing-scoped
        // (`with sharing` on that selector, argued in its own header), so a principal who cannot
        // SEE the listing reads zero and appends nothing. 🔴 THAT IS THE SAFE DIRECTION AND IT IS
        // WHY THE POLARITY OF THIS GUARD MATTERS: a false NEGATIVE skips an append, which is
        // visible on the card and repairable by hand; a false POSITIVE creates the BOV-Outreach
        // listing above and is silent forever.
        Boolean saleIsListed = !BrokerListingSelector
            .selectByDispositionIds(new Set<Id>{ dispositionId })
            .isEmpty();

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

            // ── 🔴 WRITE 3a: THE INCOMING BROKER'S OWN LISTING, CONDITIONAL ──
            // Tranche 4 item 5 (design D-9 / D-10 / D-16). The class header carries the full
            // argument for why this APPENDS rather than resetting `Disposition__c.Listing_Date__c`,
            // and `saleIsListed`'s own block above carries the argument for the condition. Neither
            // is repeated here; read them before changing this.
            //
            // ⚠ IT SITS BEFORE THE HISTORY ROW, NOT AFTER. Write 4's identity is "the LAST DML,
            // inside the savepoint" — a `BOV_Broker_Change__c` that outlives a rolled-back
            // replacement is a durable, reportable lie — and `lockedDisposition_refuses...` is the
            // falsifier for it. Appending after it would make the history row no longer last.
            //
            // ── SYSTEM_MODE, AND THE DESIGN'S USER_MODE RECOMMENDATION IS DELIBERATELY REFUSED ──
            // 🔴 THE DESIGN (D-10) ARGUED `USER_MODE` ON THE GROUND THAT "replaceSelectedBroker
            // already asserts DispositionActionPermissionService, so the caller is by construction
            // a disposition driver". MEASURED 2026-09-01, THAT PREMISE IS FALSE.
            // `DispositionActionPermissionService.computeDispositionActionAccess` passes on the
            // `Disposition_Deal_Actions` custom permission **OR on "Modify All Data"**. Modify All
            // Data lifts object CRUD and sharing; it does NOT lift FLS. And every
            // `Broker_Listing__c` field permission in this repo lives in exactly two files —
            // `DPEG_Disposition_Edit` and `DPEG_Disposition_View` — so an administrator holding
            // neither passes the gate and holds ZERO editable FLS on `Broker_Firm__c`,
            // `Contact_Name__c`, `List_Date__c` and `Listing_Status__c`. `DPEG_Disposition_View`
            // additionally carries `allowCreate = false` on the object.
            // ⇒ A `USER_MODE` insert would throw `DmlException`, be caught below, and REFUSE AND
            // ROLL BACK THE ENTIRE REPLACEMENT — an operation those principals could perform
            // yesterday — with a platform message about an object they were not trying to touch.
            // A write added to enrich an action must not be able to destroy it.
            //
            // ⚠ AND THE HONEST COUNTER-STATEMENT, copied in spirit from `openBrokerListings`, which
            // makes the same trade for the same object: SYSTEM_MODE here lets a principal create a
            // `Broker_Listing__c` they could not create by hand. It is bounded three ways — the row
            // exists only as a consequence of a replacement they were already authorised to
            // perform, every value on it is derived from records already in this transaction, and
            // NO USER INPUT REACHES IT (`reason` and `notes` go to the history row, never here).
            // Do not restate any "the persona has no create" line: for the ANALYST persona it is
            // measurably untrue, and the reason is the admin/MAD path above.
            // allOrNone = true, matching every other write in this savepoint.
            if (saleIsListed) {
                Database.insert(
                    new Broker_Listing__c(
                        Disposition__c = dispositionId,
                        // 🔴 `Date.today()`, NOT the parent's `Listing_Date__c`. This is the ONE
                        // place the two clocks are allowed to diverge, and it is the entire point
                        // of the feature: the marketing clock keeps running from when the PROPERTY
                        // went to market, and the broker clock starts now.
                        List_Date__c = Date.today(),
                        Broker_Firm__c = challenger.Broker_Firm__c,
                        // D-16. `openBrokerListings` leaves this blank and says "A human fills it,
                        // or the future broker-change action supplies it." This is that action.
                        // It also closes, for replacements at Active Listing only, the defect where
                        // the listing row kept naming the OLD broker after a swap: `Broker_Firm__c`
                        // was stamped once at stage entry and nothing re-stamped it.
                        Contact_Name__c = challenger.Contact_Name__c,
                        // A fresh broker starts On Track. Set explicitly even though it equals the
                        // field default, for the reason `openBrokerListings` gives at
                        // LISTING_INITIAL_STATUS: an implicit default is not falsifiable by a test.
                        Listing_Status__c = LISTING_INITIAL_STATUS
                    ),
                    true,
                    AccessLevel.SYSTEM_MODE
                );
            }

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
            Database.insert(
                buildChangeRow(dispositionId, outgoing, challenger, reason, notes),
                true,
                AccessLevel.SYSTEM_MODE
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
        // 🔴 BRANCHED ON WHAT HAPPENED, NOT ON WHAT WAS ASKED FOR. `outgoing` is the incumbent this
        // transaction actually demoted; there is no "which button did you click" parameter and
        // there must not be one, or the sentence could disagree with the four writes above it.
        return (outgoing == null) ? APPOINTED_MESSAGE : REPLACED_MESSAGE;
    }
    /**
     * Builds — and does NOT insert — the one `BOV_Broker_Change__c` row that records a broker
     * changing hands on a Disposition. Extracted from `replaceSelectedBroker` on 2026-08-24 so the
     * PREFERRED-broker retirement path (`BovPreferredBrokerService`) writes an IDENTICALLY SHAPED
     * row instead of a second, drifting one.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 ONE BUILDER, TWO INSERTS, AND THAT SPLIT IS DELIBERATE RATHER THAN LAZY.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * What the two callers MUST share is the ROW SHAPE — which columns are stamped, that the firm
     * Text is copied rather than left to the lookup, that `Entry_DateTime__c` is the write time and
     * `Logged_By__c` the running user. A second hand-rolled literal is exactly how a history log
     * acquires rows that answer half the questions it is read to answer.
     *
     * What they must NOT share is the DML, because the two paths sit in different transactions with
     * different obstacles: `replaceSelectedBroker` inserts inside its own savepoint and converts a
     * refusal into an authored `BovSubmissionException` for a user who is standing there;
     * `BovPreferredBrokerService` inserts from an AFTER-INSERT TRIGGER and must additionally escape
     * SHARING, because the row it is recording belongs to somebody else. Merging the inserts would
     * force one of those two shapes onto the other.
     *
     * ⚠ IT DOES NOT VALIDATE `reason`. `Reason__c` is a RESTRICTED picklist and this repo's standing
     * rule (recorded at `REASON_INITIAL_APPOINTMENT`) is that Apex does not hold a second copy of a
     * value set — the platform refuses an off-list value with its own message, at DML, and that
     * refusal is louder and more correct than an assertion here would be.
     *
     * @param dispositionId the sale the change happened on (required)
     * @param outgoing      the submission losing the appointment; NULL is legal and means a FIRST
     *                      appointment — both Outgoing columns are then left blank rather than the
     *                      row being suppressed.
     * @param incoming      the submission gaining it (required)
     * @param reason        a `BOV_Broker_Change__c.Reason__c` value; validated by the platform
     * @param notes         free text; null and blank are both fine
     * @return an UNSAVED `BOV_Broker_Change__c`. The caller owns the insert, its access level and
     *         its failure handling.
     * @example
     * BOV_Broker_Change__c row = BovSubmissionService.buildChangeRow(
     *     dispId, outgoingSubmission, incomingSubmission, 'Company Decision', 'Swapped at request.');
     */
    public static BOV_Broker_Change__c buildChangeRow(
        Id dispositionId,
        BOV_Submission__c outgoing,
        BOV_Submission__c incoming,
        String reason,
        String notes
    ) {
        return new BOV_Broker_Change__c(
            Disposition__c = dispositionId,
            // Null on both outgoing columns when there was no incumbent — "replace" degrading
            // to "appoint" is a normal state, not an error, and the row still records the
            // appointment. See `replaceSelectedBroker`'s own no-incumbent note.
            Outgoing_BOV_Submission__c = (outgoing == null) ? null : outgoing.Id,
            Outgoing_Broker__c = (outgoing == null) ? null : outgoing.Broker__c,
            // 🔴 THE FIRM IS STAMPED, NOT LEFT TO THE LOOKUP. Both Contact lookups are
            // deleteConstraint SetNull and scripts/seed-broker-contacts.apex mass-deletes every
            // broker Contact, so the lookups can go blank later with no error at all. This
            // Text column is what survives that. It is sourced from the SUBMISSION's
            // Broker_Firm__c rather than by re-querying Contact because
            // BovSubmissionBrokerStampService keeps that column equal to
            // `Broker__c.Broker_Firm__c` on every save — same value, no second SOQL.
            // 🔴 IT IS ALSO THE ONLY COLUMN THAT SURVIVES THE ROW BEING **DELETED**, which the
            // preferred-retirement path does on purpose: `Outgoing_BOV_Submission__c` goes blank
            // the moment the submission is removed, so a history card that showed only the lookup
            // would show an empty swap. Do not stop stamping this.
            Outgoing_Broker_Firm__c = (outgoing == null) ? null : outgoing.Broker_Firm__c,
            Incoming_BOV_Submission__c = (incoming == null) ? null : incoming.Id,
            Incoming_Broker__c = (incoming == null) ? null : incoming.Broker__c,
            Incoming_Broker_Firm__c = (incoming == null) ? null : incoming.Broker_Firm__c,
            Reason__c = reason,
            Notes__c = notes,
            // The write time IS the event time — see `replaceSelectedBroker`'s javadoc on why
            // there is no effectiveDate parameter to disagree with it.
            Entry_DateTime__c = System.now(),
            Logged_By__c = UserInfo.getUserId()
        );
    }
}
