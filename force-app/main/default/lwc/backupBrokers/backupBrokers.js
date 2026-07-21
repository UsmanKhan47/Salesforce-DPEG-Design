import { LightningElement, api, wire } from 'lwc';
import { formatMillions } from 'c/utils';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

export default class BackupBrokers extends LightningElement {
    @api recordId;
    _data;
    loadError;

    @wire(getSubmissions, { dispositionId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = 'Couldn\'t load backup brokers.';
            this._data = [];
        }
    }

    get rows() {
        if (!this._data) return [];
        return this._data
            .filter(r => !r.isSelected)
            .map(r => ({
                id: r.id,
                brokerFirm: r.brokerFirm || '—',
                contactName: r.contactName || '—',
                bovScore: r.bovScore != null ? r.bovScore : '—',
                bovAmountLabel: formatMillions(r.bovAmount)
            }));
    }

    get isEmpty() { return !this.loadError && this.rows.length === 0; }
}