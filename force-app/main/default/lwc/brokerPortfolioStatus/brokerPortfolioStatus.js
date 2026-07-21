import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/BrokerAssignmentController.getPortfolio';

const SEG = [
    { key:'active',   label:'Active',       color:'#22A652' },
    { key:'leased',   label:'Fully Leased', color:'#C8A045' },
    { key:'disposed', label:'Disposed',     color:'#64748B' }
];
const CIRC = 2 * Math.PI * 50;

export default class BrokerPortfolioStatus extends LightningElement {
    p;
    error;
    @wire(getPortfolio) wired({ data, error }) {
        if (data) {
            this.p = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.p = undefined;
        }
    }
    get hasError() { return !!this.error; }
    get errorMessage() { const e = this.error; return (e && e.body && e.body.message) || 'Unknown error'; }
    get pct() { const p = this.p || {}; return p.total ? Math.round(100 * p.active / p.total) : 0; }
    get dash() { const arc = (this.pct / 100) * CIRC; return `${arc.toFixed(1)} ${(CIRC - arc).toFixed(1)}`; }
    get active() { return (this.p && this.p.active) || 0; }
    get total() { return (this.p && this.p.total) || 0; }
    get segments() {
        const p = this.p || {}; const total = p.total || 1;
        return SEG.map(s => ({
            key: s.key, label: s.label, color: s.color, count: p[s.key] || 0,
            barStyle: `width:${((p[s.key] || 0) / total) * 100}%;background:${s.color};height:100%`,
            dotStyle: `width:9px;height:9px;border-radius:2px;background:${s.color};flex-shrink:0`
        }));
    }
}