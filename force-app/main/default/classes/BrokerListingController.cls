/**
 * Read-only controller behind `lwc/brokerListing` — the listing card on the Active Listing stage of
 * the Disposition record page.
 *
 * ── 🔴 THE CLOCK THAT USED TO LIVE HERE IS GONE (D27.1 / D28-Q2, 2026-08-10) ──
 * `getListing` used to hardcode a 21/28/42-day ladder producing `weekLabel` + `isAtRisk`, read off
 * `Broker_Listing__c.Days_On_Market__c` — a hand-keyed Number that NOTHING in the application
 * writes.
 *
 * ⚠ THIS BLOCK'S HEADING USED TO READ "THE 6-WEEK CLOCK … IS GONE", AND HALF OF THAT IS NOW FALSE.
 * Re-retracted 2026-08-21. It went on to say the retired ladder was *"wrong twice over: wrong
 * duration (the document allows ~2 months with a month-1 check) and wrong input"*. The DURATION half
 * is retracted: the user has settled the third dispute over these numbers in favour of a SIX-WEEK
 * clock with rungs at weeks 1, 4 and 6, overriding `DPEG-Stage-by-Stage.docx` — so the old ladder's
 * duration was, as it turns out, right. The INPUT half stands unchanged and is the reason this file
 * still computes nothing itself: `Broker_Listing__c.Days_On_Market__c` is a static number a human
 * typed, so the deployed clock could not tick no matter which thresholds it was compared against.
 * 🔴 THE LESSON THAT SURVIVES BOTH REVISIONS: the defect was never the numbers, it was having a
 * SECOND COPY of them here. Do not put one back.
 *
 * The band now comes from `DispositionTractionService`, computed from the PARENT's
 * `Disposition__c.Listing_Date__c` and the disposition's offer count. That service is also what
 * `DispositionTractionController` / `lwc/listingAlerts` renders, so the badge on this card and the
 * traction panel beside it derive from ONE computation and cannot disagree — the
 * `EmailThreadAnchorService` shape (one shared derivation, two consumers with different polarity),
 * chosen because a badge and a panel that contradict each other on the same screen is precisely
 * the W4 "the badge and the gate can never disagree" defect.
 *
 * ⚠ THE DTO FIELDS WERE RENAMED, NOT REPOINTED. `weekLabel` became `tractionLabel` and gained
 * `tractionBand` / `tractionDetail`. Leaving a field called `weekLabel` holding the string
 * "Day 34 — Traction checkpoint: no offers" would be a name asserting a clock that no longer
 * exists — the same class of stale signal the retired `listingAlerts` mock was. `lwc/brokerListing`
 * and both test files move with it.
 *
 * ── QUERY BUDGET: 2 SOQL ────────────────────────────────────────────────────
 * One for the listing (which now carries `Disposition__r.Listing_Date__c` on the grandparent path
 * it was already traversing, so the clock itself is free) and one aggregate carrying BOTH the offer
 * count and the earliest offer date. Neither can be folded into the first query:
 * `Disposition_Offer__c.Disposition__c` is a Lookup, so there is no roll-up summary and no
 * relationship subquery that yields either. ⚠ THE TWO OFFER FACTS TRAVEL IN ONE AGGREGATE ON
 * PURPOSE — the 2-SOQL budget is asserted by `BrokerListingControllerTest`, and a separate
 * first-offer-date read would fail it.
 *
 * Layering: thin controller (ARCHITECTURE.md §2) — marshal, delegate to a selector and a service,
 * catch, and throw `AuraHandledException` with a fixed user-safe message.
 *
 * ── ⚠ `cacheable=true`: THE BADGE CAN BE STALE ON THE CLIENT ────────────────
 * Recorded 2026-08-10 (review W1). This boundary is cacheable and nothing invalidates it, so the
 * offer-derived values on this card — the traction badge, and `daysOnMarket` because the first
 * offer pauses the clock — can lag a just-logged offer until the page is reloaded. The full
 * sequence, the measured reason a CustomEvent relay is not buildable (`c-disposition-offer` lives in
 * the `sidebar` flexipage region and this card in `main`, so they share no ancestor), and the
 * accepted-residual decision are in `DispositionTractionService`'s §4 header block.
 * `cacheable=true` is kept deliberately — see that block.
 *
 * ⚠ THIS BLOCK USED TO READ "THE BADGE **AND** `offersReceived`", and to warn that this card was
 * affected in TWO places while `lwc/listingAlerts` was affected in one. `offersReceived` was removed
 * from the DTO at UAT on 2026-08-21, so that second surface no longer exists. The residual SHRANK
 * WITH THE CARD; it was not fixed, and re-adding any offer-derived display here re-opens it.
 *
 * ── 🔴 THIS CARD NOW CARRIES THE ONLY COPY OF THE TRACTION LABEL (UAT, 2026-08-21) ──
 * `lwc/listingAlerts` was cut back to the three-rung escalation schedule and no longer renders a
 * band pill of its own, so `tractionLabel` / `tractionDetail` / `isAtRisk` below are read by exactly
 * one component. They are NOT dead and must not be tidied away: the string they carry
 * ("Week 4 — At Risk") is the one the user specified verbatim, and it is what justifies the Replace
 * Broker button rendered beside it.
 *
 * @see force-app/main/default/classes/DispositionTractionService.cls (the band logic)
 * @see force-app/main/default/classes/DispositionTractionController.cls (the sibling surface)
 */
