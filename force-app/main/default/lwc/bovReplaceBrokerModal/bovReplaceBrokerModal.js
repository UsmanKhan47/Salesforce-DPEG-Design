import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import replaceSelectedBroker from '@salesforce/apex/BovController.replaceSelectedBroker';

/** Fallback when the Apex error carries no readable body. */
const GENERIC_ERROR = 'The selected broker could not be replaced.';

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
    /** Inline, user-safe text for a failed replace. The modal stays open. */
    error;
    _saving = false;

    get options() {
        return this.backupOptions || [];
    }
    get hasOptions() {
        return this.options.length > 0;
    }
    get incumbentLabel() {
        return this.currentBroker || 'the current broker';
    }
    get isSaving() {
        return this._saving;
    }
    get confirmDisabled() {
        return this._saving || !this.newSubmissionId;
    }

    handleSelection(event) {
        this.newSubmissionId = event.detail.value;
        this.error = undefined;
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
            // BovController.replaceSelectedBroker(Id dispositionId, Id newSubmissionId).
            const message = await replaceSelectedBroker({
                dispositionId: this.dispositionId,
                newSubmissionId: this.newSubmissionId
            });
            this.close({ message });
        } catch (error) {
            this.error = (error && error.body && error.body.message) || GENERIC_ERROR;
        } finally {
            this._saving = false;
        }
    }
}
