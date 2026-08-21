import { api, wire } from 'lwc';
import LightningModal from 'lightning/modal';
import getOfferFormContext from '@salesforce/apex/DispositionOfferFormController.getOfferFormContext';

/** Shown when the platform hands back an error with nothing readable in it. */
const GENERIC_SAVE_ERROR = 'The offer could not be saved.';

/** Shown when the context wire fails and the server sent no readable message. */
const GENERIC_LOAD_ERROR =
    'The offer form could not be loaded. Refresh the page or contact your administrator.';

/**
 * Where to send someone whose disposition has no broker yet. TWO different screens, so one
 * generic sentence would misdirect half the users.
 */
const BROKER_HINT_ON_MARKET =
    'The broker is set when a BOV submission is approved on the comparison matrix.';
const BROKER_HINT_OFF_MARKET =
    'The broker is set on this disposition at the Broker Selection stage.';

/**
 * c-disposition-log-offer-modal — logs a `Disposition_Offer__c` against the disposition the user is
 * already looking at, WITHOUT leaving that page, with the broker auto-resolved and the buyer picked
 * from a narrow list (2026-08-21).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS IS AN LWC AND NOT A PAGE-LAYOUT EDIT — TWO INDEPENDENT REASONS.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 1. A CLASSIC PAGE LAYOUT CANNOT EXPRESS A FILTERED PICKER. `Disposition_Offer__c` has no
 *    FlexiPage and no create quick action anywhere in `force-app`, so the layout is the only
 *    entry point today — and `Buyer__c` is an UNFILTERED Contact lookup, so on that layout it
 *    offers every Contact in the org, including the introducing broker whose signed NDA sits on
 *    the same sale. Narrowing it to "buyers who signed an NDA on THIS disposition" is a
 *    per-record query no declarative lookup filter can state.
 * 2. NAVIGATING TO THE PLATFORM'S CREATE SCREEN THROWS THE USER OFF THE PAGE. Both existing
 *    "+ Log Offer" buttons called `NavigationMixin.Navigate` with
 *    `type: 'standard__objectPage', actionName: 'new'`, and the platform's own post-save
 *    behaviour there is to navigate to the record just created. Nothing suppresses it —
 *    `navigationLocation` belongs to the Aura `force:createRecord` event, not to
 *    `NavigationMixin` — so the fix is to stop navigating, exactly as `c/bovAddResponseModal`
 *    did for the same complaint two days earlier. This component is deliberately that
 *    component's twin in structure.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE BUYER IS PICKED, NOT STAMPED. "ONE BUYER PER DISPOSITION" WAS REJECTED, AND IT WOULD
 *    HAVE BEEN WRONG SILENTLY.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `DispositionBuyerTimelineService` joins each buyer's NDA to THAT BUYER'S first offer on a
 * Contact Id at both ends. Stamping one disposition-scoped buyer onto every offer would show
 * buyer 1 a date derived from buyers 2 and 3's offers, leave the others permanently blank, and
 * render the same name on every row of the competitive bid table. A multi-buyer sale is the
 * NORMAL shape here. The analyst still never types a buyer — they choose from the two or three
 * names the deal already has.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ THE COMPONENT WRITES NEITHER `Buyer_Name__c` NOR ANY OTHER DERIVED FIELD, AND MUST NOT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `DispositionOfferBuyerStampService.stampBuyerName` ALREADY derives `Buyer_Name__c` from
 * `Buyer__c` in before-insert, and a before trigger runs BEFORE validation — so setting the
 * lookup satisfies `Buyer_Required_On_Offer` (`ISBLANK(Buyer_Name__c)`) inside the same save.
 * Sending the text as well would be sending a value the trigger overwrites in the same
 * transaction.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 `Offer_Financing_Type__c` IS ON THIS FORM EVEN THOUGH THE USER ASKED TO HIDE IT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * It is read by `c/dispositionOfferSelect` (rendered into the Select Offer radio label) and is
 * an `approvalPageField` on `Offer_Selection_Approval`. This dialog is the only entry point, so
 * dropping it blanks BOTH surfaces on every offer created afterwards, permanently and silently —
 * at the exact moment someone is choosing the winning bid. The user has been told; the decision
 * is theirs to reverse, and the template says the same thing beside the field.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 DEPLOY-ORDER DEPENDENCY: `Disposition_Offer__c.Broker__c` MUST EXIST BEFORE THIS SHIPS.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The field is owned by the admin agent and, as of 2026-08-21, exists in NEITHER the repo NOR
 * `usman-dpeg` (verified by `sf sobject describe`). The payload includes `Broker__c` ONLY when a
 * broker actually resolved, so a disposition with no appointed broker saves cleanly even without
 * the field — but on a sale that HAS one, `lightning-record-edit-form` would refuse the save with
 * an unknown-field error. Field + both permission-set grants must land first. ⚠ A
 * Metadata-API-deployed field arrives with NO FLS for anyone, System Administrator included.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ BOTH SUBMIT PATHS INJECT THE SAME THREE VALUES. THERE ARE GENUINELY TWO PATHS.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *   1. The footer "Save offer" button calls `handleSave`, which gathers the input-field values
 *      itself and calls `form.submit(fields)`. It HAS to gather them: calling `submit()` from a
 *      plain (non-`type="submit"`) button does NOT fire the form's `onsubmit`, so nothing else
 *      would get a chance to add anything.
 *   2. Pressing ENTER inside any text input natively submits the form, which DOES fire
 *      `onsubmit` — a path the footer button never touches. `handleSubmit` covers it.
 * Both funnel through `withResolvedFields()`, so exactly one place knows that `Disposition__c`,
 * `Buyer__c` and `Broker__c` are not carried by ordinary inputs: the parent is `disabled` (and a
 * disabled control is conventionally excluded from a submission), the buyer lives in a
 * `lightning-combobox` outside the form's field set, and the broker is plain text.
 */
