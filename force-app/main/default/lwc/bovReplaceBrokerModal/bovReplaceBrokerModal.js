import { api, wire } from 'lwc';
import LightningModal from 'lightning/modal';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import BOV_BROKER_CHANGE_OBJECT from '@salesforce/schema/BOV_Broker_Change__c';
import REASON_FIELD from '@salesforce/schema/BOV_Broker_Change__c.Reason__c';
import replaceSelectedBroker from '@salesforce/apex/BovController.replaceSelectedBroker';

/**
 * Fallbacks when the Apex error carries no readable body — one per mode, because "could not be
 * replaced" on a disposition that had no broker to replace sends the reader looking for a broker
 * that never existed. Every FORESEEABLE refusal arrives with a body and is surfaced verbatim; these
 * two only cover a bodyless failure (a dropped connection, a platform error with no message).
 */
const GENERIC_ERROR_REPLACE = 'The selected broker could not be replaced.';
const GENERIC_ERROR_APPOINT = 'The broker could not be appointed.';

/**
 * The `BOV_Broker_Change__c.Reason__c` value recorded for a FIRST appointment (2026-08-21).
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 YES, THIS IS A PICKLIST VALUE HARDCODED IN THE FILE WHOSE HEADER SAYS NEVER TO DO THAT.
 *    READ WHY BEFORE "FIXING" IT.
 * ══════════════════════════════════════════════════════════════════════════════
 * The rule below is about the OPTIONS ARRAY the user chooses from, and the failure it prevents is
 * a value added in Setup being silently unreachable because this file's list is one short. Neither
 * half applies here: on a first appointment the user chooses nothing, so there is no list to fall
 * behind, and no value can become unreachable. What is hardcoded is a single CONSTANT ANSWER to a
 * question with only one correct answer — every other `Reason__c` value presupposes a predecessor
 * (`Performance Issue`, `Better BOV Received`, `Broker Withdrew`, `Company Decision`, `Other`),
 * and `Initial Appointment` exists precisely because a first pick had nowhere honest to go.
 *
 * ⚠ IT IS NOT UNVALIDATED. `Reason__c` is a RESTRICTED picklist and restricted picklists ARE
 * enforced by Apex DML in this org, so if this string ever stops matching the metadata the insert
 * is refused with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` and the platform's own message is
 * surfaced verbatim through the existing catch — loudly, on the first click, not silently forever.
 * `BovSubmissionService.REASON_INITIAL_APPOINTMENT` is the server's own copy of the same literal,
 * and it is what refuses this value when there IS an incumbent.
 */
const REASON_INITIAL_APPOINTMENT = 'Initial Appointment';

/**
 * Shown when the reason picklist itself cannot be read. It BLOCKS the action rather than degrading
 * it — see the header note on why an unattributed swap is not an acceptable fallback.
 */
const REASON_LOAD_ERROR =
    'The list of reasons could not be loaded, so the broker cannot be replaced right now. Contact your administrator.';

