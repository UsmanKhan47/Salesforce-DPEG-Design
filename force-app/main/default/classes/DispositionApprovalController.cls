/**
 * Backs the four DISPOSITION "Submit for Approval" quick actions (`c/dispositionSubmitForApproval`)
 * and the Select Offer screen action (`c/dispositionOfferSelect`). The sell-side twin of
 * OpportunityApprovalController, added 2026-08-19 with the disposition flow redesign (DEV-2).
 *
 * Thin controller (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). All orchestration —
 * deriving WHICH approval a Submit click means, the entry-criteria pre-checks, the duplicate-pending
 * gate, the exclusivity write and the savepoint — lives in DispositionApprovalService. These two
 * methods only marshal input, delegate, and map failures to an AuraHandledException at the LWC
 * boundary (ARCHITECTURE.md §5).
 *
 * ── 🔴 THE THREE CATCHES, AND WHY THE ORDER IS LOAD-BEARING ─────────────────
 *   1. `AccessDeniedException`  — the running user is not a disposition driver. Surfaced VERBATIM,
 *      carrying the shared denial wording every gate in this org uses. Ordered FIRST because a
 *      denial falling through to the generic clause would be masked as "could not be submitted…
 *      contact your administrator", which hides the actual reason and sends the user to the wrong
 *      person.
 *   2. `ApprovalException`      — a user-actionable rule violation (no Selected broker, wire not
 *      verified, wrong stage, already pending) or a validation rule's own message. Surfaced
 *      VERBATIM: every one of these strings was authored to be read by a user, and the whole point
 *      of the pre-checks in the service is that this message reaches them instead of the platform's
 *      "no applicable approval process was found".
 *   3. `Exception`              — anything unexpected. Masked behind a FIXED generic message with no
 *      exception detail concatenated into it, so raw Approval.process / platform text is never
 *      leaked (the OpportunityApprovalController contract, code-review W2).
 *
 * Apex requires each subclass catch above `catch (Exception e)`; the generic catch must stay
 * BENEATH them, never replace them. Delete catch 2 and every designed refusal in this feature —
 * including the authored wire-verification message that is the entire mitigation for
 * `Closing_Approval`'s new entry criterion — reaches the user as "refresh the page", advice that
 * can never work.
 *
 * ⚠ THE PERMISSION ASSERT IS NOT HERE. It is the FIRST STATEMENT OF EACH SERVICE METHOD, unlike
 * OpportunityApprovalController which asserts in the controller. That is deliberate: these service
 * methods are also reachable from Apex and Flow, and putting the gate at the service boundary means
 * a future caller cannot acquire the write path by skipping the controller. The catch clause here
 * exists to translate the resulting exception, not to perform the check.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WIDENED 2026-08-31 (Tranche 3 item 2d) — IT NOW BACKS A **FIFTH** SUBMIT ACTION, ON A
 *    DIFFERENT OBJECT. THE OPENING SENTENCE ABOVE IS NO LONGER THE WHOLE TRUTH.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * `submitNdaForApproval` backs `quickActions/NDA__c.Submit_NDA_Approval` ->
 * `c/ndaSubmitForApproval`, submitting a DISPOSITION NDA into `NDA_Issue_Approval`. Its logic lives
 * in a separate service (`NdaApprovalService`) and NOT ONE LINE of `DispositionApprovalService`
 * changed.
 *
 * ⚠ THIS IS A DELIBERATE DIVERGENCE FROM DESIGN D-9, WHICH SPECIFIED A **NEW** THIN CONTROLLER.
 * Three alternatives were weighed:
 *
 *   a. `OpportunityApprovalController` — REJECTED OUTRIGHT. Wrong module and wrong persona: it
 *      asserts the ACQUISITIONS gate (`OpportunityActionPermissionService`). A disposition NDA
 *      answers to `Disposition_Deal_Actions`. Asking the acquisitions question about a disposition
 *      record would answer it for the wrong persona — the same reason
 *      `c/dispositionSubmitForApproval` could not reuse `c/submitForApproval`.
 *   b. Extending `DispositionApprovalService.submitForApproval` to dispatch on
 *      `Id.getSObjectType()` — REJECTED. That method is a stage-and-record-type derivation table
 *      for `Disposition__c` and nothing else; folding a second object's rules into it would put
 *      NDA behaviour inside a class four other quick actions already share, and its first act is a
 *      `DispositionSelector` read that a foreign Id cannot satisfy.
 *   c. A NEW `NdaApprovalController` — the design's answer, and rejected for ONE concrete reason:
 *      🔴 EVERY NEW `@AuraEnabled` CLASS NEEDS A `classAccesses` ENTRY ON `DPEG_Apex_Access`, a
 *      shared hub permission set whose own header records THREE separate live breaks caused by a
 *      controller shipping without its grant, and whose deploy REPLACES the file's entire
 *      `classAccesses` collection. THIS class is already granted there. Reusing it means this
 *      feature needs NO permission-set change at all, which removes a cross-agent hub-file edit
 *      and a whole class of deploy-ordering failure from the wave.
 *
 * ⇒ The controller is still THIN — three catches and a delegate, no logic — and it is still exactly
 * ONE authorization boundary: all five methods here are gated by `Disposition_Deal_Actions`,
 * asserted in their services. What changed is that "disposition approvals" now means the MODULE,
 * not the `Disposition__c` object. `NdaApprovalService` (not `@AuraEnabled`) is reached only
 * through this class, matching `DPEG_Apex_Access`'s stated entry-point-only grant pattern.
 * ⚠ IF A SIXTH OBJECT EVER ARRIVES HERE, RE-OPEN THIS. The argument above is about ONE additional
 * method on ONE additional object sharing ONE gate; it is not a licence to make this the module's
 * catch-all controller.
 *
 * @see force-app/main/default/classes/DispositionApprovalService.cls (all logic)
 * @see force-app/main/default/classes/NdaApprovalService.cls (the NDA submit logic)
 * @see force-app/main/default/classes/OpportunityApprovalController.cls (the acquisitions twin)
 */
