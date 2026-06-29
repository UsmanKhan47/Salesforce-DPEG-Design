import { LightningElement, api, wire } from 'lwc';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

export default class OnboardingTaskProgressByCategory extends LightningElement {
    @api recordId;
    groups = [];
    @wire(getChecklist, { onboardingId: '$recordId' }) wired({ data }) { if (data) this.groups = data; }
    get tiles() {
        return this.groups.map((g) => {
            const pct = g.total ? Math.round((100 * g.complete) / g.total) : 0;
            const amber = pct < 60;
            return {
                key: g.category, name: g.category, count: `${g.complete} / ${g.total}`,
                tileStyle: `border:1px solid ${amber ? '#F0DFB6' : '#EDEDED'};background:${amber ? '#FDF8EC' : '#FAFAFA'};border-radius:9px;padding:13px 14px`
            };
        });
    }
}
