import { LightningElement, api, wire } from 'lwc';
import { formatLongDate } from 'c/utils';
import getOutreachSummary from '@salesforce/apex/BovController.getOutreachSummary';

export default class BovOutreach extends LightningElement {
    @api recordId;
    summary;
    loadError;

    @wire(getOutreachSummary, { dispositionId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.summary = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = 'Couldn\'t load the BOV outreach summary.';
            this.summary = undefined;
        }
    }

    /**
     * The real NDA status for this disposition, from the most recent related NDA__c.
     *
     * ⚠ This used to be a hard-coded `_ndaStatus = 'Signed'`, which reported a COMPLIANCE
     * state as satisfied on every disposition whether or not an NDA existed. Do not
     * reintroduce a default value here: a missing NDA must read as missing.
     *
     * Apex returns null both when there is genuinely no NDA and when the NDA read degraded
     * (BovController fails that read soft so a missing FLS grant cannot blank the whole
     * tile). Both render as 'No NDA' — the honest answer in either case is that we cannot
     * show a signed NDA.
     */
    get ndaStatus() { return this.summary?.ndaStatus || 'No NDA'; }

    /**
     * Pill colour by status. 'Sent' maps to the amber `nda-received` class — the CSS class
     * names predate the picklist and were not renamed here (NDA__c is out of scope for this
     * change). Anything unrecognised, including null / 'No NDA', falls back to the neutral
     * pending style, so a value added to NDA__c.Status__c later degrades gracefully instead
     * of rendering an unstyled pill.
     */
    get ndaPillClass() {
        const cls = { Signed: 'nda-signed', Sent: 'nda-received', Received: 'nda-received', Pending: 'nda-pending' };
        return 'nda-pill ' + (cls[this.summary?.ndaStatus] || 'nda-pending');
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