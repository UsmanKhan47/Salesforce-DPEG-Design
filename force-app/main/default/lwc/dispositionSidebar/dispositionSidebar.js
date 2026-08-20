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
     * ── 🔴 THE "DISJOINT VALUE SETS" ARGUMENT IS DEAD. DO NOT QUOTE IT. ──────
     * This block used to justify the absence of a record-type check like this:
     *
     *     "The two record types' stage value sets are DISJOINT for every path-specific
     *      stage: 'Call for Offers' exists only on On_Market and 'Disposition Offer' only
     *      on Off_Market, so the stage alone already identifies the path."
     *
     * Both of the values that argument rested on were RETIRED by the disposition flow
     * redesign, and the premise itself is now false in the opposite direction: 'Broker
     * Selection', 'Release Materials', 'Offer Selection' and 'Sale Closes' are all on BOTH
     * record types. THE STAGE VALUE NO LONGER IDENTIFIES THE PATH. Only 'BOV Outreach' and
     * 'Active Listing' (On_Market) remain path-exclusive.
     *
     * ⚠ THERE IS STILL NO RECORD-TYPE CHECK HERE, AND THAT IS STILL CORRECT — but the
     * reason changed completely, so read the new one. The four stages below all render the
     * SAME card with the SAME meaning on both paths: offers are being taken or have just
     * been taken, and the user needs to see them. A getObjectInfo/RecordTypeId wire would
     * buy nothing because there is no per-path DIFFERENCE to express, not because the value
     * happens to imply the path. Add one only when a stage genuinely has to RENDER
     * differently per record type — which is a much narrower trigger than the old comment's.
     *
     * ── WHY EACH STAGE IS IN THE LIST ────────────────────────────────────────
     * 'Active Listing' (On) and 'Release Materials' (Off) are where offers ARRIVE — they are
     * the two stages `DispositionApprovalService.selectOffer` accepts a selection from, one
     * per path.
     *
     * 'Offer Selection' (both) is where an offer has been put forward and is sitting in
     * `Offer_Selection_Approval`. The card is arguably most useful here: a rejected offer
     * parks the disposition at this stage for a RE-PICK, so the user needs the side-by-side
     * list to choose again.
     *
     * ⚠ 'LOI' IS INCLUDED FOR A DIFFERENT REASON THAN IT USED TO BE — corrected at the
     * Tranche 3B close-out (2026-08-09). This comment previously said the negotiation "is
     * still recorded on Disposition_Offer__c's counter fields". THAT IS NO LONGER TRUE and
     * must not be quoted: decision D6 moved the sell-side negotiation onto LOI__c's
     * Disposition_LOI record type, where each round is a Counter_Offer__c shown by
     * lwc/loiCounterOffer on the LOI record page. Disposition_Offer__c is now CAPTURE AND
     * COMPARISON ONLY. The stage stays in this list anyway, and deliberately: at 'LOI' a
     * disposition user still needs to see WHICH offer the LOI came from. Read it as "the
     * offers are still relevant here", not as "the negotiation happens here".
     *
     * 'PSA' is excluded because at that stage the only marker is PSA_Executed__c on the
     * Disposition itself and the record page falls back to the Details section. Neither
     * stage gets a placeholder component (Gate 1 Q5).
     */
    get isOfferStage() {
        return (
            this._stage === 'Active Listing' ||
            this._stage === 'Release Materials' ||
            this._stage === 'Offer Selection' ||
            this._stage === 'LOI'
        );
    }
}