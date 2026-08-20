import { api, wire } from 'lwc';
import LightningModal from 'lightning/modal';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import BOV_BROKER_CHANGE_OBJECT from '@salesforce/schema/BOV_Broker_Change__c';
import REASON_FIELD from '@salesforce/schema/BOV_Broker_Change__c.Reason__c';
import replaceSelectedBroker from '@salesforce/apex/BovController.replaceSelectedBroker';

/** Fallback when the Apex error carries no readable body. */
const GENERIC_ERROR = 'The selected broker could not be replaced.';

/**
 * Shown when the reason picklist itself cannot be read. It BLOCKS the action rather than degrading
 * it — see the header note on why an unattributed swap is not an acceptable fallback.
 */
const REASON_LOAD_ERROR =
    'The list of reasons could not be loaded, so the broker cannot be replaced right now. Contact your administrator.';

/**
 * c-bov-replace-broker-modal — promotes one of the BACKUP BOV submissions to Selected, demoting the
 * incumbent (design DEV-15 / DEV-6).
 *
 * ── 🔴 THE RETURNED MESSAGE IS THE PRODUCT, NOT A RECEIPT ───────────────────
 * `BovSubmissionService.replaceSelectedBroker` clears the outgoing submission's
 * `Approval_Status__c` as part of the swap, so the incoming broker is NOT approved — a fresh
 * `Broker_Finalize_Approval` has to be raised and won before the disposition may leave
 * `BOV Outreach`. The service's returned String ALREADY SAYS SO, in wording the service owns.
 *
 * 🔴 DO NOT RE-AUTHOR THAT WARNING HERE, and do not append to it. The consequence it describes is a
 * property of the SERVER's behaviour; a second copy of the sentence in JS is a copy that will still
 * be claiming "a fresh approval is required" the day someone changes the service to preserve the
 * approval status. This component's whole job on the success path is to hand that text back
 * untouched.
 *
 * ── WHERE THE TEXT IS SHOWN, AND WHY NOT HERE ────────────────────────────────
 * `close({ message })` hands it to `c/bovComparisonMatrix`, which raises it as a STICKY WARNING
 * toast and then refreshes its own wire. Showing it in this modal instead would put an important,
 * consequential warning on a surface that is about to disappear — and a toast raised from a modal
 * that is closing in the same tick is a race. The matrix outlives this component.
 *
 * ── WHY A FAILURE KEEPS THIS MODAL OPEN ──────────────────────────────────────
 * Opposite of `c/sellMeterInitiateModal`, and for the opposite reason: a refusal here is usually
 * about the CHOSEN SUBMISSION (it is already Selected, it has a pending approval), so picking a
 * different backup is a real remedy. The sell-meter refusals are properties of the asset, where a
 * retry is pointless.
 *
 * ── REASON + NOTES (2026-08-20, Tranche 2 Workstream B / design D4.5) ────────
 * The swap now also writes a `BOV_Broker_Change__c` history row, and this modal collects the two
 * fields nothing else can supply: WHY (required) and free-text detail (optional).
 *
 * 🔴 THE REASON OPTIONS COME FROM `getPicklistValues`, NEVER FROM AN ARRAY IN THIS FILE. A
 * hardcoded array is correct on the day it is written and silently wrong the day somebody adds a
 * value in Setup — the modal would keep offering four options out of five, with nothing failing
 * anywhere to reveal it. `Reason__c` is a RESTRICTED picklist, so a value this component invents is
 * refused by the platform at DML; a value it OMITS is simply unreachable, which is worse because it
 * is invisible. `getObjectInfo` supplies `defaultRecordTypeId` — the object has no record types, so
 * this resolves to the master type, and reading it beats hardcoding `012000000000000AAA`.
 *
 * ⚠ IF THE PICKLIST CANNOT BE READ, THE ACTION IS BLOCKED RATHER THAN DEGRADED, DELIBERATELY. The
 * tempting fallback — let the user proceed without a reason — produces exactly the row this
 * workstream exists to prevent: a durable record that a broker changed, answering none of the
 * questions it is read to answer. The server enforces the same rule independently
 * (`BovSubmissionService.REASON_REQUIRED_MESSAGE`), so degrading here would only convert a clear
 * client-side explanation into a confusing server-side refusal. The wire's failure mode in practice
 * is a missing FLS grant on a 2026-08-20 field, and the message says to contact an administrator
 * because that is precisely the fix.
 */
