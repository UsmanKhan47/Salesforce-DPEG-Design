/**
 * Read-only controller behind `lwc/brokerListing` — the listing card on the Active Listing stage of
 * the Disposition record page.
 *
 * ── 🔴 THE 6-WEEK CLOCK THAT USED TO LIVE HERE IS GONE (D27.1 / D28-Q2, 2026-08-10) ──
 * `getListing` used to hardcode a 21/28/42-day ladder producing `weekLabel` + `isAtRisk`, read off
 * `Broker_Listing__c.Days_On_Market__c` — a hand-keyed Number that NOTHING in the application
 * writes. It was the only executable copy of the 6-week clock and it was wrong twice over: wrong
 * duration (the document allows ~2 months with a month-1 check) and wrong input (a static number a
 * human typed, so it never ticked).
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
 * it was already traversing, so the clock itself is free) and one aggregate for the offer count.
 * The count cannot be folded into the first query: `Disposition_Offer__c.Disposition__c` is a
 * Lookup, so there is no roll-up summary and no relationship subquery that yields a count.
 *
 * Layering: thin controller (ARCHITECTURE.md §2) — marshal, delegate to a selector and a service,
 * catch, and throw `AuraHandledException` with a fixed user-safe message.
 *
 * ── ⚠ `cacheable=true`: THE BADGE **AND** `offersReceived` CAN BE STALE ON THE CLIENT ────────
 * Recorded 2026-08-10 (review W1). This boundary is cacheable and nothing invalidates it, so both
 * offer-derived values on this card — the traction badge and the "Offers Received" stat — can lag a
 * just-logged offer until the page is reloaded. ⚠ Note this card is affected in TWO places while
 * `lwc/listingAlerts` is affected in one; a reader who fixes only the panel has fixed half of it.
 * The full sequence, the measured reason a CustomEvent relay is not buildable (`c-disposition-offer`
 * lives in the `sidebar` flexipage region and this card in `main`, so they share no ancestor), and
 * the accepted-residual decision are in `DispositionTractionService`'s §3 header block.
 * `cacheable=true` is kept deliberately — see that block.
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
         * Offers logged against the DISPOSITION, counted live.
         *
         * ⚠ Not `Broker_Listing__c.Offers_Received__c`, which is likewise hand-keyed and written by
         * nothing. Counting the real children is what makes the offers-only traction rule (D28/Q1)
         * mean anything.
         */
        @AuraEnabled public Integer offersReceived;
        /** `DispositionTractionService.Band` name — NOT_LISTED / ON_TRACK / CHECKPOINT_DUE / … */
        @AuraEnabled public String tractionBand;
        /** Short badge text, e.g. `Day 34 — Traction checkpoint: no offers`. */
        @AuraEnabled public String tractionLabel;
        /** One sentence explaining the band. Never promises a notification (D9). */
        @AuraEnabled public String tractionDetail;
        /** True from the day-30 checkpoint onward, with zero offers. Drives the amber styling. */
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
            // keying on the child would silently restart the 60-day clock the moment a broker was
            // replaced.
            Date listingDate = (bl.Disposition__r == null) ? null : bl.Disposition__r.Listing_Date__c;
            Map<Id, Integer> offerCounts =
                DispositionOfferSelector.countByDispositionIds(new Set<Id>{ dispositionId });
            Integer offers = offerCounts.containsKey(dispositionId) ? offerCounts.get(dispositionId) : 0;

            DispositionTractionService.Traction t =
                DispositionTractionService.evaluate(listingDate, offers);
            r.daysOnMarket = t.daysOnMarket;
            r.offersReceived = t.offerCount;
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
