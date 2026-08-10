import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PRIMARY_LOI from '@salesforce/schema/Opportunity.Primary_LOI__c';
import LOI_BALL from '@salesforce/schema/Opportunity.Primary_LOI__r.Ball_In_Court__c';
import getCounterOffers from '@salesforce/apex/CounterOfferController.getCounterOffers';
import saveCounterOffer from '@salesforce/apex/CounterOfferController.saveCounterOffer';

const LEFT = { alignment: 'left' };
/**
 * [background, dot, label] soft pills per Counter_Offer__c.Direction__c value (matches the lv-*
 * list chrome).
 *
 * 🔴 'Buyer' IS A REQUIRED KEY, NOT A NICETY. Direction__c carries three values since Tranche 3B
 * and CounterOfferService DERIVES which one it stores from the parent LOI's side of the deal:
 * 'Ours' is DPEG on both sides, while the counterparty is 'Seller' on a purchase and 'Buyer' on a
 * sale. Without this key a Buyer counter fell through `|| DIRECTION.Seller` and rendered the pill
 * "Seller" — labelling the buyer as the seller on a record whose stored value was already correct.
 * That is a display defect on top of a right answer, which is the hardest kind to notice.
 *
 * The colour follows the ROLE, not the word: 'Buyer' shares the counterparty orange with 'Seller'
 * because on their own side of the deal they are the same party, and DPEG keeps blue on both.
 */
const DIRECTION = {
    Seller: ['#fff1e0', '#FB8C00', 'Seller'],
    Buyer:  ['#fff1e0', '#FB8C00', 'Buyer'],
    Ours:   ['#e8f1fc', '#1E88E5', 'Ours']
};

/**
 * Ball_In_Court__c value -> badge caption. Same three-token contract as DIRECTION above: 'Us' is
 * DPEG on both sides, and the counterparty is 'Seller' on a purchase, 'Buyer' on a sale.
 *
 * ⚠ The previous code was a ternary — `=== 'Us' ? 'our court' : 'seller court'` — so EVERY
 * non-'Us' value read as "seller", which named the wrong party on a sale and would also have
 * captioned a blank field. A lookup with an explicit fallback cannot do either.
 */
const BALL_LABEL = {
    Us: 'Ball: our court',
    Seller: 'Ball: seller court',
    Buyer: 'Ball: buyer court'
};
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    {
        label: 'Counter Offer',
        fieldName: 'recordUrl',
        type: 'url',
        sortable: true,
        initialWidth: 120,
        cellAttributes: LEFT,
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    {
        label: 'Countered By',
        fieldName: 'direction',
        type: 'pill',
        sortable: true,
        initialWidth: 130,
        typeAttributes: { wrapStyle: { fieldName: 'dirWrap' }, dotStyle: { fieldName: 'dirDot' } }
    },
    {
        label: 'Counter Price',
        fieldName: 'price',
        type: 'currency',
        sortable: true,
        initialWidth: 110,
        cellAttributes: LEFT
    },
    {
        label: 'Cap Rate',
        fieldName: 'capRate',
        type: 'percent',
        sortable: true,
        initialWidth: 90,
        cellAttributes: LEFT,
        typeAttributes: { minimumFractionDigits: 2 }
    },
    {
        label: 'Revision #',
        fieldName: 'revisionNumber',
        type: 'text',
        initialWidth: 100,
        cellAttributes: LEFT
    },
    {
        label: 'Subseq. Version',
        fieldName: 'subsequentVersion',
        type: 'text',
        initialWidth: 120,
        cellAttributes: LEFT
    },
    {
        // No initialWidth: this column absorbs the remaining width (fixed mode).
        label: 'Counter Response',
        fieldName: 'response',
        type: 'text',
        wrapText: true,
        cellAttributes: LEFT
    },
    {
        label: 'Date',
        fieldName: 'counterDate',
        type: 'date-local',
        sortable: true,
        initialWidth: 110,
        cellAttributes: LEFT
    }
];

