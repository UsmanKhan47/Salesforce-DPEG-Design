import { LightningElement, api, wire } from 'lwc';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

// Sidebar card: overall completion across every checklist category on this Onboarding.
// Mirrors transactionChecklistSummary's layout.
export default class OnboardingChecklistProgress extends LightningElement {
    @api recordId;
    groups = [];
    @wire(getChecklist, { onboardingId: '$recordId' }) wired({ data }) { if (data) this.groups = data; }
    get overall() {
        let total = 0, complete = 0;
        this.groups.forEach((g) => { total += g.total; complete += g.complete; });
        const pct = total ? Math.round((100 * complete) / total) : 0;
        return {
            pctLabel: total ? `${pct}%` : '—',
            label: total ? `${complete} of ${total} complete` : 'No checklist generated yet',
            barStyle: `width:${pct}%;background:${pct >= 100 ? '#2e7d32' : '#2BAFAC'}`
        };
    }
}
