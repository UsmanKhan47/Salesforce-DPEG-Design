import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getLog from '@salesforce/apex/LeaseInquiryController.getLog';
import addUpdate from '@salesforce/apex/LeaseInquiryController.addUpdate';

const BALLS = ['Landlord', 'Tenant', 'Legal', 'Construction', 'Broker'];

// Append-only negotiation history on the Lease Inquiry record page. Mirrors the
// prototype timeline: entries newest-first with ball-in-court badges and a "Latest"
// marker, plus an "Add Update" composer that sets the ball and can advance the stage.
export default class LeaseNegotiationLog extends LightningElement {
    @api recordId;
    _wired;
    view;
    adding = false;
    upDetails = '';
    upBall = '';
    error = '';

    @wire(getLog, { inquiryId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.view = result.data;
        }
    }

    get hasData() {
        return !!this.view;
    }
    get count() {
        return this.view && this.view.entries ? this.view.entries.length : 0;
    }
    get canLog() {
        return this.view && !this.view.closed;
    }
    get ballOptions() {
        return BALLS.map((b) => ({ label: b, value: b }));
    }

    get entries() {
        const rows = (this.view && this.view.entries) || [];
        return rows.map((e, i) => ({
            id: e.id,
            details: e.details,
            enteredBy: e.enteredBy || '—',
            ball: e.ball || '—',
            ballClass: 'lnl-ball lnl-ball--' + String(e.ball || 'Landlord').toLowerCase(),
            entryDate: e.entryDate,
            isLatest: i === 0,
            showLine: i < rows.length - 1,
            markerClass: i === 0 ? 'lnl-marker lnl-marker--latest' : 'lnl-marker'
        }));
    }

    openComposer() {
        this.adding = true;
        this.upDetails = '';
        this.upBall = '';
        this.error = '';
    }
    cancel() {
        this.adding = false;
        this.error = '';
    }
    onDetails(e) {
        this.upDetails = e.detail.value;
        this.error = '';
    }
    onBall(e) {
        this.upBall = e.detail.value;
    }

    save() {
        if (!this.upDetails || !this.upDetails.trim()) {
            this.error = 'Enter what changed before saving.';
            return;
        }
        if (!this.upBall) {
            this.error = 'Choose who the ball is in court with.';
            return;
        }
        addUpdate({
            inquiryId: this.recordId,
            details: this.upDetails,
            ball: this.upBall,
            advance: false
        })
            .then(() => {
                this.adding = false;
                // Refresh the record so the Path + highlights reflect the new stage/ball live.
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                return refreshApex(this._wired);
            })
            .then(() => {
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'Update added to the log', variant: 'success' })
                );
            })
            .catch((e) => {
                this.error = (e && e.body && e.body.message) || 'Unexpected error';
            });
    }
}
