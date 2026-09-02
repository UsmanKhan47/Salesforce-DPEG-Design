import { LightningElement, api, wire } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { formatExactCurrency, formatLongDate } from 'c/utils';
import selectOffer from '@salesforce/apex/DispositionApprovalController.selectOffer';

/**
 * The related list this reads, and the fields it asks for.
 *
 * ⚠ `Disposition_Offers__r` IS THE RELATIONSHIP NAME ON `Disposition_Offer__c.Disposition__c`, and
 * the SAME id `c/dispositionOffer` already uses in the sidebar. `getRelatedListRecords` fails with
 * an opaque error on an unknown relatedListId, so the two components sharing one literal is worth
 * more than either one owning a private copy.
 */
const RELATED_LIST_ID = 'Disposition_Offers__r';
/**
 * ⚠ `Buyer_Name__c` WAS THE FIRST ENTRY HERE UNTIL 2026-08-21 and was replaced by `Name`. DPEG
 * communicates only with the appointed listing broker; buyers sit behind them and are not tracked.
 * That has not changed — the buyer is still gone, and `c/dispositionOffer`'s sidebar card still
 * shows no broker column for the reason its own header gives.
 *
 * ── 🔴 `Broker__r.Name`, NOT `Broker__c` — MEASURED, NOT ASSUMED (2026-08-21) ─────────────────
 * UAT asked for the broker contact on this screen (it is the Broker column, and the first token of
 * each radio's `aria-label`). The obvious request — `Disposition_Offer__c
 * .Broker__c` — DOES NOT CARRY THE NAME. Measured against `usman-dpeg` on the live
 * `related-list-records` endpoint, a plain lookup comes back with the Id and a NULL display value:
 *
 *     "Broker__c": { "displayValue": null, "value": "003iw000000o39BAAQ" }
 *
 * so a component reading `displayValue` renders an empty broker for every row and looks like the
 * field is unpopulated. Requesting the TRAVERSAL instead returns the name, under a `Broker__r` key
 * (NOT `Broker__c` — the key changes with the request, which is the part that bites):
 *
 *     "Broker__r": { "displayValue": "Derek Simmons",
 *                    "value": { "id": "003…", "fields": { "Name": { "value": "Derek Simmons" } } } }
 *
 * ⚠ DO NOT "SIMPLIFY" THIS BACK TO `Broker__c`. It deploys, it passes a hand-written Jest fixture
 * that invents a `displayValue`, and it renders nothing in the org.
 *
 * ⚠ `Offer_Financing_Type__c` WAS REMOVED FROM THIS LIST ON 2026-08-21 (UAT: "No need to show
 * financing not started"). Nothing else in this bundle read it — it existed solely to build the
 * label token that was dropped — so the field is not merely unrendered, it is no longer requested,
 * which also drops an FLS gate this quick action no longer needs. 🔴 THE FIELD ITSELF IS UNTOUCHED
 * and remains load-bearing on the offer layout, on `c/dispositionLogOfferModal`'s form (whose suite
 * PINS its presence) and on the approval page. 🔴 IT DID NOT COME BACK ON 2026-09-02 EITHER — the
 * three fields added that day are the DEAL TERMS, not the financing type, and decision D4 stands.
 *
 * ── 🔴 THE THREE DEAL TERMS, ADDED 2026-09-02 (BA story 35, decision C) ─────────────────────────
 * `Earnest_Money_Proposed__c`, `Due_Diligence_Days__c` and `Closing_Period_Days__c` join the list.
 *
 * 🔴 THE DEFECT THIS CLOSES IS AN INVERSION, NOT AN OMISSION, AND IT IS WORTH STATING PRECISELY.
 * All three fields were ALREADY on `Disposition_Offer__c.Offer_Selection_Approval`'s
 * `approvalPageFields` (measured 2026-09-02, lines 99-101 of that approval process) and already
 * granted read in BOTH `DPEG_Disposition_View` and `DPEG_Disposition_Edit`. So the APPROVER — who
 * is being asked to ratify a choice already made — could see the terms, while the person actually
 * CHOOSING which offer to put forward could not. Two bids at the same price are not the same bid
 * if one closes in 30 days and the other in 90; this screen is where that decision is taken.
 *
 * ✅ ZERO PERMISSION WORK. Because both sets already grant all three, adding them here does not
 * open a new FLS gate on this quick action for either disposition persona — unlike the buyer and
 * financing fields the T-NO-BUYER / T-NO-FINANCING pins keep out, whose absence from this list IS
 * the gate. ⚠ That is a fact about TODAY'S grants, not a general licence: any FURTHER field added
 * here must have its grants checked in both sets first, because `getRelatedListRecords` fails the
 * WHOLE read for a user missing any requested field, so one ungranted field empties the picker.
 */
