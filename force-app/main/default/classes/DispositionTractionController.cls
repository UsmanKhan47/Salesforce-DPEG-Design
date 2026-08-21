/**
 * The `@AuraEnabled` boundary for the Active Listing escalation ladder — backs `lwc/listingAlerts`,
 * which replaced a hardcoded four-row mock (D28/Q4, 2026-08-10).
 *
 * ── ⚠ ITS CONSUMER STOPPED BEING A "TRACTION MONITOR" ON 2026-08-21 (UAT) ───
 * This header called it exactly that until the user said *"we don't need listing traction. We just
 * need automated alerts thats' it."* `lwc/listingAlerts` was cut back to the three-rung escalation
 * schedule: it no longer renders the band pill, the band detail, the marketing-clock progress bar
 * or the offer count. 🔴 NOTHING BELOW OR IN `DispositionTractionService` CHANGED. The payload is
 * unchanged and every member is still computed — `band`, `label` and `isAtRisk` are read by
 * `BrokerListingController` for the badge that survives on `lwc/brokerListing`, and `offerCount` /
 * `firstOfferDate` still decide the band and the pause that the RUNG NOTES ("Clock paused.")
 * express. Trimming the DTO to "what the card renders today" would break the other consumer and
 * would delete the pause.
 *
 * ── WHY THIS IS A SEPARATE CONTROLLER FROM `BrokerListingController` ────────
 * Traction is a property of the DISPOSITION (its listing date and its offers), not of the
 * `Broker_Listing__c` row. `BrokerListingController.getListing` returns null when no listing row
 * exists — a contract worth preserving, because a card claiming a broker engagement that does not
 * exist is worse than an empty one — but every disposition that reached Active Listing before this
 * change HAS no listing row while still having a listing date. Folding traction into that method
 * would have made the panel go dark for exactly the population it was built to report on.
 *
 * The two surfaces share `DispositionTractionService`, so one computation feeds both and the badge
 * on the listing card cannot contradict the panel next to it.
 *
 * ── 🔴 THIS CONTROLLER RAISES NO ALERT, AND THAT IS A DECISION (D9) ─────────
 * D9 defers every notification in this programme, the month-1 traction alert included. The
 * MECHANISM — computing the status and surfacing it — is in scope; a `CustomNotificationType`, an
 * email alert, a Chatter post or a `GroupNotifier` call is not. Nothing here sends anything, and
 * the strings it returns deliberately never promise that anyone will be told. The deferred half
 * lands as a Schedulable calling `DispositionTractionService.evaluate` + `listingStatusValue` — see
 * that class's header for exactly what it still needs.
 * ⚠ RE-CONFIRMED 2026-08-21, WHEN THE LADDER ITSELF CHANGED. The user moved the thresholds to
 * Week 1/4/6 and added the offer PAUSE, and in the same breath deferred the email and the dashboard
 * flag again, explicitly. So this deferral is now a live decision rather than an inherited one.
 *
 * Layering: thin controller (ARCHITECTURE.md §2) — marshal, delegate, catch, throw
 * `AuraHandledException` with a fixed user-safe message. Zero SOQL of its own.
 *
 * ── ⚠ `cacheable=true` MEANS THE BAND CAN BE STALE ON THE CLIENT (review W1, 2026-08-10) ────
 * The service computes the band fresh on every call, but this boundary is cacheable and nothing in
 * this feature invalidates the client cache. An offer logged through `c-disposition-offer` refreshes
 * that component's LDS related-list wire while `c-listing-alerts` may keep rendering the payload it
 * already holds — so the panel can advise changing the broker beside a list that shows an offer.
 * `DispositionTractionService`'s §3 residual block carries the full sequence, the measured reason
 * the CustomEvent relay is not buildable here (`dispositionOffer` and `listingAlerts` are in
 * DIFFERENT flexipage regions, so there is no shared ancestor to relay through), and what a future
 * author must use instead. `cacheable=true` is KEPT: this is a read-only advisory panel on a record
 * page, `getTraction` is called once per page view per record, and the alternative is a server round
 * trip on every render for a value that changes at most once a day.
 *
 * ── 🔴 A MEASURED, ARGUED COVERAGE GAP: THE `catch` BLOCK IS UNREACHABLE FROM A TEST ────────
 * Both reads behind `getTraction` are `WITH SYSTEM_MODE` by deliberate design
 * (`DispositionSelector.selectListingClockByIds`,
 * `DispositionOfferSelector.selectOfferTractionByDispositionIds`),
 * so the repo's standard technique for covering an `AuraHandledException` catch — `System.runAs` a
 * bare user and let a `USER_MODE` read throw `QueryException` — is STRUCTURALLY UNAVAILABLE here:
 * SYSTEM_MODE is precisely what stops that throw. Two other candidates were tried and measured on
 * `usman-dpeg` 2026-08-10: a wrong-SObject-type Id does not throw (it matches no rows — which is
 * why the explicit type guard below exists), and a deleted record likewise returns no rows. A
 * governor `LimitException` is not catchable by `catch (Exception)` at all.
 *
 * The catch is KEPT because ARCHITECTURE.md §5 requires it — an `@AuraEnabled` boundary must never
 * leak a raw platform exception — and because "no test can reach it today" is not "no runtime can".
 * A `@TestVisible` failure-injection seam was rejected: it would put a branch in production code
 * whose only purpose is to be false, to raise a number. The two uncovered lines are the
 * `System.debug` and the `throw`; the class sits at roughly 83% rather than the 90% target, and
 * that is a stated residual rather than an oversight. Do NOT delete the catch to reach 90%.
 *
 * @see force-app/main/default/classes/DispositionTractionService.cls
 * @see force-app/main/default/lwc/listingAlerts/listingAlerts.js
 */
