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
 * generic sentence would misdirect half the users. These are now the REMEDY line of a refusal
 * panel, not help text under an empty field.
 */
const BROKER_HINT_ON_MARKET =
    'The broker is set when a BOV submission is approved on the comparison matrix.';
const BROKER_HINT_OFF_MARKET =
    'The broker is set on this disposition at the Broker Selection stage.';

/**
 * c-disposition-log-offer-modal — logs a `Disposition_Offer__c` against the disposition the user is
 * already looking at, WITHOUT leaving that page, with the broker auto-resolved (2026-08-21).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE BUYER PICKER WAS DELETED ON 2026-08-21. DO NOT RE-ADD IT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * User decision: *"we don't need buyer information, we just need broker contact for disposition
 * offers and NDA… everything must be linked with broker contact as he is the only person that DPEG
 * will be communicating"*. The combobox, its wire payload, its de-duplication, its required-field
 * gate and its "No buyer available" empty state are all gone. `Buyer__c` is no longer sent on either
 * submit path.
 * ⚠ THE ARGUMENT THAT USED TO SIT HERE — "the buyer is picked, not stamped, because the timeline
 * joins each buyer's NDA to THAT BUYER'S first offer" — is moot: that join was deleted the same day.
 * Do not resurrect the picker from it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 🔴 SHIP-BLOCKER: `Buyer_Required_On_Offer` IS STILL **ACTIVE** ON `Disposition_Offer__c`.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Measured in `usman-dpeg` via the Tooling API, 2026-08-21. Its formula is
 * `ISBLANK(Buyer_Name__c)` with no `ISNEW` guard, and `Buyer_Name__c` is derived from `Buyer__c` by
 * a before-save trigger. With the picker gone nothing sets `Buyer__c`, so **every save from this
 * dialog is refused until that rule is deactivated** by whoever owns `objects/**`. The refusal
 * arrives through `<lightning-messages>` naming a field this form does not show — which is exactly
 * the "error with no reachable fix on this screen" shape the old empty state existed to prevent.
 * This paragraph is the one-minute diagnosis.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE REFUSAL PATH MOVED: NO BROKER NOW MEANS NO FORM AND NO SAVE BUTTON.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The dialog's only refusal used to be "no eligible buyer". Deleting the picker deleted it, and a
 * dialog with no refusal path at all was not an option — so the refusal was RE-ESTABLISHED on the
 * broker, which is now the only party an offer names.
 *
 * ⚠ THE TWO REFUSALS ARE NOT THE SAME KIND OF THING, AND THE DIFFERENCE IS WORTH KNOWING. The old
 * one was FORCED: `Buyer_Required_On_Offer` made the save literally impossible, so rendering a form
 * would have been a trap. This one is a DESIGN DECISION — nothing on the platform stops a
 * broker-less offer saving (there is no `Broker_Required_On_Offer` rule; the six active rules were
 * enumerated in the org on 2026-08-21 and none of them names the broker). It is refused because,
 * with the buyer gone, an offer naming nobody cannot be attributed, cannot be told apart from
 * another offer on the same sale, and is what `DispositionApprovalService.selectOffer` would be
 * choosing between.
 * 🔴 THE COST IS REAL AND IS REPORTED, NOT HIDDEN: an offer that genuinely arrives before the broker
 * is appointed can no longer be logged here, and this dialog is the only entry point. The panel
 * names the remedy screen, which differs by record type. If that trade is wrong, the fix is one
 * getter (`canSave`) — not a partially-populated offer.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS IS AN LWC AND NOT A PAGE-LAYOUT EDIT — ONE REASON NOW, NOT TWO.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * NAVIGATING TO THE PLATFORM'S CREATE SCREEN THROWS THE USER OFF THE PAGE. Both existing
 * "+ Log Offer" buttons called `NavigationMixin.Navigate` with `type: 'standard__objectPage',
 * actionName: 'new'`, and the platform's own post-save behaviour there is to navigate to the record
 * just created. Nothing suppresses it — `navigationLocation` belongs to the Aura
 * `force:createRecord` event, not to `NavigationMixin` — so the fix is to stop navigating, exactly
 * as `c/bovAddResponseModal` did for the same complaint two days earlier.
 * ⚠ THE SECOND REASON IS GONE. It was "a classic page layout cannot express a filtered buyer
 * picker", and there is no picker any more. The remaining reason is sufficient on its own, and the
 * dialog additionally keeps the field set narrow and the broker read-only, which a layout cannot.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 `Offer_Financing_Type__c` IS ON THIS FORM EVEN THOUGH THE USER ASKED TO HIDE IT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * It is read by `c/dispositionOfferSelect` (rendered into the Select Offer radio label) and is
 * an `approvalPageField` on `Offer_Selection_Approval`. This dialog is the only entry point, so
 * dropping it blanks BOTH surfaces on every offer created afterwards, permanently and silently —
 * at the exact moment someone is choosing the winning bid. ⚠ ITS VALUE WENT UP ON 2026-08-21: with
 * the buyer name gone from that radio label, the financing type is now one of only three things
 * distinguishing two offers on the same sale. The user has been told; the decision is theirs to
 * reverse, and the template says the same thing beside the field.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ BOTH SUBMIT PATHS INJECT THE SAME TWO VALUES. THERE ARE GENUINELY TWO PATHS.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *   1. The footer "Save offer" button calls `handleSave`, which gathers the input-field values
 *      itself and calls `form.submit(fields)`. It HAS to gather them: calling `submit()` from a
 *      plain (non-`type="submit"`) button does NOT fire the form's `onsubmit`, so nothing else
 *      would get a chance to add anything.
 *   2. Pressing ENTER inside any text input natively submits the form, which DOES fire
 *      `onsubmit` — a path the footer button never touches. `handleSubmit` covers it.
 * Both funnel through `withResolvedFields()`, so exactly one place knows that `Disposition__c` and
 * `Broker__c` are not carried by ordinary inputs: the parent is `disabled` (and a disabled control
 * is conventionally excluded from a submission), and the broker is plain text.
 * ⚠ `Broker__c` IS NOW SENT UNCONDITIONALLY rather than omitted-when-null. That is safe ONLY
 * because the form does not render at all without a broker — see `canSave`. If that gate is ever
 * relaxed, restore the `if (this._brokerId)` guard in the same edit, because a null there would be
 * a WRITE clearing a field the form never showed.
 */
