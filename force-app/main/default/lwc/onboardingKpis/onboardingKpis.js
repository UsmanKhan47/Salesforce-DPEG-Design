import { LightningElement, wire } from 'lwc';
import getKpis from '@salesforce/apex/OnboardingController.getKpis';

const CARD_META = [
    { key: 'props',   label: 'Properties in Onboarding', iconName: 'utility:home',     color: '#1B3A6B' },
    { key: 'avg',     label: 'Avg % Complete',           iconName: 'utility:trending', color: '#1A7A6B' },
    { key: 'overdue', label: 'Overdue Tasks',            iconName: 'utility:warning',  color: '#D4940A' },
    { key: 'days',    label: 'Avg Time-to-Onboard',      iconName: 'utility:event',    color: '#1B3A6B' }
];

export default class OnboardingKpis extends LightningElement {
    kpis;
    @wire(getKpis) wired({ data }) { if (data) this.kpis = data; }
    get metrics() {
        const k = this.kpis || {};
        const values = {
            props:   k.propertiesInOnboarding != null ? String(k.propertiesInOnboarding) : '0',
            avg:     (k.avgCompletionPct != null ? k.avgCompletionPct : 0) + '%',
            overdue: k.overdueTasks != null ? String(k.overdueTasks) : '0',
            days:    (k.avgDaysToOnboard != null ? k.avgDaysToOnboard : 0) + 'd'
        };
        return CARD_META.map((m) => ({
            key: m.key, label: m.label, iconName: m.iconName, iconColor: m.color, displayValue: values[m.key]
        }));
    }
}
