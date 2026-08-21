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
 * UAT asked for the broker contact in the label. The obvious request — `Disposition_Offer__c
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
 * PINS its presence) and on the approval page.
 */
const FIELDS = [
    'Disposition_Offer__c.Id',
    'Disposition_Offer__c.Name',
    'Disposition_Offer__c.Broker__r.Name',
    'Disposition_Offer__c.Offer_Amount__c',
    'Disposition_Offer__c.Offer_Date__c'
];

/**
 * Rendered in place of the broker when the offer has none.
 *
 * ⚠ THIS IS THE COMMON CASE TODAY, NOT AN EDGE CASE. `Broker__c` landed on 2026-08-21 and is
 * stamped only by `c/dispositionLogOfferModal`; every offer logged before it — including BOTH
 * offers live in `usman-dpeg` right now — has a null broker. Deliberately a sentence, not an
 * em dash or a blank: it must not be mistakable for a broker's name, and it must not leave the
 * label opening with a bare separator.
 */
const NO_BROKER = 'Broker not recorded';

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
                // The offer's AutoNumber, falling back to the record Id. See the uniqueness
                // argument below — the Id fallback is what keeps the invariant true even in the
                // unreachable case where `Name` is absent, and it also means no token in this
                // label can ever render the literal string "undefined".
                const offerRef = f.Name?.value || r.id;
                return {
                    // The radio group needs ONE string per option, so the fields are composed into
                    // the label rather than laid out in a table.
                    //
                    // ══════════════════════════════════════════════════════════════════════════
                    // 🔴 UNIQUENESS IS THE CONTRACT OF THIS STRING. THIS IS THE SCREEN WHERE DPEG
                    //    PICKS THE WINNING BID — TWO OPTIONS READING THE SAME IS A WRONG
                    //    DECISION, NOT A COSMETIC DEFECT.
                    // ══════════════════════════════════════════════════════════════════════════
                    // That sentence is the one thing carried forward unchanged from the version of
                    // this comment written when the buyer was retired and the AutoNumber LED the
                    // label. What changed on 2026-08-21 is only WHICH tokens satisfy it, and why.
                    //
                    // THE BROKER NOW LEADS, because UAT asked to see the broker contact and the
                    // broker is the only party an offer names. 🔴 IT IS NOT A DISCRIMINATOR AND
                    // MUST NEVER BE RELIED ON AS ONE: there is one appointed broker per sale, so
                    // every offer on one disposition carries the SAME broker — and today, in
                    // `usman-dpeg`, both live offers carry NONE, so the leading token is the
                    // identical `NO_BROKER` sentence on both. The old comment's objection to
                    // putting a broker here was therefore correct on the facts and is NOT being
                    // waved away; it is answered by making the tokens BEHIND the broker carry the
                    // whole burden of telling two rows apart:
                    //
                    //   1. THE AMOUNT IS NOW EXACT (`formatExactCurrency`, not `formatMillions`).
                    //      This is what made the broker safe to add. The live pair — $1,850,000 and
                    //      $1,860,000 — BOTH rendered `$1.9M` under the old formatter, so the label
                    //      was already ambiguous before a repeated broker was put in front of it.
                    //      Any abbreviation just moves the collision distance; exact removes it.
                    //   2. THE OFFER NUMBER IS APPENDED UNCONDITIONALLY, never "only when a
                    //      collision is detected". Broker + exact amount + date can still coincide
                    //      legitimately — one broker re-logging a revised bid on the same day at
                    //      the same price is a real sequence — and a conditional disambiguator is
                    //      a computation that can be wrong, whereas `Name` is a platform-assigned
                    //      AutoNumber that is unique per row by construction. Unconditional means
                    //      the guarantee does not depend on the data.
                    //
                    // ⚠ THE FINANCING TOKEN WAS REMOVED HERE, NOT DEFAULTED TO SOMETHING BETTER
                    // (UAT: "No need to show financing not started"). It never contributed to
                    // uniqueness anyway — it is a picklist of ~4 values across a handful of rows.
                    // Token order mirrors `brokerOptionLabel` in `c/utils`: who, then the facts,
                    // then the auto-number last as the tiebreak.
                    label: `${broker} — ${amount} · ${date} · ${offerRef}`,
                    value: r.id
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
    get offerOptions() {
        return this._offers || [];
    }
    get hasOffers() {
        return this.offerOptions.length > 0;
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

    handleOfferChange(event) {
        this.selectedOfferId = event.detail.value;
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
