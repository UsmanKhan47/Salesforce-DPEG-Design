import { LightningElement, wire } from 'lwc';
import getEscalations from '@salesforce/apex/WorkOrderController.getEscalations';

const PRIORITY_ACCENT = { Critical: '#B01818', High: '#9A4B00', Medium: '#8B6800', Low: '#5A5752' };
const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

// Right-column widget: Critical/High work orders that have breached SLA.
export default class WorkOrderEscalations extends LightningElement {
    _data = [];
    @wire(getEscalations) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((w) => {
            const pc = PRIORITY_ACCENT[w.priority] || '#B01818';
            return {
                id: w.id,
                recordUrl: `/lightning/r/Work_Order__c/${w.id}/view`,
                subject: w.subject || '—',
                sub: `${w.property || '—'} · ${w.priority}`,
                priorityWrap: pill(`${pc}18`, pc),
                priorityDot: dot(pc),
                priority: w.priority
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}