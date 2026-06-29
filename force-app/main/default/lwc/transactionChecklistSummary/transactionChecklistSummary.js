import { LightningElement, api, wire } from 'lwc';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';

// Sidebar card: overall completion across every task group on this Transaction.
// (Relocated out of transactionTaskGroups so the Tasks tab can lead with the phase buttons.)
export default class TransactionChecklistSummary extends LightningElement {
    @api recordId;
    _data = [];

    @wire(getTaskGroups, { transactionId: '$recordId' })
    wired({ data }) {
        if (data) {
            this._data = data;
        }
    }

    get overall() {
        const total = this._data.reduce((s, g) => s + (g.total || 0), 0);
        const complete = this._data.reduce((s, g) => s + (g.complete || 0), 0);
        const pct = total ? Math.round((complete / total) * 100) : 0;
        return {
            pctLabel: total ? `${pct}%` : '—',
            label: total ? `${complete} of ${total} complete` : 'No checklist generated yet',
            barStyle: `width:${pct}%;background:${pct >= 100 ? '#2e7d32' : '#2BAFAC'}`
        };
    }
}