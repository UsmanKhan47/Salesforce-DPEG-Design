/**
 * The `@AuraEnabled` boundary for the card titled "Broker Activity Timeline" — backs
 * `c/dispositionBuyerTimeline` on the Disposition record page (Tranche 2 Workstream D,
 * `agent-output/disposition-tranche-2-requirements.md` §3 D6.3; retargeted 2026-08-21).
 *
 * ⚠ THE CLASS AND COMPONENT NAMES SAY "BUYER", THE CARD SAYS "BROKER", AND A ROW IS AN NDA. All
 * three disagree on purpose and the full argument is in `DispositionBuyerTimelineService`'s header.
 * In short: a rename here is a FlexiPage edit plus a destructive Apex delete, i.e. a two-sided
 * deploy a check-only validation cannot prove, so only the USER-VISIBLE strings were changed
 * (2026-08-21, user instruction — the title was briefly "NDA Activity Timeline"). Read every
 * "buyer" in an API name on this feature as historical.
 * 🔴 AND "Broker" IN THE TITLE IS NOT A GROUPING CLAIM. One appointed broker per sale means the
 * same broker name repeats on every row; the title names the party DPEG deals with. Grouping the
 * rows by broker would collapse a multi-NDA sale to one row and delete the timeline. The payload
 * this method returns is one element per NDA and must stay that way.
 *
 * 🔴 THIS CARD DOES NOT READ `NDA__c.NDA_Signed__c`, AND THAT IS ITS CENTRAL CORRECTNESS PROPERTY.
 * The checkbox latches — it is only ever cleared on `Declined`, stays true through `Sent`, and
 * stayed true forever for any party who walked away before Workstream A3 — so reading it would show
 * a signed NDA for a counterparty who refused. `Status__c = 'Signed'` is the gate and
 * `Date_Signed__c` is only the value shown once it passes; `NDA_Signed_Status_Sync` never clears
 * that date, so the date alone is not sufficient either. The full argument, and the code that
 * enforces it, are in `DispositionBuyerTimelineService`. Restated here because a future author
 * reaching for "just add the signed flag" is far more likely to open the controller first.
 *
 * Layering: THIN controller (ARCHITECTURE.md §2, `layer=controller`) — marshal, delegate, catch,
 * throw `AuraHandledException` with a fixed user-safe message. **ZERO SOQL of its own** and zero
 * business logic; every rule (the signed gate, the declined treatment, the negative-duration
 * suppression, the no-broker fallback, the ordering) lives in the service.
 *
 * ── ⚠ `cacheable=true`, AND WHAT THAT COSTS ─────────────────────────────────────────────────
 * This is a read-only card on a record page, called once per page view per record, over data that
 * changes at most a few times per deal. The client therefore holds the payload and nothing in this
 * feature invalidates it — so an NDA signed in the related list on the SAME PAGE may not appear
 * here until a refresh. That is the identical, accepted trade
 * `DispositionTractionController.getTraction` documents at length, and for the same reason: the
 * alternative is a server round trip on every render. ⚠ Unlike that card, the disagreement here is
 * BENIGN — this one shows a slightly stale journey, it does not advise replacing a broker on the
 * strength of a stale number.
 *
 * ── 🔴 A `QueryException` IS **NOT** SWALLOWED INTO AN EMPTY TIMELINE ────────────────────────
 * The selector read behind this method is `WITH USER_MODE`, so a missing FLS or object grant
 * throws rather than degrading. This controller turns that into a VISIBLE error message. It
 * deliberately does NOT catch-and-return-empty, which is the tempting "fail soft" shape used
 * elsewhere in this repo (`BovController`'s NDA pill, `DispositionDealSummaryService`'s narrow
 * catch): those degrade ONE ROW of a larger card to a neutral value. Here the whole card IS the
 * data, and an empty timeline on a sale with three raised NDAs is a CONFIDENT WRONG ANSWER that
 * nothing on the page contradicts. A wrong answer nobody can detect is worse than an error message
 * that names the fix.
 *
 * 🔴 THE FIX FOR SUCH AN ERROR IS ALWAYS A PERMISSION SET, NEVER `SYSTEM_MODE` ON THE SELECTOR.
 * ⚠ AMENDED 2026-08-21 — THE GATE LIST CHANGED IN BOTH DIRECTIONS AND ONE ENTRY IS UNVERIFIED.
 * The three `Disposition_Offer__c` gates are GONE (the first-offer column and its query were
 * deleted), as are `NDA__c.Buyer__c` and `NDA__c.Counterparty_Name__c`. What remains is five
 * `NDA__c` fields verified granted on `DPEG_Disposition_View` / `DPEG_Disposition_Edit`
 * (2026-08-20), plus OBJECT read on `Contact` for the name traversal — which is on NEITHER of those
 * sets and comes from `DPEG_Contact_View` / `DPEG_Contact_Edit` inside the same permission-set
 * groups.
 * 🔴 AND A SIXTH, BRAND-NEW GATE: `NDA__c.Broker__c`, a 2026-08-21 field that did not exist in
 * `usman-dpeg` when this was written. A Metadata-API-deployed field arrives with NO FLS for anyone,
 * System Administrator included, so **this card throws for every persona until both disposition
 * permission sets grant it**. If this card is showing its error banner right after a deploy, that
 * is the first thing to check — it is a deploy-order dependency, not a defect.
 *
 * @see force-app/main/default/classes/DispositionBuyerTimelineService.cls
 * @see force-app/main/default/lwc/dispositionBuyerTimeline/dispositionBuyerTimeline.js
 * @see force-app/main/default/classes/DispositionTractionController.cls (the shape this copies)
 */