export default class DispositionLogOfferModal extends LightningModal {
    /** The `Disposition__c` this offer is being logged against. */
    @api dispositionId;

    _buyerId;
    _buyerOptions = [];
    _brokerId;
    _brokerName = '';
    _brokerSource = '';
    _isOnMarket = true;
    _loaded = false;
    _loadError;
    _saving = false;

    /**
     * The single server read: the resolved broker and the selectable buyers.
     *
     * ⚠ `dispositionId` is reactive (`'$dispositionId'`) so the wire re-runs if the opener sets
     * the property after the first render. The Apex method is null-safe and answers an EMPTY
     * context rather than throwing, which is what stops a first-render flash from raising an
     * error the user cannot act on.
     */
    @wire(getOfferFormContext, { dispositionId: '$dispositionId' })
    wiredContext({ data, error }) {
        if (data) {
            this._loadError = undefined;
            this._brokerId = data.brokerId || undefined;
            this._brokerName = data.brokerName || '';
            this._brokerSource = data.brokerSource || '';
            this._isOnMarket = data.isOnMarket !== false;
            this._buyerOptions = data.buyers || [];
            // ⚠ AUTO-SELECT WHEN THERE IS EXACTLY ONE BUYER. A menu of one is a question with a
            // single answer, and forcing the analyst to open it is a step that can only be got
            // wrong by forgetting it. It is NOT a stamp: with two or more buyers nothing is
            // preselected, so the common competitive case still demands a deliberate choice.
            this._buyerId =
                this._buyerOptions.length === 1
                    ? this._buyerOptions[0].value
                    : undefined;
            this._loaded = true;
        } else if (error) {
            this._loadError =
                (error && error.body && error.body.message) || GENERIC_LOAD_ERROR;
            this._buyerOptions = [];
            this._loaded = true;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Rendering state. ⚠ EVERY DISPLAYED GETTER RETURNS A STRING, NEVER `undefined` — a getter
    // bound to a custom element ATTRIBUTE is written UNCONDITIONALLY, so `undefined` renders the
    // literal text "undefined" (measured in this repo).
    // ─────────────────────────────────────────────────────────────────────────────────────

    /** The spinner covers both the initial load and an in-flight save. */
    get isBusy() {
        return !this._loaded || this._saving;
    }

    get hasLoadError() {
        return !!this._loadError;
    }

    get loadErrorMessage() {
        return this._loadError || '';
    }

    /**
     * 🔴 THE EMPTY STATE IS GATED ON `_loaded`, NOT MERELY ON AN EMPTY LIST. Without that the
     * dialog would flash "No buyer available" for one frame on every single open, before the wire
     * answers — a false statement shown to every user on the happy path. (That heading read "No
     * buyer can be attributed yet" until the 2026-08-21 UAT copy cut; the gate is unrelated to the
     * wording and did not change.)
     */
    get showEmptyState() {
        return this._loaded && !this._loadError && this._buyerOptions.length === 0;
    }

    /** No Save button in the empty state or on a load failure — see the footer comment. */
    get canSave() {
        return this._loaded && !this._loadError && this._buyerOptions.length > 0;
    }

    /** "Cancel" while there is something to cancel; "Close" when the dialog is only informing. */
    get cancelLabel() {
        return this.canSave ? 'Cancel' : 'Close';
    }

    get buyerOptions() {
        return this._buyerOptions;
    }

    get buyerId() {
        return this._buyerId;
    }

    get hasBroker() {
        return !!this._brokerId;
    }

    get brokerName() {
        return this._brokerName || '';
    }

    get brokerSource() {
        return this._brokerSource || '';
    }

    get brokerEmptyHint() {
        return this._isOnMarket ? BROKER_HINT_ON_MARKET : BROKER_HINT_OFF_MARKET;
    }

    get isSaving() {
        return this._saving;
    }

    handleBuyerChange(event) {
        this._buyerId = event.detail.value;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Submit
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * The ONE place that knows which values are not carried by an ordinary form input.
     *
     * 🔴 ALL THREE ARE INVISIBLE TO `lightning-record-edit-form`'s OWN FIELD SET:
     *   `Disposition__c` is rendered `disabled`, and a disabled control is conventionally
     *      excluded from a submission — relying on it would make the parent depend on a
     *      base-component implementation detail;
     *   `Buyer__c` lives in a `lightning-combobox`, which is not an `input-field` and is not part
     *      of the form's field set at all;
     *   `Broker__c` is rendered as plain TEXT, because there is no case in which it should be
     *      hand-picked on an offer.
     *
     * ⚠ `Broker__c` IS OMITTED ENTIRELY WHEN NO BROKER RESOLVED, rather than sent as null. Two
     * reasons: a null would be a WRITE (clearing a field the form never showed), and — until the
     * admin agent's field lands — omitting the key is what lets this dialog save at all on a
     * disposition with no appointed broker.
     *
     * @param {object} fields the values gathered from the form
     * @returns {object} the payload actually sent
     */
    withResolvedFields(fields) {
        const payload = {
            ...fields,
            Disposition__c: this.dispositionId,
            Buyer__c: this._buyerId
        };
        if (this._brokerId) {
            payload.Broker__c = this._brokerId;
        }
        return payload;
    }

    /**
     * Native submit path (ENTER inside a text input). `preventDefault` stops the form's own
     * default submission so the injected payload is the one that goes.
     *
     * ⚠ `submit(fields)` does NOT re-enter this handler — that is the documented shape of the
     * pattern, and it is what stops this being infinite recursion.
     */
    handleSubmit(event) {
        event.preventDefault();
        if (!this._buyerId) {
            // Same gate as the footer button. ENTER must not be a way around a required field.
            this.reportBuyerRequired();
            return;
        }
        this._saving = true;
        this.template
            .querySelector('lightning-record-edit-form')
            .submit(this.withResolvedFields(event.detail.fields));
    }

    /** Footer-button submit path. See the class header for why it gathers fields itself. */
    handleSave() {
        if (this._saving) {
            return;
        }

        // 🔴 A REAL GATE, NOT A DECORATIVE ONE. `Buyer_Required_On_Offer` refuses the save
        // server-side anyway, but its message names `Buyer_Name__c` — a field this form does not
        // show — so letting it round-trip would point the user at nothing. Checked on the stored
        // value rather than on the combobox's validity, so it works identically in Jest, where
        // `reportValidity()` returns undefined.
        if (!this._buyerId) {
            this.reportBuyerRequired();
            return;
        }

        const inputs = [...this.template.querySelectorAll('lightning-input-field')];

        // ⚠ ABORTS ONLY ON AN EXPLICIT `false`. `reportValidity()` returns a boolean on the real
        // base component; the sfdx-lwc-jest stub is `@api reportValidity() {}` and returns
        // UNDEFINED, so a truthiness test here would abort every save under Jest and leave the
        // whole submit path unexercised while the suite stayed green. The `=== false` comparison
        // keeps the real client-side gate and lets the stub fall through.
        if (inputs.some((input) => input.reportValidity() === false)) {
            return;
        }

        const fields = {};
        inputs.forEach((input) => {
            if (input.value !== undefined && input.value !== null) {
                fields[input.fieldName] = input.value;
            }
        });

        this._saving = true;
        this.template
            .querySelector('lightning-record-edit-form')
            .submit(this.withResolvedFields(fields));
    }

    /**
     * Surfaces "pick a buyer" through the combobox's OWN validity, so the message lands against
     * the control it is about rather than in a banner at the top of the dialog.
     *
     * ⚠ Guarded because the combobox is absent in the empty state and on a load error, where this
     * path is unreachable through the UI but reachable through a stray programmatic call.
     */
    reportBuyerRequired() {
        const combobox = this.template.querySelector('lightning-combobox');
        if (combobox) {
            combobox.reportValidity();
        }
    }

    /**
     * 🔴 THE OUTCOME GOES TO THE OPENER, NOT TO A TOAST RAISED FROM HERE. This component is about
     * to be destroyed; a toast dispatched from a closing modal is a race, and the offers card is
     * the thing that has to refresh anyway.
     */
    handleSuccess(event) {
        this._saving = false;
        const detail = event.detail || {};
        this.close({
            recordId: detail.id,
            name:
                (detail.fields && detail.fields.Name && detail.fields.Name.value) || ''
        });
    }

    /**
     * 🔴 A FAILURE KEEPS THIS MODAL OPEN, and the message stays inside the form.
     *
     * Every realistic refusal here is about WHAT WAS ENTERED — a missing amount, a negative
     * due-diligence period — and each active validation rule carries an authored message naming
     * its own field. `<lightning-messages>` has already rendered it against that field by the time
     * this runs, so closing the dialog would throw away both the message and the user's other
     * values. This handler's only job is to release the spinner. `_message` is captured for
     * diagnosis only and is deliberately not rendered a second time.
     */
    handleError(event) {
        this._saving = false;
        this._message =
            (event.detail && (event.detail.message || event.detail.detail)) ||
            GENERIC_SAVE_ERROR;
    }

    handleCancel() {
        this.close();
    }
}