// Counter Offer card: records the full LOI negotiation history (who countered,
// price, cap rate, date), stamps the latest terms back onto the LOI, and flips
// its Ball In Court. Works on the Opportunity LOI tab (via Primary_LOI__c) and
// directly on the LOI record page.
//
// ── SIDE-AWARENESS (Tranche 3B close-out, 2026-08-09) ───────────────────────
// Since Tranche 3B this card serves BOTH an acquisition LOI and a DISPOSITION LOI, and the
// counterparty's name inverts between them: on a purchase DPEG is the buyer and the counterparty is
// the SELLER; on a sale DPEG is the seller and the counterparty is the BUYER. CounterOfferService
// derives and stores the correct token from the parent LOI's record type, so the DATA has been
// right since 3B — this change fixes the two places the DISPLAY still hardcoded buy-side wording
// (DIRECTION had no 'Buyer' key; ballBadgeLabel was a two-way ternary). See the token contract in
// objects/LOI__c/fields/Ball_In_Court__c and objects/Counter_Offer__c/fields/Direction__c.
//
// ⚠ WHAT IS *NOT* FIXED HERE, AND WHY — the `directionOptions` picker still reads
// "Seller countered us" / "Our counter to seller" on a disposition LOI. It is FUNCTIONALLY correct:
// 'Seller' is the incumbent wire token meaning "the counterparty" on both sides, and the service
// rewrites it to 'Buyer' before storing, so a disposition user who picks it gets the right record.
// Only the two labels read buy-side. Correcting them needs the LOI's SIDE on the client, and the
// only signals are RecordTypeId and Disposition__c — and `Disposition__c` is a Tranche 3B field
// whose FLS acquisitions personas are deliberately NOT granted (which is precisely why
// LoiSelector.selectNegotiationContextById reads it WITH SYSTEM_MODE). Wiring it here would make
// the LIVE acquisition counter card depend on an FLS grant it does not have — trading a wrong
// label for a broken card. If this is worth fixing, the safe shape is a server-supplied side flag
// on the existing getCounterOffers response, not a new client-side field read.
//
// ⚠ AND A MEASURED SCOPE LIMIT ON THE BALL BADGE: `hasBall` is `isOnOpportunity && !!ballInCourt`,
// and `ballInCourt` is wired only from Opportunity.Primary_LOI__r. A disposition LOI has no
// Opportunity, so the badge does not render for it TODAY at all. The ballBadgeLabel fix is
// therefore correctness-in-advance, not a visible repair — do not report it as one. The DIRECTION
// pill fix IS visible now: this card is on LOI_Record_Page.
export default class LoiCounterOffer extends LightningElement {
    @api recordId;
    @api objectApiName;
    columns = COLUMNS;
    sortedBy = 'counterDate';
    sortedDirection = 'desc';
    editing = false;
    direction = 'Seller';
    counterPrice;
    counterCapRate;
    counterDate;
    counterResponse;
    revisionNumber;
    subsequentVersion;
    primaryLoiFromOpp;
    ballInCourt;
    offers = [];
    _wiredOffers;
    oppError;
    offersError;

    directionOptions = [
        { label: 'Seller countered us', value: 'Seller' },
        { label: 'Our counter to seller', value: 'Ours' }
    ];

    get isOnOpportunity() {
        return this.objectApiName === 'Opportunity';
    }
    // Only wires when mounted on an Opportunity page.
    get oppRecordId() {
        return this.isOnOpportunity ? this.recordId : undefined;
    }
    // The LOI to track: the Opp's Primary LOI, or the record itself on an LOI page.
    get loiId() {
        return this.isOnOpportunity ? this.primaryLoiFromOpp : this.recordId;
    }

    @wire(getRecord, { recordId: '$oppRecordId', fields: [PRIMARY_LOI], optionalFields: [LOI_BALL] })
    wiredOpp({ data, error }) {
        if (data) {
            this.oppError = undefined;
            this.primaryLoiFromOpp = getFieldValue(data, PRIMARY_LOI);
            this.ballInCourt = getFieldValue(data, LOI_BALL);
        } else if (error) {
            this.oppError = error;
            this.primaryLoiFromOpp = undefined;
            this.ballInCourt = undefined;
        }
    }

    @wire(getCounterOffers, { loiId: '$loiId' })
    wiredOffers(result) {
        this._wiredOffers = result;
        if (result.data) {
            this.offersError = undefined;
            this.offers = result.data.map((o) => ({
                id: o.Id,
                name: o.Name,
                direction: o.Direction__c,
                price: o.Counter_Price__c,
                capRate: o.Counter_Cap_Rate__c == null ? null : o.Counter_Cap_Rate__c / 100,
                response: o.Counter_Response__c,
                revisionNumber: o.Revision_Number__c,
                subsequentVersion: o.Subsequent_Version__c,
                counterDate: o.Counter_Date__c || o.CreatedDate
            }));
        } else if (result.error) {
            this.offersError = result.error;
            this.offers = [];
        }
    }

