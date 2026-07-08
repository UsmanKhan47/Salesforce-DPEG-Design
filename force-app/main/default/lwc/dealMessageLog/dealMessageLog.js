import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMessages from '@salesforce/apex/DealMessageController.getMessages';
import addMessage from '@salesforce/apex/DealMessageController.addMessage';

const METHOD_ICONS = {
    Call: 'utility:call',
    Email: 'utility:email',
    Meeting: 'utility:groups',
    Note: 'utility:note'
};

// Append-only communication tracker shared by the LOI, Underwriting, and
// Contract Review record pages (Messages tab). Mirrors the Lease Activity /
// Lease Renewal timeline: entries newest-first with method + direction badges,
// plus a composer that never edits or erases history. The parent object is
// derived server-side from the record Id.
export default class DealMessageLog extends LightningElement {
    @api recordId;
    // Card heading — configurable per page (e.g. "Counter History" on the LOI /
    // Underwriting sidebar), defaults to "Messages" where not set.
    @api cardTitle = 'Messages';
    _wired;
    messages;
    adding = false;
    upMethod = 'Note';
    upDirection = 'Internal';
    upDetails = '';
    error = '';

    methodOptions = [
        { label: 'Call', value: 'Call' },
        { label: 'Email', value: 'Email' },
        { label: 'Meeting', value: 'Meeting' },
        { label: 'Note', value: 'Note' }
    ];
    directionOptions = [
        { label: 'Received (from counterparty)', value: 'Received' },
        { label: 'Sent (by us)', value: 'Sent' },
        { label: 'Internal note', value: 'Internal' }
    ];

    @wire(getMessages, { recordId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.messages = result.data;
        }
    }

    get count() {
        return this.messages ? this.messages.length : 0;
    }
    get hasMessages() {
        return this.count > 0;
    }

    get entries() {
        const rows = this.messages || [];
        return rows.map((m, i) => ({
            id: m.id,
            details: m.details,
            enteredBy: m.enteredBy || '—',
            entryDate: m.entryDate,
            method: m.method || 'Note',
            methodIcon: METHOD_ICONS[m.method] || METHOD_ICONS.Note,
            direction: m.direction || 'Internal',
            directionClass: 'dml-dir dml-dir--' + String(m.direction || 'Internal').toLowerCase(),
            isLatest: i === 0,
            showLine: i < rows.length - 1,
            markerClass: i === 0 ? 'dml-marker dml-marker--latest' : 'dml-marker'
        }));
    }

    openComposer() {
        this.adding = true;
        this.upMethod = 'Note';
        this.upDirection = 'Internal';
        this.upDetails = '';
        this.error = '';
    }
    cancel() {
        this.adding = false;
        this.error = '';
    }
    onMethod(e) {
        this.upMethod = e.detail.value;
    }
    onDirection(e) {
        this.upDirection = e.detail.value;
    }
    onDetails(e) {
        this.upDetails = e.detail.value;
        this.error = '';
    }

    save() {
        if (!this.upDetails || !this.upDetails.trim()) {
            this.error = 'Enter what was communicated before saving.';
            return;
        }
        addMessage({
            recordId: this.recordId,
            method: this.upMethod,
            direction: this.upDirection,
            details: this.upDetails
        })
            .then(() => {
                this.adding = false;
                return refreshApex(this._wired);
            })
            .then(() => {
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'Message added to the log', variant: 'success' })
                );
            })
            .catch((e) => {
                this.error = (e && e.body && e.body.message) || 'Unexpected error';
            });
    }
}