const FIELDS = [
    'Disposition_Offer__c.Id',
    'Disposition_Offer__c.Name',
    'Disposition_Offer__c.Broker__r.Name',
    'Disposition_Offer__c.Offer_Amount__c',
    'Disposition_Offer__c.Offer_Date__c',
    'Disposition_Offer__c.Earnest_Money_Proposed__c',
    'Disposition_Offer__c.Due_Diligence_Days__c',
    'Disposition_Offer__c.Closing_Period_Days__c'
];

/**
 * Rendered in the Broker COLUMN when the offer has none.
 *
 * ⚠ THIS IS THE COMMON CASE TODAY, NOT AN EDGE CASE. `Broker__c` landed on 2026-08-21 and is
 * stamped only by `c/dispositionLogOfferModal`; every offer logged before it — including BOTH
 * offers live in `usman-dpeg` right now — has a null broker. Deliberately a sentence, not an
 * em dash or a blank: it must not be mistakable for a broker's name, and — since the same string
 * is also the first token of the radio's `aria-label` — it must not leave that announcement
 * opening with a bare separator.
 */
const NO_BROKER = 'Broker not recorded';

/**
 * A whole-number day count as a cell, or an em dash when there is none.
 *
 * ⚠ LOCAL, NOT AN EXPORT ADDED TO `c/utils`, AND THAT IS DELIBERATE. `c/utils` already carries
 * `formatDaysToMarket`, which renders `45d` — a suffix that would read as noise under a column
 * already headed "DD Days", and whose byte-compatibility contract forbids changing it for the two
 * BOV surfaces that depend on it (that module's header states the rule: divergent variants each
 * keep their own behaviour rather than being collapsed). One caller, one behaviour, no shared
 * function to drift.
 *
 * ⚠ `== null` RATHER THAN A FALSY TEST, copied from `formatDaysToMarket`'s own reasoning: a
 * genuine `0` is meaningful here — an offer with a 0-day due-diligence period is a real, and
 * notably aggressive, term — and a falsy test would print `—` for it and say something false about
 * the bid on the screen that chooses between bids.
 *
 * ⚠ APEX/UI-API NUMBERS ARRIVE AS NUMBERS OR STRINGS depending on scale, so this returns
 * `String(n)` rather than assuming either. Both fields are `scale = 0`, so no rounding is applied
 * and none should be added — a fabricated decimal would be a term nobody agreed.
 *
 * @param {number|string|null|undefined} n Raw day count.
 * @returns {string} e.g. `'30'`, `'0'`, or `'—'` when null/undefined/blank.
 */
function formatDays(n) {
    if (n == null || n === '') {
        return '—';
    }
    return String(n);
}

/** Fallback when the Apex error carries no readable body. */
const GENERIC_ERROR = 'The offer could not be selected.';

/**
 * c-disposition-offer-select — the `Select_Offer` SCREEN quick action on Disposition__c.
 *
 * Lists every offer logged against this disposition and selects one. The server
 * (`DispositionApprovalService.selectOffer`, design D-3) then does TWO things in one savepointed
 * transaction: it flips `Disposition_Offer__c.Is_Selected__c` EXCLUSIVELY (clearing any previously
 * selected offer) and advances the Disposition to `Offer Selection`, then submits the offer into
 * `Offer_Selection_Approval`. The approval — not this action — is what later advances
 * `Offer Selection -> LOI`.
 *
 * 🔴 SO THIS BUTTON DOES NOT MEAN "ACCEPT THIS OFFER". It means "put this offer in front of the
 * principals". A rejected offer parks the disposition at `Offer Selection` for a re-pick, which is
 * exactly why the stage moves on SUBMISSION rather than on approval — the stage always tells the
 * truth about where the deal is.
 * ⚠ THE ON-SCREEN NOTE THAT USED TO SAY THIS WAS REMOVED ON 2026-08-21 at the user's request (it
 * is the exact string they quoted). The confirm-button label — "Select and send for approval" — is
 * now the ONLY surface stating it, so do not shorten THAT to "Accept"; this paragraph is the
 * developer-facing record and stays.
 *
 * ── READ PATH IS LDS, DELIBERATELY. NO APEX WAS ADDED FOR IT ─────────────────
 * The offer list is a plain child-record read with no joins, no aggregates and no system-context
 * requirement, so it is expressible as `getRelatedListRecords` (ARCHITECTURE.md §5's LDS-first
 * priority). That buys FLS + sharing enforcement for free and, more usefully here, means the list
 * refreshes itself when an offer is logged from `c/dispositionOffer` or `c/dispositionCallForOffers`
 * on the same page. An `@AuraEnabled(cacheable=true)` reader would have been a second, staler source
 * of truth for the same rows.
 *
 * The WRITE stays imperative Apex because it is a multi-record, savepointed, approval-submitting
 * transaction — nothing LDS can express.
 *
 * Structure (spinner -> load error -> "nothing to select" branch -> form) is pattern-matched to
 * `c/brokerReplaceQuickAction`, the repo's other ScreenAction quick action.
 */
