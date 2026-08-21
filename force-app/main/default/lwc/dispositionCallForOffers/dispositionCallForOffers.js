import { LightningElement, api, wire } from 'lwc';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { formatLongDate } from 'c/utils';

/**
 * Related-list id is the RELATIONSHIP NAME declared on the child lookup:
 *   objects/Broker_Listing__c/fields/Disposition__c -> relationshipName Broker_Listings
 * `getRelatedListRecords` fails with an opaque error on an unknown id.
 */
const LISTING_LIST_ID = 'Broker_Listings__r';

const LISTING_FIELDS = [
    'Broker_Listing__c.Id',
    'Broker_Listing__c.Call_For_Offers_Date__c'
];

/**
 * c-disposition-call-for-offers — the Active Listing "Call for Offers" card (design D-5, DEV-16).
 *
 * Shows the call-for-offers date from the disposition's `Broker_Listing__c`. That is the whole card.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════
 * 🔴 TWO THINGS WERE REMOVED FROM THIS CARD AT UAT ON 2026-08-21
 * ══════════════════════════════════════════════════════════════════════════════════════
 * The user's words: *"No need to show count of disposition offers as well. … I asked you to remove
 * the log offer button from call for offers lwc."*
 *
 *   THE "Offers Received" ROW — and, with it, the entire second `@wire` on
 *   `Disposition_Offers__r`, its `pageSize`, its field list, its error branch and its
 *   `_offerCount` getter. 🔴 THE WIRE WENT WITH THE ROW ON PURPOSE: its only consumer was the
 *   displayed count, and a live LDS subscription whose result nothing reads is a read the org keeps
 *   paying for so a future reader can wonder what it is for.
 *
 *   THE "+ Log Offer" BUTTON — and with it `handleLogOffer`, the `c/dispositionLogOfferModal`
 *   import, the success/error toasts and `refreshApex`. ⚠ `refreshApex` EXISTED ONLY TO REFRESH THE
 *   COUNT THIS CARD NO LONGER SHOWS, so removing the button did not orphan it; both halves of that
 *   feature died together.
 *
 * ⚠ THE MODAL IS NOT ORPHANED, AND THAT WAS VERIFIED RATHER THAN ASSUMED. `c/dispositionOffer`
 * opens the identical `c/dispositionLogOfferModal` with the identical arguments, and
 * `dispositionSidebar.isOfferStage` includes `'Active Listing'` — the only stage
 * `dispositionMain.html` renders THIS card at — so at every moment this card is visible, the
 * offers card carrying the surviving "+ Log Offer" button is visible beside it in the sidebar.
 *
 * ── 🔴 THIS IS NOT `c/callForOffersList` OR `c/callForOffersPanel` ───────────
 * Those two are OPPORTUNITY-scoped (the acquisitions buy-side call-for-offers) and are explicitly
 * out of scope for the disposition redesign. The name collision is unfortunate and real: "call for
 * offers" means one thing when DPEG is buying and another when DPEG is selling. Do not "consolidate"
 * the three — they read different objects for different personas.
 *
 * ── 🔴 ZERO APEX. THE READ IS LDS ────────────────────────────────────────────
 * Per ARCHITECTURE.md §5's LDS-first priority, this read needs no Apex: it is a plain child-record
 * read of one parent with no joins, no aggregates and no system-context requirement. That buys FLS
 * and sharing enforcement for free.
 *
 * ⚠ THE 2026-08-21 AMENDMENT TO THIS CLAIM IS NOW MOOT AND IS RECORDED SO IT IS NOT RE-ADDED. It
 * read: *"'ZERO APEX' is still true of this card's reads and is no longer true of the feature —
 * `handleLogOffer` opens `c/dispositionLogOfferModal`, which DOES call Apex."* The button is gone,
 * so the card is once again zero-Apex end to end. `BrokerListingController.getListing` still returns
 * this same call-for-offers date and is still deliberately NOT reused: it is
 * `@AuraEnabled(cacheable=true)` with nothing invalidating it.
 */
export default class DispositionCallForOffers extends LightningElement {
    @api recordId;

    _cfoDate;
    _listingError;

    @wire(getRelatedListRecords, {
        parentRecordId: '$recordId',
        relatedListId: LISTING_LIST_ID,
        fields: LISTING_FIELDS
    })
    wiredListing({ data, error }) {
        if (data) {
            this._listingError = undefined;
            // A disposition has at most one active broker listing; the first row is it. `null` when
            // there is no listing yet, which is a normal Active-Listing-just-entered state and NOT
            // an error.
            const first = (data.records || [])[0];
            const field = first && first.fields && first.fields.Call_For_Offers_Date__c;
            this._cfoDate = field ? field.value : null;
        } else if (error) {
            this._listingError = (error.body && error.body.message) || 'Unexpected error';
            this._cfoDate = null;
        }
    }

    /**
     * ⚠ EVERY DISPLAYED GETTER RETURNS A STRING, NEVER `undefined`. A getter bound to a custom
     * element ATTRIBUTE is written UNCONDITIONALLY, so `undefined` renders the literal text
     * "undefined" — measured in this repo. One rule for all of them beats a per-binding judgement
     * about which position each one lands in.
     */
    get cfoDateLabel() {
        return formatLongDate(this._cfoDate);
    }

    get hasError() {
        return !!this._listingError;
    }

    get errorMessage() {
        return this._listingError || '';
    }
}
