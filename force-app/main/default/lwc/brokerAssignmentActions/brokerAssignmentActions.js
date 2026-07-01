import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import logCheckIn from '@salesforce/apex/BrokerAssignmentController.logCheckIn';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

export default class BrokerAssignmentActions extends LightningElement {
    @api recordId;
    d;
    _wire;
    @track replacing = false;
    @track repBrokerId;
    @track repDate;
    _saving = false;

    @wire(getDetail, { assignmentId: '$recordId' })
    wired(result) {
        this._wire = result;
        if (result.data) {
            this.d = result.data;
        }
    }
    @wire(getBrokerOptions) brokerOpts;

    // ---------- context getters ----------
    get hasData() { return !!this.d; }
    get propertyName() { return (this.d && this.d.propertyName) || '—'; }
    get brokerName() { return (this.d && this.d.brokerName) || '—'; }

    // ---------- action gating ----------
    get canReplace() { return !!(this.d && this.d.status === 'Active'); }

    // ---------- refresh after mutations ----------
    async refresh() {
        await refreshApex(this._wire);
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
    }

    // ---------- actions ----------
    async handleLogCheckIn() {
        if (this._saving) return;
        this._saving = true;
        try {
            await logCheckIn({ assignmentId: this.recordId });
            await this.refresh();
        } finally {
            this._saving = false;
        }
    }
    openReplace() {
        this.replacing = true;
        this.repBrokerId = null;
        this.repDate = null;
    }
    closeReplace() { this.replacing = false; }
    async confirmReplace() {
        if (this._saving || !this.repBrokerId) return;
        this._saving = true;
        try {
            await replaceBroker({
                assignmentId: this.recordId,
                newBrokerId: this.repBrokerId,
                effectiveDate: this.repDate
            });
            this.replacing = false;
            await this.refresh();
        } finally {
            this._saving = false;
        }
    }

    // ---------- modal option lists & handlers ----------
    get brokerOptionList() {
        return ((this.brokerOpts && this.brokerOpts.data) || []).map((o) => ({ label: o.label, value: o.id }));
    }
    onRepBroker(e) { this.repBrokerId = e.detail.value; }
    onRepDate(e) { this.repDate = e.target.value; }
    get replaceNote() {
        return `This listing stays Active — ${this.brokerName} is replaced by the incoming broker, whose tenure starts on the effective date.`;
    }
}
