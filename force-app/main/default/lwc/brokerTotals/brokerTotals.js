import { LightningElement, wire } from 'lwc';
import getBrokerTotals from '@salesforce/apex/BrokerAssignmentController.getBrokerTotals';

export default class BrokerTotals extends LightningElement {
    _data = [];
    @wire(getBrokerTotals) wired({ data }) { if (data) this._data = data; }
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
