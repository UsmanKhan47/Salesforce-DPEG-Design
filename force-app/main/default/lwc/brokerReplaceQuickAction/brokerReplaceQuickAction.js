import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

const REASONS = ['Leased Up', 'Performance Issue', 'Company Decision', 'Other'];

// Screen-action quick action on Broker_Assignment__c. Mirrors the sidebar
// brokerAssignmentActions "Replace Broker" flow: closes the current listing as
// Disposed and opens a new Active listing for the incoming broker. Only valid
// for Active listings.
export default class BrokerReplaceQuickAction extends LightningElement {
    @api recordId;
    d;
    repBrokerId;
    repReason = 'Performance Issue';
    repDate;
    error;
    _saving = false;

    @wire(getDetail, { assignmentId: '$recordId' })
    wired({ data }) { if (data) this.d = data; }
    @wire(getBrokerOptions) brokerOpts;

    get hasData() { return !!this.d; }
    get isActive() { return !!(this.d && this.d.status === 'Active'); }
    get status() { return (this.d && this.d.status) || ''; }
    get propertyName() { return (this.d && this.d.propertyName) || '—'; }
    get brokerName() { return (this.d && this.d.brokerName) || '—'; }
    get reasonOptions() { return REASONS.map((r) => ({ label: r, value: r })); }
    get brokerOptionList() {
        return ((this.brokerOpts && this.brokerOpts.data) || []).map((o) => ({ label: o.label, value: o.id }));
    }
    get replaceNote() {
        return `${this.brokerName}'s listing is closed as Disposed — the full record stays visible — and a new Active listing opens for the incoming broker.`;
    }
    get confirmDisabled() { return this._saving || !this.repBrokerId; }

    onRepBroker(e) { this.repBrokerId = e.detail.value; }
    onRepReason(e) { this.repReason = e.detail.value; }
    onRepDate(e) { this.repDate = e.target.value; }

    close() { this.dispatchEvent(new CloseActionScreenEvent()); }

    async confirm() {
        if (this.confirmDisabled) return;
        this._saving = true;
        this.error = undefined;
        try {
            await replaceBroker({
                assignmentId: this.recordId,
                newBrokerId: this.repBrokerId,
                effectiveDate: this.repDate,
                reason: this.repReason
            });
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({
                title: 'Broker replaced',
                message: 'A new active listing has been opened for the incoming broker.',
                variant: 'success'
            }));
            this.close();
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Something went wrong replacing the broker.';
        } finally {
            this._saving = false;
        }
    }
}
