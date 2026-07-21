import { LightningElement, wire } from 'lwc';
import getBrokerTotals from '@salesforce/apex/BrokerAssignmentController.getBrokerTotals';

export default class BrokerTotals extends LightningElement {
    _data = [];
    error;
    @wire(getBrokerTotals) wired({ data, error }) {
        if (data) {
            this._data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this._data = [];
        }
    }
    get hasError() { return !!this.error; }
    get errorMessage() { const e = this.error; return (e && e.body && e.body.message) || 'Unknown error'; }
    get showEmpty() { return !this.hasRows && !this.error; }
    get rows() {
        // _data arrives sorted by total properties desc from the controller, so index = rank.
        return this._data.map((b, i) => ({
            brokerId: b.brokerId,
            rank: i + 1,
            name: b.name || '—',
            firm: b.firm || '',
            total: b.totalProperties || 0,
            rowClass: i === 0 ? 'tb-row tb-row--top' : 'tb-row'
        }));
    }
    get hasRows() { return this.rows.length > 0; }
}