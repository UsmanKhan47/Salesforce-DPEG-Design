import { LightningElement, wire } from 'lwc';
import getPipelineByStage from '@salesforce/apex/LeaseInquiryController.getPipelineByStage';

const ACCENT = {
    'Inquiry Received': '#7A9ED4',
    'LOI Received': '#4A71B8',
    'LOI Negotiation': '#C88010',
    'LOI Signed': '#1A3464',
    'Lease Drafting': '#A88020',
    'Lease Ready': '#2E9E7B',
    'Lease Signed': '#198A40'
};
const CIRC = 2 * Math.PI * 50;

// Right-column widget styled like brokerPortfolioStatus: a donut (share of the
// active pipeline that has reached LOI) + a stacked bar and legend by stage.
export default class LeasePipelineByStage extends LightningElement {
    _data = [];
    @wire(getPipelineByStage) wired({ data }) { if (data) this._data = data; }

    get total() { return this._data.reduce((a, s) => a + (s.count || 0), 0); }
    get reachedLoi() {
        return this._data
            .filter((s) => s.stage !== 'Inquiry Received')
            .reduce((a, s) => a + (s.count || 0), 0);
    }
    get pct() { const t = this.total; return t ? Math.round((100 * this.reachedLoi) / t) : 0; }
    get dash() {
        const arc = (this.pct / 100) * CIRC;
        return `${arc.toFixed(1)} ${(CIRC - arc).toFixed(1)}`;
    }

    get segments() {
        const total = this.total || 1;
        return this._data.map((s) => {
            const color = ACCENT[s.stage] || '#4A71B8';
            return {
                key: s.stage,
                label: s.stage,
                count: s.count,
                barStyle: `width:${((s.count || 0) / total) * 100}%;background:${color};height:100%`,
                dotStyle: `width:9px;height:9px;border-radius:2px;background:${color};flex-shrink:0`
            };
        });
    }
}