import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { formatLongDate } from 'c/utils';

/**
 * Related-list ids are the RELATIONSHIP NAMES declared on the child lookups:
 *   objects/Broker_Listing__c/fields/Disposition__c    -> relationshipName Broker_Listings
 *   objects/Disposition_Offer__c/fields/Disposition__c -> relationshipName Disposition_Offers
 * `getRelatedListRecords` fails with an opaque error on an unknown id, and `Disposition_Offers__r`
 * is the same literal `c/dispositionOffer` and `c/dispositionOfferSelect` already use.
 */
const LISTING_LIST_ID = 'Broker_Listings__r';
const OFFER_LIST_ID = 'Disposition_Offers__r';

const LISTING_FIELDS = [
    'Broker_Listing__c.Id',
    'Broker_Listing__c.Call_For_Offers_Date__c'
];
const OFFER_FIELDS = ['Disposition_Offer__c.Id'];

/**
 * Page size for the OFFER read.
 *
 * ⚠ THE COUNT THIS CARD SHOWS IS A PAGE LENGTH, NOT A DATABASE COUNT.
 * `getRelatedListRecords` pages, so `records.length` is bounded by whatever is asked for here. 200
 * is chosen as a number a real disposition cannot plausibly exceed (the org's busiest disposition
 * has single-digit offers), NOT as a guarantee. If a disposition ever genuinely passes 200 offers,
 * this number stops being the truth and the honest fix is a rollup summary field or an Apex
 * aggregate — not a bigger literal.
 */
const OFFER_PAGE_SIZE = 200;

/**
 * c-disposition-call-for-offers — the Active Listing "Call for Offers" card (design D-5, DEV-16).
 *
 * Shows the call-for-offers date from the disposition's `Broker_Listing__c`, how many offers have
 * arrived, and a one-click way to log another.
 *
 * ── 🔴 THIS IS NOT `c/callForOffersList` OR `c/callForOffersPanel` ───────────
 * Those two are OPPORTUNITY-scoped (the acquisitions buy-side call-for-offers) and are explicitly
 * out of scope for the disposition redesign. The name collision is unfortunate and real: "call for
 * offers" means one thing when DPEG is buying and another when DPEG is selling. Do not "consolidate"
 * the three — they read different objects for different personas.
 *
 * ── 🔴 ZERO APEX. BOTH READS ARE LDS ─────────────────────────────────────────
 * Per ARCHITECTURE.md §5's LDS-first priority, neither read needs Apex: both are plain child-record
 * reads of one parent with no joins, no aggregates and no system-context requirement. That buys FLS
 * and sharing enforcement for free, and — the part that actually matters on this screen — the offer
 * count REFRESHES ITSELF when an offer is logged, because LDS invalidates the related-list entry.
 *
 * ⚠ `BrokerListingController.getListing` ALREADY RETURNS BOTH VALUES and was deliberately NOT
 * reused. It is `@AuraEnabled(cacheable=true)` with nothing invalidating it, and its own class
 * header records that its `offersReceived` "can be stale on the client" after an offer is logged —
 * a documented residual on `c/broker-listing`, which sits on this same screen. Reusing it would have
 * imported that staleness into a card whose entire job is to show a live count. The two numbers are
 * still the same MEASURE (`DispositionTractionService` counts `Disposition_Offer__c` rows, which is
 * what `records.length` counts here), so the cards agree — this one just agrees sooner.
 */
export default class DispositionCallForOffers extends NavigationMixin(LightningElement) {
    @api recordId;

    _cfoDate;
    _offerCount;
    _listingError;
    _offerError;

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

    @wire(getRelatedListRecords, {
        parentRecordId: '$recordId',
        relatedListId: OFFER_LIST_ID,
        fields: OFFER_FIELDS,
        pageSize: OFFER_PAGE_SIZE
    })
    wiredOffers({ data, error }) {
        if (data) {
            this._offerError = undefined;
            this._offerCount = (data.records || []).length;
        } else if (error) {
            this._offerError = (error.body && error.body.message) || 'Unexpected error';
            this._offerCount = undefined;
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

    /**
     * An em dash, not '0', while the wire has not answered or has failed. "0 offers" is a claim
     * about the data; a dash correctly says "not known yet".
     */
    get offerCountLabel() {
        return this._offerCount == null ? '—' : String(this._offerCount);
    }

    get hasError() {
        return !!(this._listingError || this._offerError);
    }

    get errorMessage() {
        return this._listingError || this._offerError || '';
    }

    /**
     * Log an offer through the platform's own create screen with the parent pre-filled.
     * `encodeDefaultFieldValues` URL-encodes the value; a hand-built `Disposition__c=<id>` string
     * breaks as soon as a defaulted value contains a reserved character.
     */
    handleLogOffer() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Disposition_Offer__c', actionName: 'new' },
            state: {
                defaultFieldValues: encodeDefaultFieldValues({
                    Disposition__c: this.recordId
                })
            }
        });
    }
}
