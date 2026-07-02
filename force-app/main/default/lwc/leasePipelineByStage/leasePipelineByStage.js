import { LightningElement, wire } from 'lwc';
import getPipelineByStage from '@salesforce/apex/LeaseInquiryController.getPipelineByStage';

const ACCENT = {
    'Inquiry Received': '#4A71B8', 'LOI Received': '#4A71B8', 'LOI Negotiation': '#C88010',
    'LOI Signed': '#1A3464', 'Lease Drafting': '#A88020', 'Lease Signed': '#198A40'
};

// Right-column widget: active pipeline count per stage, with a mini bar each.
export default class LeasePipelineByStage extends LightningElement {
    _data = [];
    @wire(getPipelineByStage) wired({ data }) { if (data) this._data = data; }

    get rows() {
        const max = Math.max(1, ...this._data.map((s) => s.count || 0));
        return this._data.map((s) => {
            const c = ACCENT[s.stage] || '#4A71B8';
            const w = s.count ? Math.max((s.count / max) * 100, 6) : 0;
            return {
                stage: s.stage,
                count: s.count,
                barStyle: `width:${w}%;height:100%;background:${c};border-radius:5px`
            };
        });
    }
    get total() { return this._data.reduce((a, s) => a + (s.count || 0), 0); }
}