export default class DispositionOfferSelect extends LightningElement {
    @api recordId;

    _offers;
    _loadError;
    selectedOfferId;
    /** Inline, user-safe text for a failed submission. The panel stays open on a failure. */
    error;
    _saving = false;

    @wire(getRelatedListRecords, {
        parentRecordId: '$recordId',
        relatedListId: RELATED_LIST_ID,
        fields: FIELDS
    })
    wiredOffers({ data, error }) {
        if (data) {
            this._loadError = undefined;
            this._offers = (data.records || []).map((r) => {
                const f = r.fields || {};
                // See the FIELDS comment: the key is `Broker__r`, and the name is inside the
                // spanned record. `displayValue` on the TRAVERSAL is populated (it is only null on
                // a plain `Broker__c` request) and is kept as a second reading of the same value,
                // not as a different source of truth.
                const broker =
                    f.Broker__r?.value?.fields?.Name?.value ||
                    f.Broker__r?.displayValue ||
                    NO_BROKER;
                const amount = formatExactCurrency(
                    f.Offer_Amount__c ? f.Offer_Amount__c.value : null
                );
                const date = formatLongDate(f.Offer_Date__c ? f.Offer_Date__c.value : null);
                // ── THE THREE DEAL TERMS (2026-09-02, BA story 35) ────────────────────────────
                // 🔴 EARNEST MONEY USES `formatExactCurrency`, NOT `formatMillions` AND NOT A
                // `lightning-formatted-number`, FOR THE SAME REASON `amount` DOES ONE LINE ABOVE.
                // It is a Currency field on the screen where DPEG picks the winning bid, and the
                // live UAT defect this bundle exists to have fixed was two distinct amounts
                // ($1,850,000 and $1,860,000) BOTH rendering `$1.9M`. Any abbreviation has a
                // collision distance; an exact figure has none. It also has to be a TEXT NODE this
                // bundle's own suite can read — a `lightning-formatted-number` renders inside a
                // stub under sfdx-lwc-jest and every assertion about it would go vacuous.
                // ⚠ ALL THREE RENDER AN EM DASH WHEN NULL, never the literal string "undefined"
                // and never `0`. A missing term is a term that was not agreed, and on this screen
                // printing `0` for it would be a false statement about the bid.
                const earnest = formatExactCurrency(
                    f.Earnest_Money_Proposed__c ? f.Earnest_Money_Proposed__c.value : null
                );
                const ddDays = formatDays(
                    f.Due_Diligence_Days__c ? f.Due_Diligence_Days__c.value : null
                );
                const closingDays = formatDays(
                    f.Closing_Period_Days__c ? f.Closing_Period_Days__c.value : null
                );
                // The offer's AutoNumber, falling back to the record Id. See the uniqueness
                // argument below — the Id fallback is what keeps the invariant true even in the
                // unreachable case where `Name` is absent, and it also means neither the Offer
                // Number CELL nor the `aria-label` can ever render the literal string "undefined".
                const offerRef = f.Name?.value || r.id;
                return {
                    id: r.id,
                    broker: broker,
                    amount: amount,
                    date: date,
                    offerRef: offerRef,
                    earnest: earnest,
                    ddDays: ddDays,
                    closingDays: closingDays,
                    // ══════════════════════════════════════════════════════════════════════════
                    // 🔴 THE COMPOSED ONE-LINE DESCRIPTION SURVIVES THE MOVE TO A TABLE — AS THE
                    //    RADIO'S `aria-label`. IT IS NOT A LEFTOVER.
                    // ══════════════════════════════════════════════════════════════════════════
                    // A sighted user now compares four ALIGNED COLUMNS, which is the whole point of
                    // the table (2026-08-24: "so a principal can actually compare offers"). A
                    // screen-reader user pressing Down through the radio group hears only each
                    // control's accessible name, so without this string they would hear five
                    // unnamed radios — the table would be a REGRESSION for them, not an
                    // improvement. `aria-label` gives them the same row, linearised.
                    //
                    // 🔴 UNIQUENESS IS STILL THE CONTRACT OF THIS STRING. THIS IS THE SCREEN WHERE
                    //    DPEG PICKS THE WINNING BID — TWO CONTROLS ANNOUNCING THE SAME IS A WRONG
                    //    DECISION, NOT A COSMETIC DEFECT. That sentence is carried forward
                    //    unchanged from the radio-group version of this comment; only its rendered
                    //    home moved, from `option.label` to a DOM attribute.
                    //
                    // THE BROKER LEADS, because UAT (2026-08-21) asked to see the broker contact
                    // and the broker is the only party an offer names. 🔴 IT IS NOT A
                    // DISCRIMINATOR AND MUST NEVER BE RELIED ON AS ONE: there is one appointed
                    // broker per sale, so every offer on one disposition carries the SAME broker —
                    // and today, in `usman-dpeg`, both live offers carry NONE, so the leading
                    // token is the identical `NO_BROKER` sentence on both. The tokens BEHIND it
                    // carry the whole burden of telling two rows apart:
                    //
                    //   1. THE AMOUNT IS EXACT (`formatExactCurrency`, not `formatMillions`). The
                    //      live pair — $1,850,000 and $1,860,000 — BOTH rendered `$1.9M` under the
                    //      old formatter. Any abbreviation just moves the collision distance;
                    //      exact removes it. ⚠ THIS IS ALSO WHY THE `Amount` COLUMN IS FORMATTED
                    //      HERE IN JS RATHER THAN BY A `lightning-formatted-number` OR A
                    //      datatable `type: 'currency'` COLUMN — the exact figure has to be a text
                    //      node this bundle's own suite can read. See the template's comment.
                    //   2. THE OFFER NUMBER IS APPENDED UNCONDITIONALLY, never "only when a
                    //      collision is detected". Broker + exact amount + date can still coincide
                    //      legitimately — one broker re-logging a revised bid on the same day at
                    //      the same price is a real sequence — and a conditional disambiguator is
                    //      a computation that can be wrong, whereas `Name` is a platform-assigned
                    //      AutoNumber that is unique per row by construction.
                    //
                    // ⚠ THE FINANCING TOKEN WAS REMOVED HERE, NOT DEFAULTED TO SOMETHING BETTER
                    // (UAT: "No need to show financing not started"), and it did not return as a
                    // fifth COLUMN either. It never contributed to uniqueness — a picklist of ~4
                    // values across a handful of rows.
                    //
                    // 🔴 AND THE THREE DEAL TERMS ADDED ON 2026-09-02 ARE DELIBERATELY **NOT** IN
                    // THIS STRING. THIS LINE IS BYTE-IDENTICAL TO WHAT IT WAS BEFORE THAT CHANGE.
                    // The obvious move — "the table gained three columns, so the accessible name
                    // should gain three tokens" — is wrong twice over:
                    //   1. `aria-label` is a UNIQUENESS CONTRACT (see above), and it is already
                    //      satisfied by the unconditional AutoNumber. Appending
                    //      "— $50,000 · 30 · 60" adds nothing a screen-reader user can act on at
                    //      the moment of choosing a radio, and makes an already-long announcement
                    //      unreadable.
                    //   2. THE TERMS ARE STILL ANNOUNCED. They are ordinary table cells with
                    //      `<th scope="col">` headers and a `<th scope="row">` on each row, so a
                    //      screen reader reads them WITH their column names when the user moves
                    //      through the table — which is strictly better than a positional token
                    //      inside a control's name. The `aria-label` exists because a radio in a
                    //      cell would otherwise announce as an unnamed control, not because the
                    //      table is inaccessible.
                    // ⚠ THE SUITE PINS THIS STRING EXACTLY (T-UNIQUE, and the missing-fields
                    // case). If you change it, you are changing a contract, not formatting.
                    ariaLabel: `${broker} — ${amount} · ${date} · ${offerRef}`
                };
            });
        } else if (error) {
            this._offers = [];
            this._loadError = (error.body && error.body.message) || 'Unexpected error';
        }
    }