public with sharing class DispositionBuyerTimelineController {

    /**
     * Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never interpolate
     * platform text or exception detail into it — the detail goes to the debug log (admin-only).
     */
    private static final String READ_FAILURE_MESSAGE =
        'The NDA timeline could not be loaded. Refresh the page or contact your administrator.';

    /** An Id of the wrong SObject type is a wiring mistake, not a data state. See getTimeline. */
    private static final String WRONG_TYPE_MESSAGE =
        'The NDA timeline can only be read for a Disposition.';

    /**
     * `AuraHandledException` loses its message unless `setMessage` is called explicitly — a platform
     * quirk this repo hits everywhere, hence the helper. Same shape as
     * `DispositionTractionController.ahe`.
     *
     * @param msg The user-safe message.
     * @return The exception, with its message actually set.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The rows behind the "Broker Activity Timeline" card for one Disposition — ONE PER NDA, never
     * one per broker (see the class header).
     *
     * NOT-FOUND CONTRACT: a null Id, or a Disposition with no buyer-role NDA, returns an EMPTY LIST.
     * "No NDA has been raised yet" is a normal early state the component renders as an empty state —
     * it is not an error and it is not a null.
     *
     * ── ⚠ A WRONG SOBJECT TYPE IS A DIFFERENT THING AND IS REFUSED ─────────────────────────────
     * An Id of some other object is a WIRING MISTAKE, not a data state. Binding a foreign Id into
     * `WHERE Disposition__c = :id` throws NOTHING — it simply matches no rows (measured on
     * `usman-dpeg` 2026-08-10 for the equivalent shape on `Disposition__c`). Without this guard a
     * component wired to the wrong `record-id` would render a confident, permanent empty state and
     * nobody would ever learn the card was pointed at the wrong record.
     * The guard sits OUTSIDE the try on purpose: inside it, the `catch (Exception)` below would
     * swallow its own `AuraHandledException` and replace a precise message with the generic one.
     *
     * @param dispositionId The Disposition whose NDA journey to read.
     * @return One row per buyer-role NDA, active parties first and declined parties last. Never
     *         null.
     * @throws AuraHandledException when the Id is of the wrong SObject type, or when the underlying
     *         read fails (almost always a missing FLS or object grant — see the class header).
     */
    @AuraEnabled(cacheable=true)
    public static List<DispositionBuyerTimelineService.NdaRow> getTimeline(Id dispositionId) {
        if (dispositionId == null) {
            return new List<DispositionBuyerTimelineService.NdaRow>();
        }
        if (dispositionId.getSObjectType() != Disposition__c.SObjectType) {
            throw ahe(WRONG_TYPE_MESSAGE);
        }
        try {
            return DispositionBuyerTimelineService.getTimeline(dispositionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionBuyerTimelineController.getTimeline on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
