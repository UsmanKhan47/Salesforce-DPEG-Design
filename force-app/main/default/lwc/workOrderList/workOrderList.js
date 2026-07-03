import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRecentWorkOrders from '@salesforce/apex/WorkOrderController.getRecentWorkOrders';

const PRIORITY_ACCENT = { Critical: '#B01818', High: '#9A4B00', Medium: '#8B6800', Low: '#5A5752' };
const pillWrap = (bg, fg) => `display:inline-flex;align-items:center;gap:6px;background:${bg};color:${fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Work Order', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'subject' }, target: '_self' } },
    { label: 'Property · Unit', fieldName: 'propUnit', type: 'text' },
    { label: 'Priority', fieldName: 'priority', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'priorityWrap' }, dotStyle: { fieldName: 'priorityDot' } } },
    { label: 'Status', fieldName: 'status', type: 'text' },
    { label: 'SLA', fieldName: 'slaText', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'slaWrap' }, dotStyle: { fieldName: 'slaDot' } } },
    { label: 'Days Open', fieldName: 'daysOpen', type: 'text', initialWidth: 110 }
];

// Open Work Orders list on the Work Orders home page (6 newest, View All footer).
export default class WorkOrderList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data = [];
    listUrl = '#';
    @wire(getRecentWorkOrders) wired({ data }) { if (data) this._data = data; }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => { this.listUrl = url; });
    }
    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Work_Order__c', actionName: 'list' },
            state: { filterName: 'My_Open_Work_Orders' }
        };
    }

    get rows() {
        return this._data.map((w) => {
            const pc = PRIORITY_ACCENT[w.priority] || '#5A5752';
            const h = w.slaHealth || '';
            let slaWrap;
            let slaDot = '';
            let slaText;
            if (h.indexOf('Breached') >= 0) { slaText = 'Breached'; slaWrap = pillWrap('#FDF0F0', '#8B1A1A'); slaDot = dot('#D93636'); }
            else if (h.indexOf('Due Soon') >= 0) { slaText = 'Due Soon'; slaWrap = pillWrap('#FDF5E6', '#7A4A00'); slaDot = dot('#C88010'); }
            else if (h.indexOf('Resolved') >= 0) { slaText = 'Resolved'; slaWrap = pillWrap('#EBF9F1', '#146830'); }
            else { slaText = 'On Track'; slaWrap = pillWrap('#EBF9F1', '#146830'); slaDot = dot('#22A652'); }
            const days = w.hoursOpen == null ? 0 : Math.floor(w.hoursOpen / 24);
            return {
                id: w.id,
                recordUrl: `/lightning/r/Work_Order__c/${w.id}/view`,
                subject: w.subject || '—',
                propUnit: `${w.property || '—'}${w.unit ? ' · ' + w.unit : ''}`,
                priority: w.priority || '—',
                priorityWrap: pillWrap(`${pc}18`, pc),
                priorityDot: dot(pc),
                status: w.status || '—',
                slaText, slaWrap, slaDot,
                daysOpen: `${days}d`
            };
        });
    }
    get count() { return this.rows.length; }

    viewAll(event) {
        if (event) event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
