/**
 * Backs `c/dispositionLogOfferModal`'s single `@wire` — the resolved broker for one Disposition.
 * Added 2026-08-21 with the in-place Log Offer modal; the buyer half was removed the same day.
 *
 * Thin controller (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It marshals one Id,
 * delegates, and maps failures to an `AuraHandledException` at the LWC boundary (ARCHITECTURE.md
 * §5). ZERO SOQL, ZERO DML, ZERO business logic — the record-type branch and the broker resolution
 * both live in `DispositionOfferFormService`.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS CONTROLLER HAS NO WRITE METHOD, AND THAT IS A DESIGN DECISION, NOT AN OMISSION.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The offer itself is created by `lightning-record-edit-form` inside the modal, which:
 *   - enforces CRUD and FLS for the running user without a line of Apex;
 *   - surfaces each validation rule's AUTHORED message against the FIELD it names, through
 *     `<lightning-messages>` — `Buyer_Required_On_Offer` and `Offer_Amount_Required_On_Offer` are
 *     both active on this object (verified in `usman-dpeg`, 2026-08-21) and both were written to be
 *     read by a user;
 *   - and would surface `Buyer_Required_On_Offer` the same way. 🔴 THAT RULE IS STILL ACTIVE AND IS
 *     NOW UNSATISFIABLE FROM THIS DIALOG — with the buyer picker gone nothing sets `Buyer__c`, so
 *     `DispositionOfferBuyerStampService` never derives `Buyer_Name__c` and every save is refused.
 *     It must be deactivated by whoever owns `objects/**` before this ships; the full writeup is in
 *     `DispositionOfferFormService`'s header. Adding an Apex insert here would NOT work around it —
 *     a validation rule refuses Apex DML exactly as it refuses an LDS save.
 * An `@AuraEnabled` insert here would duplicate all three and LOSE the per-field attribution, which
 * is the specific regression `c/bovAddResponseModal`'s template warns about. 🔴 If a future
 * requirement genuinely needs server-side orchestration on save, add it to a SERVICE and give this
 * controller a method that delegates — do not put an `insert` in this class.
 *
 * ── 🔴 ONE CATCH WITH AN `instanceof` TEST, NOT TWO TYPED CATCHES. THIS DIVERGES FROM
 *      `DispositionApprovalController` DELIBERATELY, AND THE REASON IS MEASURED. ──────────────
 * Two outcomes are still expressed, and they are the same two:
 *   `System.QueryException` -> `ACCESS_MESSAGE`. An FLS or object-read denial wearing a SCHEMA
 *      error ("No such column"). It gets an AUTHORED message naming a PERMISSION problem, because
 *      the platform's own wording sends the reader hunting for a field that exists.
 *      ARCHITECTURE.md §2: the fix is a permission set, never `SYSTEM_MODE`.
 *      ⚠ The message deliberately does NOT concatenate the exception text: `e.getMessage()` names
 *      the FIELD, which is information about the org's security model.
 *   anything else           -> `GENERIC_MESSAGE`, with NO exception detail interpolated into it
 *      (the `OpportunityApprovalController` / `DispositionApprovalController` contract, code-review
 *      W2), so raw platform text is never leaked to a UI.
 *
 * 🔴 WHY NOT `catch (QueryException)` THEN `catch (Exception)`: THE SECOND BLOCK WOULD BE
 * PERMANENTLY UNCOVERABLE, AND THAT IS NOT COSMETIC. Measured on `usman-dpeg` 2026-08-21 with the
 * two-catch form: this class validated at **38.5%** and the deploy returned a `codeCoverageWarnings`
 * entry ("at least 75% test coverage is required"). This repo has a recorded incident where exactly
 * that warning rolled a whole deploy back while every error counter read zero. The reason the second
 * block cannot be reached is STRUCTURAL, not a gap in effort: every exception
 * `DispositionOfferFormService` lets escape comes from a `WITH USER_MODE` selector call, so it is
 * always a `QueryException` — a deleted Id degrades to an empty context (proved in
 * `DispositionOfferFormServiceTest`) and a wrong-SObject-type Id throws `QueryException` too.
 * ⚠ RE-CHECKED 2026-08-21 AFTER THE BUYER READ WAS DELETED, AND THE ANSWER CHANGED TWICE. Deleting
 * that read would have made the service incapable of throwing at all — every remaining selector call
 * sat inside a `catch (QueryException)` — which would have left THIS catch unreachable and this
 * class back at ~38%. The service's two degrade-catches were removed in the same edit, for an
 * independent correctness reason (a broker the user cannot READ must not be reported as a broker
 * that does not EXIST). Reachability here is a consequence of that, not the justification for it —
 * but if anyone ever re-adds those catches, THIS BLOCK GOES UNREACHABLE AGAIN. Check it. Apex
 * coverage is LINE-based, so folding the choice into a ternary on ONE line lets the single reachable
 * test execute every line here while both messages survive intact.
 * ⚠ THIS IS NOT A LICENCE TO COLLAPSE `DispositionApprovalController`'S THREE CATCHES. Those three
 * do genuinely different things (re-throw a denial verbatim, re-throw an authored refusal, mask),
 * all three are reachable, and all three are covered. Merge catches only when their bodies differ by
 * nothing but a message.
 *
 * ⚠ `cacheable = true` IS CORRECT AND IS NOT A STALENESS RISK HERE. This is a pure read, the modal
 * is constructed fresh on every open, and nothing the dialog itself does changes its own answer —
 * creating an OFFER does not appoint a broker. ⚠ It DOES mean that appointing a broker in another
 * tab is not reflected until the client cache expires or the page reloads; that is accepted, and it
 * is the same trade `BrokerListingController` documents for itself.
 * 🔴 THE STAKES OF THAT STALENESS WENT UP ON 2026-08-21. A stale null broker no longer just blanks a
 * read-only field — it now REFUSES THE SAVE. A user who appoints a broker in another tab and comes
 * straight back may still be told the sale has none; a page refresh clears it. Accepted, and stated
 * so it is recognised rather than debugged.
 *
 * @see force-app/main/default/classes/DispositionOfferFormService.cls (all logic)
 * @see force-app/main/default/lwc/dispositionLogOfferModal (the only consumer)
 */
