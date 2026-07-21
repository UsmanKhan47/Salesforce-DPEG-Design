import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTimeline from '@salesforce/apex/LeaseRenewalController.getTimeline';
import addUpdate from '@salesforce/apex/LeaseRenewalController.addUpdate';

const METHOD_META = {
    Call:   { fg: '#1A4880', bg: '#EBF3FC' },
    Email:  { fg: '#7A4A00', bg: '#FDF5E6' },
    Visit:  { fg: '#4A2A7A', bg: '#F3EEFB' },
    Note:   { fg: '#132850', bg: '#E8EFF7' },
    System: { fg: '#5A5752', bg: '#EDEBE7' }
};
const badge = (m) => {
    const x = METHOD_META[m] || METHOD_META.Note;
    return `display:inline-flex;align-items:center;font-size:10px;font-weight:700;letter-spacing:0.03em;text-transform:uppercase;padding:2px 7px;border-radius:9999px;background:${x.bg};color:${x.fg}`;
};

// Append-only renewal timeline: entries newest-first with method badges, a
// non-responsive pill in the header, and a Log Follow-Up composer (method +
// outcome both mandatory). Mirrors the leaseNegotiationLog patterns.
export default class RenewalTimeline extends LightningElement {
    @api recordId;
    _wired;
    view;
    adding = false;
    upMethod = '';
    upDetails = '';
    error = '';        // composer (save) error
    loadError;         // timeline wire (read) error — kept separate from the composer error

    @wire(getTimeline, { renewalId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.view = result.data;
            this.loadError = undefined;
        } else if (result.error) {
            this.loadError = result.error;
        }
    }

    get hasLoadError() { return !!this.loadError; }
    get loadErrorMessage() {
        const e = this.loadError;
        return (e && e.body && e.body.message) || 'Unable to load the renewal timeline.';
    }

    get count() { return this.view && this.view.entries ? this.view.entries.length : 0; }
    get canLog() { return this.view && this.view.canLog; }
    get nonResponsive() { return !!(this.view && this.view.nonResponsive); }
    get silentText() { return `Non-responsive · ${this.view.daysSinceContact}d silent`; }
    get methodOptions() {
        // "System" is reserved for seeded/Yardi entries — humans pick a real touch.
        return ['Call', 'Email', 'Visit', 'Note'].map((m) => ({ label: m, value: m }));
    }

    get entries() {
        const rows = (this.view && this.view.entries) || [];
        return rows.map((e, i) => ({
            id: e.id,
            details: e.details,
            enteredBy: e.enteredBy || '—',
            method: e.method || 'Note',
            methodStyle: badge(e.method),
            entryDate: e.entryDate,
            isLatest: i === 0,
            showLine: i < rows.length - 1,
            markerClass: i === 0 ? 'rt-marker rt-marker--latest' : 'rt-marker'
        }));
    }

    openComposer() { this.adding = true; this.upMethod = ''; this.upDetails = ''; this.error = ''; }
    cancel() { this.adding = false; this.error = ''; }
    onDetails(e) { this.upDetails = e.detail.value; this.error = ''; }
    onMethod(e) { this.upMethod = e.detail.value; }

    save() {
        if (!this.upMethod) { this.error = 'Choose how the tenant was contacted.'; return; }
        if (!this.upDetails || !this.upDetails.trim()) { this.error = 'Enter the outcome before saving.'; return; }
        addUpdate({ renewalId: this.recordId, method: this.upMethod, details: this.upDetails })
            .then(() => {
                this.adding = false;
                // Refresh the record so highlights/detail (Last Contact, flags) update live.
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                return refreshApex(this._wired);
            })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({ title: 'Follow-up logged to the timeline', variant: 'success' }));
            })
            .catch((e) => {
                this.error = (e && e.body && e.body.message) || 'Unexpected error';
            });
    }
}