public with sharing class BrokerListingController {

    public class ListingRow {
        @AuraEnabled public String id;
        @AuraEnabled public String assetName;
        @AuraEnabled public String brokerFirm;
        @AuraEnabled public String contactName;
        @AuraEnabled public Date listDate;
        @AuraEnabled public Date callForOffersDate;
        /**
         * Days since the PARENT's `Disposition__c.Listing_Date__c` — the marketing clock.
         *
         * ⚠ THIS IS NO LONGER `Broker_Listing__c.Days_On_Market__c`. That field is a hand-keyed
         * Number nothing writes; reading it is what made the deployed card show a static value
         * beside a risk badge derived from the same static value. Null means the clock has not
         * started (no listing date), which is NOT the same as 0.
         */
        @AuraEnabled public Integer daysOnMarket;
        @AuraEnabled public String listingStatus;
        /**
         * ⚠ `offersReceived` WAS HERE AND WAS REMOVED AT UAT ON 2026-08-21, NOT RENAMED. The user's
         * words: *"No need to show count of disposition offers as well."* `lwc/brokerListing`'s
         * fourth stat tile went in the same change, which left this member unread by every client —
         * an `@AuraEnabled` member nobody reads is a promise this class would have to keep for no
         * one.
         *
         * 🔴 THE COUNT ITSELF IS STILL READ, AND MUST STAY. `getListing` below still asks
         * `DispositionOfferSelector.selectOfferTractionByDispositionIds` for it, because the count
         * is what DECIDES the band (an offer is traction — D28/Q1) and it travels in the SAME
         * aggregate that yields `firstOfferDate`, which is what pauses the clock. Deleting the query
         * to "clean up after the removed tile" would silently un-pause this card while the alerts
         * card beside it stayed paused — one ladder, two answers.
         */
        /** `DispositionTractionService.Band` name — NOT_LISTED / ON_TRACK / WEEK_1 / WEEK_4 / WEEK_6. */
        @AuraEnabled public String tractionBand;
        /** Short badge text, e.g. `Week 4 — At Risk`. */
        @AuraEnabled public String tractionLabel;
        /** One sentence explaining the band. Never promises a notification (D9). */
        @AuraEnabled public String tractionDetail;
        /**
         * True from WEEK_4 onward, with zero offers. Drives the amber styling.
         *
         * ⚠ NOT "from the first rung onward" — `WEEK_1` is a check-in, not a risk state. The reason
         * the line is drawn at week 4 is on `DispositionTractionService.Band`; do not re-derive it
         * from the band name here, which would be the second copy of the ladder this class exists
         * to not have.
         */
        @AuraEnabled public Boolean isAtRisk;
    }

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never
    // interpolate platform text or exception detail into it — the detail goes to the
    // debug log (admin-only) and the user gets this.
    private static final String READ_FAILURE_MESSAGE =
        'The broker listing could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The listing card for one Disposition, with its traction band.
     *
     * NOT-FOUND CONTRACT UNCHANGED: a Disposition with no `Broker_Listing__c` returns **null**, and
     * `lwc/brokerListing` renders its empty card. That contract is deliberately preserved even
     * though `DispositionStageEntryService` now opens a listing on entry to Active Listing — every
     * disposition that reached that stage BEFORE this change has no listing row, and inventing a
     * synthetic one here would make the card claim a broker engagement that does not exist. The
     * traction panel (`lwc/listingAlerts`) answers for those records instead, because it is keyed
     * on the Disposition rather than on the listing.
     *
     * @param dispositionId The Disposition to read the current listing for.
     * @return The most recent listing with its computed traction band, or null when none exists.
     */
    @AuraEnabled(cacheable=true)
    public static ListingRow getListing(Id dispositionId) {
        try {
            Broker_Listing__c bl = BrokerListingSelector.selectMostRecentByDispositionId(dispositionId);
            if (bl == null) {
                return null;
            }
            ListingRow r = new ListingRow();
            r.id = bl.Id;
            r.assetName = bl.Disposition__r != null && bl.Disposition__r.Property_Asset__r != null
                          ? bl.Disposition__r.Property_Asset__r.Name : '';
            r.brokerFirm = bl.Broker_Firm__c;
            r.contactName = bl.Contact_Name__c;
            r.listDate = bl.List_Date__c;
            r.callForOffersDate = bl.Call_For_Offers_Date__c;
            r.listingStatus = bl.Listing_Status__c;

            // The clock is the PARENT's listing date, not this row's List_Date__c: the marketing
            // period survives a broker change, whereas a Broker_Listing__c row is per-broker, so
            // keying on the child would silently restart the six-week clock the moment a broker was
            // replaced — which, now that this card carries a Replace Broker button, is one click
            // away rather than hypothetical.
            Date listingDate = (bl.Disposition__r == null) ? null : bl.Disposition__r.Listing_Date__c;
            // ⚠ ONE aggregate returns BOTH the count and the earliest offer date, so the query
            // budget below is still 2. The date is what pauses the clock; passing the 2-argument
            // `evaluate` overload here would compile and silently disable the pause on this card
            // while the panel beside it still paused — the exact two-ladders defect this shared
            // service exists to prevent.
            Map<Id, DispositionOfferSelector.OfferTraction> offerFacts =
                DispositionOfferSelector.selectOfferTractionByDispositionIds(
                    new Set<Id>{ dispositionId });
            DispositionOfferSelector.OfferTraction ot = offerFacts.get(dispositionId);
            Integer offers = (ot == null) ? 0 : ot.offerCount;
            Date firstOfferDate = (ot == null) ? null : ot.firstOfferDate;

            DispositionTractionService.Traction t =
                DispositionTractionService.evaluate(listingDate, offers, firstOfferDate);
            r.daysOnMarket = t.daysOnMarket;
            r.tractionBand = t.band;
            r.tractionLabel = t.label;
            r.tractionDetail = t.detail;
            r.isAtRisk = t.isAtRisk;
            return r;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerListingController.getListing on ' + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
