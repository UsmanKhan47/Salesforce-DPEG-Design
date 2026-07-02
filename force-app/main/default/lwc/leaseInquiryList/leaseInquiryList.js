import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRecentInquiries from '@salesforce/apex/LeaseInquiryController.getRecentInquiries';

const STAGE_ACCENT = {
    'Inquiry Received': '#4A71B8', 'LOI Received': '#4A71B8', 'LOI Negotiation': '#C88010',
    'LOI Signed': '#1A3464', 'Lease Drafting': '#A88020', 'Lease Signed': '#198A40'
};
const BALL = {
    'Landlord':     { bg: '#E8EFF7', fg: '#132850', dot: '#1A3464' },
    'Tenant':       { bg: '#E4F3EF', fg: '#0F5A4D', dot: '#1A7A6B' },
    'Legal':        { bg: '#FDF5E6', fg: '#7A4A00', dot: '#C88010' },
    'Construction': { bg: '#EDEBE7', fg: '#3F3C38', dot: '#8A8680' },
    'Broker':       { bg: '#EBF3FC', fg: '#1A4880', dot: '#2E7AC8' }
};
const pillWrap = (bg, fg) => `display:inline-flex;align-items:center;gap:6px;background:${bg};color:${fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Prospect / Tenant', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'tenant' }, target: '_self' } },
    { label: 'Property', fieldName: 'property', type: 'text' },
    { label: 'Broker', fieldName: 'broker', type: 'text' },
    { label: 'Stage', fieldName: 'stage', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: '' } },
    { label: 'Ball in Court', fieldName: 'ball', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'ballWrap' }, dotStyle: { fieldName: 'ballDot' } } },
    { label: 'Days in Stage', fieldName: 'daysText', type: 'pill', initialWidth: 130, typeAttributes: { wrapStyle: { fieldName: 'agingWrap' }, dotStyle: { fieldName: 'agingDot' } } }
];

export default class LeaseInquiryList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data = [];
    @wire(getRecentInquiries) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((q) => {
            const sc = STAGE_ACCENT[q.stage] || '#4A71B8';
            const b = BALL[q.ball] || BALL['Landlord'];
            let agingWrap;
            let agingDot = '';
            let daysText;
            if (q.closed) {
                agingWrap = pillWrap('#EBF9F1', '#146830');
                daysText = 'Signed';
            } else {
                const d = q.days == null ? 0 : q.days;
                daysText = `${d}d`;
                if (d > 14) { agingWrap = pillWrap('#FDF0F0', '#8B1A1A'); agingDot = dot('#D93636'); }
                else if (d > 7) { agingWrap = pillWrap('#FDF5E6', '#7A4A00'); agingDot = dot('#C88010'); }
                else { agingWrap = pillWrap('#EBF9F1', '#146830'); agingDot = dot('#22A652'); }
            }
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Inquiry__c/${q.id}/view`,
                tenant: q.tenant || '—',
                property: q.property || '—',
                broker: q.broker || '—',
                stage: q.stage,
                stageWrap: `display:inline-flex;align-items:center;font-size:11px;font-weight:600;padding:3px 9px;border-radius:6px;background:${sc}18;color:${sc};border:1px solid ${sc}44;white-space:nowrap`,
                ball: q.ball || '—',
                ballWrap: pillWrap(b.bg, b.fg),
                ballDot: dot(b.dot),
                daysText,
                agingWrap,
                agingDot
            };
        });
    }
    get count() { return this.rows.length; }

    newInquiry() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lease_Inquiry__c', actionName: 'new' }
        });
    }
    viewAll() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lease_Inquiry__c', actionName: 'list' },
            state: { filterName: 'Active_Pipeline' }
        });
    }
}
