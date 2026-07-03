import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRecentRenewals from '@salesforce/apex/LeaseRenewalController.getRecentRenewals';

const STAGE_ACCENT = {
    'Not Yet Started': '#7A9ED4', 'Notice Sent': '#4A71B8', 'Awaiting Tenant Response': '#C88010',
    'Negotiating': '#B8651A', 'Escalated for Approval': '#1A3464', 'Amendment Drafted': '#A88020',
    'Renewed': '#198A40', 'Not Renewing': '#8A8680', 'Vacating': '#6B6862'
};
const pillWrap = (bg, fg) => `display:inline-flex;align-items:center;gap:6px;background:${bg};color:${fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Tenant', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'tenant' }, target: '_self' } },
    { label: 'Property', fieldName: 'property', type: 'text' },
    { label: 'Lease Expiry', fieldName: 'leaseEnd', type: 'date', initialWidth: 120, typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' } },
    { label: 'Days Left', fieldName: 'daysText', type: 'pill', initialWidth: 120, typeAttributes: { wrapStyle: { fieldName: 'daysWrap' }, dotStyle: { fieldName: 'daysDot' } } },
    { label: 'Stage', fieldName: 'stage', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: '' } },
    { label: 'Last Contact', fieldName: 'contactText', type: 'pill', initialWidth: 140, typeAttributes: { wrapStyle: { fieldName: 'contactWrap' }, dotStyle: { fieldName: 'contactDot' } } }
];

// Recent Renewals list on the Lease Renewals home page (6 newest, View All footer).
export default class RenewalList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data = [];
    listUrl = '#';
    @wire(getRecentRenewals) wired({ data }) { if (data) this._data = data; }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => { this.listUrl = url; });
    }
    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lease_Renewal__c', actionName: 'list' },
            state: { filterName: 'All' }
        };
    }

    get rows() {
        return this._data.map((q) => {
            const sc = STAGE_ACCENT[q.stage] || '#4A71B8';
            const d = q.daysToExpiry;
            let daysText;
            let daysWrap;
            let daysDot = '';
            if (q.closed) {
                daysText = q.stage === 'Renewed' ? 'Renewed' : (q.stage === 'Vacating' ? 'Vacating' : 'Not renewing');
                daysWrap = q.stage === 'Renewed' ? pillWrap('#EBF9F1', '#146830') : pillWrap('#E2E0DB', '#3F3C38');
            } else if (d == null) {
                daysText = '—'; daysWrap = pillWrap('#EDEBE7', '#5A5752');
            } else if (d < 0) {
                daysText = 'Expired'; daysWrap = pillWrap('#FDF0F0', '#8B1A1A'); daysDot = dot('#D93636');
            } else if (d <= 30) {
                daysText = `${d}d left`; daysWrap = pillWrap('#FDF0F0', '#8B1A1A'); daysDot = dot('#D93636');
            } else if (d <= 90) {
                daysText = `${d}d left`; daysWrap = pillWrap('#FDF5E6', '#7A4A00'); daysDot = dot('#C88010');
            } else {
                daysText = `${d}d left`; daysWrap = pillWrap('#EBF9F1', '#146830'); daysDot = dot('#22A652');
            }
            let contactText;
            let contactWrap;
            let contactDot = '';
            if (q.closed) {
                contactText = '—'; contactWrap = pillWrap('transparent', '#524F4A');
            } else if (q.daysSinceContact == null) {
                contactText = 'No contact yet'; contactWrap = pillWrap('transparent', '#8A8680');
            } else if (q.nonResponsive) {
                contactText = `${q.daysSinceContact}d ago`; contactWrap = pillWrap('#FDECEC', '#B01818'); contactDot = dot('#D42B2B');
            } else {
                contactText = `${q.daysSinceContact}d ago`; contactWrap = pillWrap('transparent', '#524F4A');
            }
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Renewal__c/${q.id}/view`,
                tenant: q.tenant || '—',
                property: q.property || '—',
                leaseEnd: q.leaseEnd,
                daysText, daysWrap, daysDot,
                stage: q.stage,
                stageWrap: `display:inline-flex;align-items:center;font-size:11px;font-weight:600;padding:3px 9px;border-radius:6px;background:${sc}18;color:${sc};border:1px solid ${sc}44;white-space:nowrap`,
                contactText, contactWrap, contactDot
            };
        });
    }
    get count() { return this.rows.length; }

    newRenewal() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lease_Renewal__c', actionName: 'new' }
        });
    }
    viewAll(event) {
        if (event) event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