public with sharing class DispositionApprovalController {

    // Fixed, generic user-safe message for an unexpected submission failure. Never interpolate
    // platform/exception text into it (ARCHITECTURE.md §5).
    private static final String SUBMIT_FAILURE_MESSAGE =
        'This could not be submitted for approval. Refresh the page or contact your administrator.';

    // Fixed, generic user-safe message for an unexpected offer-selection failure. Separate wording
    // from the submit one so a toast tells the reader WHICH action failed — two different fixes.
    private static final String SELECT_OFFER_FAILURE_MESSAGE =
        'The offer could not be selected. Refresh the page or contact your administrator.';

    /**
     * An Id of the wrong SObject type is a WIRING MISTAKE, not a data state. See
     * `submitNdaForApproval`. Named for the NDA action specifically because it is the only method
     * in this class whose parameter is not a `Disposition__c`.
     */
    @TestVisible
    private static final String NDA_WRONG_TYPE_MESSAGE =
        'This action can only be run on an NDA.';

    /**
     * Submits whichever approval this disposition's stage and record type call for.
     *
     * @param dispositionId the Disposition__c the quick action was clicked on
     * @return an authored confirmation naming which approval was submitted
     * @throws AuraHandledException when the running user is not a disposition driver, when a
     *         user-actionable rule blocks the submission (its guidance is surfaced), or — with a
     *         fixed generic message — on an unexpected failure.
     */
    @AuraEnabled
    public static String submitForApproval(Id dispositionId) {
        try {
            return DispositionApprovalService.submitForApproval(dispositionId);
        } catch (DispositionActionPermissionService.AccessDeniedException e) {
            throw ahe(e.getMessage());
        } catch (DispositionApprovalService.ApprovalException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            System.debug(LoggingLevel.INFO, 'DispositionApprovalController.submitForApproval '
                + 'refused on ' + dispositionId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalController.submitForApproval on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(SUBMIT_FAILURE_MESSAGE);
        }
    }

    /**
     * Selects the winning offer, advances the disposition to `Offer Selection`, and submits the
     * offer for approval — all or nothing (design D-3).
     *
     * @param dispositionId the Disposition__c the screen action was launched from
     * @param offerId       the Disposition_Offer__c chosen in the radio list
     * @return an authored confirmation
     * @throws AuraHandledException as above; a blocked stage advance surfaces the validation rule's
     *         own message, which is the only thing that identifies the gate.
     */
    @AuraEnabled
    public static String selectOffer(Id dispositionId, Id offerId) {
        try {
            return DispositionApprovalService.selectOffer(dispositionId, offerId);
        } catch (DispositionActionPermissionService.AccessDeniedException e) {
            throw ahe(e.getMessage());
        } catch (DispositionApprovalService.ApprovalException e) {
            System.debug(LoggingLevel.INFO, 'DispositionApprovalController.selectOffer refused on '
                + dispositionId + '/' + offerId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalController.selectOffer on '
                + dispositionId + '/' + offerId + ': ' + e.getMessage() + ' | '
                + e.getStackTraceString());
            throw ahe(SELECT_OFFER_FAILURE_MESSAGE);
        }
    }

    /**
     * Submits a DISPOSITION NDA into the `NDA_Issue_Approval` approval process — the replacement
     * for the retired `NDA__c.Move_to_Approved` one-click stage write (Gate 1 decision D-7).
     *
     * 🔴 IT IS A DIFFERENT OBJECT FROM EVERY OTHER METHOD IN THIS CLASS, AND THE SAME GATE. See the
     * class header's 2026-08-31 block for why it lives here rather than in a new controller, and
     * `NdaApprovalService` for what it refuses and why.
     *
     * ⚠ THE THREE CATCHES ARE THE SAME SHAPE AND THE SAME ORDER AS `submitForApproval` ABOVE, but
     * catch 2 is typed to `NdaApprovalService.ApprovalException` — a SEPARATE type from
     * `DispositionApprovalService.ApprovalException` on purpose, so a refusal authored for a
     * Disposition can never surface on the NDA's button and vice versa. Do not merge the two types
     * to "simplify" this.
     *
     * ⚠ IT REUSES `SUBMIT_FAILURE_MESSAGE`, WHICH IS CORRECT BECAUSE THAT STRING SAYS "This" AND
     * NOT "This disposition". Both actions produce the same fix (refresh, or call an admin), so a
     * second constant would be two strings to keep in step for no reader benefit.
     *
     * ── 🔴 A WRONG SOBJECT TYPE IS REFUSED, OUTSIDE THE TRY (added 2026-08-31, review S-1) ─────
     * This is the ONLY method in this class whose parameter is not a `Disposition__c`, so it is
     * also the only one a quick action can plausibly be wired to the wrong way round. A
     * `Disposition__c` Id reaching `NdaSelector.selectStageRequiredById` throws a raw
     * `QueryException` ("List has no rows for assignment to SObject"), which catch 3 flattens into
     * "This could not be submitted for approval. Refresh the page or contact your administrator."
     * — advice that cannot possibly work, on a defect that is in the METADATA and would survive
     * every refresh and every admin call. The guard turns the one diagnosable failure this method
     * has into a message that names it.
     *
     * ⚠ IT SITS OUTSIDE THE TRY FOR THE SAME REASON `DispositionApprovalTrackerController.getTracker`
     * puts its guard there: inside, catch 3's `catch (Exception)` would swallow the
     * `AuraHandledException` this guard throws and replace the precise message with the generic
     * one, which is exactly the outcome the guard exists to prevent.
     *
     * ⚠ A NULL Id IS **NOT** GUARDED HERE, AND THAT ASYMMETRY WITH THE TRACKER IS DELIBERATE. The
     * tracker is a `cacheable=true` WIRE that fires on every render, including the transient tick
     * before `recordId` is provisioned — null is a normal state there and returns an empty list.
     * This method is an IMPERATIVE call made by a button click on a record that already exists;
     * a null here is a genuine failure and `NdaApprovalService` authors its own refusal for it.
     *
     * @param ndaId the NDA__c the quick action was clicked on
     * @return an authored confirmation naming the NDA Issue approval
     * @throws AuraHandledException when the Id is of the wrong SObject type, when the running user
     *         is not a disposition driver, when a user-actionable rule blocks the submission (its
     *         guidance is surfaced), or — with a fixed generic message — on an unexpected failure,
     *         including the platform's own refusal of a submitter who does not own the record
     *         (`allowedSubmitters = owner`).
     */
    @AuraEnabled
    public static String submitNdaForApproval(Id ndaId) {
        if (ndaId != null && ndaId.getSObjectType() != NDA__c.SObjectType) {
            throw ahe(NDA_WRONG_TYPE_MESSAGE);
        }
        try {
            return NdaApprovalService.submitForApproval(ndaId);
        } catch (DispositionActionPermissionService.AccessDeniedException e) {
            throw ahe(e.getMessage());
        } catch (NdaApprovalService.ApprovalException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            System.debug(LoggingLevel.INFO, 'DispositionApprovalController.submitNdaForApproval '
                + 'refused on ' + ndaId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalController.submitNdaForApproval '
                + 'on ' + ndaId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(SUBMIT_FAILURE_MESSAGE);
        }
    }

    /**
     * ⚠ `setMessage` AS WELL AS THE CONSTRUCTOR. An AuraHandledException built from the constructor
     * alone surfaces "Script-thrown exception" to the client on some paths; setting the message
     * explicitly is what makes the authored text actually arrive. Same helper, same reason, as
     * every other controller in this repo.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
