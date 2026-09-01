import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import initiateAndSubmit from '@salesforce/apex/DispositionController.initiateAndSubmit';

/**
 * The two allowed record types, and the ONLY two — rendered as the "Sell Type" picklist.
 *
 * 🔴 THE VALUES ARE RECORD TYPE **DEVELOPER NAMES**, NOT LABELS. They are matched
 * character-for-character against `objects/Disposition__c/recordTypes/On_Market` and
 * `.../Off_Market` by `DispositionService.initiateAndSubmit`'s allow-list, which throws
 * `InvalidRecordTypeException` on anything else. That exception is deliberately masked behind the
 * controller's generic write-failure message — it is a CALLER defect, not something a user can act
 * on — so a typo here surfaces as an unexplained "could not create" rather than as anything that
 * names this file. Do not "tidy" these into 'On Market' / 'Off Market'.
 *
 * ⚠ THE LABELS ARE HYPHENATED, THE VALUES ARE NOT, AND THAT ASYMMETRY IS THE WHOLE POINT
 * (user instruction, 2026-08-24: "Sell Type: 1- On-Market 2. Off-Market"). The hyphen is a
 * PRESENTATION change and stops at this array. It was NOT applied to the record type labels in
 * `objects/Disposition__c/recordTypes/`, and no `Sell_Type__c` field was created to carry it —
 * both were settled user decisions, so this list is the only place the hyphenated spelling
 * exists. Anyone reconciling the two will find them different ON PURPOSE.
 */
const RECORD_TYPE_OPTIONS = [
    { label: 'On-Market', value: 'On_Market' },
    { label: 'Off-Market', value: 'Off_Market' }
];

/** Placeholder for a summary value the caller did not supply. */
const DASH = '—';

/**
 * c-sell-meter-initiate-modal — the Sell Meter "Initiate" / "Override" popup
 * (user-confirmed decision 1 of the disposition flow redesign).
 *
 * Read-only property summary + a MANDATORY "Sell Type" choice (On-Market / Off-Market), then one
 * call to `DispositionController.initiateAndSubmit`, which creates the Disposition at the chosen
 * record type AND submits it into `Sale_Decision_Approval` in the same transaction.
 *
 * ⚠ THE DIALOG IS TITLED "Decide to Sell - Approval" AND THE CONTROL IS A PICKLIST (both user
 * instructions, 2026-08-24). The control was a `lightning-radio-group` until then; the swap is
 * presentational only — same values, same mandatory gate, same Apex call.
 *
 * ── WHY THE SUMMARY ARRIVES PRE-FORMATTED ────────────────────────────────────
 * Every summary field is a STRING the caller already rendered (`sellMeterList.allRows` builds
 * `noiLabel` / `capRateLabel` / `targetLabel` / `peakDateLabel` for the datatable). This modal does
 * no formatting and holds no formatter, so the popup and the row it was opened from cannot disagree
 * about the same property's numbers — which they would the moment two independent `_fmtM`
 * implementations drifted. It also means this component needs NO wire and NO record read at all.
 *
 * ── 🔴 THE CLOSE CONTRACT (read this before changing `handleConfirm`) ────────
 * `close()` is called with exactly one of three shapes, and the caller
 * (`c/sellMeterList._openInitiateModal`) branches on them:
 *
 *   undefined        Cancelled or dismissed. Nothing was created. Say nothing.
 *   { outcome }      The Apex returned. `outcome` is `DispositionService.InitiateOutcome`
 *                    ({ dispositionId, submitted, message }) — see the DTO-name warning below.
 *   { error }        The Apex THREW. The caller raises its sticky error toast.
 *
 * ⚠ A THROW CLOSES THIS MODAL RATHER THAN KEEPING IT OPEN, WHICH IS THE OPPOSITE OF
 * `c/brokerReplaceQuickAction`'s inline-error behaviour, and the difference is deliberate. Every
 * refusal reachable from here is terminal FOR THIS ASSET, not for this FORM: the RED-band
 * sell-meter gate and the "already has an open disposition" refusal are both properties of the
 * Property Asset, so re-picking the other record type and pressing the button again produces the
 * identical refusal. Keeping the form open would invite exactly that pointless retry. The
 * brokerReplaceQuickAction case is different — there the user can pick a different broker and
 * succeed.
 *
 * ⚠ `submitted === false` IS NOT AN ERROR AND MUST NOT BE TURNED INTO ONE HERE. It arrives on the
 * SUCCESS path with `dispositionId` populated; the record exists. `DispositionController`'s header
 * states the same contract from the server side.
 */
export default class SellMeterInitiateModal extends LightningModal {
    /** The Property_Asset__c to initiate against. */
    @api assetId;
    /**
     * Display name of that property.
     *
     * ⚠ NO LONGER RENDERED (2026-08-21). It fed the intro paragraph, which the UAT prose removal
     * deleted. The property is RETAINED rather than removed because `c/sellMeterList` still passes
     * it into `LightningModal.open()`, and because the property's NAME is the one fact that
     * removal cost this dialog — if a user asks for it back, this is the value to render, as a
     * fifth `summaryRows` entry and not as a sentence.
     */
    @api propertyName;

    // ── Pre-formatted summary strings, supplied by the caller (see header) ──
    /** Net operating income, already formatted (e.g. '$2.0M'). */
    @api noiLabel;
    /** Market cap rate, already formatted (e.g. '6.5%'). */
    @api capRateLabel;
    /** Target price, already formatted (e.g. '$30.0M'). */
    @api targetLabel;
    /** Peak sell date, already formatted (e.g. 'Aug 12, 2027'). */
    @api peakDateLabel;

