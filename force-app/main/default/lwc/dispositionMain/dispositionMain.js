import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import STAGE_FIELD from '@salesforce/schema/Disposition__c.Disposition_Stage__c';

export default class DispositionMain extends LightningElement {
    @api recordId;
    _stage;
    _error;

    @wire(getRecord, { recordId: '$recordId', fields: [STAGE_FIELD] })
    wiredRecord({ data, error }) {
        if (data) {
            this._stage = getFieldValue(data, STAGE_FIELD);
            this._error = undefined;
        } else if (error) {
            this._error = error;
            this._stage = undefined;
        }
    }

    get hasError() { return !!this._error; }
    get errorMessage() {
        return (this._error && this._error.body && this._error.body.message) || 'Unknown error';
    }

    get isBovOutreach()   { return this._stage === 'BOV Outreach'; }
    get isActiveListing() { return this._stage === 'Active Listing'; }
    // Show the closing cards (wire + checklist) through Completed, so a finished deal
    // displays its final closing state rather than an empty main area.
    get isClosing()       { return this._stage === 'Closing' || this._stage === 'Completed'; }
}