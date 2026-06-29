import { LightningElement, wire } from 'lwc';
import getTaskSummary from '@salesforce/apex/TransactionController.getTaskSummary';

// Overall task posture across Active transactions (Total / Pending / At Risk / Wire).
const META = [
    { key: 'totalTasks',   label: 'Total Tasks', iconName: 'utility:task' },
    { key: 'pendingTasks', label: 'Pending',     iconName: 'utility:clock' },
    { key: 'overdueTasks', label: 'At Risk',     iconName: 'utility:warning', risk: 'amber' },
    { key: 'wireTasks',    label: 'Wire Tasks',  iconName: 'utility:shield',  risk: 'red', goodWhenZero: true }
];

export default class TransactionTaskCards extends LightningElement {
    summary;

    @wire(getTaskSummary)
    wired({ data }) {
        if (data) {
            this.summary = data;
        }
    }

    get stats() {
        const s = this.summary || {};
        return META.map((m) => {
            const value = s[m.key] != null ? s[m.key] : 0;
            // Risk icons only "light up" when there's something to act on; a clean wire count reads green.
            let iconColor = '#1565c0';
            if (m.key === 'pendingTasks') iconColor = '#5a6b7b';
            else if (m.risk === 'amber') iconColor = value > 0 ? '#bf5d0a' : '#5a6b7b';
            else if (m.risk === 'red') iconColor = value > 0 ? '#c23934' : '#2e7d32';
            return {
                key: m.key,
                label: m.label,
                iconName: m.iconName,
                iconColor,
                value: String(value)
            };
        });
    }
}