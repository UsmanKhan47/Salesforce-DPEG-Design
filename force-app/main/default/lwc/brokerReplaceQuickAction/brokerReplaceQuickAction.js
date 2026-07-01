import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import STATUS from '@salesforce/schema/Broker_Assignment__c.Status__c';
import BROKER_NAME from '@salesforce/schema/Broker_Assignment__c.Broker_Name__c';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

const REASONS = ['Leased Up', 'Performance Issue', 'Company Decision', 'Other'];

// Screen-action quick action on Broker_Assignment__c. Swaps the broker on the
// current listing in place — the listing stays Active and the incoming broker's
// tenure starts on the effective date. The outgoing broker is snapshotted into
// history with the reason + notes captured here. Gated to Active listings, read
// from the live LDS record (getRecord) so a just-changed status is always current.
export default class BrokerReplaceQuickAction extends LightningElement {
    @api recordId;
    _rec;
    repBrokerId;
    repDate;
    repReason;
    repNotes;
    error;
    _saving = false;

    @wire(getRecord, { recordId: '$recordId', fields: [STATUS, BROKER_NAME] })
    wired(result) { this._rec = result; }
    @wire(getBrokerOptions) brokerOpts;

    get hasData() { return !!(this._rec && this._rec.data); }
    get status() { return this.hasData ? getFieldValue(this._rec.data, STATUS) : ''; }
    get isActive() { return this.status === 'Active'; }
    get brokerName() { return (this.hasData && getFieldValue(this._rec.data, BROKER_NAME)) || '—'; }
    get brokerOptionList() {
        return ((this.brokerOpts && this.brokerOpts.data) || []).map((o) => ({ label: o.label, value: o.id }));
    }
    get reasonOptions() { return REASONS.map((r) => ({ label: r, value: r })); }
    get replaceNote() {
        return `This listing stays Active — ${this.brokerName} is replaced by the incoming broker. ${this.brokerName}'s stint is saved to history with the reason and notes below.`;
    }
    get confirmDisabled() { return this._saving || !this.repBrokerId; }

    onRepBroker(e) { this.repBrokerId = e.detail.value; }
    onRepDate(e) { this.repDate = e.target.value; }
    onRepReason(e) { this.repReason = e.detail.value; }
    onRepNotes(e) { this.repNotes = e.target.value; }

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
                reason: this.repReason,
                notes: this.repNotes
            });
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({
                title: 'Broker replaced',
                message: 'This listing now shows the incoming broker and stays Active.',
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
