import { LightningElement, api, wire } from 'lwc';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

export default class BackupBrokers extends LightningElement {
    @api recordId;
    _data;

    @wire(getSubmissions, { dispositionId: '$recordId' })
    wired({ data }) { if (data) this._data = data; }

    get rows() {
        if (!this._data) return [];
        return this._data
            .filter(r => !r.isSelected)
            .map(r => ({
                id: r.id,
                brokerFirm: r.brokerFirm || '—',
                contactName: r.contactName || '—',
                bovScore: r.bovScore != null ? r.bovScore : '—',
                bovAmountLabel: r.bovAmount != null
                    ? '$' + (parseFloat(r.bovAmount) / 1000000).toFixed(1) + 'M' : '—'
            }));
    }

    get isEmpty() { return this.rows.length === 0; }
}