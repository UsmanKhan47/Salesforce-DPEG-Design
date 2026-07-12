import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getLeaseSummary from '@salesforce/apex/LeaseInquiryController.getLeaseSummary';

// Mirrors the Deal Summary (dealDocStatus) UI/UX: a document row with an icon
// tile, a clickable record name, a status pill (the Lease stage) and a meta line.
const STAGE_TONE = { Draft: 'grey', 'Prepare/Review': 'blue', Completed: 'green' };
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class LeaseStatusSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    data;

    @wire(getLeaseSummary, { inquiryId: '$recordId' })
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    get hasLease() {
        return !!(this.data && this.data.exists);
    }
    get leaseName() {
        return (this.data && this.data.leaseName) || 'Lease';
    }
    get stage() {
        return (this.data && this.data.stage) || '—';
    }
    get pillClass() {
        return `pill pill--${STAGE_TONE[this.data && this.data.stage] || 'grey'}`;
    }
    get meta() {
        if (!this.data) return '';
        const parts = [];
        if (this.data.legalOwner) parts.push(this.data.legalOwner);
        if (this.data.targetDate) parts.push(`Target ${this.fmtDate(this.data.targetDate)}`);
        if (this.data.executedDate) parts.push(`Executed ${this.fmtDate(this.data.executedDate)}`);
        return parts.join('  ·  ');
    }

    openLease() {
        if (!this.data || !this.data.leaseId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.data.leaseId, objectApiName: 'Lease__c', actionName: 'view' }
        });
    }

    fmtDate(d) {
        if (!d) return '';
        const dt = new Date(d);
        if (isNaN(dt.getTime())) return '';
        return `${MONTHS[dt.getUTCMonth()]} ${dt.getUTCDate()}, ${dt.getUTCFullYear()}`;
    }
}