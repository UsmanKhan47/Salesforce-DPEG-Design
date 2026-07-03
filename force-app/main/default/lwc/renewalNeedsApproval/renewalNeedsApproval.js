import { LightningElement, wire } from 'lwc';
import getNeedsApproval from '@salesforce/apex/LeaseRenewalController.getNeedsApproval';

const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

// Right-column widget: rate decisions awaiting owner sign-off.
export default class RenewalNeedsApproval extends LightningElement {
    _data = [];
    @wire(getNeedsApproval) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((q) => {
            const d = q.daysToExpiry == null ? 0 : q.daysToExpiry;
            let wrap;
            let dotStyle;
            if (d <= 30) { wrap = pill('#FDF0F0', '#8B1A1A'); dotStyle = dot('#D93636'); }
            else if (d <= 90) { wrap = pill('#FDF5E6', '#7A4A00'); dotStyle = dot('#C88010'); }
            else { wrap = pill('#EBF9F1', '#146830'); dotStyle = dot('#22A652'); }
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Renewal__c/${q.id}/view`,
                tenant: q.tenant || '—',
                sub: `${q.stage} · ${q.property || '—'}`,
                daysText: `${d}d left`,
                daysWrap: wrap,
                daysDot: dotStyle
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}
