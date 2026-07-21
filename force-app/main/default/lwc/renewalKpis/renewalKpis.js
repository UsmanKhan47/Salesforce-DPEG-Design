import { LightningElement, wire } from 'lwc';
import getHomeKpis from '@salesforce/apex/LeaseRenewalController.getHomeKpis';

// Top KPI strip on the Lease Renewals home page.
export default class RenewalKpis extends LightningElement {
    k;
    error;
    @wire(getHomeKpis) wired({ data, error }) {
        if (data) {
            this.k = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get hasError() { return !!this.error; }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load renewal metrics.';
    }

    get cards() {
        const k = this.k || {};
        return [
            { key: 'active',   value: k.active ?? 0,        label: 'Active Renewals',      iconName: 'utility:event',    iconColor: '#7A9ED4' },
            { key: 'expiring', value: k.expiring90 ?? 0,    label: 'Expiring ≤ 90 Days',   iconName: 'utility:clock',    iconColor: '#D8BE72' },
            { key: 'nonresp',  value: k.nonResponsive ?? 0, label: 'Non-Responsive',       iconName: 'utility:comments', iconColor: '#E58A8A' },
            { key: 'renewed',  value: k.renewedYtd ?? 0,    label: 'Renewed (YTD)',        iconName: 'utility:success',  iconColor: '#8FCBAA' }
        ];
    }
}