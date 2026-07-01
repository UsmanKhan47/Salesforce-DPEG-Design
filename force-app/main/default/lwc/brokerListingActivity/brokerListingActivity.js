import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import ACTIVE_DAYS from '@salesforce/schema/Broker_Assignment__c.Listing_Active_Days__c';
import LAST_CHECKIN from '@salesforce/schema/Broker_Assignment__c.Last_Check_In_Date__c';
import DAYS_IDLE from '@salesforce/schema/Broker_Assignment__c.Days_Since_Check_In__c';
import LISTING_START from '@salesforce/schema/Broker_Assignment__c.Listing_Start_Date__c';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const fmtDate = (v) => {
    if (!v) return '—';
    const p = String(v).split('-').map(Number);
    return `${MONTHS[p[1] - 1]} ${p[2]}, ${p[0]}`;
};

export default class BrokerListingActivity extends LightningElement {
    @api recordId;
    record;

    @wire(getRecord, { recordId: '$recordId', fields: [ACTIVE_DAYS, LAST_CHECKIN, DAYS_IDLE, LISTING_START] })
    wired(result) { if (result.data) this.record = result.data; }

    get _idle() { return getFieldValue(this.record, DAYS_IDLE); }

    get tiles() {
        const active = getFieldValue(this.record, ACTIVE_DAYS);
        const idle = this._idle;
        return [
            { key: 'active',  icon: 'utility:clock',     value: active == null ? '—' : `${active}`, label: 'Active Days', valStyle: '' },
            { key: 'start',   icon: 'utility:event',     value: fmtDate(getFieldValue(this.record, LISTING_START)), label: 'Listing Start', valStyle: '' },
            { key: 'checkin', icon: 'utility:check',     value: fmtDate(getFieldValue(this.record, LAST_CHECKIN)), label: 'Last Check-In', valStyle: '' },
            { key: 'idle',    icon: 'utility:date_time', value: idle == null ? '—' : `${idle}`, label: 'Days Since Check-In', valStyle: `color:${this._healthColor(idle)}` }
        ];
    }

    _healthColor(idle) {
        if (idle == null) return '#1A1714';
        if (idle >= 30) return '#B52020';
        if (idle >= 7) return '#A06200';
        return '#146830';
    }
    get _health() {
        const idle = this._idle;
        if (idle == null) return { label: 'No check-in', color: '#8A8680' };
        if (idle >= 30) return { label: 'Very stale', color: '#B52020' };
        if (idle >= 7) return { label: 'Stale', color: '#A06200' };
        return { label: 'On track', color: '#146830' };
    }
    get healthLabel() { return this._health.label; }
    get pillDotStyle() { return `background:${this._health.color}`; }
    get pillTextStyle() { return `color:${this._health.color}`; }
}
