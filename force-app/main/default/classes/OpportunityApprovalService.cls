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
 * ⚠⚠ RETRACTED AGAIN 2026-09-01 (W4 of the LOI approval cutover) — THE PARAGRAPH DIRECTLY ABOVE
 * IS NOW HALF WRONG IN ITS TURN, AND IT IS KEPT ONLY BECAUSE IT EXPLAINS THE 2026-08-28 SHAPE.
 * The clause "LOI__c ... still resolve to the PARENT Opportunity. LOI_Approval is NOT changing"
 * WAS TRUE WHEN WRITTEN AND IS FALSE NOW. `approvalProcesses/LOI__c.LOI_Approval` is active
 * (W2, 2026-09-01) and the routing is:
 *   - Underwriting__c    -> ITSELF.
 *   - LOI__c             -> ITSELF.  ← the W4 change
 *   - Contract_Review__c -> the PARENT Opportunity (the only child that still does).
 *   - Opportunity        -> itself.
 * 🔴 THE MOTIVATION WAS A BLOCKED USER, NOT TIDINESS. `Opportunity.LOI_Approval` declares
 * `allowedSubmitters type=owner`, so routing an LOI click to the deal meant the submission was
 * refused for anyone who did not OWN the deal — which is the deal driver's normal situation.
 * `LOI__c.LOI_Approval` carries the same `owner` setting, but an acquisition LOI is owned by the
 * `Acquisition` QUEUE and `owner` was MEASURED (W2) to mean "the queue's members may submit".
 *
 * ⚠ RETRACTED 2026-09-01 (W5). This read: "`Opportunity.LOI_Approval` IS STILL ACTIVE AND THAT IS
 * DELIBERATE. Deactivating it is W5, separately authorised, so that the old route survives as an
 * escape hatch until the new one has been used in anger." W5 HAS NOW RUN. The escape hatch served
 * its purpose and is closed: the new route was used in anger first (ProcessInstance
 * 04giw0000003Yzd, Approved, on an LOI__c target, 2026-09-01) and only then was the old process
 * deactivated.
 * 🔴 THERE ARE NOW ZERO ACTIVE APPROVAL PROCESSES ON `Opportunity`. Both LOI_Approval and
 * Underwriting_Approval are Obsolete on that object. Any Opportunity target reaching
 * `Approval.process` from here WILL fail — see the 'LOI'-stage branch in the catch, which no
 * longer propagates raw.
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
 * all. An Opportunity-side rule is no better: approval field updates BYPASS custom validation
 * rules in this org (org finding F2). The demonstration USED to be
 * `LoiGateTest.rejectionReturnsDealToUnderwriting`; that method is now
 * `rejectionLeavesLoiUnderReviewAndDoesNotRewindTheDeal` and, with the deal rewind retired by
 * D-3, it asserts the deal does NOT move at all, so it no longer exercises the bypass. The
 * finding stands on F2; do not cite the test for it, and do not rebuild the rewind to restore
 * the citation.
 *
 * 🔴 THE FIRST HALF OF THAT PARAGRAPH IS RETRACTED, 2026-09-01 (W4), AND THE RETRACTION IS
 * RECORDED RATHER THAN ACTED ON. Its premise — "no DML ever touches the `LOI__c` row" — was true
 * only because the LOI resolved to its parent. An LOI now submits ITSELF: `Approval.process`
 * locks the LOI (`recordEditability = AdminOnly`) and its `finalApprovalActions` writes
 * `LOI_Status__c` ON THAT ROW, so DML DOES touch it and a validation rule on `LOI__c` is no
 * longer dead code. ⚠ THAT MAKES A VR *VIABLE*, NOT *CHOSEN*. Converting this gate to a
 * validation rule is a redesign with its own consequences (a VR fires on every save of the row,
 * not only on submission, and cannot distinguish a submission from an edit), and W4 is a
 * REPOINT. The gate stays in Apex for this wave. Anyone reopening it should start here.
 * ⚠ The SECOND half still stands unchanged: an Opportunity-side rule is still no better, for the
 * same measured reason.
 *
 * ⚠ AND THERE IS DELIBERATELY NO `RecordType.DeveloperName == 'Acquisition_LOI'` CRITERION.
 * The module boundary is already STRUCTURAL: a `Disposition_LOI` carries a blank `Opportunity__c`,
 * so `resolveApprovalTargetId` returns null and the "not linked to a deal" refusal above fires
 * before the gate is reached; the disposition side has a wholly separate path
 * (`dispositionSubmitForApproval` -> `DispositionApprovalService`). A criterion that can never
 * discriminate reads as load-bearing to the next person and gets defended forever. The reasoning
 * is recorded here INSTEAD of being encoded as a check.
 *
 * 🔴 THAT PARAGRAPH'S *MECHANISM* IS RETRACTED TOO, 2026-09-01 (W4), THOUGH ITS CONCLUSION
 * SURVIVES. The boundary is no longer structural in THIS class: an LOI resolves to itself, so a
 * `Disposition_LOI` with a blank `Opportunity__c` is no longer refused here — it reaches
 * `Approval.process` and is refused by `LOI__c.LOI_Approval`'s own
 * `RecordTypeId = Acquisition_LOI` entry criterion. The boundary moved from Apex to the approval
 * process's entry criteria, which is a better place for it. What survives is the conclusion: a
 * record-type criterion in THIS class would still be redundant, so none is added. What is LOST is
 * message quality — that refusal now surfaces as the controller's generic mask instead of a typed
 * message. Accepted, and cheap, because the Submit button is hidden on `Disposition_LOI` by the
 * page's own visibility rule, so the path is not reachable from the UI.
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
     * `LOI__c.Stage__c` value that `LOI__c.LOI_Approval` takes as its entry criteria (together
     * with `RecordTypeId = Acquisition_LOI`). A submission from any other stage can never match,
     * so it is reported as a user-actionable reason instead of falling through to the
     * controller's generic mask.
     *
     * ⚠ THIS LITERAL IS DUPLICATED IN DECLARATIVE METADATA — three times, not once, and they must
     * move together: the approval's `entryCriteria`, the Submit button's visibility rule on
     * `flexipages/LOI_Record_Page`, and this constant. There is no compile-time link between any
     * of them. A mismatch between the first two produces `NO_APPLICABLE_PROCESS` on a button the
     * page said was available; a mismatch with this constant only makes the refusal message name
     * the wrong stage.
     */
    private static final String LOI_STAGE_UNDER_REVIEW = 'Under Review';

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
     * Surfaced when an OPPORTUNITY is submitted and no approval applies to it. Added 2026-09-01
     * (W4), the exact counterpart of UNDERWRITING_MOVED_MESSAGE and for the same reason: the
     * principal LOI approval moved off the deal and onto `LOI__c`, so every Opportunity-target
     * refusal in the catch below now has to name a route that still exists.
     *
     * ⚠ IT STATES WHERE THE APPROVAL LIVES; IT DOES NOT DIAGNOSE WHY THIS SUBMISSION FAILED, AND
     * THAT WORDING IS DELIBERATE. `NO_APPLICABLE_PROCESS` is returned for at least three
     * different causes — entry criteria did not match, the submitter is not an allowed submitter,
     * and the submitter cannot evaluate the record at all for CRUD/FLS reasons — and this catch
     * cannot tell them apart. A message that asserted "your deal is at the wrong stage" would be
     * wrong two times in three. "LOI approval runs on the LOI record" is true in all three.
     *
     * ⚠ RETRACTED 2026-09-01 (W5). This paragraph read:
     *     "IT IS USED ON THE NON-'LOI' STAGES ONLY, NOT ON A DEAL AT 'LOI'. That looks like an
     *      omission and is not: while `Opportunity.LOI_Approval` remains ACTIVE (until W5), 'LOI'
     *      is still an eligible Opportunity stage and a failure there is still genuinely
     *      unexpected..."
     * `Opportunity.LOI_Approval` IS NOW DEACTIVATED, so 'LOI' is no longer an eligible Opportunity
     * stage — there are ZERO active approval processes on Opportunity. This message is therefore
     * now used on EVERY Opportunity-target refusal, at 'LOI' and elsewhere, in two shapes:
     *   - non-'LOI' stage -> prefixed with 'No approval applies to this deal at the X stage. '
     *   - 'LOI' stage     -> this message ALONE. Tests distinguish the two by exact equality.
     *
     * @TestVisible so the tests can assert the exact string rather than a substring, which is what
     * separates the two shapes above — and, more importantly, separates this refusal from
     * NDA_UNSIGNED_MESSAGE on the sharing-axis tests.
     */
    @TestVisible
    private static final String LOI_MOVED_MESSAGE =
        'LOI approval runs on the LOI record, not on the deal. '
        + 'Open this deal\'s LOI and use Submit for Approval there.';

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
     * `Underwriting_Approval` on the `Underwriting__c` record at Stage__c = 'In Progress', or
     * `LOI_Approval` on the `LOI__c` record at Stage__c = 'Under Review' with record type
     * Acquisition_LOI.
     * ⚠ CHANGED 2026-09-01 (W4). This line said "LOI_Approval on the Opportunity at
     * StageName = 'LOI'"; that process still exists and is still active, but it is the escape
     * hatch, and nothing in the UI routes here to reach it.
     *
     * ⚠ An `LOI__c` target — and an Opportunity target at `StageName = 'LOI'` — additionally
     * passes through the signed-NDA gate (`assertNdaSignedForLoiSubmission`) before
     * `Approval.process` is reached. See the class header for why that pre-check exists and why
     * it does not contradict the catch-block comment about the stage re-read.
     *
     * @param recordId the clicked record: an Underwriting or an LOI (both submit THEMSELVES), an
     *                 Opportunity (itself), or a Contract Review (submits the parent deal).
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
        // ⚠ AND AS OF 2026-09-01 (W4) THE SAME IS TRUE OF AN LOI. It needs no code change here
        // because the guard keys on `targetId`, whatever that resolves to — which is exactly why
        // it was written against the resolved target rather than against `recordId`. It also
        // matters more than before: the page's `LOI_Status__c NE 'Pending Approval'` criterion is
        // inert (nothing writes that value), so this Apex check is the only thing standing
        // between a second click and a duplicate submission.
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
            if (targetId.getSobjectType() == LOI__c.SObjectType) {
                // ── NEW 2026-09-01 (W4). An LOI now submits ITSELF, so a failed LOI submission
                // must be interpreted against the LOI's OWN entry criteria, not the deal's.
                // 🔴 WITHOUT THIS BRANCH THE FALL-THROUGH BELOW IS A BUG, NOT A GAP: it would
                // hand an LOI Id to OpportunitySelector.selectStageRequiredById, whose single-row
                // assignment throws System.QueryException for a row that is not an Opportunity.
                // Every user-actionable LOI refusal would have surfaced as the controller's
                // generic mask.
                LOI__c loi = LoiSelector.selectStageRequiredById(targetId);
                if (loi.Stage__c != LOI_STAGE_UNDER_REVIEW) {
                    throw new ApprovalException(
                        'An LOI is submitted for principal approval from the '
                        + LOI_STAGE_UNDER_REVIEW + ' stage. This one is at the '
                        + loi.Stage__c + ' stage.');
                }
                // ⚠ AT THE ELIGIBLE STAGE, PROPAGATE RAW — AND DO NOT BE TEMPTED TO NAME THE
                // RECORD TYPE HERE. The other half of the approval's entry criteria is
                // RecordTypeId = Acquisition_LOI, so a Disposition_LOI at 'Under Review' reaches
                // this line. It is NOT worth a second typed message: the same
                // NO_APPLICABLE_PROCESS is also what a non-allowed submitter and an
                // FLS-blocked submitter get, so a record-type message would be wrong more often
                // than right. The disposition path is a separate feature
                // (dispositionSubmitForApproval -> DispositionApprovalService) and the Submit
                // button is hidden on that record type by the page's own visibility rule.
                throw e;
            }
            Opportunity deal = OpportunitySelector.selectStageRequiredById(targetId);
            if (deal.StageName == STAGE_UNDERWRITING) {
                // ⚠ CHANGED 2026-08-28. 'Underwriting' USED TO BE IN THE ELIGIBLE SET alongside
                // 'LOI', so this case fell through to `throw e` and was masked. See
                // UNDERWRITING_MOVED_MESSAGE for why that was the worst possible outcome here.
                throw new ApprovalException(UNDERWRITING_MOVED_MESSAGE);
            }
            // ── ⚠ MESSAGE REPOINTED 2026-09-01 (W4). This block used to read:
            //     throw new ApprovalException('No approval applies at the ' + deal.StageName +
            //         ' stage - LOI approval runs at the LOI stage.');
            // "LOI approval runs at the LOI stage" told the submitter to move the DEAL to a stage
            // at which, after this change, nothing useful happens: the principal LOI approval no
            // longer accepts an Opportunity from any UI route. The replacement names where the
            // approval actually lives.
            if (deal.StageName != STAGE_LOI) {
                throw new ApprovalException('No approval applies to this deal at the '
                    + deal.StageName + ' stage. ' + LOI_MOVED_MESSAGE);
            }
            // ── ✅ W5 APPLIED, 2026-09-01. THIS IS THE ONE APEX LINE W5 NEEDED. ───────────────
            // `Opportunity.LOI_Approval` is now DEACTIVATED
            // (approvalProcesses/Opportunity.LOI_Approval, <active>false</active>), so there are
            // ZERO active approval processes on Opportunity. A deal at 'LOI' can no longer enter
            // any approval by any route, which means a failure here is no longer "unexpected" —
            // it is the guaranteed and fully-explained outcome, and the EXCEPTION CONTRACT's raw
            // propagate is reserved for genuinely unexpected failures only.
            //
            // ⚠ WHAT THIS LINE COST, RECORDED SO IT IS NOT REDISCOVERED AS A BUG. It was written,
            // measured and REVERTED at W4, because
            // `OpportunityApprovalServiceTest.aSubmitterWhoCannotSeeTheNdaIsNotFalselyBlocked`
            // distinguished "the service's own gates let this through" from "a gate refused it"
            // by WHETHER AN ApprovalException CAME BACK. That discriminator is now gone: every
            // Opportunity target ends in an ApprovalException.
            // 🟢 IT WAS REPLACED, NOT DROPPED, AND THE REPLACEMENT IS SOUND. The discriminator
            // moved from the exception TYPE to the exception MESSAGE, and it is exactly as strong,
            // because THIS THROW IS INSIDE THE CATCH: reaching it PROVES `Approval.process` was
            // called and threw. So `message == LOI_MOVED_MESSAGE` still proves the submission got
            // past every gate this service owns (the null check, the duplicate-pending guard and
            // the signed-NDA gate), which is precisely what that test measures. A refusal by one
            // of those gates carries a different message — NDA_UNSIGNED_MESSAGE in particular —
            // and is still distinguishable. The sharing axis remains measurable.
            //
            // ⚠ NO_APPLICABLE_PROCESS IS STILL AMBIGUOUS, AND THAT IS WHY THIS MESSAGE DOES NOT
            // DIAGNOSE. It is returned for "entry criteria did not match", "the submitter is not
            // an allowed submitter" AND "the submitter cannot evaluate the record at all for
            // CRUD/FLS reasons". This branch cannot tell them apart, so it states only where the
            // approval now lives — true in all three cases. See LOI_MOVED_MESSAGE's own docstring.
            throw new ApprovalException(LOI_MOVED_MESSAGE);
        }
    }

    /**
     * 🔴 THE SIGNED-NDA GATE. Refuses an Opportunity submission at the LOI stage when the deal has
     * no primary NDA, or has one that is not signed. See the class header for why this is a
     * pre-check (and why that does NOT contradict the catch-block comment about the stage re-read),
     * why it is Apex rather than a validation rule, and why it carries no record-type criterion.
     *
     * ══ 🔴 REPOINTED 2026-09-01 (W4) — IT NOW FIRES FOR AN `LOI__c` TARGET TOO ═══════════════
     * ⚠ RETRACTED, VERBATIM, FROM NARROWING CONDITION 1 BELOW:
     *     "NOT AN OPPORTUNITY TARGET -> return, WITHOUT QUERYING."
     * That single line WAS the whole gate for an LOI submission, because an LOI used to resolve
     * to its parent Opportunity and therefore arrived here as an Opportunity target. W4 repointed
     * `resolveApprovalTargetId` so an LOI submits ITSELF — and had this method been left alone,
     * the gate would have RETURNED IMMEDIATELY on every LOI submission and silently stopped
     * firing. 🔴 IT WOULD NOT HAVE GONE RED. Its five existing tests all submit an OPPORTUNITY,
     * so they would have kept passing against a branch that no production click can reach any
     * more. That is why the design pack calls this "the edit that gets forgotten": the gate buys
     * "a REFUSAL THAT WOULD OTHERWISE NOT HAPPEN", and a refusal that stops happening looks
     * exactly like a green test suite.
     *
     * TWO TARGET SHAPES ARE NOW HANDLED, AND THE OPPORTUNITY ONE IS DELIBERATELY KEPT:
     *   - `LOI__c`      -> the LIVE path. Reads the NDA through the LOI's parent deal in ONE
     *                      query (`LoiSelector.selectNdaGateByLoiId`).
     *   - `Opportunity` -> UNCHANGED, and not dead code. `Opportunity.LOI_Approval` stays ACTIVE
     *                      until W5 as the escape hatch, and `Contract_Review__c` still resolves
     *                      to its parent deal, so an Opportunity target can still reach
     *                      `Approval.process`. Deleting this half now would remove the gate from
     *                      the hatch it is meant to protect.
     *
     * ══ 🔴 W5 (2026-09-01): THE OPPORTUNITY BRANCH WAS RE-EXAMINED AND **KEPT**. READ THIS ═════
     * ══    BEFORE DELETING IT — ESPECIALLY IF YOUR REASON IS "THE LOI ROUTE IS GONE".      ═════
     * ⚠ RETRACTED, VERBATIM, FROM THE LINE DIRECTLY ABOVE:
     *     "🔴 W5 IS WHERE IT IS RETIRED, NOT HERE."
     * That promise was re-examined against the ORG at W5 and deliberately NOT kept. It rested on
     * the theory that this half existed only to protect the `Opportunity.LOI_Approval` escape
     * hatch. The theory was INCOMPLETE — the routing table, not the hatch, is what keeps the
     * branch alive:
     *
     *   🔴 `resolveApprovalTargetId` STILL MAPS `Contract_Review__c` -> THE PARENT OPPORTUNITY. It
     *   is the one child that never moved, and it is a live, tested branch
     *   (`OpportunityApprovalServiceTest.resolvesDealFromContractReviewRecord`). An Opportunity
     *   target therefore still reaches this method in production after W5. The branch is NOT
     *   unreachable, and "the LOI route is gone" does not make it so.
     *
     *   ⚠ SECOND ROUTE, WEAKER BUT REAL: `quickActions/Opportunity.Submit_for_Approval` EXISTS as
     *   deployed metadata (LWC `submitForApproval`; one of three `Submit_for_Approval`
     *   QuickActionDefinition rows in the org). It is on NO layout and NO FlexiPage today, so it
     *   is unreachable from the UI — but surfacing it is a one-line App Builder change by an
     *   admin, with no code review and no deploy.
     *
     * ⚠ BE HONEST ABOUT WHAT THE BRANCH IS NOW WORTH — ITS JUSTIFICATION HAS WEAKENED, AND SAYING
     * SO IS THE POINT OF THIS BLOCK. With ZERO active Opportunity approvals, this gate can no
     * longer buy "a REFUSAL THAT WOULD OTHERWISE NOT HAPPEN" on the Opportunity path: the platform
     * refuses every Opportunity submission anyway. What it still buys there is MESSAGE QUALITY —
     * an unsigned-NDA deal at 'LOI' is told to link a signed NDA rather than told the approval
     * moved, and the former is the more actionable. On the `LOI__c` path the original, stronger
     * justification is completely untouched: that gate DOES prevent a real approval.
     *
     * ⇒ VERDICT: KEEP. Retiring it is a defensible SEPARATE decision — it would reduce this method
     * to the LOI path alone and release five Opportunity-target tests — but W5's authorised scope
     * was one Apex line plus test repoints, and deleting a live branch on a live path is not that.
     * Anyone reopening it must settle the `Contract_Review__c` routing question FIRST; that, not
     * the LOI route, is the thing keeping this branch alive.
     *
     * ⚠ THE LOI PATH DOES NOT TEST THE PARENT'S StageName, AND THAT IS A WIDENING ON PURPOSE.
     * The old condition 3 (`deal.StageName == 'LOI'`) was a PROXY for "this submission is the LOI
     * approval"; the target's own SObject type now says so directly. The new approval's entry
     * criteria are the LOI's `Stage__c` and its record type — the deal's stage is not part of
     * them — so keeping the proxy would mean the gate silently stopped firing whenever the deal
     * had moved on. The business rule is "an LOI must not go to the principals unless the deal
     * has a signed NDA", and that does not depend on where the deal sits.
     *
     * ── NARROWING CONDITIONS, EACH OF WHICH IS A NO-OP FOR SOMEONE ─────
     *   1. NEITHER AN LOI NOR AN OPPORTUNITY TARGET -> return, WITHOUT QUERYING. An
     *      `Underwriting__c` submits itself into `Underwriting_Approval`, which has nothing to do
     *      with the LOI or the NDA. This is what keeps the added cost off the underwriting path.
     *   2. THE ROW DOES NOT RESOLVE -> return. Both selector methods return null rather than
     *      throwing precisely so this gate cannot change WHERE an unexpected failure originates:
     *      a dead Id must still reach `Approval.process` and fail there, raw, as it always has.
     *      (`OpportunityApprovalServiceTest.unexpectedFailurePropagatesRawNotWrapped` is the pin.)
     *   3a. LOI PATH — NO PARENT DEAL -> return. A blank `Opportunity__c` is a LEGAL state (the
     *      lookup is `SetNull`, and a sell-side LOI hangs off `Disposition__c`), and a
     *      disposition NDA is a different object's business entirely.
     *   3b. OPPORTUNITY PATH — NOT AT THE LOI STAGE -> return, unchanged.
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
     * @throws ApprovalException when the target is an LOI (or an LOI-stage deal) whose deal has no
     *         signed primary NDA. The message is user-actionable and safe to surface verbatim
     *         (EXCEPTION CONTRACT).
     */
    private static void assertNdaSignedForLoiSubmission(Id targetId) {
        Schema.SObjectType targetType = targetId.getSobjectType();

        if (targetType == LOI__c.SObjectType) {
            LOI__c loi = LoiSelector.selectNdaGateByLoiId(targetId);
            if (loi == null || loi.Opportunity__c == null) {
                return;
            }
            assertDealNdaSigned(loi.Opportunity__r);
            return;
        }

        if (targetType != Opportunity.SObjectType) {
            return;
        }
        Opportunity deal = OpportunitySelector.selectNdaGateById(targetId);
        if (deal == null || deal.StageName != STAGE_LOI) {
            return;
        }
        assertDealNdaSigned(deal);
    }

    /**
     * The gate's actual test, shared by both target shapes so the two paths cannot drift into
     * enforcing subtly different rules. Extracted 2026-09-01 (W4); the logic is byte-identical to
     * what `assertNdaSignedForLoiSubmission` inlined before.
     *
     * ⚠ `deal.Primary_NDA__r` IS NOT DEREFERENCED WHEN `Primary_NDA__c` IS NULL. A null lookup
     * yields a null parent, so `deal.Primary_NDA__r.NDA_Signed__c` would be a null dereference;
     * the `Primary_NDA__c == null` test is checked FIRST and short-circuits. Do not "simplify" the
     * two conditions into one `!= true` expression on the spanning field.
     *
     * 🔴 A NULL `deal` SKIPS, IT DOES NOT REFUSE, AND THAT IS THE MOST IMPORTANT LINE HERE. On the
     * LOI path this argument is a SPANNED parent (`loi.Opportunity__r`), and a spanned parent
     * comes back NULL when the running user cannot see it — a `WITH SYSTEM_MODE` read is
     * sharing-filtered on the parent, MEASURED on this very gate on 2026-08-30. Refusing on null
     * would not degrade the gate, it would INVERT it: it would fabricate "this deal has no signed
     * NDA" and block a legitimate submission for every submitter who cannot see the deal. The
     * primary defence is that `LoiSelector.selectNdaGateByLoiId` reads `without sharing` so the
     * parent is not filtered in the first place; this null-skip is the belt to that braces, and it
     * fails in the safe direction.
     *
     * @param deal The deal carrying `Primary_NDA__c` + `Primary_NDA__r.NDA_Signed__c`; may be null.
     * @throws ApprovalException when the deal has no primary NDA, or one that is not signed.
     */
    private static void assertDealNdaSigned(Opportunity deal) {
        if (deal == null) {
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
     *   - LOI__c                     -> ITSELF. ⚠ CHANGED 2026-09-01 (W4). See below.
     *   - Opportunity                -> itself.
     *   - Contract_Review__c         -> the PARENT Opportunity (unchanged).
     *
     * ── 🔴 THE LOI BRANCH, 2026-09-01 (W4 of the LOI approval cutover) ────────────────────────
     * ⚠ RETRACTED, VERBATIM, FROM THIS DOCSTRING AND FROM THE CLASS HEADER ABOVE:
     *     "LOI__c / Contract_Review__c -> the PARENT Opportunity (unchanged — LOI_Approval still
     *      runs on the deal)."
     * The principal LOI approval has MOVED onto `approvalProcesses/LOI__c.LOI_Approval` (active
     * since W2), so an LOI now submits ITSELF, exactly as an Underwriting has since 2026-08-28.
     * This one line is the change the user asked for: *"Make sure that we must have approval on
     * LOI record page not on opportunity."* Until it landed, clicking Submit for Approval on an
     * LOI put the approval on the DEAL — which is owner-gated and owned by someone else, so the
     * deal driver was simply blocked.
     *
     * ⚠ IT LOSES A QUERY AND TWO BEHAVIOURS, THE SAME THREE THE UNDERWRITING BRANCH LOST:
     *   - The happy path no longer reads `LoiSelector.selectOpportunityIdRequiredById`, which now
     *     has NO production caller at all (kept and annotated there, not deleted).
     *   - A non-existent LOI Id no longer throws `System.QueryException` HERE. It fails at
     *     `Approval.process`, and the catch's own LOI stage re-read then throws the SAME
     *     exception — the "unexpected failure propagates raw" contract is preserved, one step
     *     later.
     *   - 🔴 AN LOI WITH A BLANK `Opportunity__c` IS NO LONGER REFUSED AS "not linked to a deal",
     *     AND THAT RETRACTS AN ARGUMENT THE CLASS HEADER MADE. The header used to say the
     *     acquisition/disposition module boundary was STRUCTURAL — a `Disposition_LOI` carries a
     *     blank `Opportunity__c`, so the resolver returned null and the submission was refused
     *     before any gate ran. It no longer is. A disposition LOI now reaches `Approval.process`
     *     and is refused by the new approval's OWN `RecordTypeId = Acquisition_LOI` entry
     *     criterion instead, which is a correct refusal with a worse message. The button is
     *     hidden on that record type by the page's visibility rule, so the path is not reachable
     *     from the UI; it is recorded here rather than closed with a criterion, because a
     *     criterion that can never discriminate reads as load-bearing and gets defended forever.
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
            return recordId;
        }
        if (objectName == 'Contract_Review__c') {
            return ContractReviewSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        throw new ApprovalException('Submit for Approval is not available on ' + objectName + '.');
    }
}
