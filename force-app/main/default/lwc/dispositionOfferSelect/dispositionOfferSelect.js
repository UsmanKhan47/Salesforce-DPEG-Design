import { LightningElement, api, wire } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { formatMillions, formatLongDate } from 'c/utils';
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
const FIELDS = [
    'Disposition_Offer__c.Id',
    'Disposition_Offer__c.Buyer_Name__c',
    'Disposition_Offer__c.Offer_Amount__c',
    'Disposition_Offer__c.Offer_Date__c',
    'Disposition_Offer__c.Offer_Financing_Type__c'
];

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
 * truth about where the deal is. The confirm-button label and the note in the markup both say so;
 * do not shorten either to "Accept".
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
                const buyer = (f.Buyer_Name__c && f.Buyer_Name__c.value) || 'Unnamed buyer';
                const amount = formatMillions(
                    f.Offer_Amount__c ? f.Offer_Amount__c.value : null
                );
                const date = formatLongDate(f.Offer_Date__c ? f.Offer_Date__c.value : null);
                const financing =
                    (f.Offer_Financing_Type__c && f.Offer_Financing_Type__c.value) ||
                    'Financing not stated';
                return {
                    // The radio group needs ONE string per option, so the four fields are
                    // composed into the label rather than laid out in a table. A radio whose
                    // label is only the buyer name would make two offers from the same buyer
                    // indistinguishable — which is a real case in a re-bid.
                    label: `${buyer} — ${amount} · ${date} · ${financing}`,
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
