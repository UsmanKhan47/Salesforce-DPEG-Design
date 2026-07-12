import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getDocStatus from '@salesforce/apex/OpportunityDocStatusController.getDocStatus';

// Status -> pill tone (drives the CSS class). Anything unmapped falls back to grey.
const NDA_TONE = { Pending: 'amber', Sent: 'blue', Signed: 'green' };
const LOI_TONE = {
    Draft: 'grey',
    Working: 'blue',
    'Pending Approval': 'amber',
    Submitted: 'blue',
    Countered: 'amber',
    Approved: 'green',
    Signed: 'green',
    Rejected: 'red',
    Killed: 'red'
};
// Development / Construction feasibility-review stages.
const REVIEW_TONE = {
    Requested: 'grey',
    'Feasibility analysis': 'blue',
    'Vendor proposals': 'blue',
    'Scope & Cost Review': 'blue',
    'GC / Vendor Proposals': 'blue',
    'Site Visit': 'blue',
    'Condition Assessment': 'blue',
    'Cost Estimate': 'blue',
    'Share Opinion': 'amber',
    'Completed': 'green'
};
// Contract-review stages.
const CONTRACT_TONE = {
    'PSA Drafting': 'blue',
    'Review': 'amber',
    'Counter': 'red',
    'Contract Execution': 'green'
};
// Underwriting stages.
const UW_TONE = {
    Requested: 'grey',
    'In Progress': 'blue',
    Complete: 'green'
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class DealDocStatus extends NavigationMixin(LightningElement) {
    @api recordId;
    data;

    @wire(getDocStatus, { opportunityId: '$recordId' })
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    // ---- NDA ----
    get hasNda() {
        return this.data && this.data.hasNda;
    }
    get ndaStatus() {
        return (this.data && this.data.ndaStatus) || '—';
    }
    get ndaPillClass() {
        return `pill pill--${NDA_TONE[this.data && this.data.ndaStatus] || 'grey'}`;
    }
    get ndaMeta() {
        if (!this.data) return '';
        const parts = [];
        if (this.data.ndaSent) parts.push(`Received ${this.fmtDate(this.data.ndaSent)}`);
        if (this.data.ndaExpiry) parts.push(`Expires ${this.fmtDate(this.data.ndaExpiry)}`);
        return parts.join('  ·  ');
    }

    // ---- Underwriting ----
    get hasUnderwriting() {
        return this.data && this.data.hasUnderwriting;
    }
    get underwritingStage() {
        return (this.data && this.data.underwritingStage) || '—';
    }
    get underwritingPillClass() {
        return `pill pill--${UW_TONE[this.data && this.data.underwritingStage] || 'grey'}`;
    }
    get underwritingMeta() {
        if (!this.data) return '';
        const parts = [];
        if (this.data.underwritingPrice != null) parts.push(this.fmtMoney(this.data.underwritingPrice));
        if (this.data.underwritingVerdict && this.data.underwritingVerdict !== '—') {
            parts.push(`Verdict: ${this.data.underwritingVerdict}`);
        }
        if (this.data.underwritingOpened) parts.push(`Opened ${this.fmtDate(this.data.underwritingOpened)}`);
        return parts.join('  ·  ');
    }

    // ---- LOI ----
    get hasLoi() {
        return this.data && this.data.hasLoi;
    }
    get loiStatus() {
        return (this.data && this.data.loiStatus) || '—';
    }
    get loiPillClass() {
        return `pill pill--${LOI_TONE[this.data && this.data.loiStatus] || 'grey'}`;
    }
    get loiMeta() {
        if (!this.data) return '';
        const parts = [];
        if (this.data.loiOfferPrice != null) parts.push(this.fmtMoney(this.data.loiOfferPrice));
        if (this.data.loiCapRate != null) parts.push(`${this.data.loiCapRate}% cap`);
        if (this.data.loiSubmitted) parts.push(this.fmtDate(this.data.loiSubmitted));
        return parts.join('  ·  ');
    }

    // ---- Development ----
    get hasDevelopment() {
        return this.data && this.data.hasDevelopment;
    }
    get developmentStage() {
        return (this.data && this.data.developmentStage) || '—';
    }
    get developmentPillClass() {
        return `pill pill--${REVIEW_TONE[this.data && this.data.developmentStage] || 'blue'}`;
    }
    get developmentMeta() {
        if (!this.data || !this.data.developmentOpened) return '';
        return `Opened ${this.fmtDate(this.data.developmentOpened)}`;
    }

    // ---- Construction ----
    get hasConstruction() {
        return this.data && this.data.hasConstruction;
    }
    get constructionStage() {
        return (this.data && this.data.constructionStage) || '—';
    }
    get constructionPillClass() {
        return `pill pill--${REVIEW_TONE[this.data && this.data.constructionStage] || 'blue'}`;
    }
    get constructionMeta() {
        if (!this.data || !this.data.constructionOpened) return '';
        return `Opened ${this.fmtDate(this.data.constructionOpened)}`;
    }

    // ---- Contract ----
    get hasContract() {
        return this.data && this.data.hasContract;
    }
    get contractStage() {
        return (this.data && this.data.contractStage) || '—';
    }
    get contractPillClass() {
        return `pill pill--${CONTRACT_TONE[this.data && this.data.contractStage] || 'blue'}`;
    }
    get contractMeta() {
        if (!this.data) return '';
        const parts = [];
        if (this.data.contractValue != null) parts.push(this.fmtMoney(this.data.contractValue));
        if (this.data.contractDate) parts.push(this.fmtDate(this.data.contractDate));
        return parts.join('  ·  ');
    }

    // ---- navigation ----
    openNda() {
        this.openRecord(this.data && this.data.ndaId, 'NDA__c');
    }
    openLoi() {
        this.openRecord(this.data && this.data.loiId, 'LOI__c');
    }
    openUnderwriting() {
        this.openRecord(this.data && this.data.underwritingId, 'Underwriting__c');
    }
    openDevelopment() {
        this.openRecord(this.data && this.data.developmentId, 'Development_Feasibility_Review__c');
    }
    openConstruction() {
        this.openRecord(this.data && this.data.constructionId, 'Construction_Feasibility_Review__c');
    }
    openContract() {
        this.openRecord(this.data && this.data.contractId, 'Contract_Review__c');
    }
    openRecord(recordId, objectApiName) {
        if (!recordId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName, actionName: 'view' }
        });
    }

    // ---- formatting ----
    fmtDate(d) {
        if (!d) return '';
        const dt = new Date(d);
        if (isNaN(dt.getTime())) return '';
        // Date-only fields come back as 'YYYY-MM-DD'; use UTC parts to avoid TZ shift.
        return `${MONTHS[dt.getUTCMonth()]} ${dt.getUTCDate()}, ${dt.getUTCFullYear()}`;
    }
    fmtMoney(n) {
        const v = Number(n);
        if (!isFinite(v)) return '';
        if (Math.abs(v) >= 1000000) return `$${(v / 1000000).toFixed(1)}M`;
        if (Math.abs(v) >= 1000) return `$${Math.round(v / 1000)}K`;
        return `$${v}`;
    }
}