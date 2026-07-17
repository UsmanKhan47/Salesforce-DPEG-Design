import { LightningElement, api, wire } from 'lwc';
import { formatLongDate } from 'c/utils';
import getOutreachSummary from '@salesforce/apex/BovController.getOutreachSummary';

export default class BovOutreach extends LightningElement {
    @api recordId;
    summary;

    // NDA status shown in the footer row. Hard-set to 'Signed' for now; swap to
    // 'Received' / 'Pending' (or wire to the NDA record) when the data is available.
    _ndaStatus = 'Signed';

    @wire(getOutreachSummary, { dispositionId: '$recordId' })
    wired({ data }) { if (data) this.summary = data; }

    get ndaStatus() { return this._ndaStatus; }
    get ndaPillClass() {
        const cls = { Signed: 'nda-signed', Received: 'nda-received', Pending: 'nda-pending' };
        return 'nda-pill ' + (cls[this._ndaStatus] || 'nda-pending');
    }

    get packageSentLabel()        { return formatLongDate(this.summary?.packageSent); }
    get submissionDeadlineLabel() { return formatLongDate(this.summary?.submissionDeadline); }
    get selectedBrokerLabel()     { return this.summary?.selectedBroker || 'TBD'; }

    get stats() {
        const s = this.summary || {};
        return [
            { key: 'pkg',  label: 'Package Sent',        value: this.packageSentLabel,        iconName: 'utility:upload', iconColor: '#5a6b7b' },
            { key: 'dl',   label: 'Submission Deadline', value: this.submissionDeadlineLabel, iconName: 'utility:event',  iconColor: '#1565c0' },
            { key: 'resp', label: 'Responses Received',  value: `${s.responsesReceived ?? 0} of ${s.brokersContacted ?? 0}`, iconName: 'utility:reply', iconColor: '#2BAFAC' },
            { key: 'brk',  label: 'Selected Broker',     value: this.selectedBrokerLabel,     iconName: 'utility:user',   iconColor: '#5a6b7b' }
        ];
    }
}