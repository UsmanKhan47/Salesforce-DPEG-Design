import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import ACTIVE_DAYS from '@salesforce/schema/Broker_Assignment__c.Listing_Active_Days__c';
import LAST_CHECKIN from '@salesforce/schema/Broker_Assignment__c.Last_Check_In_Date__c';
import DAYS_IDLE from '@salesforce/schema/Broker_Assignment__c.Days_Since_Check_In__c';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class BrokerListingActivity extends LightningElement {
    @api recordId;
    record;

    @wire(getRecord, { recordId: '$recordId', fields: [ACTIVE_DAYS, LAST_CHECKIN, DAYS_IDLE] })
    wired(result) {
        if (result.data) this.record = result.data;
    }

    get activeDays() {
        const v = getFieldValue(this.record, ACTIVE_DAYS);
        return v == null ? '—' : `${v}`;
    }

    get daysIdle() {
        const v = getFieldValue(this.record, DAYS_IDLE);
        return v == null ? '—' : `${v}`;
    }

    get lastCheckIn() {
        const v = getFieldValue(this.record, LAST_CHECKIN);
        if (!v) return '—';
        const p = String(v).split('-').map(Number);
        return `${MONTHS[p[1] - 1]} ${p[2]}, ${p[0]}`;
    }
}
