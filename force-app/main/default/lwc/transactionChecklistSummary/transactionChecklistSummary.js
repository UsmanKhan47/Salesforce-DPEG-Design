import { LightningElement, api, wire } from 'lwc';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';

// Sidebar card: overall completion across every task group on this Transaction.
// (Relocated out of transactionTaskGroups so the Tasks tab can lead with the phase buttons.)
export default class TransactionChecklistSummary extends LightningElement {
    @api recordId;
    _data = [];
    error;

    @wire(getTaskGroups, { transactionId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get hasError() {
        return !!this.error;
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load the checklist summary.';
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