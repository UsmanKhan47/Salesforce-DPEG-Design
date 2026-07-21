import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/OnboardingController.getPortfolio';

const SEG = [
    { key: 'complete',   label: 'Completed',   color: '#1A7A6B' },
    { key: 'notStarted', label: 'Not Started', color: '#6B7280' }
];

export default class OnboardingPortfolioProgress extends LightningElement {
    p;
    error;
    @wire(getPortfolio)
    wired({ data, error }) {
        if (data) {
            this.p = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load portfolio progress.';
    }
    get pct() { const p = this.p; if (!p || !p.tasksTotal) return 0; return Math.round((100 * p.complete) / p.tasksTotal); }
    get donutStyle() { const v = this.pct; return `background:conic-gradient(#1A7A6B 0% ${v}%, #ECEBEA ${v}% 100%)`; }
    get pctLabel() { return this.pct + '%'; }
    get completeLabel() { return this.p ? String(this.p.complete) : '0'; }
    get totalLabel() { return this.p ? `/ ${this.p.tasksTotal}` : '/ 0'; }
    get segments() {
        const p = this.p || {}; const total = p.tasksTotal || 1;
        return SEG.map((s) => {
            const count = p[s.key] || 0;
            return {
                key: s.key, label: s.label, count,
                barStyle: `width:${(count / total) * 100}%;height:100%;background:${s.color}`,
                dotStyle: `width:9px;height:9px;border-radius:2px;background:${s.color};flex-shrink:0`
            };
        });
    }
}