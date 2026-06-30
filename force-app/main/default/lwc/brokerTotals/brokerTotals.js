import { LightningElement, wire } from 'lwc';
import getBrokerTotals from '@salesforce/apex/BrokerAssignmentController.getBrokerTotals';

export default class BrokerTotals extends LightningElement {
    _data = [];
    @wire(getBrokerTotals) wired({ data }) { if (data) this._data = data; }
    initials(name) { return (name || '').split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase(); }
    get rows() {
        return this._data.map(b => ({
            brokerId: b.brokerId, name: b.name || '—', firm: b.firm || '',
            initials: this.initials(b.name), total: b.totalProperties || 0,
            unitLabel: (b.totalProperties === 1) ? 'property' : 'properties'
        }));
    }
    get hasRows() { return this.rows.length > 0; }
}