public with sharing class DispositionTractionController {

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never interpolate
    // platform text or exception detail into it — the detail goes to the debug log (admin-only).
    //
    // ⚠ BOTH STRINGS SAID "Listing traction" UNTIL 2026-08-21 AND WERE RETEXTED, NOT REWORDED FOR
    // STYLE. `lwc/listingAlerts` is titled "Automated Alerts" since the UAT pass removed the
    // traction monitor from it, and these are the only two strings from this class a USER ever
    // sees — a toast naming a card that no longer exists sends them looking for it. The class,
    // the service and the payload keep the word `traction`, which is what they compute.
    private static final String READ_FAILURE_MESSAGE =
        'Automated alerts could not be loaded. Refresh the page or contact your administrator.';

    /** An Id of the wrong SObject type is a wiring mistake, not a data state. See getTraction. */
    private static final String WRONG_TYPE_MESSAGE =
        'Automated alerts can only be read for a Disposition.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The traction state of one Disposition.
     *
     * NOT-FOUND CONTRACT: a null Id, or an Id that resolves to no readable row, returns the
     * NOT_LISTED state rather than null or an exception. That is deliberate — the component's job
     * is to say what the clock is doing, and "the clock has not started" is a true and useful
     * answer, whereas a null would render an empty box indistinguishable from a load failure.
     *
     * ── ⚠ A WRONG SOBJECT TYPE IS A DIFFERENT THING AND IS REFUSED ─────────
     * An Id of some other object is a WIRING MISTAKE, not a data state, and it is refused rather
     * than folded into NOT_LISTED. This is not defensive decoration: it was MEASURED on
     * `usman-dpeg` 2026-08-10 that binding a `Property__c` Id into `WHERE Id IN :ids` on
     * `Disposition__c` throws NOTHING — it simply matches no rows. So without this guard a
     * component wired to the wrong `record-id` would render a confident, permanently green
     * "Not listed yet" and nobody would ever learn the panel was pointed at the wrong record.
     * The guard sits OUTSIDE the try on purpose: inside it, the `catch (Exception)` below would
     * swallow its own AuraHandledException and replace a precise message with the generic one.
     *
     * @param dispositionId The Disposition to evaluate.
     * @return Its computed traction state. Never null.
     */
    @AuraEnabled(cacheable=true)
    public static DispositionTractionService.Traction getTraction(Id dispositionId) {
        if (dispositionId == null) {
            return DispositionTractionService.evaluate(null, 0);
        }
        if (dispositionId.getSObjectType() != Disposition__c.SObjectType) {
            throw ahe(WRONG_TYPE_MESSAGE);
        }
        try {
            Map<Id, DispositionTractionService.Traction> byId =
                DispositionTractionService.evaluateAll(new Set<Id>{ dispositionId });
            DispositionTractionService.Traction t = byId.get(dispositionId);
            return (t == null) ? DispositionTractionService.evaluate(null, 0) : t;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionTractionController.getTraction on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
