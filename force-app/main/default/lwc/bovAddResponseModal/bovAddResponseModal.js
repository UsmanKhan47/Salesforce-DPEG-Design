import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/** Submission_Status__c is a restricted picklist of exactly {Backup, Selected}. */
const STATUS_BACKUP = 'Backup';

/** Shown when the platform hands back an error with nothing readable in it. */
const GENERIC_ERROR = 'The broker response could not be saved.';

/**
 * c-bov-add-response-modal — logs a new `BOV_Submission__c` against the disposition the user is
 * already looking at, WITHOUT leaving that page (2026-08-21, UAT fix).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS COMPONENT EXISTS: THE BUG IT REPLACES.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `c/bovComparisonMatrix`'s "Add Broker Response" button used to call
 *
 *     this[NavigationMixin.Navigate]({
 *         type: 'standard__objectPage',
 *         attributes: { objectApiName: 'BOV_Submission__c', actionName: 'new' },
 *         state: { defaultFieldValues: encodeDefaultFieldValues({ Disposition__c: … }) }
 *     });
 *
 * That is the platform's OWN create screen, and the platform's own post-save behaviour for a
 * record created that way is to navigate to the new record. The user reported it as "once we
 * save broker response it redirects to that record page instead of staying on the same page" —
 * which is not a defect in the navigation call, it is what `actionName: 'new'` DOES. There is no
 * flag on that page reference that suppresses it: `navigationLocation` belongs to the Aura
 * `force:createRecord` event, not to `NavigationMixin`, and `state.backgroundContext` at best
 * substitutes one full page transition for another — the matrix would still be re-rendered from
 * scratch by a page load rather than refreshed in place, and the user would still watch the
 * disposition page disappear and come back.
 *
 * 🔴 THE FIX IS THEREFORE TO STOP NAVIGATING AT ALL, not to navigate more cleverly. This modal
 * renders over the disposition page, saves in place, and hands the new record's Id back to the
 * matrix, which raises a toast and calls `refreshApex` on its own wire. Same shape as
 * `c/bovReplaceBrokerModal` and `c/dispositionOfferSelect`, and the same reason: the opener
 * outlives the dialog, so the opener is where the outcome belongs.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE FIELD SET IS NOT A GUESS — IT IS `BOV Submission Layout`, MINUS FOUR, PLUS ONE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * This project has a measured incident of a modal that looked EMPTY because the child layouts
 * behind it were four-field stubs, so the exclusions below are each argued rather than assumed.
 * The layout's Information + BOV Terms sections give: Disposition__c, Broker__c,
 * Submission_Status__c, OwnerId, BOV_Amount__c, Cap_Rate__c, Commission_Rate__c,
 * Days_To_Market__c, Hist_Success_Rate__c, BOV_Score__c.
 *
 * ⚠ READ AGAINST THE 2026-08-21 RETRIEVED COPY OF THAT LAYOUT, NOT THE OLDER COMMITTED ONE. The
 * layout was edited by hand in Setup on 2026-08-20 and reconciled into the repo the next day;
 * that edit made six fields layout-Required and REMOVED `BOV_Score__c` from the screen entirely.
 * 🔴 RETRACTED 2026-08-21 (later the same day): `BOV_Score__c` is back on that layout — the
 * formula-conversion effort the removal was clearing the way for is deferred, and the field is
 * restored per the layout file's own reconciliation comment. The layout-Required point still
 * holds — see the `required` attributes below and the BOV_Score__c note in the template for its
 * (unrelated) history. Re-derive from the layout file rather than from this paragraph if it has
 * moved again.
 *
 * OMITTED, WITH REASONS:
 *   - `Name` — AutoNumber (`BOV-{0000}`). It cannot be typed and the platform assigns it.
 *   - `OwnerId` — defaults to the creating user, which is right in every case this dialog
 *     serves (an analyst logging a response they took). Changing ownership is a record-page
 *     action with its own audit expectations, not a field to fill in while logging a valuation.
 *     🔴 IF A USER ASKS FOR IT, IT IS ONE `lightning-input-field` — do not conclude from its
 *     absence that owner assignment is unsupported.
 *   - `Broker_Firm__c` and `Contact_Name__c` — 🔴 THE STRONGEST EXCLUSION. Both are STAMPED in
 *     the before-save trigger by `BovSubmissionBrokerStampService` from the chosen `Broker__c`
 *     Contact. Anything typed into them is overwritten inside the same save. Offering them would
 *     be offering the user a field whose value is discarded with a success toast.
 *   - `Approval_Status__c` — not on the layout, written only by the approval process, and
 *     `editable=false` in `DPEG_Disposition_Edit`. Rendering it would raise an FLS error inside
 *     the form.
 *   - The three formula fields (`Broker_Display__c`, `Property_Name__c`, `Selected_Broker__c`)
 *     are read-only by construction.
 *   - `BOV_Score__c` — 🔴 RETRACTED 2026-08-21 (later the same day). This used to read "REMOVED
 *     FROM THE LAYOUT BY HAND ON 2026-08-20, so it is omitted here for the same reason." That
 *     removal was part of a formula-conversion effort now EVALUATED AND DEFERRED (cancelled for
 *     now, user instruction). The field is now RENDERED here, OPTIONAL, and is back on the page
 *     layout too (see that file's own reconciliation comment). See the template for the same
 *     retraction in place.
 *
 * NOTHING IS ADDED BEYOND THE LAYOUT. Every field on this form is one the platform's own New
 * screen offers, which is the property that makes this dialog a drop-in replacement for it.
 *
 * Every field rendered here is granted `editable=true` on `BOV_Submission__c` in
 * `DPEG_Disposition_Edit`, checked 2026-08-21. A field the running user cannot edit renders as
 * an error inside the form rather than being silently skipped, so that check is not optional
 * when adding one.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ BOTH SUBMIT PATHS INJECT `Disposition__c`. THERE ARE GENUINELY TWO.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *   1. The footer "Save response" button calls `handleSave`, which gathers the input-field
 *      values itself and calls `form.submit(fields)`. It has to gather them: calling `submit()`
 *      from a plain (non-`type="submit"`) button does NOT fire the form's `onsubmit` handler, so
 *      nothing else would get a chance to add the parent.
 *   2. Pressing ENTER inside any text input natively submits the form, which DOES fire
 *      `onsubmit` — a path the footer button never touches. `handleSubmit` covers it.
 * Both funnel through `withParent()`, so there is exactly one place that knows the parent must
 * be forced, and the disabled `Disposition__c` input is a DISPLAY, not the transport.
 */