    get hasData() {
        return this._offers !== undefined;
    }
    get isLoading() {
        return !this.hasData && !this._loadError;
    }
    get loadError() {
        // Bound as TEXT, but defaulted to '' rather than left undefined for the same reason the
        // rest of this repo does: a getter bound to a custom element ATTRIBUTE is written
        // unconditionally, so `undefined` renders the literal string "undefined". One rule for
        // every displayed getter is cheaper than a per-binding judgement.
        return this._loadError || '';
    }
    /**
     * One row per offer, resolved for the table: the four displayed columns, plus the selection
     * state the template needs.
     *
     * ⚠ SELECTION IS DERIVED HERE RATHER THAN LEFT TO THE BROWSER. A native radio group would keep
     * its own checked state perfectly well on its own — but the `getRelatedListRecords` wire can
     * re-emit at any time (a sibling card on the same page logs an offer and LDS refreshes this
     * list), which rebuilds every `<tr>`. An unbound `checked` would then render nothing selected
     * while `selectedOfferId` still held a value and the confirm button still read enabled — a
     * screen that says "ready" with no visible choice. Binding it makes the DOM a projection of
     * `selectedOfferId`, which is also the value that reaches Apex.
     *
     * @returns {Array<object>} `{ id, broker, amount, date, offerRef, earnest, ddDays,
     *   closingDays, ariaLabel, selected, rowClass }` per offer, in the order LDS returned them.
     */
    get offerRows() {
        return (this._offers || []).map((row) => {
            const selected = row.id === this.selectedOfferId;
            return {
                ...row,
                selected,
                // Two classes rather than a toggled single one, so the selected state is
                // assertable as a rendered attribute on the `<tr>` without reading a getter.
                rowClass: selected ? 'qa-row qa-row_selected' : 'qa-row'
            };
        });
    }
    get hasOffers() {
        return (this._offers || []).length > 0;
    }
    /** True only once the wire has answered AND answered with nothing. */
    get showNoOffers() {
        return this.hasData && !this.hasOffers && !this._loadError;
    }
    get confirmDisabled() {
        return this._saving || !this.selectedOfferId;
    }
    get isSaving() {
        return this._saving;
    }

