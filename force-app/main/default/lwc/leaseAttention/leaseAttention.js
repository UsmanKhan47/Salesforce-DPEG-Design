import { LightningElement, wire } from 'lwc';
import getAttention from '@salesforce/apex/LeaseInquiryController.getAttention';

const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

// Right-column widget: active deals that need a nudge (with the landlord, or aging).
export default class LeaseAttention extends LightningElement {
    _data = [];
    _error;
    @wire(getAttention) wired({ data, error }) {
        if (data) {
            this._data = data;
            this._error = undefined;
        } else if (error) {
            this._error = error;
            this._data = [];
        }
    }

    get hasError() { return !!this._error; }
    // Suppress the "nothing needs a nudge" copy when the read actually failed.
    get showEmpty() { return !this.hasRows && !this.hasError; }
    get errorMessage() {
        return (this._error && this._error.body && this._error.body.message) || 'Unknown error';
    }

    get rows() {
        return this._data.map((q) => {
            const d = q.days == null ? 0 : q.days;
            let wrap;
            let dotStyle;
            if (d > 14) { wrap = pill('#FDF0F0', '#8B1A1A'); dotStyle = dot('#D93636'); }
            else if (d > 7) { wrap = pill('#FDF5E6', '#7A4A00'); dotStyle = dot('#C88010'); }
            else { wrap = pill('#EBF9F1', '#146830'); dotStyle = dot('#22A652'); }
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Inquiry__c/${q.id}/view`,
                tenant: q.tenant || '—',
                sub: `${q.stage} · ball with ${q.ball}`,
                daysText: `${d}d`,
                daysWrap: wrap,
                daysDot: dotStyle
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}