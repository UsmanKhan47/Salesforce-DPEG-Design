import { LightningElement, api, wire } from 'lwc';
import getLeaseSummary from '@salesforce/apex/LeaseInquiryController.getLeaseSummary';

// Deal-Summary-style panel on the Lease Inquiry record page: shows the related
// Lease (legal team) record's stage progression (Draft -> Prepare/Review ->
// Completed) plus owner and dates, with a link to open the Lease record.
export default class LeaseStatusSummary extends LightningElement {
    @api recordId;
    s;

    @wire(getLeaseSummary, { inquiryId: '$recordId' })
    wired({ data }) {
        if (data) {
            this.s = data;
        }
    }

    get exists() { return !!(this.s && this.s.exists); }
    get leaseUrl() { return this.s && this.s.leaseId ? `/lightning/r/Lease__c/${this.s.leaseId}/view` : '#'; }
    get leaseName() { return (this.s && this.s.leaseName) || ''; }
    get legalOwner() { return (this.s && this.s.legalOwner) || 'Unassigned'; }
    get targetDate() { return this.s ? this.s.targetDate : null; }
    get executedDate() { return this.s ? this.s.executedDate : null; }

    get steps() {
        const st = (this.s && this.s.steps) || [];
        return st.map((x) => ({
            key: x.label,
            label: x.label,
            cls: x.done ? 'lss-step lss-step--done' : (x.current ? 'lss-step lss-step--current' : 'lss-step')
        }));
    }
}
