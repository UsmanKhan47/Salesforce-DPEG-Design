import { LightningElement, wire } from 'lwc';
import getUntouched from '@salesforce/apex/WorkOrderController.getUntouched';

const PRIORITY_ACCENT = { Critical: '#B01818', High: '#9A4B00', Medium: '#8B6800', Low: '#5A5752' };
const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;

// Right-column widget: open work orders nobody has acted on yet.
export default class WorkOrderUntouched extends LightningElement {
    _data = [];
    @wire(getUntouched) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((w) => {
            const h = w.slaHealth || '';
            const breached = h.indexOf('Breached') >= 0;
            const dueSoon = h.indexOf('Due Soon') >= 0;
            let wrap;
            if (breached) wrap = pill('#FDF0F0', '#8B1A1A');
            else if (dueSoon) wrap = pill('#FDF5E6', '#7A4A00');
            else wrap = pill('#EBF9F1', '#146830');
            const label = breached ? 'Breached' : (dueSoon ? 'Due Soon' : 'On Track');
            return {
                id: w.id,
                recordUrl: `/lightning/r/Work_Order__c/${w.id}/view`,
                subject: w.subject || '—',
                sub: `${w.property || '—'} · ${w.priority}`,
                slaWrap: wrap,
                slaText: label
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}
