import { LightningElement, api, wire } from 'lwc';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

// One tile per checklist category (mirrors transactionPhaseCards, which does one per deal phase).
// Uses the shared c-onboarding-card-child tile for an identical look.
const ICONS = {
    'Property Set up': 'utility:setup',
    'Unit & Tenant Setup': 'utility:people',
    'Vendor & Expense Management': 'utility:money',
    'NNN Reconciliation & Billing Setup': 'utility:percent',
    'Tenant Communication & Transition': 'utility:email',
    'Performance Tracking': 'utility:metrics',
    'Leasing': 'utility:contract'
};

export default class OnboardingTaskProgressByCategory extends LightningElement {
    @api recordId;
    groups = [];
    @wire(getChecklist, { onboardingId: '$recordId' }) wired({ data }) { if (data) this.groups = data; }
    get cards() {
        return this.groups.map((g) => {
            const done = g.total > 0 && g.complete >= g.total;
            return {
                key: g.category,
                label: g.category,
                value: `${g.complete} / ${g.total}`,
                iconName: ICONS[g.category] || 'utility:task',
                iconColor: done ? '#2e7d32' : '#1565c0',
                done
            };
        });
    }
}