import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import DispositionLogOfferModal from 'c/dispositionLogOfferModal';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

/**
 * c-disposition-offer — the Disposition record page's offers card.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 EACH ROW IS IDENTIFIED BY THE OFFER'S NUMBER, NOT BY A BUYER (2026-08-21).
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `Buyer_Name__c` was the first column here until buyer identity was retired — DPEG communicates
 * only with the appointed listing broker, and buyers sit behind them untracked. The field is NOT
 * deleted from the object (a separate retirement wave owns that) and it is still populated on every
 * pre-existing row; this card simply stops READING it. `Name` (the AutoNumber) replaces it, because
 * with the buyer gone the amount and the date are otherwise the only things telling two offers on
 * one sale apart — and two offers can legitimately share both.
 * ⚠ DO NOT SUBSTITUTE `Broker__c` HERE. It is the SAME broker on every offer on the sale (one
 * appointed broker per disposition), so a broker column would render one repeated name down the
 * card while looking like a per-row discriminator.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 "+ LOG OFFER" OPENS A MODAL. IT USED TO NAVIGATE, AND THAT WAS THE BUG (2026-08-21).
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * It called:
 *
 *     this[NavigationMixin.Navigate]({
 *         type: 'standard__objectPage',
 *         attributes: { objectApiName: 'Disposition_Offer__c', actionName: 'new' },
 *         state: { defaultFieldValues: `Disposition__c=${this.recordId}` }
 *     });
 *
 * Two separate defects in three lines:
 *   1. `actionName: 'new'` opens the PLATFORM's create screen, whose post-save behaviour is to
 *      NAVIGATE TO THE NEW RECORD. The user leaves the disposition page every time they log an
 *      offer. No flag suppresses it — `navigationLocation` belongs to the Aura
 *      `force:createRecord` event, not to `NavigationMixin`.
 *   2. That screen renders from the PAGE LAYOUT, which cannot express a narrow field set or a
 *      read-only, server-resolved broker.
 * `c/dispositionLogOfferModal` fixes both: it saves in place and resolves the broker itself. Same
 * shape as `c/bovComparisonMatrix` -> `c/bovAddResponseModal`, built two days earlier for the
 * identical complaint.
 * ⚠ DEFECT 2 USED TO READ "the layout offers `Buyer__c` as a bare, UNFILTERED Contact lookup, every
 * Contact in the org". That sentence is retired, not merely reworded: the buyer was removed from
 * this feature on 2026-08-21, so there is no picker left to narrow.
 * 🔴 A REGRESSION TO ANY FORM OF NAVIGATION HERE IS THE ORIGINAL BUG RETURNING. `NavigationMixin`
 * is no longer imported, deliberately — re-adding the import is the tell.
 *
 * ⚠ THE WIRE RESULT IS RETAINED IN `_wired` BECAUSE `refreshApex` REQUIRES IT. Destructuring the
 * handler's argument (`wired({ data, error })`, which is what this file used to do) throws the
 * refreshable object away, and a "tidying" edit back to that shape silently reinstates a stale
 * card after every save. The record is created through `lightning-record-edit-form`, i.e. through
 * LDS, so LDS may well invalidate this related list on its own — but that is not something this
 * file can assert, and an explicit refresh costs one call.
 */
export default class DispositionOffer extends LightningElement {
    @api recordId;
    _offers = [];
    _error;
    _wired;

    @wire(getRelatedListRecords, {
        parentRecordId: '$recordId',
        relatedListId: 'Disposition_Offers__r',
        fields: ['Disposition_Offer__c.Id', 'Disposition_Offer__c.Name',
                 'Disposition_Offer__c.Offer_Amount__c', 'Disposition_Offer__c.Offer_Date__c']
    })
    wired(result) {
        this._wired = result;
        const { data, error } = result;
        if (data) {
            this._error = undefined;
            this._offers = data.records.map(r => ({
                id: r.id,
                // The AutoNumber. The platform assigns it on insert, so the em-dash fallback is
                // unreachable in practice and exists only because every displayed value on this
                // card must be a string — an `undefined` bound into the DOM renders the literal
                // text "undefined" (measured in this repo).
                offerName: r.fields.Name?.value || '—',
                amountLabel: r.fields.Offer_Amount__c?.value != null
                    ? '$' + (r.fields.Offer_Amount__c.value / 1000000).toFixed(2) + 'M' : '—',
                dateLabel: this._fmtDate(r.fields.Offer_Date__c?.value)
            }));
        } else if (error) {
            this._error = error;
            this._offers = [];
        }
    }

    get offers()    { return this._offers; }
    get hasOffers() { return this._offers.length > 0; }
    get hasError()  { return !!this._error; }
    // Suppress the "no offers yet" copy when the failure is an actual load error.
    get showEmpty() { return !this.hasOffers && !this.hasError; }
    get errorMessage() {
        return (this._error && this._error.body && this._error.body.message) || 'Unknown error';
    }

    /**
     * Opens the Log Offer dialog over this page and, on success, toasts and refreshes in place.
     *
     * ⚠ THE MODAL'S RESULT IS THE ONLY CHANNEL BACK. `LightningModal.open()` renders into the
     * PLATFORM's modal layer, which shares no ancestor with this component — a bubbling
     * `CustomEvent` from the dialog has no path here. The promise IS the wiring.
     */
    async handleLogOffer() {
        let result;
        try {
            result = await DispositionLogOfferModal.open({
                size: 'medium',
                label: 'Log Offer',
                description:
                    'Log an offer against this disposition without leaving the page.',
                dispositionId: this.recordId
            });
        } catch (error) {
            this._toast(
                'Could not open the offer dialog',
                (error && error.body && error.body.message) ||
                    'The log-offer dialog could not be opened.',
                'error'
            );
            return;
        }

        // Cancelled, dismissed, or closed from the empty state — nothing changed, so say nothing.
        // ⚠ A dismissed LightningModal resolves `undefined`, and this repo's Jest stub for it
        // resolves `null` (CustomEvent coerces an absent `detail` to null). Both are falsy and
        // both must take this branch.
        if (!result || !result.recordId) {
            return;
        }

        this._toast(
            'Offer logged',
            result.name
                ? `${result.name} was added to this disposition.`
                : 'The offer was added to this disposition.',
            'success'
        );
        refreshApex(this._wired);
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _fmtDate(d) {
        if (!d) return '—';
        const parts = String(d).split('-');
        return MONTHS[parseInt(parts[1], 10) - 1] + ' ' + parseInt(parts[2], 10) + ', ' + parts[0];
    }
}
