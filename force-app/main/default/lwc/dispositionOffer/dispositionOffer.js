import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class DispositionOffer extends NavigationMixin(LightningElement) {
    @api recordId;
    _offers = [];
    _error;

    @wire(getRelatedListRecords, {
        parentRecordId: '$recordId',
        relatedListId: 'Disposition_Offers__r',
        fields: ['Disposition_Offer__c.Id', 'Disposition_Offer__c.Buyer_Name__c',
                 'Disposition_Offer__c.Offer_Amount__c', 'Disposition_Offer__c.Offer_Date__c']
    })
    wired({ data, error }) {
        if (data) {
            this._error = undefined;
            this._offers = data.records.map(r => ({
                id: r.id,
                buyerName: r.fields.Buyer_Name__c?.value || '—',
                amountLabel: r.fields.Offer_Amount__c?.value != null
                    ? '$' + (r.fields.Offer_Amount__c.value / 1000000).toFixed(2) + 'M' : '—',
                dateLabel: this._fmtDate(r.fields.Offer_Date__c?.value)
            }));
        } else if (error) {
            this._error = error;
            this._offers = [];
        }
    }

    get offers()    { return this._offers; }
    get hasOffers() { return this._offers.length > 0; }
    get hasError()  { return !!this._error; }
    // Suppress the "no offers yet" copy when the failure is an actual load error.
    get showEmpty() { return !this.hasOffers && !this.hasError; }
    get errorMessage() {
        return (this._error && this._error.body && this._error.body.message) || 'Unknown error';
    }

    handleLogOffer() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Disposition_Offer__c', actionName: 'new' },
            state: { defaultFieldValues: `Disposition__c=${this.recordId}` }
        });
    }

    _fmtDate(d) {
        if (!d) return '—';
        const parts = String(d).split('-');
        return MONTHS[parseInt(parts[1], 10) - 1] + ' ' + parseInt(parts[2], 10) + ', ' + parts[0];
    }
}