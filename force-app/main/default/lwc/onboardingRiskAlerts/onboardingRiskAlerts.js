import { LightningElement, wire } from 'lwc';
import getRiskAlerts from '@salesforce/apex/OnboardingController.getRiskAlerts';

const TILES = [
    { key: 'overdue', label: 'Overdue Tasks',   tone: 'red' },
    { key: 'blocked', label: 'Blocked Tasks',   tone: 'red' },
    { key: 'stalled', label: 'Stalled Over 7 Days', tone: 'amber' },
    { key: 'due7d',   label: 'Due Next 7 Days', tone: 'amber' }
];
const TONE = {
    red:   { bg: '#FCF3F1', border: '#F1C9C2', fg: '#C0392B' },
    amber: { bg: '#FDF8EC', border: '#F0DFB6', fg: '#B17A0A' }
};

export default class OnboardingRiskAlerts extends LightningElement {
    a;
    @wire(getRiskAlerts) wired({ data }) { if (data) this.a = data; }
    get tiles() {
        const a = this.a || {};
        return TILES.map((t) => {
            const tone = TONE[t.tone];
            return {
                key: t.key, label: t.label,
                value: a[t.key] != null ? String(a[t.key]) : '0',
                tileStyle: `border:1px solid ${tone.border};background:${tone.bg}`,
                valueStyle: `color:${tone.fg}`
            };
        });
    }
}
