import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import STAGE_FIELD from '@salesforce/schema/Disposition__c.Disposition_Stage__c';

export default class DispositionSidebar extends LightningElement {
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
    get isClosing()       { return this._stage === 'Closing'; }

    /**
     * Stages at which the sidebar shows the disposition-offer card.
     *
     * Previously 'Active Listing' ONLY, which left the sidebar empty at exactly the stages
     * where offers are actually being taken. Disposition_Offer__c already exists and is
     * fully built, so covering the offer-bearing stages costs nothing.
     *
     * ⚠ NO RECORD-TYPE CHECK, AND NONE IS NEEDED. The two record types' stage value sets
     * are DISJOINT for every path-specific stage: 'Call for Offers' exists only on
     * On_Market and 'Disposition Offer' only on Off_Market, so the stage alone already
     * identifies the path. Adding a getObjectInfo/RecordTypeId wire here would buy nothing
     * and add a second source of truth to keep in step. Revisit only if a SHARED stage
     * (Readiness / LOI / PSA / Closing / Completed) ever has to render differently per path.
     *
     * ⚠ 'LOI' IS INCLUDED FOR A DIFFERENT REASON THAN IT USED TO BE — corrected at the
     * Tranche 3B close-out (2026-08-09). This comment previously said the negotiation "is
     * still recorded on Disposition_Offer__c's counter fields". THAT IS NO LONGER TRUE and
     * must not be quoted: decision D6 moved the sell-side negotiation onto LOI__c's
     * Disposition_LOI record type, where each round is a Counter_Offer__c shown by
     * lwc/loiCounterOffer on the LOI record page. Per D15/Q2 the offer keeps only 'Received'
     * — its genuine arrival state — and its four LOI-shaped statuses plus the
     * DPEG_Counter_Price__c / Buyer_Counter_Price__c / Final_Agreed_Price__c fields are
     * retiring. Disposition_Offer__c is now CAPTURE AND COMPARISON ONLY.
     *
     * The stage stays in this list anyway, and deliberately: at 'LOI' a disposition user
     * still needs to see WHICH offer the LOI came from, and the offer card is the only
     * surface that lists the offers side by side. Read it as "the offers are still relevant
     * here", not as "the negotiation happens here".
     *
     * 'PSA' is excluded because at that stage the only marker is PSA_Executed__c on the
     * Disposition itself and the record page falls back to the Details section. Neither
     * stage gets a placeholder component (Gate 1 Q5).
     */
    get isOfferStage() {
        return (
            this._stage === 'Active Listing' ||
            this._stage === 'Call for Offers' ||
            this._stage === 'Disposition Offer' ||
            this._stage === 'LOI'
        );
    }
}