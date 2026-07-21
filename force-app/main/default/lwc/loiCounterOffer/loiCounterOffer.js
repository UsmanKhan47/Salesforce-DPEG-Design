import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PRIMARY_LOI from '@salesforce/schema/Opportunity.Primary_LOI__c';
import LOI_BALL from '@salesforce/schema/Opportunity.Primary_LOI__r.Ball_In_Court__c';
import getCounterOffers from '@salesforce/apex/CounterOfferController.getCounterOffers';
import saveCounterOffer from '@salesforce/apex/CounterOfferController.saveCounterOffer';

const LEFT = { alignment: 'left' };
// [background, dot, label] soft pills per direction (matches the lv-* list chrome).
const DIRECTION = {
    Seller: ['#fff1e0', '#FB8C00', 'Seller'],
    Ours:   ['#e8f1fc', '#1E88E5', 'Ours']
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
        return this.ballInCourt === 'Us' ? 'Ball: our court' : 'Ball: seller court';
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