export default class BovReplaceBrokerModal extends LightningModal {
    /** The Disposition__c whose Selected_Broker__c is being swapped. */
    @api dispositionId;
    /**
     * Backup submissions as ready-made radio options (`{ label, value }`), composed by
     * `c/bovComparisonMatrix` from the SAME `getSubmissions` payload that draws the matrix rows.
     * This component does no formatting, so the modal and the matrix behind it cannot disagree
     * about the same broker's numbers.
     */
    @api backupOptions;
    /** Display name of the incumbent, for the prompt copy. */
    @api currentBroker;

    newSubmissionId;
    /** Selected `BOV_Broker_Change__c.Reason__c` value. Required before Confirm enables. */
    reason;
    /** Optional free text for the history row. */
    notes;
    /** Inline, user-safe text for a failed replace. The modal stays open. */
    error;
    _saving = false;
    _reasonOptions = [];
    _reasonLoadFailed = false;

    @wire(getObjectInfo, { objectApiName: BOV_BROKER_CHANGE_OBJECT })
    objectInfo;

    /**
     * ⚠ The config depends on `$objectInfo.data.defaultRecordTypeId`, so this wire does not
     * provision until getObjectInfo has answered. That is ordinary LDS chaining, not a bug — but it
     * does mean "no options yet" and "options failed to load" are different states, tracked
     * separately below so the second one can explain itself.
     */
    @wire(getPicklistValues, {
        recordTypeId: '$objectInfo.data.defaultRecordTypeId',
        fieldApiName: REASON_FIELD
    })
    wiredReasons({ data, error }) {
        if (data) {
            // The wire's own {label, value} shape is already lightning-combobox's option shape.
            // Passed through rather than re-mapped, so a value added in Setup appears here with no
            // code change at all.
            this._reasonOptions = data.values;
            this._reasonLoadFailed = false;
        } else if (error) {
            this._reasonOptions = [];
            this._reasonLoadFailed = true;
        }
    }

    get options() {
        return this.backupOptions || [];
    }
    get hasOptions() {
        return this.options.length > 0;
    }
    get reasonOptions() {
        return this._reasonOptions;
    }
    get reasonLoadError() {
        return this._reasonLoadFailed ? REASON_LOAD_ERROR : undefined;
    }
    get incumbentLabel() {
        return this.currentBroker || 'the current broker';
    }
    get isSaving() {
        return this._saving;
    }
    /**
     * 🔴 THE REASON IS PART OF THE GATE. Confirm stays disabled until a backup AND a reason are
     * chosen — the same rule the server enforces, so a user can never reach a refusal they could
     * have been shown as a disabled button.
     */
    get confirmDisabled() {
        return this._saving || !this.newSubmissionId || !this.reason;
    }

    handleSelection(event) {
        this.newSubmissionId = event.detail.value;
        this.error = undefined;
    }

    handleReasonChange(event) {
        this.reason = event.detail.value;
        this.error = undefined;
    }

    handleNotesChange(event) {
        this.notes = event.detail.value;
    }

    handleCancel() {
        this.close();
    }

    async handleConfirm() {
        if (this.confirmDisabled) {
            return;
        }
        this._saving = true;
        this.error = undefined;
        try {
            // ⚠ Parameter names are the Apex signature verbatim:
            // BovController.replaceSelectedBroker(Id dispositionId, Id newSubmissionId,
            //                                     String reason, String notes).
            // An imperative Apex call binds by NAME — a mismatch here does not fail the build, it
            // arrives at Apex as a null.
            const message = await replaceSelectedBroker({
                dispositionId: this.dispositionId,
                newSubmissionId: this.newSubmissionId,
                reason: this.reason,
                notes: this.notes
            });
            this.close({ message });
        } catch (error) {
            this.error = (error && error.body && error.body.message) || GENERIC_ERROR;
        } finally {
            this._saving = false;
        }
    }
}