export default class BovAddResponseModal extends LightningModal {
    /** The `Disposition__c` this response is being logged against. */
    @api dispositionId;

    _saving = false;

    get isSaving() {
        return this._saving;
    }

    get defaultStatus() {
        return STATUS_BACKUP;
    }

    /**
     * The one place that knows `Disposition__c` must be forced onto the payload.
     *
     * 🔴 A `disabled` input-field is a DISPLAY affordance, not a transport guarantee — a disabled
     * control is conventionally excluded from a form submission, and relying on it would make
     * the parent lookup depend on a base-component implementation detail. Forcing it costs one
     * line and makes the dialog's central invariant — a response is logged against the sale the
     * user opened it from, and no other — true by construction.
     */
    withParent(fields) {
        return { ...fields, Disposition__c: this.dispositionId };
    }

    /**
     * Native submit path (ENTER inside a text input). `preventDefault` stops the form's own
     * default submission so the parent-injected payload is the one that goes.
     *
     * ⚠ `submit(fields)` does NOT re-enter this handler — that is the documented shape of the
     * pattern, and it is what stops this from being infinite recursion.
     */
    handleSubmit(event) {
        event.preventDefault();
        this._saving = true;
        this.template
            .querySelector('lightning-record-edit-form')
            .submit(this.withParent(event.detail.fields));
    }

    /** Footer-button submit path. See the class header for why it gathers fields itself. */
    handleSave() {
        if (this._saving) {
            return;
        }
        const inputs = [...this.template.querySelectorAll('lightning-input-field')];

        // ⚠ ABORTS ONLY ON AN EXPLICIT `false`. `reportValidity()` returns a boolean on the real
        // base component; the sfdx-lwc-jest stub is `@api reportValidity() {}` and returns
        // UNDEFINED, so a truthiness test here would abort every save in Jest and leave the
        // whole submit path unexercised. The `=== false` comparison keeps the real client-side
        // gate and lets the stub fall through — and the suite proves BOTH branches by overriding
        // the stub's return value. The server-side rules are enforced independently either way;
        // this only spares the user a round trip.
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
            .submit(this.withParent(fields));
    }

    /**
     * 🔴 THE OUTCOME GOES TO THE OPENER, NOT TO A TOAST RAISED FROM HERE. This component is about
     * to be destroyed; a toast dispatched from a closing modal is a race, and the matrix is the
     * thing that has to refresh anyway. Same division of labour as c/bovReplaceBrokerModal.
     */
    handleSuccess(event) {
        this._saving = false;
        const detail = event.detail || {};
        this.close({
            recordId: detail.id,
            name:
                (detail.fields && detail.fields.Name && detail.fields.Name.value) ||
                ''
        });
    }

    /**
     * 🔴 A FAILURE KEEPS THIS MODAL OPEN, and the message stays inside the form.
     *
     * Every realistic refusal here is about WHAT WAS TYPED — a missing broker, a missing amount
     * — and each of the two validation rules carries an authored message naming its own field.
     * `<lightning-messages>` has already rendered it against that field by the time this runs, so
     * closing the dialog would throw away both the message and the user's other seven values.
     * This handler's only job is to release the spinner. `_message` is captured for diagnosis
     * only and is deliberately not rendered a second time.
     */
    handleError(event) {
        this._saving = false;
        this._message =
            (event.detail && (event.detail.message || event.detail.detail)) ||
            GENERIC_ERROR;
    }

    handleCancel() {
        this.close();
    }
}
