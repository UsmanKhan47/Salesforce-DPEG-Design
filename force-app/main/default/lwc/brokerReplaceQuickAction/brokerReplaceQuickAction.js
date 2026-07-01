import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

// Screen-action quick action on Broker_Assignment__c. Swaps the broker on the
// current listing in place — the listing stays Active and the incoming broker's
// tenure starts on the effective date. Only valid for Active listings.
export default class BrokerReplaceQuickAction extends LightningElement {
    @api recordId;
    d;
    repBrokerId;
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
    get brokerOptionList() {
        return ((this.brokerOpts && this.brokerOpts.data) || []).map((o) => ({ label: o.label, value: o.id }));
    }
    get replaceNote() {
        return `This listing stays Active — ${this.brokerName} is replaced by the incoming broker, whose tenure starts on the effective date.`;
    }
    get confirmDisabled() { return this._saving || !this.repBrokerId; }

    onRepBroker(e) { this.repBrokerId = e.detail.value; }
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
                effectiveDate: this.repDate
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
