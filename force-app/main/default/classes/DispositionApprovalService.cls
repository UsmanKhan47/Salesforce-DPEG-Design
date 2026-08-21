/**
 * Service behind the DISPOSITION approval quick actions — the sell-side twin of
 * OpportunityApprovalService, added 2026-08-19 with the disposition flow redesign (design DEV-2).
 * Backs DispositionApprovalController.
 *
 * It owns two operations:
 *   `submitForApproval(dispositionId)`  DERIVES which of four approvals a Submit click means, from
 *                                       the disposition's STAGE and RECORD TYPE, pre-checks that
 *                                       approval's own entry criteria, and submits.
 *   `selectOffer(dispositionId, offerId)` the two-step offer selection (design D-3): flip the
 *                                       exclusive `Is_Selected__c` flag, advance the stage to
 *                                       `Offer Selection`, and submit the OFFER for approval —
 *                                       all under one savepoint.
 *
 * ── 🔴 WHY THE TARGET IS DERIVED AND NEVER SUPPLIED ──────────────────────────
 * One quick-action LWC (`c/dispositionSubmitForApproval`) backs FOUR quick actions
 * (Submit_Sale_Decision, Submit_Selected_Broker, Submit_Broker_Selection,
 * Submit_Closing_Approval) whose only difference is the Dynamic Actions visibility rule that
 * decides which one is on the page. A visibility rule is a UX affordance and nothing else — any
 * direct @AuraEnabled call bypasses it — so if this method took a "which approval" parameter, a
 * hand-crafted call could submit a Closing approval on a record sitting at Readiness. Deriving
 * from the record's own state makes that unexpressible, exactly as
 * `RecordStageAdvanceService.advance` derives its stage target rather than accepting one.
 *
 * ── 🔴 AND WHY EVERY BRANCH PRE-CHECKS ITS OWN ENTRY CRITERIA ────────────────
 * An approval whose entry criteria the record does not meet fails with the platform's
 * "no applicable approval process was found" — a sentence that is true, useless, and
 * indistinguishable from "an administrator deactivated the process". Two of the four branches have
 * a criterion a user can actually satisfy, and both are checked here with AUTHORED wording:
 *
 *   `Broker Selection` (off-market)  `Broker__c` must be non-null
 *   `Closing`                        `Wire_Verification_Completed__c` must be true
 *
 * ⚠ THE FIRST ROW CHANGED ON 2026-08-20 (off-market broker lookup) AND THE OLD FORM MUST NOT COME
 * BACK. It used to read `String.isBlank(Selected_Broker__c)` — a non-blank TEXT field. The gate now
 * requires the Contact LOOKUP, so the broker on an off-market disposition is a real record in the
 * system rather than a string naming nobody. **`Selected_Broker__c` is NOT retained as an `||`
 * fallback, and adding one would invert the purpose of the change twice over:** it would let a
 * hand-typed name satisfy the very gate that exists to stop exactly that, and — because
 * `DispositionBrokerStampService` DERIVES `Selected_Broker__c` from `Broker__c` on every off-market
 * pick — the fallback would be satisfied by the feature's own output, making the gate unfailable.
 * There is also no population to protect: the off-market path was rebuilt from scratch on
 * 2026-08-19 and the org sweep found zero Off_Market rows.
 *
 * 🔴 THE SECOND ONE IS A DELIBERATE SUPERSESSION AND MUST NOT BE READ AS DUPLICATION. Until this
 * redesign, `Wire_Complete_Before_Completed`'s XML comment recorded a design decision (Q4) that
 * the wire flag must NOT be an approval `entryCriteria` — reasoning, correctly, that an unmet
 * entry criterion surfaces as that opaque platform error. The redesign ADDS the criterion anyway,
 * because without it the AdminOnly approval lock and the wire rollup deadlock each other; THIS
 * PRE-CHECK IS THE MITIGATION THAT MAKES THAT TRADE PAY. Deleting it does not break the submit —
 * it silently restores the exact error the Q4 decision was written to avoid.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). ZERO inline SOQL: every read
 * goes to a selector (DispositionSelector, BovSubmissionSelector, DispositionOfferSelector,
 * ProcessInstanceSelector). Record-type resolution is a DESCRIBE, not a query, so it costs no SOQL.
 *
 * ── EXCEPTION CONTRACT (copied from OpportunityApprovalService, which is the point) ──
 *   - A user-actionable rule violation throws a TYPED {@link ApprovalException} whose message is
 *     authored here and safe to surface VERBATIM (no record, no Selected BOV, MORE THAN ONE
 *     Selected BOV, blank broker, wire incomplete, already pending, wrong stage, offer not on this
 *     disposition).
 *   - A DML BLOCK on the stage advance surfaces the platform's own message verbatim inside an
 *     ApprovalException — that is deliberate and is the same choice `RecordStageAdvanceService
 *     .setStage` makes: a validation rule's text is the ONLY thing that tells the user which gate
 *     stopped them, and swallowing it is how a rule ships invisible.
 *   - Anything else (a QueryException from a missing/inaccessible record, a genuine
 *     `Approval.process` failure at an otherwise-eligible stage) is left to propagate RAW. This
 *     service NEVER throws AuraHandledException — the controller maps a raw failure to a fixed,
 *     generic, user-safe message (ARCHITECTURE.md §5).
 *
 * ── PERMISSION ──────────────────────────────────────────────────────────────
 * Both public methods open with `DispositionActionPermissionService.assertDispositionActionAccess()`
 * as their FIRST statement, before any read. Same reason OpportunityApprovalController states: the
 * Dynamic Actions rule is a UX affordance, and the server assert asks the same question, so no user
 * gains or loses access. ⚠ It is the DISPOSITION gate (`Disposition_Deal_Actions`), never
 * `Acquisition_Deal_Actions` — those are two separate authorization boundaries and a sale must not
 * be drivable by an acquisitions deal driver.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * Both methods are per-transaction-singleton @AuraEnabled operations invoked once per quick-action
 * click: one record, no loop over records, no collection DML across records. The
 * `.claude/rules/bulk-test-rule.md` 251-record mandate does not apply — the same shape and the same
 * exemption `RecordStageAdvanceService` and `OpportunityApprovalService` already carry. Record that
 * reasoning in the test class header so review does not demand 251.
 * ⚠ The exemption is about VOLUME only. `selectOffer` still performs ONE bulk DML over the
 * disposition's offers and holds zero SOQL/DML inside any loop.
 *
 * @see force-app/main/default/classes/DispositionApprovalController.cls (thin caller)
 * @see force-app/main/default/classes/OpportunityApprovalService.cls (the acquisitions twin)
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls (what an APPROVAL does
 *      afterwards — this class submits, that one advances)
 */
