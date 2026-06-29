import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PRIMARY_LOI from '@salesforce/schema/Opportunity.Primary_LOI__c';
import getCounterOffers from '@salesforce/apex/CounterOfferController.getCounterOffers';
import saveCounterOffer from '@salesforce/apex/CounterOfferController.saveCounterOffer';

const LEFT = { alignment: 'left' };
const COLUMNS = [
    {
        label: 'Counter Offer',
        fieldName: 'recordUrl',
        type: 'url',
        sortable: true,
        initialWidth: 130,
        cellAttributes: LEFT,
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
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
        // No initialWidth: this column absorbs the remaining width (fixed mode).
        label: 'Counter Response',
        fieldName: 'response',
        type: 'text',
        wrapText: true,
        cellAttributes: LEFT
    },
    {
        label: 'Date',
        fieldName: 'created',
        type: 'date',
        sortable: true,
        initialWidth: 120,
        cellAttributes: LEFT,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' }
    }
];

// Counter Offer card on the Opportunity LOI tab: records counter offers against the
// deal's Primary LOI (Counter_Offer__c history shown in a native related-list datatable,
// newest first) and stamps the latest price/response back onto the LOI.
export default class LoiCounterOffer extends LightningElement {
    @api recordId; // Opportunity Id
    columns = COLUMNS;
    sortedBy = 'created';
    sortedDirection = 'desc';
    editing = false;
    counterPrice;
    counterResponse;
    primaryLoiId;
    offers = [];
    _wiredOffers;

    @wire(getRecord, { recordId: '$recordId', fields: [PRIMARY_LOI] })
    wiredOpp({ data }) {
        if (data) {
            this.primaryLoiId = getFieldValue(data, PRIMARY_LOI);
        }
    }

    @wire(getCounterOffers, { loiId: '$primaryLoiId' })
    wiredOffers(result) {
        this._wiredOffers = result;
        if (result.data) {
            this.offers = result.data.map((o) => ({
                id: o.Id,
                name: o.Name,
                price: o.Counter_Price__c,
                response: o.Counter_Response__c,
                created: o.CreatedDate
            }));
        }
    }

    get hasPrimaryLoi() {
        return !!this.primaryLoiId;
    }
    get hasOffers() {
        return this.offers && this.offers.length > 0;
    }
    get count() {
        return this.offers ? this.offers.length : 0;
    }

    get rows() {
        const data = this.offers.map((o) => ({
            id: o.id,
            recordUrl: `/lightning/r/Counter_Offer__c/${o.id}/view`,
            name: o.name,
            price: o.price,
            response: o.response,
            created: o.created
        }));
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
        this.counterPrice = null;
        this.counterResponse = null;
        this.editing = true;
    }
    handleCancel() {
        this.editing = false;
    }
    handlePriceChange(e) {
        this.counterPrice = e.target.value;
    }
    handleResponseChange(e) {
        this.counterResponse = e.target.value;
    }

    handleSave() {
        saveCounterOffer({
            loiId: this.primaryLoiId,
            counterPrice: this.counterPrice,
            counterResponse: this.counterResponse
        })
            .then(() => {
                this.editing = false;
                // Refresh the Opp so the LOI tab's Primary_LOI__r.Counter_Price__c updates live.
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