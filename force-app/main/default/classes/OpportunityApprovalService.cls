/**
 * Service behind the custom "Submit for Approval" quick action. Backs
 * OpportunityApprovalController.
 *
 * Owns the approval-submission ORCHESTRATION extracted from OpportunityApprovalController
 * in the controller-thinning fix (code-review W3): resolving the APPROVAL TARGET from the
 * clicked record, the duplicate-pending gate, the Approval.process submission, and the
 * stage-based "no applicable process" error derivation. Per
 * .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2 this orchestration is Service
 * work, not Controller work.
 *
 * ⚠ RETRACTED 2026-08-28. This header used to say, and the class used to implement:
 *   "The approval processes live on the Opportunity, so a submission from a child record
 *    resolves its parent deal first, then submits it — the process whose entry criteria the
 *    deal meets (Underwriting_Approval at Stage = Underwriting, LOI_Approval at Stage = LOI)
 *    picks it up."
 * That is now FALSE FOR UNDERWRITING and remains TRUE FOR LOI / CONTRACT REVIEW. The
 * principal underwriting approval was moved off the Opportunity and onto the Underwriting__c
 * record itself, so:
 *   - Underwriting__c    -> the approval target is THE UNDERWRITING RECORD ITSELF.
 *   - LOI__c / Contract_Review__c -> still resolve to the PARENT Opportunity. LOI_Approval is
 *                          NOT changing and still runs on the Opportunity at StageName = 'LOI'.
 *   - Opportunity        -> still itself.
 * The private resolver was renamed resolveDealId -> resolveApprovalTargetId in the same
 * change, because "deal id" stopped being an accurate name for what it returns.
 *
 * 🔴 THIS CHANGE ALSO CLOSES A LIVE DEFECT (found in design analysis, 2026-08-28). Under the
 * old resolver, clicking Submit for Approval on an Underwriting record whose PARENT happened
 * to sit at StageName = 'LOI' resolved to the parent and submitted the deal into
 * **LOI_Approval** — the wrong approval process entirely. It was reachable because the
 * Underwriting record page's visibility rule keys on the CHILD's Stage__c and never looks at
 * the parent's stage, so nothing in the UI prevented it and the submitter got a success
 * toast. Resolving Underwriting__c to itself makes that unreachable BY CONSTRUCTION rather
 * than by a guard that could be forgotten. Regression test:
 * OpportunityApprovalServiceTest.underwritingWithParentAtLoiNeverEntersLoiApproval.
 *
 * All SOQL is delegated to selectors (ProcessInstanceSelector / OpportunitySelector /
 * LoiSelector / UnderwritingSelector / ContractReviewSelector) — this service holds no
 * inline SOQL.
 *
 * ═══ 🔴 THE SIGNED-NDA GATE (2026-08-30) — AND THE PREMISE IT FALSIFIES ═══
 * `submitForApproval` now REFUSES an Opportunity submission at `StageName = 'LOI'` when the deal's
 * `Primary_NDA__c` is blank or its `Primary_NDA__r.NDA_Signed__c` is false. It is a PRE-check, run
 * before `Approval.process`, and it costs one query on the Opportunity path.
 *
 * ⚠ RETRACTED, verbatim, from the `catch` block below, where it still stands as a comment about
 * the STAGE re-read and is still correct THERE:
 *     "⚠ THE STAGE RE-READ IS DELIBERATELY IN THE CATCH, NOT BEFORE THE SUBMIT. A pre-check would
 *      cost a query on every successful submission to serve only the failure path, and would
 *      duplicate the entry criteria in Apex — where it would silently drift from the approval
 *      process's own definition."
 * THAT RULE DOES NOT EXTEND TO THIS GATE, AND THE DISTINCTION IS THE WHOLE JUSTIFICATION:
 *   - The stage re-read buys a better ERROR MESSAGE for a submission the platform was going to
 *     refuse anyway. Paying a query on every SUCCESS to improve a FAILURE's wording is a bad
 *     trade, which is why it lives in the catch.
 *   - The NDA gate buys a REFUSAL THAT WOULD OTHERWISE NOT HAPPEN. Post-check is not an option at
 *     any price: by the time the catch runs, `Approval.process` has SUCCEEDED and the deal is in
 *     the approval. There is no failure to interpret, and unwinding a submitted approval is not
 *     something this service may do.
 *   - It does NOT duplicate the approval's entry criteria. `LOI_Approval`'s criterion is the
 *     STAGE; the NDA is not part of it and never was. This is an additional business rule, not a
 *     second copy of a declarative one.
 * 🔴 DO NOT DELETE THIS PRE-CHECK ON THE STRENGTH OF THE CATCH-BLOCK COMMENT. That is the exact
 * reading this paragraph exists to prevent.
 *
 * ⚠ WHY THE GATE IS APEX AND NOT A VALIDATION RULE — MEASURED, NOT PREFERRED. `resolveApprovalTargetId`
 * maps `LOI__c` to the PARENT Opportunity and `Approval.process` submits THAT. **No DML ever touches
 * the `LOI__c` row**, so a validation rule on `LOI__c` is dead code — it cannot fire on this path at
 * all. An Opportunity-side rule is no better: `LoiGateTest.rejectionReturnsDealToUnderwriting`
 * demonstrates that approval field updates BYPASS custom validation rules in this org.
 *
 * ⚠ AND THERE IS DELIBERATELY NO `RecordType.DeveloperName == 'Acquisition_LOI'` CRITERION.
 * The module boundary is already STRUCTURAL: a `Disposition_LOI` carries a blank `Opportunity__c`,
 * so `resolveApprovalTargetId` returns null and the "not linked to a deal" refusal above fires
 * before the gate is reached; the disposition side has a wholly separate path
 * (`dispositionSubmitForApproval` -> `DispositionApprovalService`). A criterion that can never
 * discriminate reads as load-bearing to the next person and gets defended forever. The reasoning
 * is recorded here INSTEAD of being encoded as a check.
 *
 * ⚠ TWO ACCEPTED RESIDUALS, so neither is later filed as a bug:
 *   1. This is a UI-PATH gate, not an absolute one. `Approval.process` can still be called
 *      directly — `scripts/verify-junior-lifecycle.apex` does exactly that. No platform mechanism
 *      makes an approval submission absolutely conditional.
 *   2. Its live population is NARROW. `NDA_Signed_Before_Deal_Progression` already blocks ENTRY to
 *      the LOI stage without a signed NDA, so this covers only the insert-time hole in that rule
 *      (it is `ISCHANGED`-gated), a deal whose NDA is un-signed or repointed after it reached LOI,
 *      and stage moves made by approval field updates. "The gate never fires" is the expected
 *      steady state, not a defect.
 *
 * EXCEPTION CONTRACT (code-review W2 — no raw platform text may reach the user):
 *   - A user-actionable rule violation throws a TYPED {@link ApprovalException} whose
 *     message is safe to surface verbatim (no record, not linked to a deal, already
 *     pending, unsupported object, or a stage that meets no approval entry criteria).
 *   - An UNEXPECTED failure (a QueryException from a missing/inaccessible record, or a
 *     genuine Approval.process / platform error at an otherwise-eligible stage) is left to
 *     propagate RAW. This service NEVER throws AuraHandledException — the caller
 *     (controller) maps the raw failure to a fixed, generic, user-safe message so the raw
 *     platform text is not leaked (ARCHITECTURE.md §5).
 *
 * @see force-app/main/default/classes/OpportunityApprovalController.cls (thin caller)
 * @see force-app/main/default/classes/StageAdvanceService.cls — ⚠ NO LONGER A CALLER as of
 *      2026-08-28. It used to hand Underwriting -> LOI off to this service; Initiate LOI is now
 *      a plain stage write gated by a validation rule.
 * @see force-app/main/default/classes/UnderwritingApprovalStampService.cls (what runs AFTER the
 *      underwriting approval is granted — mirrors the decision onto the parent deal)
 */
