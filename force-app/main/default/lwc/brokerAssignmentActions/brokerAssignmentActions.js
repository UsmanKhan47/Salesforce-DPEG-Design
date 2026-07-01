import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import logCheckIn from '@salesforce/apex/BrokerAssignmentController.logCheckIn';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

const REASONS = ['Leased Up', 'Performance Issue', 'Company Decision', 'Other'];

export default class BrokerAssignmentActions extends LightningElement {
    @api recordId;
    d;
    _wire;
    @track replacing = false;
    @track repBrokerId;
    @track repReason = 'Performance Issue';
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
        this.repReason = 'Performance Issue';
        this.repDate = null;
    }
    closeReplace() { this.replacing = false; }
    async confirmReplace() {
        if (this._saving) return;
        this._saving = true;
        try {
            await replaceBroker({
                assignmentId: this.recordId,
                newBrokerId: this.repBrokerId,
                effectiveDate: this.repDate,
                reason: this.repReason
            });
            this.replacing = false;
            await this.refresh();
        } finally {
            this._saving = false;
        }
    }

    // ---------- modal option lists & handlers ----------
    get reasonOptions() { return REASONS.map((r) => ({ label: r, value: r })); }
    get brokerOptionList() {
        return ((this.brokerOpts && this.brokerOpts.data) || []).map((o) => ({ label: o.label, value: o.id }));
    }
    onRepBroker(e) { this.repBrokerId = e.detail.value; }
    onRepReason(e) { this.repReason = e.detail.value; }
    onRepDate(e) { this.repDate = e.target.value; }
    get replaceNote() {
        return `${this.brokerName}'s listing is closed as Disposed — the full record stays visible — and a new Active listing opens for the incoming broker.`;
    }
}