    get hasOppError() { return !!this.oppError; }
    get oppErrorMessage() {
        return (this.oppError && this.oppError.body && this.oppError.body.message) || 'Unknown error';
    }
    get hasOffersError() { return !!this.offersError; }
    get offersErrorMessage() {
        return (this.offersError && this.offersError.body && this.offersError.body.message) || 'Unknown error';
    }

    get hasPrimaryLoi() {
        return !!this.loiId;
    }
    get hasOffers() {
        return this.offers && this.offers.length > 0;
    }
    get count() {
        return this.offers ? this.offers.length : 0;
    }

    get hasBall() {
        return this.isOnOpportunity && !!this.ballInCourt;
    }
    get ballBadgeClass() {
        return this.ballInCourt === 'Us'
            ? 'slds-badge slds-theme_warning'
            : 'slds-badge';
    }
    get ballBadgeLabel() {
        // Explicit lookup, never a two-way ternary — see BALL_LABEL. The fallback is deliberately
        // party-neutral: naming a party the field does not name is exactly the defect being fixed.
        return BALL_LABEL[this.ballInCourt] || 'Ball: with the counterparty';
    }

    get rows() {
        const data = this.offers.map((o) => {
            const [dBg, dDot, dLabel] = DIRECTION[o.direction] || DIRECTION.Seller;
            return {
                id: o.id,
                recordUrl: `/lightning/r/Counter_Offer__c/${o.id}/view`,
                name: o.name,
                direction: o.direction ? dLabel : '—',
                dirWrap: pillWrap(dBg),
                dirDot: pillDot(dDot),
                price: o.price,
                capRate: o.capRate,
                revisionNumber: o.revisionNumber,
                subsequentVersion: o.subsequentVersion,
                response: o.response,
                counterDate: o.counterDate
            };
        });
        const field = this.sortedBy === 'recordUrl' ? 'name' : this.sortedBy;
        const dir = this.sortedDirection === 'asc' ? 1 : -1;
        return [...data].sort((a, b) => {
            const av = a[field] == null ? '' : a[field];
            const bv = b[field] == null ? '' : b[field];
            if (av > bv) return dir;
            if (av < bv) return -dir;
            return 0;
        });
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
    }

    handleAdd() {
        this.direction = 'Seller';
        this.counterPrice = null;
        this.counterCapRate = null;
        this.counterDate = null;
        this.counterResponse = null;
        this.revisionNumber = null;
        this.subsequentVersion = null;
        this.editing = true;
    }
    handleCancel() {
        this.editing = false;
    }
    handleDirectionChange(e) {
        this.direction = e.detail.value;
    }
    handlePriceChange(e) {
        this.counterPrice = e.target.value;
    }
    handleCapRateChange(e) {
        this.counterCapRate = e.target.value;
    }
    handleDateChange(e) {
        this.counterDate = e.target.value;
    }
    handleResponseChange(e) {
        this.counterResponse = e.target.value;
    }
    handleRevisionNumberChange(e) {
        this.revisionNumber = e.target.value;
    }
    handleSubsequentVersionChange(e) {
        this.subsequentVersion = e.target.value;
    }

    handleSave() {
        saveCounterOffer({
            loiId: this.loiId,
            direction: this.direction,
            counterPrice: this.counterPrice,
            counterCapRate: this.counterCapRate,
            counterDate: this.counterDate,
            counterResponse: this.counterResponse,
            revisionNumber: this.revisionNumber,
            subsequentVersion: this.subsequentVersion
        })
            .then(() => {
                this.editing = false;
                // Refresh the Opp so the LOI tab's spanning fields + ball badge update live.
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                return refreshApex(this._wiredOffers);
            })
            .then(() => {
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'Counter offer added', variant: 'success' })
                );
            })
            .catch((e) => {
                const message = e && e.body && e.body.message ? e.body.message : 'Unexpected error';
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'Could not save the counter offer', message, variant: 'error' })
                );
            });
    }
}