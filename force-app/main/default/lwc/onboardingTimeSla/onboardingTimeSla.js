import { LightningElement, wire } from 'lwc';
import getTimeSla from '@salesforce/apex/OnboardingController.getTimeSla';

const TILES = [
    { key: 'avgDaysToOnboard', label: 'Avg Days to Onboard', tone: 'neutral' },
    { key: 'avgAge',           label: 'Avg Age of Active',   tone: 'neutral' },
    { key: 'pastTarget',       label: 'Past Target Duration', tone: 'amber' },
    { key: 'oldestOpen',       label: 'Oldest Open (Days)',  tone: 'red' }
];
const TONE = {
    neutral: { bg: '#FAFAFA', border: '#EDEDED', fg: '#181818' },
    amber:   { bg: '#FDF8EC', border: '#F0DFB6', fg: '#B17A0A' },
    red:     { bg: '#FCF3F1', border: '#F1C9C2', fg: '#C0392B' }
};

export default class OnboardingTimeSla extends LightningElement {
    t;
    @wire(getTimeSla) wired({ data }) { if (data) this.t = data; }
    get tiles() {
        const t = this.t || {};
        return TILES.map((x) => {
            const tone = TONE[x.tone];
            return {
                key: x.key, label: x.label,
                value: t[x.key] != null ? String(t[x.key]) : '0',
                tileStyle: `border:1px solid ${tone.border};background:${tone.bg}`,
                valueStyle: `color:${tone.fg}`
            };
        });
    }
}