public with sharing class OpportunityApprovalService {

    private static final String STAGE_UNDERWRITING = 'Underwriting';
    private static final String STAGE_LOI = 'LOI';

    /**
     * Underwriting__c.Stage__c value that the Underwriting_Approval process takes as its entry
     * criteria. A submission from any other stage can never match, so it is reported as a
     * user-actionable reason instead of falling through to the controller's generic mask.
     *
     * ⚠ THIS LITERAL IS DUPLICATED IN DECLARATIVE METADATA (the approval process's entryCriteria)
     * and there is no compile-time link between them. If the approval's entry stage is ever
     * changed, this constant is the second half of that change; a mismatch does not break the
     * submission, it just makes the refusal message name the wrong stage.
     */
    private static final String UW_STAGE_IN_PROGRESS = 'In Progress';

    /**
     * Surfaced when someone submits the OPPORTUNITY while it sits at the Underwriting stage.
     *
     * Before 2026-08-28 this case fell through to `throw e` (the guard below tested
     * `!= STAGE_UNDERWRITING && != STAGE_LOI`, which was FALSE at Underwriting), so the raw
     * NO_APPLICABLE_PROCESS reached the controller and was masked as "The deal could not be
     * submitted for approval. Refresh the page or contact your administrator." — user-safe but
     * useless, and it pointed at exactly the confusion this whole change exists to remove.
     */
    private static final String UNDERWRITING_MOVED_MESSAGE =
        'Underwriting approval now runs on the Underwriting record. '
        + 'Open this deal\'s Underwriting record and use Submit for Approval there.';

    /**
     * Surfaced when an LOI-stage deal is submitted for approval without a signed primary NDA.
     *
     * ⚠ IT DELIBERATELY MIRRORS `NDA_Signed_Before_Deal_Progression`'s `errorMessage` — "The
     * primary NDA must be signed before this deal can move to this stage. Link a signed NDA
     * (Primary NDA) first." — so the two gates read to a user as ONE rule enforced at two moments,
     * rather than as two rules that happen to be about NDAs. If that validation rule's wording is
     * ever changed, change this with it; they are a pair, and nothing but this comment links them.
     */
    @TestVisible
    private static final String NDA_UNSIGNED_MESSAGE =
        'The primary NDA must be signed before this LOI can be submitted for approval. '
        + 'Link a signed NDA (Primary NDA) on the deal first.';

    /**
     * Raised when a submission cannot proceed and the reason is user-actionable and safe to
     * surface verbatim: no record supplied, the record is not linked to a deal, a submission
     * is already pending, the object type is unsupported, or the deal's stage meets no
     * approval entry criteria. An UNEXPECTED failure is deliberately NOT wrapped in this type
     * — it propagates raw for the caller to mask with a fixed generic message.
     */
    public class ApprovalException extends Exception {}

    /**
     * Submits the clicked record's APPROVAL TARGET into whichever approval process it matches:
     * Underwriting_Approval on the Underwriting__c record at Stage__c = 'In Progress', or
     * LOI_Approval on the Opportunity at StageName = 'LOI'.
     *
     * ⚠ An Opportunity target at `StageName = 'LOI'` additionally passes through the signed-NDA
     * gate (`assertNdaSignedForLoiSubmission`) before `Approval.process` is reached — see the
     * class header for why that pre-check exists and why it does not contradict the catch-block
     * comment about the stage re-read.
     *
     * @param recordId the clicked record: an Underwriting (submits ITSELF), or an Opportunity /
     *                 LOI / Contract Review (all submit the parent deal).
     * @return a user-facing confirmation message.
     * @throws ApprovalException for a user-actionable rule violation (message safe to
     *                 surface verbatim).
     * @throws System.QueryException / platform Exception on an unexpected failure (the
     *                 caller masks it with a fixed generic message).
     */
    public static String submitForApproval(Id recordId) {
        if (recordId == null) {
            throw new ApprovalException('No record was provided.');
        }
        Id targetId = resolveApprovalTargetId(recordId);
        if (targetId == null) {
            throw new ApprovalException('This record is not linked to a deal (Opportunity) yet.');
        }
        // Block a duplicate submission while one is already pending. ⚠ As of 2026-08-28 this
        // guards the UNDERWRITING record for an underwriting submission, which is the correct
        // target — the pending ProcessInstance now hangs off the child, not the deal.
        if (!ProcessInstanceSelector.selectPendingByTargetId(targetId).isEmpty()) {
            throw new ApprovalException('This record is already pending approval.');
        }
        assertNdaSignedForLoiSubmission(targetId);
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(targetId);
            Approval.process(req);
            return 'The record has been submitted for approval.';
        } catch (Exception e) {
            // Turn the raw NO_APPLICABLE_PROCESS into a reason the submitter can act on.
            //
            // ⚠ THE STAGE RE-READ IS DELIBERATELY IN THE CATCH, NOT BEFORE THE SUBMIT. A
            // pre-check would cost a query on every successful submission to serve only the
            // failure path, and would duplicate the entry criteria in Apex — where it would
            // silently drift from the approval process's own definition.
            if (targetId.getSobjectType() == Underwriting__c.SObjectType) {
                // Underwriting_Approval's entry criterion is Stage__c = 'In Progress'.
                Underwriting__c uw = UnderwritingSelector.selectStageRequiredById(targetId);
                if (uw.Stage__c != UW_STAGE_IN_PROGRESS) {
                    throw new ApprovalException(
                        'An underwriting is submitted for principal approval from the In Progress '
                        + 'stage. This one is at the ' + uw.Stage__c + ' stage.');
                }
                // Eligible stage -> unexpected; propagate raw for the controller to mask (W2).
                throw e;
            }
            Opportunity deal = OpportunitySelector.selectStageRequiredById(targetId);
            if (deal.StageName == STAGE_UNDERWRITING) {
                // ⚠ CHANGED 2026-08-28. 'Underwriting' USED TO BE IN THE ELIGIBLE SET alongside
                // 'LOI', so this case fell through to `throw e` and was masked. See
                // UNDERWRITING_MOVED_MESSAGE for why that was the worst possible outcome here.
                throw new ApprovalException(UNDERWRITING_MOVED_MESSAGE);
            }
            if (deal.StageName != STAGE_LOI) {
                throw new ApprovalException('No approval applies at the ' + deal.StageName +
                    ' stage - LOI approval runs at the LOI stage.');
            }
            // At an eligible stage the process should apply; a failure here is unexpected.
            // Propagate raw so the controller masks it with a fixed generic message rather
            // than leaking platform approval text to the user (code-review W2). Defensive:
            // not reachable in normal operation — the pending-gate above prevents
            // ALREADY_IN_PROCESS and an eligible stage always matches its process.
            throw e;
        }
    }

    /**
     * 🔴 THE SIGNED-NDA GATE. Refuses an Opportunity submission at the LOI stage when the deal has
     * no primary NDA, or has one that is not signed. See the class header for why this is a
     * pre-check (and why that does NOT contradict the catch-block comment about the stage re-read),
     * why it is Apex rather than a validation rule, and why it carries no record-type criterion.
     *
     * ── FOUR NARROWING CONDITIONS, EACH OF WHICH IS A NO-OP FOR SOMEONE ─────
     *   1. NOT AN OPPORTUNITY TARGET -> return, WITHOUT QUERYING. An `Underwriting__c` submits
     *      itself into `Underwriting_Approval`, which has nothing to do with the LOI or the NDA.
     *      This is also what keeps the added cost off the underwriting path entirely.
     *   2. THE ROW DOES NOT RESOLVE -> return. `selectNdaGateById` returns null rather than
     *      throwing precisely so this gate cannot change WHERE an unexpected failure originates:
     *      a dead Id must still reach `Approval.process` and fail there, raw, as it always has.
     *      (`OpportunityApprovalServiceTest.unexpectedFailurePropagatesRawNotWrapped` is the pin.)
     *   3. NOT AT THE LOI STAGE -> return. The gate is about the LOI approval. A deal at any other
     *      stage is refused, or accepted, by the pre-existing logic untouched.
     *   4. NDA PRESENT AND SIGNED -> return. The steady state; see RESIDUAL 2 in the class header.
     *
     * ⚠ THE BLANK-LOOKUP AND THE UNSIGNED-NDA CASES SHARE ONE MESSAGE, ON PURPOSE. They are the
     * same user-facing fact ("this deal has no signed NDA") reached two ways, and the remedy is
     * identical — link a signed NDA as the primary. Splitting them would make the submitter guess
     * which of two similar sentences applies to them.
     *
     * ⚠ `deal.Primary_NDA__r` IS NOT DEREFERENCED WHEN `Primary_NDA__c` IS NULL. A null lookup
     * yields a null parent, so `deal.Primary_NDA__r.NDA_Signed__c` would be a null dereference; the
     * `Primary_NDA__c == null` test is checked FIRST and short-circuits. Do not "simplify" the two
     * conditions into one `!= true` expression on the spanning field.
     *
     * @param targetId The record `Approval.process` is about to be called on.
     * @throws ApprovalException when the target is an LOI-stage deal without a signed primary NDA.
     *         The message is user-actionable and safe to surface verbatim (EXCEPTION CONTRACT).
     */
    private static void assertNdaSignedForLoiSubmission(Id targetId) {
        if (targetId.getSobjectType() != Opportunity.SObjectType) {
            return;
        }
        Opportunity deal = OpportunitySelector.selectNdaGateById(targetId);
        if (deal == null || deal.StageName != STAGE_LOI) {
            return;
        }
        if (deal.Primary_NDA__c == null || deal.Primary_NDA__r.NDA_Signed__c != true) {
            throw new ApprovalException(NDA_UNSIGNED_MESSAGE);
        }
    }

    /**
     * The record that is actually submitted for approval.
     *
     * ⚠ RENAMED 2026-08-28 from `resolveDealId`, because it no longer always returns a deal.
     *   - Underwriting__c            -> ITSELF. The principal approval runs on this record.
     *   - Opportunity                -> itself.
     *   - LOI__c / Contract_Review__c -> the PARENT Opportunity (unchanged — LOI_Approval still
     *                                   runs on the deal).
     *
     * ⚠ THE UNDERWRITING BRANCH DELIBERATELY DOES NOT QUERY. It used to load the record to read
     * Opportunity__c; returning the Id itself needs no read, so the happy path lost a query. The
     * consequences are intentional and each has a replacement:
     *   - A non-existent Underwriting Id no longer throws System.QueryException here. It fails at
     *     Approval.process instead, and the catch's stage re-read then throws the SAME
     *     System.QueryException — the "unexpected failure propagates raw" contract is preserved,
     *     just one step later.
     *   - An Underwriting with a blank Opportunity__c is no longer refused as "not linked to a
     *     deal". That is correct now: the approval targets the child, which does not need a
     *     parent to be approved. The parent stamp handles the orphan case by skipping it — see
     *     UnderwritingApprovalStampService.
     *
     * 🔴 DO NOT ADD A CALLER-SUPPLIED TARGET PARAMETER TO THE @AuraEnabled PATH. Routing is
     * decided here, server-side, from the clicked record's SObject type. A `targetId` parameter
     * would make the approval target attacker-controlled — precisely the class of hole
     * StageAdvanceService.ALLOWED_EXPLICIT_TARGETS was created to close on the stage-write side.
     *
     * @TestVisible so the routing table can be asserted directly, independently of whether any
     * given approval process happens to be active in the org.
     */
    @TestVisible
    private static Id resolveApprovalTargetId(Id recordId) {
        String objectName = recordId.getSobjectType().getDescribe().getName();
        if (objectName == 'Opportunity') {
            return recordId;
        }
        if (objectName == 'Underwriting__c') {
            return recordId;
        }
        if (objectName == 'LOI__c') {
            return LoiSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        if (objectName == 'Contract_Review__c') {
            return ContractReviewSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        throw new ApprovalException('Submit for Approval is not available on ' + objectName + '.');
    }
}
