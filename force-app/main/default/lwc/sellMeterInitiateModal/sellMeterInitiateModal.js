import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import initiateAndSubmit from '@salesforce/apex/DispositionController.initiateAndSubmit';

/**
 * The two allowed record types, and the ONLY two.
 *
 * 🔴 THE VALUES ARE RECORD TYPE **DEVELOPER NAMES**, NOT LABELS. They are matched
 * character-for-character against `objects/Disposition__c/recordTypes/On_Market` and
 * `.../Off_Market` by `DispositionService.initiateAndSubmit`'s allow-list, which throws
 * `InvalidRecordTypeException` on anything else. That exception is deliberately masked behind the
 * controller's generic write-failure message — it is a CALLER defect, not something a user can act
 * on — so a typo here surfaces as an unexplained "could not create" rather than as anything that
 * names this file. Do not "tidy" these into 'On Market' / 'Off Market'.
 */
const RECORD_TYPE_OPTIONS = [
    { label: 'On Market', value: 'On_Market' },
    { label: 'Off Market', value: 'Off_Market' }
];

/** Placeholder for a summary value the caller did not supply. */
const DASH = '—';

/**
 * c-sell-meter-initiate-modal — the Sell Meter "Initiate" / "Override" popup
 * (user-confirmed decision 1 of the disposition flow redesign).
 *
 * Read-only property summary + a MANDATORY On Market / Off Market choice, then one call to
 * `DispositionController.initiateAndSubmit`, which creates the Disposition at the chosen record
 * type AND submits it into `Sale_Decision_Approval` in the same transaction.
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
    /** Display name of that property. Used in the prompt copy only. */
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

    get propertyLabel() {
        return this.propertyName || 'this property';
    }

    get isSaving() {
        return this._saving;
    }

    /**
     * "Send for Approval" stays disabled until a record type is chosen — the choice is MANDATORY
     * (user-confirmed decision 1) and there is deliberately no default. A default would silently
     * decide the entire downstream path (On Market gets BOV Outreach + Active Listing; Off Market
     * gets neither) for a user who never looked at the radio.
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
            // DispositionController.initiateAndSubmit(Id assetId, String recordTypeDeveloperName).
            // A mismatch here is not a compile error on either side — the call simply arrives with
            // a null argument.
            const outcome = await initiateAndSubmit({
                assetId: this.assetId,
                recordTypeDeveloperName: this.recordType
            });
            this.close({ outcome });
        } catch (error) {
            this.close({ error });
        } finally {
            this._saving = false;
        }
    }
}
