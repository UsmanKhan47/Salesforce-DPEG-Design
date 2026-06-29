import { LightningElement, api, wire } from 'lwc';
import getClosingSummary from '@salesforce/apex/DispositionController.getClosingSummary';

export default class DispositionClosing extends LightningElement {
    @api recordId;
    row;

    @wire(getClosingSummary, { dispositionId: '$recordId' })
    wired({ data }) { if (data) this.row = data; }

    get psaLabel()             { return this.row?.psaExecuted ? 'Executed' : 'Pending'; }
    get titleLabel()           { return this.row?.titleCompany || 'TBD'; }
    get closingStatementLabel(){ return this.row?.closingStatementUploaded ? 'Uploaded' : 'Not uploaded'; }
    get wireLabel()            { return this.row?.wireCreated ? 'Created' : 'Not created'; }

    get stats() {
        const r = this.row || {};
        return [
            { key: 'psa',     label: 'PSA Executed',      value: this.psaLabel,              iconName: 'utility:contract', iconColor: r.psaExecuted ? '#2e7d32' : '#b45309' },
            { key: 'title',   label: 'Title Company',     value: this.titleLabel,            iconName: 'utility:company',  iconColor: '#5a6b7b' },
            { key: 'closing', label: 'Closing Statement', value: this.closingStatementLabel, iconName: 'utility:file',     iconColor: r.closingStatementUploaded ? '#2e7d32' : '#b91c1c' },
            { key: 'wire',    label: 'Wire',              value: this.wireLabel,             iconName: 'utility:money',    iconColor: r.wireCreated ? '#2e7d32' : '#b91c1c' }
        ];
    }
}