public with sharing class DispositionApprovalService {

    /**
     * Raised when a submission or selection cannot proceed and the reason is user-actionable and
     * safe to surface verbatim. An UNEXPECTED failure is deliberately NOT wrapped in this type —
     * it propagates raw for the controller to mask with a fixed generic message.
     *
     * ⚠ ONE EXCEPTION TO "AUTHORED HERE": the stage-advance DML block re-wraps the PLATFORM's
     * validation-rule message in this type on purpose. That is the one place raw platform text is
     * WANTED, because the rule's own wording is the only thing that identifies the gate. See
     * `selectOffer`.
     */
    public class ApprovalException extends Exception {}

    // ── Stage literals. Runtime picklist values, matching Disposition_Stage__c exactly. ──
    @TestVisible
    private static final String STAGE_READINESS = 'Disposition Readiness';
    @TestVisible
    private static final String STAGE_BOV_OUTREACH = 'BOV Outreach';
    @TestVisible
    private static final String STAGE_BROKER_SELECTION = 'Broker Selection';
    @TestVisible
    private static final String STAGE_RELEASE_MATERIALS = 'Release Materials';
    @TestVisible
    private static final String STAGE_ACTIVE_LISTING = 'Active Listing';
    @TestVisible
    private static final String STAGE_OFFER_SELECTION = 'Offer Selection';
    @TestVisible
    private static final String STAGE_CLOSING = 'Closing';

    /**
     * Record type developer names — ALIASES of the canonical pair on `DispositionDomain`, not
     * literals (code review C-2, 2026-08-19). The local names are kept because they read better at
     * the point of use, but the VALUE has exactly one source, so this class and
     * `DispositionApprovalAdvanceService` can no longer disagree about the casing the way their two
     * private `recordTypeNameOf` copies disagreed about the Master default. Do not re-inline them.
     */
    @TestVisible
    private static final String RT_ON_MARKET = DispositionDomain.RT_ON_MARKET;
    @TestVisible
    private static final String RT_OFF_MARKET = DispositionDomain.RT_OFF_MARKET;

    // ── Authored, user-safe messages. No platform text, no field API names. ──────

    private static final String NO_RECORD_MESSAGE = 'No record was provided.';

    private static final String NO_SELECTED_BOV_MESSAGE =
        'No broker is marked Selected yet. Choose a broker in the BOV comparison matrix, '
        + 'then submit for approval.';

    /**
     * The `BOV Outreach` branch's SECOND refusal, added 2026-08-21 with the Select Broker picker.
     *
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 THIS IS A BACKSTOP, NOT A LIVE BUG, AND IT IS NOT DEAD CODE. DO NOT DELETE IT.
     * ══════════════════════════════════════════════════════════════════════════════
     * `BovSubmissionSelectionGuardService` runs at `before insert` AND `before update` on
     * `BOV_Submission__c` and refuses any save that would leave a disposition with two Selected
     * responses, so **as of 2026-08-21 this branch is UNREACHABLE THROUGH THE UI.** A reader who
     * checks that guard and concludes this message can never fire is reading it correctly — and
     * would still be wrong to remove it, because the guard does not cover every way the state can
     * arise:
     *   - `BovSubmissionTrigger` declares no `after undelete` context (and the platform has no
     *     BEFORE undelete context at all), so restoring a previously-Selected submission from the
     *     Recycle Bin onto a disposition that has since appointed someone else creates a second
     *     Selected row NO guard sees. That is the path the test fixture uses, because it is real.
     *   - rows that predate the guard (2026-08-20) were never validated by it;
     *   - the guard's sibling read is `with sharing`, so it FAILS OPEN — a Selected row the saving
     *     user cannot see is absent from its count and the save is permitted.
     * The cost of keeping this branch is one comparison per Submit click. The cost of removing it
     * is submitting an arbitrary one of two brokers into `Broker_Finalize_Approval` and appointing
     * a broker nobody chose.
     *
     * ⚠ IT NAMES THE ON-SCREEN LABELS `Selected` AND `Backup`, NOT FIELD API NAMES, per this
     * class's stated convention. Those are the only two values `Submission_Status__c` is
     * restricted to, so both are visible to the user doing the fixing.
     */
    private static final String MULTIPLE_SELECTED_BOV_MESSAGE =
        'More than one broker response is marked Selected on this disposition, and exactly one is '
        + 'required. Set all but the appointed broker to Backup in the BOV comparison matrix, '
        + 'then submit for approval.';

    /**
     * ⚠ RE-AUTHORED 2026-08-20. The previous wording said "Set the Selected Broker", which now names
     * the WRONG field — `Selected Broker` became a derived, read-back display value and setting it
     * by hand no longer satisfies anything. This names `Broker`, the on-screen LABEL of the lookup
     * the analyst must actually use, not its API name, per this class's stated convention above.
     *
     * RENAMED from `NO_SELECTED_BROKER_MESSAGE` (unit-testing agent pass, 2026-08-20, code review
     * Suggestion 1) — the constant now guards `Broker__c`, not `Selected_Broker__c`, and the old name
     * implied the field this class was rewritten to stop reading. See the pre-check below.
     */
    private static final String NO_BROKER_MESSAGE =
        'No broker has been selected on this disposition yet. Choose a broker in the Broker '
        + 'field, then submit for approval.';

    /**
     * 🔴 THE AUTHORED REPLACEMENT FOR "no applicable approval process was found". See the class
     * header — this string is the entire mitigation for adding the wire flag to
     * `Closing_Approval`'s entry criteria.
     */
    private static final String WIRE_INCOMPLETE_MESSAGE =
        'Wire verification must be complete before the closing approval can be submitted. '
        + 'Verify the wire on this disposition, then try again.';

    /**
     * The on-market `Broker Selection` case. An on-market disposition reaches `NDA` through the
     * Advance to NDA quick action, NOT through `Broker_Selection_Approval` (whose entry criteria
     * are `Broker Selection` AND record type Off Market). Without this branch the click would reach
     * `Approval.process` and come back as the platform's opaque refusal.
     */
    private static final String ON_MARKET_BROKER_SELECTION_MESSAGE =
        'An on-market disposition does not need a broker-selection approval - '
        + 'use Advance to NDA once the broker is appointed.';

    private static final String ALREADY_PENDING_MESSAGE =
        'This record is already pending approval.';

    private static final String OFFER_NOT_ON_DISPOSITION_MESSAGE =
        'That offer does not belong to this disposition.';

    // ── Authored success messages, one per branch. The user must be told WHICH approval. ──
    private static final String SUBMITTED_SALE_DECISION_MESSAGE =
        'The disposition has been submitted for the Sale Decision approval.';
    private static final String SUBMITTED_BROKER_FINALIZE_MESSAGE =
        'The selected broker has been submitted for approval.';
    private static final String SUBMITTED_BROKER_SELECTION_MESSAGE =
        'The broker selection has been submitted for approval.';
    private static final String SUBMITTED_CLOSING_MESSAGE =
        'The disposition has been submitted for the Closing approval.';
    private static final String OFFER_SELECTED_MESSAGE =
        'The offer has been selected and submitted for approval.';

    /**
     * Submits whichever approval this disposition's CURRENT STATE calls for.
     *
     * | stage / record type              | what is submitted                                    |
     * |----------------------------------|------------------------------------------------------|
     * | `Disposition Readiness`          | the DISPOSITION -> Sale_Decision_Approval            |
     * | `BOV Outreach` (on-market)       | the SELECTED BOV_Submission__c -> Broker_Finalize    |
     * | `Broker Selection` (off-market)  | the DISPOSITION -> Broker_Selection_Approval         |
     * | `Closing`                        | the DISPOSITION -> Closing_Approval                  |
     *
     * 🔴 THE SECOND ROW SUBMITS A DIFFERENT RECORD, AND THAT IS THE MOST IMPORTANT LINE HERE. The
     * on-market broker approval lives on the `BOV_Submission__c`, not on the Disposition (design
     * decision 3) — precisely so the AdminOnly lock lands on the SUBMISSION and leaves the parent
     * writable, which is what lets `BovSubmissionTriggerHandler` update the Disposition
     * SYNCHRONOUSLY when the approval completes. Moving this approval onto the Disposition would
     * silently re-introduce the ENTITY_IS_LOCKED class of failure that produced
     * `DispositionNdaStampQueueable`.
     *
     * ⚠ THE `BOV Outreach` BRANCH IS NOT RECORD-TYPE-GUARDED AND DOES NOT NEED TO BE. That value
     * is on the `On_Market` value set only, so the stage test is self-limiting — the same argument
     * `DispositionStageEntryService.LISTING_STAGE` records for `Active Listing`. The
     * `Broker Selection` branch IS guarded, because that value is on BOTH record types and the two
     * types reach `NDA` by different owners.
     *
     * ⚠ THE PENDING GATE IS APPLIED TO THE TARGET, NOT TO THE DISPOSITION. On the `BOV Outreach`
     * branch the target is the submission, so a Disposition with an unrelated pending approval does
     * not block a broker submission, and a re-click on an already-submitted broker is refused. Gating
     * the Disposition instead would get both cases wrong.
     *
     * @param dispositionId the Disposition__c whose state selects the approval (required)
     * @return an authored confirmation naming which approval was submitted
     * @throws ApprovalException for a user-actionable rule violation (safe to surface verbatim)
     * @throws System.QueryException when dispositionId matches no visible Disposition
     * @throws DispositionActionPermissionService.AccessDeniedException when the running user is not
     *         a disposition driver
     * @example
     * String msg = DispositionApprovalService.submitForApproval(dispositionId);
     */
    public static String submitForApproval(Id dispositionId) {
        DispositionActionPermissionService.assertDispositionActionAccess();
        if (dispositionId == null) {
            throw new ApprovalException(NO_RECORD_MESSAGE);
        }

        Disposition__c disposition = DispositionSelector.selectApprovalContextById(dispositionId);
        String stage = disposition.Disposition_Stage__c;
        // 🔴 NEVER NULL, AND THAT IS THE C-2 FIX. This class used to hold its own private copy of
        // this helper which returned null for a Master / unset row, while
        // `DispositionApprovalAdvanceService`'s copy returned On_Market. The `RT_ON_MARKET.equals`
        // guard below is false for null, so a Master row fell through to the OFF-MARKET branch,
        // submitted `Broker_Selection_Approval`, and then stranded its semaphore because the
        // advance map has no `On_Market|Broker Selection` entry. One shared helper, one answer.
        String recordType = DispositionDomain.recordTypeNameOf(disposition);

        Id targetId;
        String successMessage;

        if (STAGE_READINESS.equals(stage)) {
            targetId = disposition.Id;
            successMessage = SUBMITTED_SALE_DECISION_MESSAGE;
        } else if (STAGE_BOV_OUTREACH.equals(stage)) {
            // 🔴 THREE-WAY, NOT TWO-WAY, AND THE THIRD WAY IS WHY THE SELECTOR LOST ITS `LIMIT 1`
            // ON 2026-08-21. This read used to return a single record; on a disposition with two
            // Selected responses it returned ONE OF THEM and this branch submitted it — appointing
            // an arbitrary broker with nothing reporting that a choice had been made. `LIMIT 1`
            // cannot express "exactly one", only "at most one", so the >1 case was invisible HERE
            // no matter what was written in this method. See MULTIPLE_SELECTED_BOV_MESSAGE for why
            // that branch is a live backstop rather than dead code.
            List<BOV_Submission__c> selected =
                BovSubmissionSelector.selectSelectedByDispositionId(disposition.Id);
            if (selected.isEmpty()) {
                throw new ApprovalException(NO_SELECTED_BOV_MESSAGE);
            }
            if (selected.size() > 1) {
                throw new ApprovalException(MULTIPLE_SELECTED_BOV_MESSAGE);
            }
            targetId = selected[0].Id;
            successMessage = SUBMITTED_BROKER_FINALIZE_MESSAGE;
        } else if (STAGE_BROKER_SELECTION.equals(stage)) {
            if (RT_ON_MARKET.equals(recordType)) {
                throw new ApprovalException(ON_MARKET_BROKER_SELECTION_MESSAGE);
            }
            // 🔴 THE LOOKUP, NOT THE TEXT. `Selected_Broker__c` is now DERIVED from `Broker__c` by
            // `DispositionBrokerStampService`, so testing it here — even as an `||` fallback —
            // would be testing this feature's own output and the gate could never fail. See the
            // class header's pre-check table for the full argument. Do not restore the blank-check.
            if (disposition.Broker__c == null) {
                throw new ApprovalException(NO_BROKER_MESSAGE);
            }
            targetId = disposition.Id;
            successMessage = SUBMITTED_BROKER_SELECTION_MESSAGE;
        } else if (STAGE_CLOSING.equals(stage)) {
            // 🔴 `!= true` rather than `== false` — a Checkbox is never null on a saved row, but
            // reading it as "anything other than a definite yes is a no" is the shape that stays
            // correct if this ever becomes a formula or a cross-object read.
            if (disposition.Wire_Verification_Completed__c != true) {
                throw new ApprovalException(WIRE_INCOMPLETE_MESSAGE);
            }
            targetId = disposition.Id;
            successMessage = SUBMITTED_CLOSING_MESSAGE;
        } else {
            throw new ApprovalException(noApprovalAtStageMessage(stage));
        }

        if (!ProcessInstanceSelector.selectPendingByTargetId(targetId).isEmpty()) {
            throw new ApprovalException(ALREADY_PENDING_MESSAGE);
        }
        submit(targetId);
        return successMessage;
    }

    /**
     * Selects the winning offer and starts its approval — design decision D-3, and it is TWO steps
     * on purpose.
     *
     * ── 🔴 WHY THE STAGE MOVES HERE AND NOT ON APPROVAL ──────────────────────
     * Selecting an offer is a decision the business has ALREADY made; the approval ratifies it. So
     * the stage moves to `Offer Selection` NOW, and the approval moves it on to `LOI` afterwards
     * (via `DispositionOfferTriggerHandler`). The stage therefore always tells the truth, and a
     * REJECTED offer parks the disposition at `Offer Selection` for a re-pick rather than silently
     * reverting to `Active Listing` as though nobody had chosen anything.
     *
     * ── 🔴 THE EXCLUSIVITY WRITE IS ONE DML AND IS CHANGE-ONLY ───────────────
     * Every other offer on this disposition is cleared in the SAME `Database.update` that sets the
     * winner, because `Offer_Selection_Approval`'s entry criterion is `Is_Selected__c = true` and
     * two flagged rows would put two records into that approval. Rows already holding the correct
     * value are OMITTED from the list, so re-picking the same offer costs no DML and fires no
     * trigger — which is what makes this action idempotent rather than merely repeatable.
     *
     * ⚠ SYSTEM_MODE ON THE OFFER WRITE, `Is_Selected__c` IS THE REASON. It is a 2026-08-19 field:
     * a Metadata-API-deployed custom field arrives with NO FLS for any profile, System Administrator
     * included, and the permission sets then grant it READ ONLY (this feature is its only writer).
     * A `USER_MODE` write would be refused for everyone. `allOrNone = true`: a half-applied
     * exclusivity flag is the one outcome worse than a refused click.
     *
     * ── 🔴 ORDINARY DML FOR THE STAGE — DELIBERATELY NOT AN EXPLICIT AccessLevel ─
     * ⚠ THE HEADING USED TO READ "DELIBERATELY NOT SYSTEM_MODE" AND THAT WAS BACKWARDS. A plain
     * `update` with no `AccessLevel` argument ALREADY RUNS IN SYSTEM MODE for CRUD and FLS — that
     * is the platform default for Apex DML, and `RecordStageAdvanceService.cls`'s own write-mode
     * note states it correctly. So this statement and the `AccessLevel.SYSTEM_MODE` write two
     * statements above enforce the SAME CRUD/FLS level; what differs is only that one says so
     * explicitly. The body below is the real argument and is unchanged.
     *
     * `AccessLevel.SYSTEM_MODE` bypasses CRUD and FLS but NOT validation rules, so that is not what
     * the plain `update` is buying. What it IS buying is consistency with
     * `RecordStageAdvanceService.setStage`, which drives every other disposition stage change: one
     * write mode for one field, so a rule that blocks the Advance button also blocks this one, and
     * a user cannot discover that the two disagree. `All_NDAs_Signed_Before_Progression` gates
     * `Offer Selection` in the redesigned rule, and its message reaching the user IS the feature —
     * see the DmlException catch.
     *
     * ── 🔴 THE SAVEPOINT, AND EXACTLY WHAT IT PROTECTS ───────────────────────
     * It is taken BEFORE the offer flags, not between the flags and the stage, because the state
     * this method must never leave behind is "the stage says Offer Selection and an offer is
     * flagged, but no approval exists" — a sale that looks decided with nobody deciding it. A
     * failure at ANY of the three statements rolls back ALL of them, so the only two reachable
     * end states are "nothing happened, and here is why" or "all three happened".
     *
     * ⚠ A SAVEPOINT IS NOT FREE AND IS NOT USED ELSEWHERE IN THIS MODULE. It is warranted here and
     * only here because this is the module's one operation that spans two objects AND an approval
     * submission. Do not copy it into the single-write services.
     *
     * @param dispositionId the Disposition__c the offer belongs to (required)
     * @param offerId       the winning Disposition_Offer__c (required, must be a child of the above)
     * @return an authored confirmation
     * @throws ApprovalException for a user-actionable rule violation, or carrying a validation
     *         rule's own message when the stage advance is blocked
     * @throws System.QueryException when dispositionId matches no visible Disposition
     * @throws DispositionActionPermissionService.AccessDeniedException when the running user is not
     *         a disposition driver
     * @example
     * String msg = DispositionApprovalService.selectOffer(dispositionId, offerId);
     */
    public static String selectOffer(Id dispositionId, Id offerId) {
        DispositionActionPermissionService.assertDispositionActionAccess();
        if (dispositionId == null || offerId == null) {
            throw new ApprovalException(NO_RECORD_MESSAGE);
        }

        Disposition__c disposition = DispositionSelector.selectApprovalContextById(dispositionId);
        // Master / unset answers `On_Market` here, so the required stage for such a row is
        // `Active Listing` — the same answer `RecordStageAdvanceService`'s default type key gives.
        String recordType = DispositionDomain.recordTypeNameOf(disposition);
        // On-market collects offers at `Active Listing`; off-market has no listing stage at all and
        // collects them at `Release Materials`. Both converge on `Offer Selection`.
        String requiredStage = RT_OFF_MARKET.equals(recordType)
            ? STAGE_RELEASE_MATERIALS
            : STAGE_ACTIVE_LISTING;
        if (!requiredStage.equals(disposition.Disposition_Stage__c)) {
            throw new ApprovalException(
                wrongStageForOfferMessage(requiredStage, disposition.Disposition_Stage__c));
        }

        // ONE read of the whole sibling set — it is simultaneously the exclusivity input and the
        // proof that offerId belongs to THIS disposition. See the selector's header.
        List<Disposition_Offer__c> offers =
            DispositionOfferSelector.selectSelectionStateByDispositionId(dispositionId);
        Boolean offerBelongs = false;
        List<Disposition_Offer__c> flagUpdates = new List<Disposition_Offer__c>();
        for (Disposition_Offer__c offer : offers) {
            Boolean shouldBeSelected = (offer.Id == offerId);
            if (shouldBeSelected) {
                offerBelongs = true;
            }
            // Change-only. `true == null` is false in Apex, so an unset flag on an existing row is
            // correctly treated as "not selected" and gets written when it should be.
            if (offer.Is_Selected__c != shouldBeSelected) {
                flagUpdates.add(new Disposition_Offer__c(
                    Id = offer.Id,
                    Is_Selected__c = shouldBeSelected
                ));
            }
        }
        if (!offerBelongs) {
            throw new ApprovalException(OFFER_NOT_ON_DISPOSITION_MESSAGE);
        }

        Savepoint beforeSelection = Database.setSavepoint();
        try {
            // 🔴 THE TWO DML MODES BELOW DIFFER ON PURPOSE. DO NOT "HARMONISE" THEM — the
            // difference IS the behaviour, and making them match either way breaks one of them.
            //   SYSTEM_MODE (the flags): `Is_Selected__c` and its siblings carry no FLS for the
            //     personas that select an offer, and the user did not ask for this write — it is
            //     bookkeeping performed on their behalf. A USER_MODE refusal here would be an FLS
            //     gap wearing a business error, and it would abort a selection that is otherwise
            //     legitimate. ARCHITECTURE.md §2, automation-path exception.
            //   BARE `update` (the stage): sharing- and FLS-enforcing DELIBERATELY. This is the
            //     write the user DID ask for, on the record they are acting on, and a refusal is
            //     the correct answer — it throws, the catch below rolls back the whole selection,
            //     and the platform's own message (a validation rule's text, an access error)
            //     reaches the user instead of a silent partial commit. Wrapping it in SYSTEM_MODE
            //     would let someone with no edit rights on the sale move its stage.
            if (!flagUpdates.isEmpty()) {
                Database.update(flagUpdates, true, AccessLevel.SYSTEM_MODE);
            }
            update new Disposition__c(
                Id = disposition.Id,
                Disposition_Stage__c = STAGE_OFFER_SELECTION
            );
            submit(offerId);
        } catch (DmlException e) {
            Database.rollback(beforeSelection);
            // 🔴 THE PLATFORM MESSAGE IS SURFACED VERBATIM, AND THAT IS THE POINT. A validation
            // rule's own text is the only thing that tells the user WHICH gate stopped them; the
            // NDA gate on `Offer Selection` is the live example. Same choice, same reasoning, as
            // RecordStageAdvanceService.setStage — including its getNumDml() guard, because a
            // DmlException with no row detail is a real shape (MIXED_DML_OPERATION,
            // LIMIT_EXCEEDED) on which getDmlMessage(0) itself throws.
            throw new ApprovalException(e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        } catch (Exception e) {
            Database.rollback(beforeSelection);
            // Unexpected: the approval's entry criterion (`Is_Selected__c = true`) was satisfied two
            // statements ago. Propagate RAW so the controller masks it with the fixed generic
            // message rather than leaking platform approval text (the OpportunityApprovalService
            // contract).
            // NOT debug output — this is the failure channel. The rethrow is deliberately MASKED at
            // the controller boundary, so this line is the only place the real cause and stack of a
            // rolled-back offer selection is ever recorded. A lint pass will flag it; leave it.
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalService.selectOffer rolled back on '
                + dispositionId + '/' + offerId + ': ' + e.getMessage() + ' | '
                + e.getStackTraceString());
            throw e;
        }
        return OFFER_SELECTED_MESSAGE;
    }

    /**
     * Submits one record into whichever approval process its own state matches.
     *
     * ⚠ `Approval.process(request)` — the ONE-ARGUMENT form, which THROWS on refusal, unlike
     * `DispositionService.submitSaleDecision`'s two-argument soft form. The difference is
     * deliberate and is about what the caller can do next: there, a Disposition had just been
     * created and had to be handed back whatever happened; here, every foreseeable refusal has
     * already been pre-checked above, so anything left IS unexpected and belongs in the
     * controller's generic-failure path — or, inside `selectOffer`, in the savepoint rollback.
     */
    private static void submit(Id targetId) {
        Approval.ProcessSubmitRequest request = new Approval.ProcessSubmitRequest();
        request.setObjectId(targetId);
        Approval.process(request);
    }

    /**
     * Wording for a Submit click at a stage no approval runs at. It NAMES THE FOUR stages that do,
     * so the refusal reads as a rule rather than as a defect — the same choice
     * `RecordStageAdvanceService.NO_NEXT_STEP_HINTS` makes for a blocked advance.
     */
    private static String noApprovalAtStageMessage(String stage) {
        return 'No approval applies at the ' + stage + ' stage. The disposition approvals run at '
            + 'Disposition Readiness, BOV Outreach, Broker Selection (off-market) and Closing.';
    }

    /** Wording for Select Offer clicked at the wrong stage. Names the stage that IS right. */
    private static String wrongStageForOfferMessage(String requiredStage, String actualStage) {
        return 'An offer can only be selected at the ' + requiredStage + ' stage. '
            + 'This disposition is at ' + actualStage + '.';
    }
}