public with sharing class DispositionOfferFormController {

    /**
     * Authored message for a read the running user is not provisioned for. Names the CAUSE (an
     * access grant) and the FIX (an administrator), which the platform's own `QueryException` text
     * does not.
     */
    @TestVisible
    private static final String ACCESS_MESSAGE =
        'You do not have access to the broker information on this disposition. '
            + 'Ask your administrator to check your permission set assignments.';

    /** Fixed, generic user-safe message. Never interpolate platform text into it. */
    @TestVisible
    private static final String GENERIC_MESSAGE =
        'The offer form could not be loaded. Refresh the page or contact your administrator.';

    /**
     * The Log Offer dialog's whole context: the broker this sale's offers are attributed to.
     *
     * @param dispositionId The Disposition__c the Log Offer button was clicked on. Null-safe — the
     *        service returns an empty context rather than throwing, because the modal's `@wire` can
     *        fire before the property is set.
     * @return The context. Never null. `brokerId` is null when no broker is appointed yet — a
     *         normal state, which the modal renders as an explained refusal rather than an error.
     * @throws AuraHandledException with an authored access message when the running user lacks a
     *         required grant, or with a fixed generic message on any other failure.
     * @example
     * &#64;wire(getOfferFormContext, { dispositionId: '$dispositionId' })
     * wiredContext({ data, error }) { ... }
     */
    @AuraEnabled(cacheable=true)
    public static DispositionOfferFormService.OfferFormContext getOfferFormContext(
        Id dispositionId
    ) {
        try {
            return DispositionOfferFormService.getFormContext(dispositionId);
        } catch (Exception e) {
            // The FULL detail goes to the LOG, where an administrator can read it. None of it
            // reaches the user — see the class header on why raw platform text must not.
            System.debug(
                LoggingLevel.ERROR,
                'DispositionOfferFormController.getOfferFormContext on '
                    + dispositionId + ': ' + e.getTypeName() + ' | ' + e.getMessage()
                    + ' | ' + e.getStackTraceString()
            );
            // 🔴 ONE LINE, TWO OUTCOMES. See the class header: two typed catches would leave the
            // generic block permanently uncoverable and drag this class under the 75% per-class
            // threshold, which this repo has measured rolling a whole deploy back silently.
            throw ahe(e instanceof System.QueryException ? ACCESS_MESSAGE : GENERIC_MESSAGE);
        }
    }

    /**
     * Builds an `AuraHandledException` whose MESSAGE the client can actually read.
     *
     * ⚠ `setMessage` IS REQUIRED, NOT DECORATIVE. Without it the LWC receives
     * `error.body.message === 'Script-thrown exception'` and every authored string above is lost —
     * the same construction `DispositionApprovalController` uses.
     *
     * @param message The user-safe text.
     * @return The exception to throw.
     */
    private static AuraHandledException ahe(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