    /**
     * The principal's override reason — A PASS-THROUGH. THIS DIALOG NEVER RENDERS IT.
     *
     * Added 2026-08-31 (Tranche 2 item 5b, stories 12 / 14). It is collected by
     * `c/sellMeterOverrideModal`, which runs BEFORE this dialog on the YELLOW band, handed
     * straight down by `c/sellMeterList`, and forwarded verbatim as the third argument of
     * `DispositionController.initiateAndSubmit`. It is `null` on the GREEN Initiate path.
     *
     * 🔴 IT IS NOT RENDERED, AND THAT IS THE ENTIRE REASON IT IS A PASS-THROUGH RATHER THAN A
     * FIELD ON THIS FORM. This modal's class header states that Initiate and Override must be
     * "deliberately identical apart from the toast title, so an override can never diverge from an
     * initiate". An override-only textarea here — the cheaper design, and the one that was
     * rejected — would make the two paths visibly different and reverse that recorded decision as
     * a side effect of an audit change. Adding a `summaryRows` entry for it, or any markup that
     * reads it, is the same reversal.
     *
     * ⚠ IT IS ALSO NOT VALIDATED HERE. Requiredness is enforced by
     * `c/sellMeterOverrideModal.confirmDisabled`, one dialog earlier, because that is where the
     * user types it. A second check here would refuse a value this dialog cannot help the user
     * fix — its form has no field to correct.
     */
    @api overrideReason;

    /** The chosen record type developer name. Undefined until the user picks one. */
    recordType;
    /** Inline, user-safe text for a failure that must not close the modal. */
    error;
    _saving = false;

    get recordTypeOptions() {
        return RECORD_TYPE_OPTIONS;
    }

    /**
     * The read-only property summary, as label/value pairs for a <dl>.
     *
     * Each value falls back to an em dash rather than to `undefined`: these render as TEXT, but the
     * repo has been bitten by the attribute variant of the same bug (a getter bound to a custom
     * element attribute is written UNCONDITIONALLY, so `undefined` renders the literal string
     * "undefined"), and a single dash-defaulting rule for every displayed value is cheaper to hold
     * than a per-binding judgement about which position it lands in.
     */
    get summaryRows() {
        return [
            { key: 'noi', label: 'NOI', value: this.noiLabel || DASH },
            { key: 'cap', label: 'Market Cap Rate', value: this.capRateLabel || DASH },
            { key: 'target', label: 'Target Price', value: this.targetLabel || DASH },
            { key: 'peak', label: 'Peak Sell Date', value: this.peakDateLabel || DASH }
        ].map((r) => ({
            ...r,
            // Each iteration emits a dt AND a dd as siblings in the same list, so
            // they need DISTINCT keys — see the markup comment.
            labelKey: `${r.key}-label`,
            valueKey: `${r.key}-value`
        }));
    }

    // ⚠ `propertyLabel` WAS DELETED ON 2026-08-21 with the intro paragraph, its only consumer. Its
    // `|| 'this property'` fallback existed to stop an absent `propertyName` rendering the literal
    // string "undefined"; nothing binds that value now, and the suite still pins
    // `not.toContain('undefined')` on the rendered markup for the bindings that remain.

    get isSaving() {
        return this._saving;
    }

    /**
     * "Send for Approval" stays disabled until a Sell Type is chosen — the choice is MANDATORY
     * (user-confirmed decision 1) and there is deliberately no default. A default would silently
     * decide the entire downstream path (On-Market gets BOV Outreach + Active Listing; Off-Market
     * gets neither) for a user who never opened the picklist.
     *
     * 🔴 THIS GETTER IS THE ONLY REAL ENFORCEMENT OF `required`. The markup's `required`
     * attribute draws the asterisk, but `lightning-combobox` (like the radio group before it)
     * only refuses on `reportValidity()`, which nothing calls here — this dialog has no
     * `lightning-record-edit-form` and no submit path other than the button below. Delete this
     * gate and the picklist's asterisk becomes decoration.
     */
    get confirmDisabled() {
        return this._saving || !this.recordType;
    }

    handleRecordTypeChange(event) {
        this.recordType = event.detail.value;
        this.error = undefined;
    }

    /** Cancel and dismiss both resolve `undefined` — nothing was created, so say nothing. */
    handleCancel() {
        this.close();
    }

    /**
     * Create + submit, then hand the result back to the opener. See the close contract in the class
     * header — this method must never `throw`, and must never convert `submitted === false` into an
     * error.
     */
    async handleConfirm() {
        if (this.confirmDisabled) {
            return;
        }
        this._saving = true;
        this.error = undefined;
        try {
            // ⚠ PARAMETER NAMES ARE THE APEX SIGNATURE, VERBATIM:
            // DispositionController.initiateAndSubmit(Id assetId, String recordTypeDeveloperName,
            // String overrideReason).
            // A mismatch here is not a compile error on either side — the call simply arrives with
            // a null argument. 🔴 THAT MATTERS MOST FOR `overrideReason` (added 2026-08-31), whose
            // null is INDISTINGUISHABLE FROM A GREEN INITIATE on the server: a misspelling here
            // would not throw, would not fail a test that only checks the outcome, and would
            // silently drop the principal's stated reason on every override while everything
            // reported success.
            const outcome = await initiateAndSubmit({
                assetId: this.assetId,
                recordTypeDeveloperName: this.recordType,
                overrideReason: this.overrideReason
            });
            this.close({ outcome });
        } catch (error) {
            this.close({ error });
        } finally {
            this._saving = false;
        }
    }
}