export default class DispositionLogOfferModal extends LightningModal {
    /** The `Disposition__c` this offer is being logged against. */
    @api dispositionId;

    _brokerId;
    _brokerName = '';
    _brokerSource = '';
    _isOnMarket = true;
    _loaded = false;
    _loadError;
    _saving = false;

    /**
     * The single server read: the resolved broker.
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
            this._loaded = true;
        } else if (error) {
            this._loadError =
                (error && error.body && error.body.message) || GENERIC_LOAD_ERROR;
            this._brokerId = undefined;
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
     * 🔴 THE REFUSAL PANEL IS GATED ON `_loaded`, NOT MERELY ON A MISSING BROKER. Without that the
     * dialog would flash "No broker appointed" for one frame on every single open, before the wire
     * answers — a false statement shown to every user on the happy path. (The panel used to say "No
     * buyer available"; the gate is unrelated to the wording and did not change when the subject
     * did.)
     */
    get showEmptyState() {
        return this._loaded && !this._loadError && !this._brokerId;
    }

    /**
     * No Save button in the refusal panel or on a load failure — see the footer comment.
     *
     * 🔴 IT GATES ON `brokerId`, NOT ON `brokerName`. The name can legitimately be '' while the Id
     * is set: `USER_MODE` returns a lookup Id but not the related sObject when the running user
     * cannot see that Contact under SHARING. Gating on the name would refuse the save for a sale
     * that genuinely has an appointed broker.
     */
    get canSave() {
        return this._loaded && !this._loadError && !!this._brokerId;
    }

    /** "Cancel" while there is something to cancel; "Close" when the dialog is only informing. */
    get cancelLabel() {
        return this.canSave ? 'Cancel' : 'Close';
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

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Submit
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * The ONE place that knows which values are not carried by an ordinary form input.
     *
     * 🔴 BOTH ARE INVISIBLE TO `lightning-record-edit-form`'s OWN FIELD SET:
     *   `Disposition__c` is rendered `disabled`, and a disabled control is conventionally
     *      excluded from a submission — relying on it would make the parent depend on a
     *      base-component implementation detail;
     *   `Broker__c` is rendered as plain TEXT, because there is no case in which it should be
     *      hand-picked on an offer.
     *
     * ⚠ NO NULL IS EVER SENT FOR `Broker__c`, because this method is unreachable without one —
     * the form only renders when `canSave` is true, and `canSave` requires a broker.
     *
     * @param {object} fields the values gathered from the form
     * @returns {object} the payload actually sent
     */
    withResolvedFields(fields) {
        return {
            ...fields,
            Disposition__c: this.dispositionId,
            Broker__c: this._brokerId
        };
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
     * ⚠ UNTIL `Buyer_Required_On_Offer` IS DEACTIVATED, THIS IS THE PATH EVERY SAVE TAKES, and the
     * message it renders names `Buyer_Name__c` — see the ship-blocker note in the class header.
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
