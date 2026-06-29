import { LightningElement, api, wire } from 'lwc';
import getListing from '@salesforce/apex/BrokerListingController.getListing';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class BrokerListing extends LightningElement {
    @api recordId;
    listing;

    @wire(getListing, { dispositionId: '$recordId' })
    wired({ data }) { if (data) this.listing = data; }

    get listDateLabel() { return this._fmtDate(this.listing?.listDate); }
    get cfoDateLabel()  { return this._fmtDate(this.listing?.callForOffersDate); }

    get stats() {
        const l = this.listing || {};
        return [
            { key: 'dom',    label: 'Days On Market',       value: `${l.daysOnMarket ?? 0} days`, iconName: 'utility:clock', iconColor: l.isAtRisk ? '#b45309' : '#5a6b7b' },
            { key: 'list',   label: 'List Date',            value: this.listDateLabel,            iconName: 'utility:event', iconColor: '#1565c0' },
            { key: 'cfo',    label: 'Call For Offers Date', value: this.cfoDateLabel,             iconName: 'utility:event', iconColor: '#1565c0' },
            { key: 'offers', label: 'Offers Received',      value: String(l.offersReceived ?? 0), iconName: 'utility:reply', iconColor: l.offersReceived === 0 ? '#b91c1c' : '#2e7d32' }
        ];
    }

    get hasWeekLabel() { return !!this.listing?.weekLabel; }

    handleReplaceBroker() {
        console.log('Replace Broker — stub');
    }

    _fmtDate(d) {
        if (!d) return '—';
        const parts = String(d).split('-');
        return MONTHS[parseInt(parts[1], 10) - 1] + ' ' + parseInt(parts[2], 10) + ', ' + parts[0];
    }
}