import { LightningElement, wire } from 'lwc';
import getHomeKpis from '@salesforce/apex/LeaseInquiryController.getHomeKpis';

// Top KPI strip on the Lease Activity Tracker home page.
export default class LeaseInquiryKpis extends LightningElement {
    k;
    @wire(getHomeKpis) wired({ data }) { if (data) this.k = data; }

    get cards() {
        const k = this.k || {};
        return [
            { key: 'active',  value: k.active ?? 0,          label: 'Active Inquiries',    iconName: 'utility:trending', iconColor: '#132850' },
            { key: 'waiting', value: k.waitingLandlord ?? 0, label: 'Waiting on Landlord', iconName: 'utility:user',     iconColor: '#132850' },
            { key: 'stalled', value: k.stalled ?? 0,         label: 'Stalled (over 14d)',  iconName: 'utility:warning',  iconColor: '#B52020' },
            { key: 'signed',  value: k.signed ?? 0,          label: 'Signed Leases',       iconName: 'utility:success',  iconColor: '#C8A045' }
        ];
    }
}