/**
 * c-bov-replace-broker-modal — appoints a BOV submission as this disposition's Selected broker,
 * demoting the incumbent if there is one (design DEV-15 / DEV-6).
 *
 * ── 🔴 ONE BUNDLE, TWO MODES (2026-08-21) ────────────────────────────────────
 * `@api isFirstAppointment` switches the heading, the confirm label, the empty state and the
 * reason — and NOTHING else. (It also switched the INTRO COPY until 2026-08-21, when the UAT prose
 * removal deleted both mode notes; the flag now has one fewer visible effect, not a new one.) The Apex call, the exclusivity swap, the approval
 * revocation, the savepoint and the history row are identical, because they are the same server
 * method. The bundle was NOT forked into `bovSelectBrokerModal` deliberately: the five contracts
 * listed below are non-obvious, load-bearing and would have to be duplicated verbatim into a
 * second file that would then drift from this one. ⚠ The file name still says "replace" — renaming
 * an LWC bundle is a delete-and-recreate against every reference to it, which is churn bought with
 * risk for a word.
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
    /**
     * Display name of the incumbent. Absent on a first appointment.
     *
     * ⚠ NO LONGER RENDERED (2026-08-21). It existed solely for the replacement intro note, which
     * the UAT prose removal deleted. The property is RETAINED rather than removed because
     * `c/bovComparisonMatrix` still passes it through `LightningModal.open()`, and because the
     * incumbent's name is the one fact that removal cost this dialog — if a user asks for it back,
     * this is the value to render, as a plain label/value pair and not as a sentence.
     */
    @api currentBroker;
    /**
     * TRUE when this disposition has no appointed broker yet, so the modal is performing a FIRST
     * APPOINTMENT rather than a replacement (2026-08-21).
     *
     * 🔴 IT SWITCHES COPY AND THE REASON, NOT THE MECHANISM. The same Apex method runs either way
     * — see `c/bovComparisonMatrix`'s header and `BovSubmissionService.replaceSelectedBroker`'s
     * javadoc for why a second server path was rejected. A second MODAL bundle was rejected for the
     * matching reason: this file's four non-obvious contracts (options sourced from
     * `getPicklistValues`, block-don't-degrade on a failed picklist read, "the returned message is
     * the product, not a receipt", stay-open-on-failure) would have to be duplicated verbatim and
     * would drift.
     *
     * ⚠ THIS FLAG IS THE CLIENT'S BELIEF, NOT A FACT, and the server does not trust it. It is
     * derived from a cacheable wire that can be seconds stale, so a colleague can appoint a broker
     * between the button rendering and the Confirm click. The server re-derives the truth inside
     * the transaction and refuses `Initial Appointment` if an incumbent turns out to exist. Do not
     * add a client-side re-check to "help" — it would be the same stale data asked twice.
     */
    @api isFirstAppointment;

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
    // ⚠ `incumbentLabel` WAS DELETED ON 2026-08-21 with the replacement intro note, its only
    // consumer. Its `|| 'the current broker'` fallback existed to stop an absent `currentBroker`
    // rendering the literal string "undefined"; nothing binds that value now, and the suite still
    // pins `not.toContain('undefined')` on the rendered markup for the bindings that remain.
    get isSaving() {
        return this._saving;
    }

    // ── First-appointment mode. Copy and the reason differ; nothing else does. ──

    /** `=== true`, so an absent or string-ish prop is read as "replacement", the safer default. */
    get isAppointment() {
        return this.isFirstAppointment === true;
    }
    /** The visible heading. `open()`'s `label` sets the ACCESSIBLE name; both must agree. */
    get headerLabel() {
        return this.isAppointment ? 'Select Broker' : 'Replace Selected Broker';
    }
    get confirmLabel() {
        return this.isAppointment ? 'Appoint broker' : 'Replace broker';
    }
    get savingText() {
        return this.isAppointment ? 'Appointing the broker' : 'Replacing the broker';
    }
    /**
     * ⚠ THE REASON COMBOBOX IS HIDDEN, NOT DISABLED-WITH-A-VALUE. Rendering a control the user
     * cannot change invites them to try; and a disabled combobox announces as a dead form field.
     * The static line rendered in its place says what WILL be recorded, so the history value is
     * disclosed rather than silently applied.
     */
    get showReasonPicker() {
        return !this.isAppointment;
    }
    /**
     * 🔴 THE ONE VALUE SENT TO APEX, and it is a getter rather than an assignment so that no code
     * path can leave a stale `this.reason` from a mode switch in the field.
     */
    get effectiveReason() {
        return this.isAppointment ? REASON_INITIAL_APPOINTMENT : this.reason;
    }
    /**
     * ⚠ A FAILED PICKLIST READ BLOCKS A REPLACEMENT AND DOES NOT BLOCK A FIRST APPOINTMENT, AND
     * THAT IS NOT AN INCONSISTENCY. The block exists to prevent an UNATTRIBUTED history row — the
     * one row this workstream exists to prevent. On a first appointment the attribution is fixed
     * and known without reading the picklist at all, so blocking there would refuse a safe action
     * for a reason that cannot occur on it.
     */
    get reasonLoadError() {
        return !this.isAppointment && this._reasonLoadFailed
            ? REASON_LOAD_ERROR
            : undefined;
    }
    /** Copy for the empty state — there is nothing to PROMOTE vs nothing to APPOINT. */
    get emptyMessage() {
        return this.isAppointment
            ? 'There are no broker responses on this disposition yet. Log a BOV response first, then select a broker.'
            : 'There are no backup submissions to promote. Log another BOV response first, then replace the selected broker.';
    }

    /**
     * 🔴 THE REASON IS PART OF THE GATE. Confirm stays disabled until a backup AND a reason are
     * chosen — the same rule the server enforces, so a user can never reach a refusal they could
     * have been shown as a disabled button. On a first appointment `effectiveReason` is a constant,
     * so the gate reduces to "choose a broker", which is the only choice that path has.
     */
    get confirmDisabled() {
        return this._saving || !this.newSubmissionId || !this.effectiveReason;
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
                reason: this.effectiveReason,
                notes: this.notes
            });
            this.close({ message });
        } catch (error) {
            this.error =
                (error && error.body && error.body.message) ||
                (this.isAppointment
                    ? GENERIC_ERROR_APPOINT
                    : GENERIC_ERROR_REPLACE);
        } finally {
            this._saving = false;
        }
    }
}
