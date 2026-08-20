/**
 * The `@AuraEnabled` boundary for the disposition Deal Summary card — backs
 * `c/dispositionDealSummary` on `Disposition_Record_Page`. Tranche 2 Workstream C (design D5),
 * 2026-08-20.
 *
 * Layering: thin controller (ARCHITECTURE.md §2) — marshal, delegate, catch, throw
 * `AuraHandledException` with a fixed user-safe message. **Zero SOQL of its own**; every read is
 * `DispositionDealSummaryService` -> the four object selectors.
 *
 * ═══ ⚠ WHY THIS CATCH IS ALMOST UNREACHABLE, AND WHY IT STAYS ═══
 * The service fails soft PER ROW (see its header): a permission gap on NDA, LOI or Contract Review
 * degrades one line of the card and returns normally. So the exceptions that reach here are only
 * the ones no row-level catch could sensibly own — a heap/CPU limit, a platform fault, a
 * deliberately malformed Id from a hand-crafted client call. That residue is small, and it is
 * precisely the residue that must NOT reach the browser as a raw platform string.
 * 🔴 Do not "promote" this catch by removing the service's row-level ones and letting everything
 * land here. That inverts the entire design: the card is placed UNGATED and renders on all 11
 * disposition stages, so a whole-card error banner is a permanent fixture rather than a transient
 * one. One row degrading is the requirement (design D5).
 *
 * ═══ 🔴 THE WRONG-SOBJECT-TYPE GUARD IS NOT DEFENSIVE PADDING — IT IS THE ONLY REACHABLE THROW ═══
 * Added 2026-08-20 (code review C4), copied verbatim from the sibling card built the same day,
 * `DispositionBuyerTimelineController.getTimeline`. Two things made it necessary at once:
 *
 *   1. A REAL WIRING HAZARD. Every read behind this card is `WHERE Disposition__c = :id`. Binding a
 *      foreign Id there throws NOTHING — it simply matches no rows — so a component dropped on the
 *      wrong record page would render a confident, permanent EMPTY card, on all 11 stages, and
 *      nobody would ever learn it was pointed at the wrong record. Until the same day's W5 fix the
 *      bundle carried no `<objects>` restriction at all, so that was one drag-and-drop away.
 *   2. A COVERAGE FLOOR THIS CLASS COULD NOT OTHERWISE MEET. With the fail-soft service owning
 *      every row-level failure, the `catch` below had no test-reachable trigger, and the class sat
 *      at 33% — under the per-class 75% that a `RunSpecifiedTests` production deploy enforces
 *      through `codeCoverageWarnings`. This repo has already had a deploy report "689/689 deployed,
 *      0 errors" and roll everything back on exactly that.
 *
 * ⚠ The guard sits OUTSIDE the try DELIBERATELY: inside it, the `catch (Exception)` would swallow
 * its own `AuraHandledException` and replace a precise "wrong object" message with the generic
 * read-failure text — and a wiring mistake and a permission gap need completely different fixes.
 * ⚠ It is null-guarded rather than null-returning, because the NULL CONTRACT LIVES IN THE SERVICE
 * (`summarise(null)` returns an empty summary). `null.getSObjectType()` would NPE straight into the
 * catch and turn the first render tick into an error banner.
 *
 * ⚠ `cacheable=true` — read-only, and the staleness is bounded and acceptable. Nothing on this
 * card writes; the values it shows change through the record page's own edit paths and through
 * `NDA_Signed_Rollup`, both of which the client refreshes against by re-provisioning the wire.
 * Contrast `DispositionTractionController`, whose header records a real staleness hazard because a
 * sibling component on the same page WRITES the data it reads.
 *
 * @see DispositionDealSummaryService.cls
 * @see force-app/main/default/lwc/dispositionDealSummary/dispositionDealSummary.js
 */
public with sharing class DispositionDealSummaryController {

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never interpolate
    // platform text or exception detail into it — the detail goes to the debug log (admin-only)
    // and the user gets this. Matches BovController's shape so the two disposition cards fail with
    // one voice.
    private static final String READ_FAILURE_MESSAGE =
        'The deal summary could not be loaded. Refresh the page or contact your administrator.';

    /**
     * An Id of the wrong SObject type is a WIRING MISTAKE, not a data state, and gets its own
     * message rather than the generic read failure — the two need different fixes. Same wording
     * shape as `DispositionBuyerTimelineController.WRONG_TYPE_MESSAGE`, so the two disposition
     * cards refuse a foreign Id with one voice instead of disagreeing about whether it is an error.
     */
    private static final String WRONG_TYPE_MESSAGE =
        'The deal summary can only be read for a Disposition.';

    /**
     * Build an AuraHandledException whose message actually reaches the client.
     * `setMessage` is required — the constructor alone yields "Script-thrown exception".
     *
     * @param msg The user-safe message.
     * @return The exception to throw.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The NDA / LOI / PSA state of one sale, for the Deal Summary card.
     *
     * ── ⚠ A WRONG SOBJECT TYPE IS A DIFFERENT THING FROM A NULL, AND IS REFUSED ────────────────
     * Null is a normal render tick and yields an empty card. An Id of some OTHER object is a wiring
     * mistake that would otherwise render a permanent, confident empty card on every stage — see
     * the class header for why that is worse than an error message.
     *
     * @param dispositionId The Disposition__c on the record page. Null — which the client sends
     *                      for one render tick before `recordId` is injected — returns an empty
     *                      summary rather than an error.
     * @return The summary; never null. Rows the running user cannot read come back flagged
     *         unavailable, not omitted.
     * @throws AuraHandledException when the Id is of the wrong SObject type, or — with a fixed
     *         user-safe message — on an unexpected read failure.
     */
    @AuraEnabled(cacheable=true)
    public static DispositionDealSummaryService.DealSummary getDealSummary(Id dispositionId) {
        // OUTSIDE the try on purpose — see the class header. Null-guarded because the null contract
        // belongs to the service, not here.
        if (dispositionId != null && dispositionId.getSObjectType() != Disposition__c.SObjectType) {
            throw ahe(WRONG_TYPE_MESSAGE);
        }
        try {
            return DispositionDealSummaryService.summarise(dispositionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionDealSummaryController.getDealSummary on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
