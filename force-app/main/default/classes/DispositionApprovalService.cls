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
 * a criterion a user can actually satisfy, and both are checked here with AUTHORED wording —
 * joined 2026-08-22 by a THIRD pre-check that is NOT an entry-criterion mitigation (read the ⚠
 * under the table):
 *
 *   `Disposition Readiness`          the PARENT ASSET's `Target_Sale_Price__c` must be non-null
 *                                    and greater than zero (via `Property_Asset__r`)
 *   `Broker Selection` (off-market)  `Broker__c` must be non-null
 *   `Closing`                        `Wire_Verification_Completed__c` must be true
 *
 * ⚠ THE FIRST ROW IS NEW ON 2026-08-22 AND IS THE ODD ONE OUT — IT IS NOT MITIGATING AN APPROVAL
 * ENTRY CRITERION. `Sale_Decision_Approval` enters on the STAGE alone, so a blank price
 * would submit and approve perfectly happily and the platform would never say a word. That
 * pre-check exists because the STAGE ADVANCE the approval triggers is written by a Queueable in
 * SYSTEM_MODE with `allOrNone = false`, where a refusal is SILENT — so submission time is the only
 * place a refusal can still reach a person. Full argument at TARGET_SALE_PRICE_REQUIRED_MESSAGE. Do
 * not "harmonise" it by adding an entry criterion or a validation rule without reading design F-4
 * (`objects/Disposition__c/fields/Asking_Price__c.field-meta.xml` still records it) first.
 *
 * 🔴 THE FIRST ROW WAS REPOINTED ON 2026-08-25 AND THE OLD FORM MUST NOT COME BACK. It read
 * `Asking_Price__c` ("Expected Value") ON THE DISPOSITION until that date. The user retired that
 * field from the disposition flow and removed it from the record page; `BOV_Score__c`'s value basis
 * moved to `Property_Asset__c.Target_Sale_Price__c`, and this gate moved WITH the score, because
 * the score is the only reason the gate exists. The field is NOT deleted — additive retirement —
 * so `Asking_Price__c` still compiles here and always will. Do not reinstate it because it does.
 *
 * ⚠ THE `Broker Selection` ROW CHANGED ON 2026-08-20 (off-market broker lookup) AND THE OLD FORM
 * MUST NOT COME BACK. (It read "THE FIRST ROW" until 2026-08-22, when the asking-price row was
 * inserted above it and silently made that ordinal name the wrong gate — the rows are addressed by
 * NAME from here on, so the next insertion cannot repeat it.) It used to read `String.isBlank(Selected_Broker__c)` — a non-blank TEXT field. The gate now
 * requires the Contact LOOKUP, so the broker on an off-market disposition is a real record in the
 * system rather than a string naming nobody. **`Selected_Broker__c` is NOT retained as an `||`
 * fallback, and adding one would invert the purpose of the change twice over:** it would let a
 * hand-typed name satisfy the very gate that exists to stop exactly that, and — because
 * `DispositionBrokerStampService` DERIVES `Selected_Broker__c` from `Broker__c` on every off-market
 * pick — the fallback would be satisfied by the feature's own output, making the gate unfailable.
 * There is also no population to protect: the off-market path was rebuilt from scratch on
 * 2026-08-19 and the org sweep found zero Off_Market rows.
 *
 * 🔴 THE `Closing` ROW IS A DELIBERATE SUPERSESSION AND MUST NOT BE READ AS DUPLICATION. Until this
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
 *     Selected BOV, blank broker, MISSING ASKING PRICE, wire incomplete, already pending, wrong
 *     stage, offer not on this disposition).
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
     *   - the platform has no BEFORE undelete context at all, so restoring a previously-Selected
     *     submission from the Recycle Bin onto a disposition that has since appointed someone else
     *     creates a second Selected row NO guard sees. That is the path the test fixture uses,
     *     because it is real. (READ THE RETRACTION BELOW BEFORE QUOTING THIS BULLET.)
     *   - rows that predate the guard (2026-08-20) were never validated by it;
     *   - the guard's sibling read is `with sharing`, so it FAILS OPEN — a Selected row the saving
     *     user cannot see is absent from its count and the save is permitted.
     * The cost of keeping this branch is one comparison per Submit click. The cost of removing it
     * is submitting an arbitrary one of two brokers into `Broker_Finalize_Approval` and appointing
     * a broker nobody chose.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE FIRST BULLET WAS RETRACTED IN PLACE 2026-08-31 (Tranche 1 RE-REVIEW, W-4a — this
     *    file was missed by BOTH the D-5 sweep and the W-3 sweep of the same day, and it is
     *    DEPENDANT #1 on the W-3 sweep's OWN corrected list of seven, the only PRODUCTION entry
     *    on it). HALF OF IT WAS FALSE; THE OTHER HALF IS WHY THIS CONSTANT
     *    EXISTS, WHICH IS WHY THE SENTENCE WAS SPLIT RATHER THAN DELETED.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     *     RETRACTED: "`BovSubmissionTrigger` declares no `after undelete` context (and the
     *     platform has no BEFORE undelete context at all)".
     *
     * FALSE HALF: the trigger HAS declared `after undelete` since 2026-08-31 (design decision
     * D-5). It routes `DispositionCounterRollupService` — `Disposition__c.Responses_Received__c`
     * — and nothing else.
     *
     * TRUE HALF, AND IT IS THE HALF THIS BACKSTOP RESTS ON: there is still no BEFORE undelete
     * context anywhere on the platform, so `BovSubmissionSelectionGuardService` — which runs at
     * `before insert` and `before update` — still never sees a restore. The two-Selected state is
     * still reachable, this branch is still live rather than dead code, and removing it would
     * still submit an arbitrary one of two brokers for approval.
     * ⚠ THE NEW CONTEXT DOES NOT CLOSE THE GAP EITHER. The counter never reads
     * `Submission_Status__c` (`BovSubmissionSelector.countByDispositionIds` counts every row
     * regardless of status, per D-9), so it is structurally incapable of repairing, hiding or
     * contradicting a two-Selected state.
     *
     * 🔴 THE LIVE HAZARD THE STALE SENTENCE CREATED, AND THE REASON IT WAS WORTH CORRECTING IN A
     * PRODUCTION CLASS RATHER THAN LEFT AS A HARMLESS INACCURACY. A reader of THIS class believed
     * the context DOES NOT EXIST. Anyone who then needed undelete behaviour would have set out to
     * CREATE it — arriving at the trigger from the wrong direction and never reaching the standing
     * rule that already governs it, at `BovSubmissionTriggerHandler.afterUndelete`: THAT CONTEXT
     * ROUTES THE COUNTER AND NOTHING ELSE. Routing a second job there — `BovAutoSelectionService`
     * above all — would SELF-HEAL the restored duplicate and turn this branch, plus six test-side
     * dependants, green-and-vacuous instead of red. The existence of the context is not
     * permission to use it. The enumerated list of seven dependants lives at
     * `BovAutoSelectionService.reselectForDeleted` and is deliberately NOT copied here — a list
     * duplicated across files is a list that will disagree with itself.
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
     * The same refusal for the PREFERRED slot, added 2026-08-24 with the two-slot selection model.
     *
     * 🔴 A SEPARATE CONSTANT BECAUSE THE REMEDY IS DIFFERENT, NOT BECAUSE THE WORDING IS. A user
     * told to "set all but the appointed broker to Backup in the BOV comparison matrix" cannot act
     * on it for preferred rows: they are rendered in a separate, action-free list, and the way a
     * preferred broker is changed is Add Preferred Broker (which retires the outgoing one via
     * `BovPreferredBrokerService`). Sharing one message would send half the users to a control that
     * is not there.
     *
     * ⚠ IT IS EVEN LESS REACHABLE THAN ITS SIBLING, AND IS STILL NOT DEAD CODE. The narrowed
     * exclusivity guard refuses a second Selected PREFERRED row, and the retirement service deletes
     * the outgoing one — but the same three gaps the sibling's header lists apply unchanged (the
     * undelete gap, rows predating the guard, and the guard's `with sharing` read failing OPEN),
     * and the retirement service can be refused by a validation rule or a lookup filter. Submitting
     * an arbitrary one of two preferred brokers into an approval is exactly the outcome this whole
     * branch exists to prevent.
     */
    private static final String MULTIPLE_PREFERRED_BOV_MESSAGE =
        'More than one preferred broker is marked Selected on this disposition, and exactly one is '
        + 'required. Remove the preferred brokers that no longer apply, leaving one, then submit '
        + 'for approval.';

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
     * The `Disposition Readiness` branch's ONLY refusal, added 2026-08-22 to the user requirement
     * "asking price should be mandatory before moving to BOV Outreach".
     *
     * ⚠ RENAMED FROM `ASKING_PRICE_REQUIRED_MESSAGE` ON 2026-08-25, AND THE RENAME IS THE POINT.
     * The gate now reads `Property_Asset__r.Target_Sale_Price__c` on the PARENT ASSET, not
     * `Asking_Price__c` ("Expected Value") on the disposition — that field is retired from the
     * disposition flow (user decision; the field itself is NOT deleted, per this repo's additive
     * retirement rule) and `BOV_Score__c`'s value basis moved to the asset with it. The constant is
     * private and had no external caller, so the name was corrected rather than left to describe a
     * field this class no longer reads. Every argument below survives the move unchanged; only the
     * FIELD the gate names is different, and the message text names the new one.
     *
     * ═════════════════════════════════════════════════════════════════════════════
     * 🔴 THIS PRE-CHECK IS THE WHOLE CONTROL. THERE IS NO VALIDATION RULE BEHIND IT,
     *    AND THAT ABSENCE IS A DECISION, NOT AN OMISSION.
     * ═════════════════════════════════════════════════════════════════════════════
     * A reader who notices that `Wire_Verification_Completed__c` is guarded in THREE places
     * (approval `entryCriteria` + this class's pre-check + `Wire_Complete_Before_Sale_Closes`)
     * and that this one is guarded in ONE will assume the other two were forgotten. They were not.
     *
     * WHY NO VALIDATION RULE (design F-4, recorded in
     * `objects/Disposition__c/fields/Asking_Price__c.field-meta.xml` — read it before adding one,
     * and note it is now the historical record of a retired field rather than a live one):
     * the `Disposition Readiness` -> `BOV Outreach` / `Broker Selection` hop IS NOT A USER ACTION.
     * It is written by `DispositionApprovalAdvanceService.advance`, inside
     * `DispositionApprovalAdvanceQueueable`, as
     * `Database.update(rows, false, AccessLevel.SYSTEM_MODE)`. **SYSTEM_MODE lifts CRUD and FLS and
     * NEVER a validation rule**, and `allOrNone = false` DISCARDS the failure. So a rule of the
     * obvious shape would fire on the machine's write, be swallowed, and leave an APPROVED
     * disposition parked at Readiness with `Approval_Advance_Pending__c` stuck true and nothing
     * shown to the approver. That is strictly worse than no backstop.
     *
     * 🔴 AND THE MOVE TO THE ASSET MAKES A VALIDATION RULE WORSE STILL, NOT BETTER. The value now
     * lives on a DIFFERENT OBJECT, so the only rule that could see it is a cross-object formula on
     * `Disposition__c` reading `Property_Asset__r.Target_Sale_Price__c` — which would fire on every
     * disposition save for a value the disposition's own editor may not be able to change, and
     * would still be swallowed by the Queueable exactly as described above.
     *
     * ⚠ AND THIS IS WHY THE GUARD MUST STAY AT **SUBMISSION** TIME RATHER THAN MOVING TO THE
     * WRITE: refusing here is the last moment a human is still holding the click. One statement
     * later the decision belongs to an approval process and an async job, neither of which has a
     * user to tell.
     *
     * 🔴 IF A BACKSTOP RULE IS EVER WANTED ANYWAY, THE SAFE SHAPE IS NOT A CLEVERER FORMULA —
     * it is `Property_Asset__r.Target_Sale_Price__c != null` added to `Sale_Decision_Approval`'s
     * `entryCriteria`, which makes the blank-price state unreachable BY the approval and therefore
     * unreachable by the advance — exactly the argument `Wire_Complete_Before_Sale_Closes`'s own
     * XML comment makes for the wire gate ("it should never trip on that path, because
     * Closing_Approval cannot be entered unless the flag is already true"). That PAIR overturns F-4
     * and needs sign-off; do not add the rule on its own, and do not reach for PRIORVALUE to dodge
     * the Queueable.
     *
     * ── WHY IT COVERS BOTH RECORD TYPES, DELIBERATELY ─────────────────────────
     * This branch is not record-type-guarded (`Sale_Decision_Approval` enters at this stage on BOTH
     * types), so the gate applies to the off-market `Broker Selection` hop as well as the on-market
     * `BOV Outreach` one. The user asked for "before moving to BOV Outreach"; the business reason —
     * an asset cannot be taken to market with no target sale price — is record-type independent,
     * and an off-market sale has no BOV Outreach stage to be stopped at, so scoping the gate to
     * that stage name would exempt an entire record type for good. No later stage asks for this.
     *
     * ── WHY ZERO IS REFUSED TOO, AND WHERE THAT COMES FROM ───────────────────
     * Not an invented rule: `BOV_Submission__c.BOV_Score__c`'s own guard returns **null** for a
     * blank OR ZERO OR NEGATIVE basis, because the score's value dimension DIVIDES BY IT.
     * A zero target sale price satisfies "populated" and still blanks every BOV score on the sale,
     * so `<= 0` is refused with the same message. A currency of 0 is not a price.
     *
     * ⚠ THIS READ "the score's 50-point value dimension" UNTIL 2026-09-02. `BOV_Score__c` was
     * re-weighted on 2026-09-01 and the Value dimension is now worth 40, not 50.
     * 🟢 THE GATE'S ARGUMENT IS COMPLETELY UNAFFECTED and must not be reopened on the strength of
     * the new number: what refuses a zero basis is the DIVISION and the formula's own guard
     * clause, neither of which has a weight in it. The weight is dropped from the sentence rather
     * than restated for that reason.
     * 🔴 AND THE RE-WEIGHTING MAKES THE "blanks EVERY BOV score" CLAIM STRONGER, NOT WEAKER —
     * WORTH STATING, BECAUSE THE OBVIOUS INFERENCE FROM THE NEW FORMULA IS THE WRONG ONE. The two
     * new terms (Buyer Ready 10, Known Performer 10) do NOT divide by the basis, so a reader may
     * reasonably assume a flagged response still scores 20 on an unpriced asset and that this gate
     * is therefore over-strict now. It does not: `BOV_Score__c`'s guard returns null for the WHOLE
     * formula, and that field's own description says so in terms — "the two flags cannot make an
     * unpriced response scoreable". Read the field XML before relaxing this gate.
     *
     * ⚠ IT NAMES THE ON-SCREEN LABEL, NOT the API name, per this class's stated convention —
     * "Target Sale Price", which is `Target_Sale_Price__c`'s `<label>` on `Property_Asset__c`.
     * 🔴 AND THE FIELD IT NAMES IS ON A **DIFFERENT RECORD FROM THE ONE THE USER IS LOOKING AT**,
     * WHICH IS NEW AND IS WHY THE MESSAGE SAYS SO EXPLICITLY. The 2026-08-22 version of this
     * constant could rely on the field being on the very page the Submit button sits on (it was
     * verified to be on `Disposition_Record_Page`'s Details section). That is no longer true: the
     * user must open the PROPERTY ASSET. A message reading "enter the Target Sale Price" with no
     * hint of where would be the LOI `Final_Agreed_Price__c` dead end again — a gate demanding a
     * field the user cannot find — so the wording names the property asset outright.
     * ⚠ HISTORY, KEPT: on 2026-08-24 `Asking_Price__c`'s `<label>` was renamed to `Expected Value`
     * and this message was reworded to match. Both that field and that wording are gone from this
     * gate as of 2026-08-25; the paragraph stays because the CONVENTION it records (name the label,
     * never the API name, and verify the user can actually reach it) still governs.
     */
    private static final String TARGET_SALE_PRICE_REQUIRED_MESSAGE =
        'A target sale price is required before this sale can leave Disposition Readiness. '
        + 'Enter the Target Sale Price on this disposition\'s property asset, then submit for '
        + 'approval.';

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
     * | `BOV Outreach` (on-market)       | ONE Selected BOV_Submission__c -> Broker_Finalize    |
 * |                                  | (the PREFERRED broker if there is one, else the      |
 * |                                  | non-preferred Selected row — see that branch)        |
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
            // 🔴 THE PRICE GATE (2026-08-22; REPOINTED TO THE ASSET 2026-08-25). Same shape as the
            // `Closing` branch's wire pre-check below, and the last point in the flow where a human
            // is still present to be told: everything after this line is an approval process and an
            // async Queueable whose refusals are silent. See TARGET_SALE_PRICE_REQUIRED_MESSAGE for
            // why there is deliberately NO validation rule behind it (design F-4).
            //
            // ⚠ IT READS THE **PROPERTY ASSET**, NOT THE DISPOSITION, SINCE 2026-08-25. It used to
            // read `disposition.Asking_Price__c` ("Expected Value"); that field is retired from the
            // disposition flow (the user removed it from the record page) and `BOV_Score__c`'s value
            // basis moved with it to `Property_Asset__c.Target_Sale_Price__c`. The gate follows the
            // score, because the score is the reason the gate exists — a sale whose price gate reads
            // one field while its BOV ranking divides by another would refuse submissions it can
            // score and accept submissions it cannot.
            //
            // 🔴 THE NULL CHAIN IS A REFUSAL, NOT AN ERROR, AND THAT IS DELIBERATE.
            // `Disposition__c.Property_Asset__c` is a NOT-REQUIRED lookup, so `Property_Asset__r` is
            // null on an asset-less disposition and dereferencing it directly would throw a raw
            // `NullPointerException` that the controller masks as the generic "could not be
            // submitted". A disposition with no asset has no target sale price BY DEFINITION, so it
            // takes the same authored refusal as a blank one — the user is told what to fix either
            // way, which is the whole point of pre-checking here rather than at the write.
            //
            // `<= 0` as well as null: `BOV_Score__c`'s own guard returns null for a zero or negative
            // basis exactly as it does for a blank one, so a zero target blanks every BOV score on
            // the sale. Mutation-tested 2026-08-22 (against the old field, same branch) — narrowing
            // this to `== null` reds exactly one test
            // (submitAtReadiness_zeroAskingPrice_isRefusedLikeABlankOne) and nothing else, so that
            // test is the ONLY thing holding the zero half of the rule.
            //
            // ⚠ `Property_Asset__r.Target_Sale_Price__c` MUST STAY IN
            // `DispositionSelector.selectApprovalContextById`. Dropping it does NOT degrade to null
            // — measured 2026-08-22 for the field this replaced, Apex throws
            // `System.SObjectException: SObject row was retrieved via SOQL without querying the
            // requested field`, the controller masks it as the generic "could not be submitted", and
            // Submit for Approval breaks at Readiness for every user on both record types. The span
            // also carries an FLS/CRUD gate on a SECOND object; that is argued in full at the
            // selector, and the fix if it ever throws is the permission set, never SYSTEM_MODE.
            Decimal targetSalePrice = disposition.Property_Asset__r == null
                ? null
                : disposition.Property_Asset__r.Target_Sale_Price__c;
            if (targetSalePrice == null || targetSalePrice <= 0) {
                throw new ApprovalException(TARGET_SALE_PRICE_REQUIRED_MESSAGE);
            }
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
            //
            // ══════════════════════════════════════════════════════════════════════════════════
            // 🔴 AMENDED 2026-08-24 — **TWO** SELECTED ROWS IS NOW NORMAL, AND THIS IS WHERE THE
            //    TIE IS BROKEN: **IF A PREFERRED BROKER EXISTS, SUBMIT THAT ROW.**
            // ══════════════════════════════════════════════════════════════════════════════════
            // A Disposition now holds two independent appointment slots — the preferred broker a
            // human named, and the scored winner the model picked (`BovAutoSelectionService`'s
            // header carries the model in full; the exclusivity guard was narrowed to match on the
            // same day). `selectSelectedByDispositionId` therefore routinely returns TWO rows and
            // `size() > 1` STOPPED BEING AN ERROR CONDITION. Treating it as one would refuse every
            // sale that has a preferred broker — the feature would look broken with a message
            // telling the user to undo it.
            //
            // The tie-break is the user's decision, stated plainly: A HUMAN'S NAMED PREFERENCE
            // OUTRANKS A SCORE. The exclusivity check survives INSIDE the chosen slot, which is
            // where it was always doing its work.
            //
            // ⚠ THE PARTITION KEY IS `Is_Preferred_Broker__c`, **NOT** `Is_System_Selected__c`, AND
            // THE DIFFERENCE IS A LIVE REGRESSION RATHER THAN A STYLE CHOICE.
            // `BovSubmissionService.replaceSelectedBroker` promotes a challenger to Selected with
            // `Is_Manually_Appointed__c = true` and NO system flag — a manual appointment is not a
            // scoring pick, and that field's XML names `BovAutoSelectionService` as its ONLY
            // writer. Routing on "the system-selected row" would therefore find NOTHING after every
            // Replace Broker, and Submit for Approval would refuse with "No broker is marked
            // Selected yet" while the matrix plainly showed one. Routing on "the row that is not a
            // preferred broker" covers the scored winner and the manual appointment identically,
            // which is also exactly how the narrowed guard counts them.
            // `submitAtBovOutreach_afterReplaceBroker_submitsTheManuallyAppointedRow` is the
            // falsifier for that specific trap.
            List<BOV_Submission__c> selected =
                BovSubmissionSelector.selectSelectedByDispositionId(disposition.Id);
            if (selected.isEmpty()) {
                throw new ApprovalException(NO_SELECTED_BOV_MESSAGE);
            }
            List<BOV_Submission__c> preferredRows = new List<BOV_Submission__c>();
            List<BOV_Submission__c> appointedRows = new List<BOV_Submission__c>();
            for (BOV_Submission__c candidate : selected) {
                if (candidate.Is_Preferred_Broker__c == true) {
                    preferredRows.add(candidate);
                } else {
                    appointedRows.add(candidate);
                }
            }
            // `selected` is non-empty, so at least one of the two lists is — no third branch is
            // reachable here and none is written, deliberately: an unreachable `else` would be a
            // line no test can cover and every future reader has to re-derive.
            Boolean routeToPreferred = !preferredRows.isEmpty();
            List<BOV_Submission__c> routed = routeToPreferred ? preferredRows : appointedRows;
            if (routed.size() > 1) {
                throw new ApprovalException(
                    routeToPreferred
                        ? MULTIPLE_PREFERRED_BOV_MESSAGE
                        : MULTIPLE_SELECTED_BOV_MESSAGE
                );
            }
            targetId = routed[0].Id;
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
