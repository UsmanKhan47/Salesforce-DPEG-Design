import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getWire from '@salesforce/apex/WireController.getWire';
import saveWire from '@salesforce/apex/WireController.saveWire';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class WireVerification extends LightningElement {
    @api recordId;
    _wired;
    _wireData;
    isSaving = false;

    // form state
    verbalChecked = false;
    verifierName = '';
    verifierPhone = '';
    wireSource = '';
    confirmedAmount = null;

    @wire(getWire, { dispositionId: '$recordId' })
    wiredWire(result) {
        this._wired = result;
        if (result.data) {
            const d = result.data;
            this._wireData = d;
            this.verbalChecked = d.verbalVerificationCompleted || false;
            this.verifierName  = d.verifierName || '';
            this.verifierPhone = d.verifierPhone || '';
            this.wireSource    = d.wireInstructionsSource || '';
            this.confirmedAmount = d.confirmedWireAmount || null;
        }
    }

    get fieldsComplete()    { return this._wireData ? this._wireData.fieldsComplete : 0; }
    get saveLabel()         { return this.isSaving ? 'Saving…' : 'Save'; }
    get progressBadgeStyle() {
        return this.fieldsComplete === 6
            ? 'background:#e6f4ea;color:#2e7d32'
            : 'background:#fef3c7;color:#92400e';
    }
    get verifiedDateTimeLabel() {
        if (this._wireData?.verifiedDateTime) {
            const dt = new Date(this._wireData.verifiedDateTime);
            const m = MONTHS[dt.getMonth()];
            return m + ' ' + dt.getDate() + ', ' + dt.getFullYear()
                + ' ' + dt.toTimeString().slice(0, 5);
        }
        return 'Waiting for field 1 checkbox…';
    }

    onVerbalChange(e) { this.verbalChecked = e.target.checked; }
    onNameChange(e)   { this.verifierName  = e.target.value; }
    onPhoneChange(e)  { this.verifierPhone = e.target.value; }
    onSourceChange(e) { this.wireSource    = e.target.value; }
    onAmountChange(e) { this.confirmedAmount = e.target.value ? parseFloat(e.target.value) : null; }

    handleSave() {
        this.isSaving = true;
        saveWire({
            dispositionId: this.recordId,
            wireId: this._wireData?.id || null,
            verbalDone: this.verbalChecked,
            verifierName: this.verifierName || null,
            verifierPhone: this.verifierPhone || null,
            wireSource: this.wireSource || null,
            confirmedAmount: this.confirmedAmount
        })
        .then(() => refreshApex(this._wired))
        .finally(() => { this.isSaving = false; });
    }
}