    /**
     * Records the chosen offer.
     *
     * ⚠ READS `data-id` OFF THE ELEMENT THE USER CLICKED, which is the point of not using a
     * `lightning-datatable` row action here. This repo has already shipped a per-row action that
     * silently did nothing because `event.detail.action.name` arrived as the raw
     * `{ fieldName: 'actionName' }` OBJECT rather than a string (`c/meterRegister`,
     * `c/sellMeterList`) — and Jest stayed green, because the suite had hand-written a
     * string-shaped payload the platform never sends. A native `<input type="radio">` has no
     * such indirection: `event.target` IS the radio, and `dataset.id` is the literal the
     * template wrote onto it.
     *
     * @param {Event} event The radio's change event.
     */
    handleOfferChange(event) {
        this.selectedOfferId = event.target.dataset.id;
        this.error = undefined;
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async confirm() {
        if (this.confirmDisabled) {
            return;
        }
        this._saving = true;
        this.error = undefined;
        try {
            // ⚠ Parameter names are the Apex signature verbatim:
            // DispositionApprovalController.selectOffer(Id dispositionId, Id offerId).
            const message = await selectOffer({
                dispositionId: this.recordId,
                offerId: this.selectedOfferId
            });
            // The service's returned text is AUTHORED — it names the offer and says an approval
            // was raised. Show it rather than re-authoring a weaker summary here.
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Offer selected', message, variant: 'success' })
            );
            // The stage write and the Is_Selected__c flips are imperative Apex DML, so they
            // happened behind LDS's back — without this the Path and the Details panel keep
            // showing the pre-selection stage.
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.close();
        } catch (error) {
            // Stays OPEN on failure, unlike c/sellMeterInitiateModal: the refusals reachable here
            // ("this disposition is not at a stage where an offer can be selected", "an approval
            // is already pending on that offer") can be answered by picking a DIFFERENT offer, so
            // the form is still useful. Surface the authored text verbatim.
            this.error = (error && error.body && error.body.message) || GENERIC_ERROR;
        } finally {
            this._saving = false;
        }
    }
}
