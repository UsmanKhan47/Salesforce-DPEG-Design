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

    /**
     * Show the closing cards (wire verification + checklist) through the TERMINAL stage too, so a
     * finished deal displays its final closing state rather than an empty main area.
     *
     * ⚠ THE TERMINAL STAGE IS NOW 'Sale Closes'. This getter used to name 'Completed', which the
     * disposition flow redesign RETIRED, together with `Call for Offers` and `Disposition Offer`.
     *
     * ⚠ RETIRED IS NOT THE SAME AS GONE, AND THIS COMMENT PREVIOUSLY OVERSTATED BOTH HALVES
     * (corrected 2026-08-19, code review S-3). Neither of the following has happened yet:
     *   1. The three values have NOT been removed from `Disposition_Stage__c`. They are still in
     *      the field, PARKED at positions 12 to 14 behind the real terminal value, awaiting a
     *      MANUAL Setup deletion wave. A Metadata API deploy cannot delete a picklist value; it
     *      merges the local and remote value sets and puts deleted values straight back. See the
     *      in-file note at the top of
     *      objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml.
     *   2. NOTHING WAS MIGRATED. The org sweep found ZERO rows on any of the three values, so
     *      there was no data to move. The absence of a migration here is a measurement, not a
     *      pending task.
     *
     * Because the values still exist, the org CAN in principle still produce 'Completed' (by API,
     * seed or data load) until the manual wave lands, so this getter naming only the live terminal
     * value is deliberate: a record parked on a retired value should fall out of the closing view
     * and be visible as wrong, not be quietly accommodated. Once the wave lands, a stale
     * 'Completed' comparison would fail silently instead: the branch would never fire and the
     * closing cards would vanish the moment a deal finished. Both are reasons to name the retired
     * value here rather than quietly delete the mention.
     *
     * ⚠ NO RECORD-TYPE TEST, AND NONE IS NEEDED — but not for the reason the sidebar's old comment
     * gave. Both of these stages exist on BOTH record types and render identically on both, so the
     * path is simply irrelevant to this decision. Contrast `isActiveListing`, which is an ON-MARKET
     * stage: it needs no test either, because Off-Market records can never reach the value.
     */
    get isClosing()       { return this._stage === 'Closing' || this._stage === 'Sale Closes'; }
}