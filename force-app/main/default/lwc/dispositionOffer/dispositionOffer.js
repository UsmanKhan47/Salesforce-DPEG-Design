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
 * 🔴 THIS CARD HAS TWO MODES, AND THE STAGE DECISION IS **NOT MADE HERE** (2026-08-24).
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `@api selectedOnly` switches the card from "every offer on this sale" to "the one offer that
 * was put forward for approval". `c/dispositionSidebar` — the component whose entire job is stage
 * routing, and which already holds a `getRecord` wire on `Disposition_Stage__c` — sets it at the
 * `Offer Selection` stage and nowhere else.
 *
 * WHY THE FLAG COMES IN FROM THE PARENT RATHER THAN BEING DERIVED HERE OR ON THE SERVER:
 *
 *   1. 🔴 NOT A STAGE WIRE ON THIS COMPONENT. This card renders at FOUR stages (Active Listing,
 *      Release Materials, Offer Selection, LOI) and is mounted by a parent that has already
 *      resolved the stage. Adding a second `getRecord` here would duplicate that read and give an
 *      offers card standing knowledge of the disposition stage machine — a second place for the
 *      stage list to drift out of agreement with `isOfferStage`.
 *
 *   2. 🔴 NOT A STAGE-KEYED SERVER FILTER. There is no Apex behind this card at all: the rows come
 *      from `getRelatedListRecords`, an LDS read. A stage-keyed filter would mean writing an Apex
 *      controller purely to express a RENDERING choice, a second LDS cache entry whose contents
 *      differ from the related list every other consumer sees, and a data layer that answers the
 *      same question differently depending on a picklist value it should not care about. It would
 *      also break the moment this card is reused at a fifth stage.
 *
 *   3. ✅ AN `@api` MODE IS THE SHAPE THIS PAGE ALREADY USES. `c/bovComparisonMatrix` splits its
 *      preferred/normal cards exactly this way — one wire, filtered in a private getter, with the
 *      parent choosing the mode. Same reasoning, same file layout, one payload, so the two
 *      renderings can never disagree about the same record's numbers.
 *
 * ⚠ THE FLAG DEFAULTS `false` AND EVERY BRANCH READS `=== true`, so the three other stages take
 * byte-for-byte the path they always took.
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

    /**
     * Renders ONLY the offer that was put forward for approval (2026-08-24).
     *
     * Set by `c/dispositionSidebar` at the `Offer Selection` stage and nowhere else. Changes four
     * things and nothing else: which rows are shown (`isSelected === true` instead of all of
     * them), the card title, the empty-state sentence, and whether "+ Log Offer" is enabled.
     *
     * ⚠ DEFAULT `false` IS THE WHOLE SAFETY ARGUMENT. Every branch below reads
     * `this.selectedOnly === true`, so the card takes its existing path at Active Listing,
     * Release Materials and LOI by construction rather than by hope.
     *
     * 🔴 `=== true`, NOT TRUTHINESS, AND THE NEAR-MISS IS ONE CHARACTER AWAY. A bare attribute
     * (`<c-disposition-offer selected-only>`) passes boolean `true`, but `selected-only=""` passes
     * the EMPTY STRING, which is falsy — the card would silently list every offer again with
     * nothing on the page to show it. The parent binds a real boolean getter
     * (`selected-only={isOfferSelection}`) precisely so neither form can be typed by accident.
     */
    @api selectedOnly = false;

    _offers = [];
    _error;
    _wired;

    /**
     * ⚠ `Is_Selected__c` IS REQUESTED IN **EVERY** MODE, NOT ONLY WHEN `selectedOnly` IS SET. A
     * mode-dependent field list would reconfigure the wire — a second LDS cache entry and a second
     * round trip — every time the parent flipped the flag, and would make the card's data shape
     * depend on a rendering decision. The field is one checkbox.
     *
     * 🔴 IF THIS FIELD IS EVER DROPPED FROM THIS LIST, `selected-only` MODE GOES BLIND, NOT LOUD:
     * `fields.Is_Selected__c` becomes `undefined` on every row, `_visible` filters all of them
     * out, and the Offer Selection card renders its empty state forever. There is a
     * `getLastConfig()` assertion in __tests__ pinned on this line for exactly that reason.
     *
     * ⚠ FLS CHECKED 2026-08-24 AGAINST THE ORG (not the repo XML): `Disposition_Offer__c
     * .Is_Selected__c` is readable=true / editable=false in DPEG_Disposition_Edit,
     * DPEG_Disposition_View, DPEG_Admin_Access and both PSGs. Read-only by design — this card only
     * reads it; `DispositionApprovalService.selectOffer` is the sole writer, in SYSTEM mode.
     */
    @wire(getRelatedListRecords, {
        parentRecordId: '$recordId',
        relatedListId: 'Disposition_Offers__r',
        fields: ['Disposition_Offer__c.Id', 'Disposition_Offer__c.Name',
                 'Disposition_Offer__c.Offer_Amount__c', 'Disposition_Offer__c.Offer_Date__c',
                 'Disposition_Offer__c.Is_Selected__c']
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
                dateLabel: this._fmtDate(r.fields.Offer_Date__c?.value),
                // 🔴 NOT RENDERED — this is the FILTER KEY for `selected-only` mode. Deliberately
                // not shown as a column: in that mode every visible row is selected by definition,
                // so a marker would be a constant; and in the default mode a per-row tick would
                // compete with the Select Offer quick action for the same meaning.
                isSelected: r.fields.Is_Selected__c?.value === true
            }));
        } else if (error) {
            this._error = error;
            this._offers = [];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Which rows this instance is about (2026-08-24)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The subset of the wire payload THIS instance renders.
     *
     * 🔴 ONE WIRE, FILTERED HERE — NOT A SECOND QUERY. Both modes are drawn from the SAME
     * related-list payload and cannot disagree about the same offer's amount or date.
     *
     * ⚠ `=== true`, SO AN ABSENT OR NULL FLAG FALLS OUT OF THE SELECTED VIEW. That is the safe
     * side: this card's premise in `selected-only` mode is "this is the one going to the
     * principals", and only an explicit `true` says that. The default mode filters nothing at all,
     * so an unflagged row is unaffected either way.
     */
    get _visible() {
        const all = this._offers || [];
        return this.selectedOnly === true
            ? all.filter((o) => o.isSelected === true)
            : all;
    }

    get offers()    { return this._visible; }
    get hasOffers() { return this._visible.length > 0; }
    get hasError()  { return !!this._error; }
    // Suppress the "no offers yet" copy when the failure is an actual load error.
    get showEmpty() { return !this.hasOffers && !this.hasError; }
    get errorMessage() {
        return (this._error && this._error.body && this._error.body.message) || 'Unknown error';
    }

    /**
     * ⚠ "Selected Offer", NOT "Offer Sent for Approval". `Is_Selected__c` SURVIVES A REJECTION —
     * its own field metadata says so ("a selected-but-rejected offer must remain visibly
     * selected-and-rejected so the team can see what was tried") and a rejected offer parks the
     * disposition back at Offer Selection for a re-pick. A title claiming the offer is currently
     * out for approval would be false in exactly the state the user most needs to read this card
     * in. "Selected Offer" names the flag, and stays true in both states.
     */
    get cardTitle() {
        return this.selectedOnly === true ? 'Selected Offer' : 'Disposition Offers';
    }

    /**
     * ⚠ THE DEFAULT STRING IS PINNED IN __tests__ AND MUST STAY EXACTLY "No offers yet." — the
     * assertion is an equality, not a `toContain`, because the sentence it replaced (a stale
     * 60-day marketing clock) would have survived a substring check.
     *
     * 🔴 THE SELECTED-MODE STRING EXISTS BECAUSE "No offers yet." WOULD BE A LIE THERE. In
     * `selected-only` mode an empty card means "offers exist, none is flagged" — a state the
     * authored path cannot produce (`DispositionApprovalService.selectOffer` sets the flag and
     * moves the stage in one savepointed transaction, so reaching Offer Selection with no selected
     * offer takes a data load or a direct API write). If it ever does appear, telling the user
     * there are no offers would send them to log another one, which is the one thing the disabled
     * button below exists to prevent.
     */
    get emptyMessage() {
        return this.selectedOnly === true
            ? 'No offer is currently selected for approval.'
            : 'No offers yet.';
    }

    /**
     * "+ Log Offer" is DISABLED — not hidden — in `selected-only` mode (user decision,
     * 2026-08-24).
     *
     * 🔴 DISABLED, NOT HIDDEN, ON PURPOSE. A greyed control with a `title` explains itself; a
     * vanished one reads as a permission problem or a broken page, and this card is the only place
     * the button has ever appeared.
     *
     * WHY IT IS DISABLED AT ALL: at Offer Selection the card shows only the flagged offer, so a
     * newly logged offer would save successfully and then RENDER NOWHERE — a silent disappearing
     * save. The route for changing the choice is the Select Offer quick action on the Disposition,
     * which re-runs the exclusivity sweep; logging a fresh offer does not.
     */
    get logDisabled() {
        return this.selectedOnly === true;
    }

    /**
     * ⚠ ALWAYS A NON-EMPTY STRING, IN BOTH MODES. The LWC compiler writes a bound attribute
     * UNCONDITIONALLY, so returning `undefined` here would render the literal `title="undefined"`
     * on the enabled button (measured in this repo, on a different bundle).
     */
    get logTitle() {
        return this.selectedOnly === true
            ? 'An offer has already been selected for approval. Use the Select Offer action on this disposition to change the choice.'
            : 'Log an offer against this disposition.';
    }

    /**
     * Opens the Log Offer dialog over this page and, on success, toasts and refreshes in place.
     *
     * ⚠ THE MODAL'S RESULT IS THE ONLY CHANNEL BACK. `LightningModal.open()` renders into the
     * PLATFORM's modal layer, which shares no ancestor with this component — a bubbling
     * `CustomEvent` from the dialog has no path here. The promise IS the wiring.
     */
    async handleLogOffer() {
        // 🔴 THE SECOND OF TWO GUARDS, AND IT IS NOT REDUNDANT. The button carries
        // `disabled={logDisabled}`, which is what the user SEES and what stops the click; this is
        // what stops the SAVE if that binding is ever dropped in a template edit. They fail
        // independently and each has its own falsifier in __tests__ — a single guard would let one
        // of those tests go vacuous behind the other.
        if (this.selectedOnly === true) {
            return;
        }

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
