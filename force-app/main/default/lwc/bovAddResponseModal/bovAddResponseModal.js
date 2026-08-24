import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/**
 * 🔴 `STATUS_BACKUP` WAS DELETED FROM HERE 2026-08-24. This bundle no longer names a
 * `Submission_Status__c` value anywhere: the control is not rendered in either mode and the key is
 * not in the payload on either submit path. The picklist DEFAULT (`Backup`) carries a new row
 * until `BovAutoSelectionService` — its sole writer for rows created here — decides. The retracted
 * comments below and in the template still QUOTE the old constant; that is history, not a live
 * reference. (The identically-named constants in `BovAutoSelectionService`,
 * `BovSubmissionService` and `BovSubmissionSelectionGuardTest` are unrelated Apex.)
 */

/** Shown when the platform hands back an error with nothing readable in it. */
const GENERIC_ERROR = 'The broker response could not be saved.';

/** Header + save-button copy, keyed on the mode. Both are announced, so both are authored here. */
const TITLE_RESPONSE = 'Add Broker Response';
const TITLE_PREFERRED = 'Add Preferred Broker';
const SAVE_RESPONSE = 'Save response';
const SAVE_PREFERRED = 'Save preferred broker';

/**
 * The THIRD mode's copy (2026-08-24). "Replace Preferred Broker", not "Add" — this
 * dialog is reached from the panel's Replace Broker button when a preferred broker
 * already exists, and calling it an appointment would mislead: something is being
 * retired, not just recorded.
 *
 * ⚠ THE SAVE BUTTON NAMES THE WHOLE ACTION, NOT THE HALF THIS DIALOG PERFORMS. The
 * form only CREATES the incoming row; the outgoing one is retired by the opener
 * immediately afterwards. "Save replacement" would describe the form; "Replace
 * preferred broker" describes what the user is about to cause, which is what a
 * confirming button should say.
 */
const TITLE_REPLACEMENT = 'Replace Preferred Broker';
const SAVE_REPLACEMENT = 'Replace preferred broker';

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
 * Days_To_Market__c, Hist_Success_Rate__c. `BOV_Score__c` is ALSO on that layout, Readonly — see
 * the OMITTED list below for why it is not one of the fields rendered on THIS form.
 *
 * ⚠ READ AGAINST THE 2026-08-21 RETRIEVED COPY OF THAT LAYOUT, NOT THE OLDER COMMITTED ONE. The
 * layout was edited by hand in Setup on 2026-08-20 and reconciled into the repo the next day;
 * that edit made six fields layout-Required and REMOVED `BOV_Score__c` from the screen entirely.
 * 🔴 RETRACTED 2026-08-21 (later the same day): `BOV_Score__c` went back on that layout as
 * behavior=Edit while the formula-conversion effort the removal was clearing the way for was
 * deferred. 🔴 RE-RETRACTED 2026-08-22 (manifest/bov-score-formula-conversion/, Step 3): the
 * conversion has now completed and the layout's BOV_Score__c behavior is Readonly again (a
 * formula field cannot carry behavior=Edit). The layout-Required point still holds for the other
 * six fields — see the `required` attributes below. Re-derive from the layout file rather than
 * from this paragraph if it has moved again.
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
 *     removal was part of a formula-conversion effort then EVALUATED AND DEFERRED (cancelled for
 *     now, user instruction), and the field was RENDERED here, OPTIONAL, for that interim period.
 *     🔴 RE-RETRACTED 2026-08-22 (manifest/bov-score-formula-conversion/, Step 3, formula
 *     conversion completed). BOV_Score__c is removed from this form again, this time
 *     permanently: it is now a FORMULA field and `lightning-input-field` cannot render a formula
 *     field as an editable input — a hard runtime error, not a soft no-op. It joins the three
 *     formula fields (`Broker_Display__c`, `Property_Name__c`, `Selected_Broker__c`) already
 *     excluded above for the same reason. See the template for the same retraction in place.
 *
 *   - `Submission_Status__c` — 🔴 ADDED TO THIS LIST 2026-08-24, AND IT IS THE ONE DELIBERATE
 *     SUBTRACTION FROM THE LAYOUT. It is on `BOV Submission Layout` and it WAS rendered here
 *     (response mode only, for part of 2026-08-24). Omitted in BOTH modes now: automatic
 *     selection by score is live, so the field is SERVER-DERIVED, and an insert naming
 *     `Selected` is refused outright by `BovSubmissionSelectionGuardService`. The picklist
 *     default (`Backup`) is what a new row carries until `BovAutoSelectionService` runs. The
 *     layout is untouched — a status can still be set by hand from the record page, by someone
 *     who can see which sibling already holds the single `Selected` slot. This dialog cannot.
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
 * 🔴 RE-RETRACTED AGAIN 2026-08-24 — A THIRD RETRACTION, AND IT IS NOT ABOUT `BOV_Score__c`.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The two retractions above (both about `BOV_Score__c`) STAND AS WRITTEN and are deliberately
 * left in place; this one sits beside them rather than replacing them. Read all three.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════
 * 🔴 A FOURTH RETRACTION 2026-08-24 (LATER STILL): THERE ARE **THREE** MODES NOW, NOT TWO.
 * ══════════════════════════════════════════════════════════════════════════════════════
 * The paragraph below and its four numbered items stand as written for the two modes they
 * describe. `@api isReplacement` (default `false`) adds a third, opened by
 * `c/bovBrokerPanel`'s "Replace Broker" button WHEN A PREFERRED BROKER ALREADY EXISTS:
 *
 *   isReplacement = true  "Replace Preferred Broker" — same create, same field set, same
 *                         `Is_Preferred_Broker__c` injection (it is passed WITH
 *                         `isPreferred: true`), plus ONE read-only line naming the
 *                         outgoing broker. `Broker__c` is the control that chooses the
 *                         incoming one; there is no second picker, because a successor has
 *                         usually submitted no BOV at all and so has no row to offer.
 *
 * 🔴 THE RETIREMENT OF THE OUTGOING ROW IS NOT THIS BUNDLE'S JOB AND MUST NOT BECOME IT.
 * This dialog creates and closes; `c/bovBrokerPanel` then calls
 * `BovController.replacePreferredBroker(dispositionId, newSubmissionId,
 * outgoingSubmissionId)`. Keeping the Apex out of here is what preserves the property
 * stated at the top of this header — "this component needs no Apex of its own", so
 * `lightning-record-edit-form` owns CRUD/FLS and validation-rule surfacing in ALL THREE
 * modes.
 * ⚠ CONSEQUENCE, NAMED SO IT IS A DECISION: between this dialog's success and the opener's
 * retire call the disposition briefly carries TWO preferred rows. The opener toasts a
 * STICKY ERROR if the retire fails, rather than showing a success and leaving the user to
 * find two preferred cards. Creating first is deliberate — deleting first would risk
 * leaving ZERO preferred brokers, which is worse and unrecoverable from this dialog.
 *
 * THIS BUNDLE NOW HAS TWO MODES, driven by `@api isPreferred` (default `false`):
 *
 *   isPreferred = false  "Add Broker Response"   — 🔴 RETRACTED IN PLACE 2026-08-24 (LATER
 *                                                  STILL): NO LONGER "unchanged, byte for byte".
 *                                                  The `Submission_Status__c` input was removed
 *                                                  from THIS mode too — see item 3. Everything
 *                                                  else about it is still untouched.
 *   isPreferred = true   "Add Preferred Broker"  — records a broker DPEG would LIKE to use.
 *
 * What the second mode changes, and nothing else:
 *   1. The header label and the Save button label.
 *   2. `Broker__c` STAYS REQUIRED; `BOV_Amount__c`, `Cap_Rate__c`, `Commission_Rate__c` and
 *      `Days_To_Market__c` become OPTIONAL. (User decision: everything optional EXCEPT the
 *      broker, because a preferred broker with no Contact is an empty row — `Broker_Firm__c`
 *      and `Contact_Name__c` are both STAMPED from that lookup.)
 *   3. `Submission_Status__c` is not rendered, and — 🔴 REVISED 2026-08-24, LATER THE SAME DAY —
 *      is NOT WRITTEN BY THIS COMPONENT AT ALL. It briefly forced `Backup` here. The user has
 *      since decided that a preferred broker BECOMES the appointed broker (it takes the single
 *      `Selected` slot and the scored winner is demoted), so `Backup` is no longer the right
 *      value — and `'Selected'` cannot be written from here either, because
 *      `BovSubmissionSelectionGuardService` refuses an insert-as-Selected while a committed
 *      Selected sibling exists. `BovAutoSelectionService` is the SOLE WRITER of that field on
 *      this path; the picklist default (`Backup`) carries the row safely until it runs. Full
 *      argument at `withParent()`.
 *      🔴 RETRACTED IN PLACE 2026-08-24 (LATER STILL) — THIS IS NO LONGER SOMETHING THE PREFERRED
 *      MODE CHANGES, BECAUSE IT IS NOW TRUE OF BOTH MODES. The input is removed from the form
 *      outright and neither submit path sends the key. Every word above about why the value
 *      cannot be written from here still applies; it now applies unconditionally. The response
 *      mode arrived at the same place by its own route: automatic selection by score is live, so
 *      a hand-picked `Selected` fights the scoring model AND is refused by
 *      `BovSubmissionSelectionGuardService` on any disposition that already has an appointed
 *      broker — which, once a disposition is priced, is all of them. Read this item as a
 *      BOTH-MODES fact, and item 2 as the only remaining difference besides the two labels.
 *   4. `Is_Preferred_Broker__c = true` is forced in `withParent()`.
 *
 * 🔴 THE STATEMENT ABOVE — "Every field rendered here is granted `editable=true`" — NOW HAS AN
 * EXCEPTION THAT MATTERS MORE THAN THE RULE. `Is_Preferred_Broker__c` is NOT rendered; it is
 * injected into the payload. That does not exempt it from FLS: `lightning-record-edit-form`
 * FLS-checks EVERY KEY IN THE PAYLOAD, including programmatic ones, and a key the running user
 * cannot edit is DROPPED SILENTLY — the save succeeds, the success toast fires, and the record
 * is created with the flag `false`. It lands in the comparison matrix as an ordinary Backup
 * response instead of in the preferred card, and NOTHING anywhere reports it.
 * ⚠ THAT WAS THE FAILURE MODE TO EXPECT IF THIS SHIPPED BEFORE THE FIELD AND ITS PERMISSION-SET
 * GRANT. 🔴 UPDATED 2026-08-24: BOTH ARE NOW LIVE on usman-dpeg — the field exists
 * (FieldDefinition query) and `DPEG_Disposition_Edit` grants readable + editable
 * (FieldPermissions query), so the deploy-ordering risk is DISCHARGED for that persona.
 * ⚠ IT IS NOT DISCHARGED FOR EVERY PERSONA. The same query shows `DPEG_Principal_PSG` and
 * `DPEG_Disposition_View` hold READ-ONLY on this field. A user on either who reaches "Add
 * Preferred Broker" gets exactly the silent drop described above — success toast, unflagged row,
 * wrong card, no error anywhere. Whether principals should see that button at all is a
 * permission-set question, not one this component can answer; it is named here so it is not
 * discovered in UAT. A rendered field would at least have thrown; an injected one will not.
 *
 * ⚠ RETRACTED IN PLACE 2026-08-24 (LATER STILL) — ONE OF THE TWO REFUSALS IS GONE, AND THE
 * PARAGRAPH IS KEPT BECAUSE ITS *RULE* IS STILL THE RIGHT ONE.
 * It read: *"TWO SERVER-SIDE REFUSALS ARE STILL LIVE ON THE PREFERRED PATH AND ARE NOT FIXED
 * HERE. `Broker_Required_On_Submission` and `BOV_Amount_Required_On_Submission` are ACTIVE,
 * UNGUARDED validation rules … the second REFUSES a preferred row with a blank amount until it
 * carries a `NOT(Is_Preferred_Broker__c)` exemption."*
 * 🔴 THAT EXEMPTION HAS SINCE BEEN DEPLOYED. Verified against the checked-in metadata on
 * 2026-08-24: `BOV_Amount_Required_On_Submission` is `<active>true</active>` with
 * `AND(NOT(Is_Preferred_Broker__c), ISBLANK(BOV_Amount__c))`, so a preferred row — first
 * appointment OR replacement — saves with a blank amount. The client-side relaxation in
 * `isResponseFieldRequired` and the server rule now agree.
 * ⚠ `Broker_Required_On_Submission` IS STILL ACTIVE AND STILL UNGUARDED (`ISBLANK(Broker__c)`),
 * which is exactly why `Broker__c` keeps a BARE `required` in every mode. Do not "relax it for
 * consistency" — that rule has no exemption and never should: the broker IS the row.
 * 🔴 AND THE GENERAL RULE THE PARAGRAPH TAUGHT STANDS: making a field optional on the client does
 * not make it optional on the server. When one is relaxed the other must be checked in the same
 * change; this dialog stays honest either way, because the rule's own authored message renders
 * through `<lightning-messages>` and the dialog stays open.
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

    /**
     * Switches this dialog into "Add Preferred Broker" mode (2026-08-24). See the class header
     * for the full list of four things it changes.
     *
     * ⚠ DEFAULT `false`, AND EVERY READ BELOW IS `=== true`. The opener that has always existed
     * (`c/bovComparisonMatrix`'s "Add Broker Response") passes `isPreferred: false` explicitly,
     * and an opener that passes nothing at all still gets the response mode.
     */
    @api isPreferred = false;

    /**
     * Switches the preferred mode from "first appointment" into "REPLACEMENT"
     * (2026-08-24). Opened by `c/bovBrokerPanel`'s Replace Broker button when the
     * disposition already has a preferred broker.
     *
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 IT CHANGES THE COPY AND ADDS ONE READ-ONLY LINE. NOTHING ELSE.
     * ══════════════════════════════════════════════════════════════════════════
     * Same field set, same two submit paths, same `Is_Preferred_Broker__c = true`
     * injection, same create-only contract. The incoming broker is chosen with the
     * SAME `Broker__c` lookup the other two modes use — there is no second picker,
     * because the successor is usually a broker who has submitted no BOV at all
     * and so has no row for a picker to offer.
     *
     * ⚠ THIS DIALOG DOES NOT RETIRE THE OUTGOING ROW AND MUST NOT LEARN HOW.
     * It creates; the OPENER calls `BovController.replacePreferredBroker` once this
     * resolves. That division is what keeps this bundle free of Apex — the property
     * that lets `lightning-record-edit-form` own CRUD/FLS and validation-rule
     * surfacing for all three modes. See `c/bovBrokerPanel._retireOutgoingPreferred`.
     *
     * ⚠ ALWAYS PASSED TOGETHER WITH `isPreferred: true`. `isReplacement` alone would
     * relabel a dialog that still created an unflagged ordinary response, so every
     * mode-keyed getter below tests `isReplacement` FIRST and the flag injection is
     * left keyed on `isPreferred`, where it belongs.
     */
    @api isReplacement = false;

    /**
     * The outgoing preferred broker, already formatted for display by the opener.
     *
     * 🔴 A STRING, NOT AN ID, AND NOT A FIELD ON THE FORM. It is rendered as static
     * text — never as a `lightning-input-field` — because a non-editable field put
     * on a record-edit-form is FLS-checked like any other key and dropped SILENTLY
     * with a success toast, which is exactly the failure this repo has measured.
     * Static text cannot reach the payload: `handleSave` gathers only rendered
     * `lightning-input-field`s and the native submit carries only the form's own
     * fields.
     *
     * ⚠ THE OPENER FORMATS IT because the opener holds the row. Formatting it here
     * would need this bundle to read BOV data it otherwise never touches.
     */
    @api outgoingBrokerLabel;

    _saving = false;

    get isSaving() {
        return this._saving;
    }

    /**
     * ⚠ `isReplacement` IS TESTED FIRST, and the order is load-bearing: the
     * replacement mode is opened WITH `isPreferred: true`, so a `isPreferred`-first
     * chain would label a replacement "Add Preferred Broker" and never reach the
     * replacement string at all.
     */
    get modalTitle() {
        if (this.isReplacement === true) {
            return TITLE_REPLACEMENT;
        }
        return this.isPreferred === true ? TITLE_PREFERRED : TITLE_RESPONSE;
    }

    get saveLabel() {
        if (this.isReplacement === true) {
            return SAVE_REPLACEMENT;
        }
        return this.isPreferred === true ? SAVE_PREFERRED : SAVE_RESPONSE;
    }

    /**
     * Whether to render the read-only "Current preferred broker" line.
     *
     * ⚠ GATED ON THE LABEL BEING NON-EMPTY, NOT JUST ON THE MODE. An empty label
     * would render a form element with a heading and no value — worse than absent,
     * because it reads as data that failed to load. The opener returns `''` (never
     * `undefined`) when it has no preferred row, so this is the one test needed.
     */
    get showOutgoingBroker() {
        return this.isReplacement === true && !!this.outgoingBrokerLabel;
    }

    /**
     * Whether the four BOV-response fields are marked required on the client.
     *
     * ⚠ `Broker__c` IS NOT ONE OF THEM — it keeps a bare `required` in the template in both
     * modes. If a future change makes the broker optional too, this getter is NOT the place: add
     * a separate one, so the two decisions cannot be collapsed by accident.
     */
    get isResponseFieldRequired() {
        return this.isPreferred !== true;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // 🔴 `isStatusRendered` AND `defaultStatus` WERE DELETED HERE 2026-08-24.
    // ══════════════════════════════════════════════════════════════════════════════════════
    // The deleted docblock read: "`Submission_Status__c` is offered only in response mode — see
    // the template for why." It is now offered in NEITHER mode, so a mode-keyed getter has
    // nothing left to decide and a `defaultStatus` getter has no control to feed.
    // ⚠ CHECKED BEFORE DELETING: a repo-wide grep for `isStatusRendered` / `defaultStatus` /
    // `bar-field-status` found callers ONLY in this bundle's own template and Jest suite (the
    // `defaultStatusCode` in SharePointCalloutMock is an unrelated Apex field). Nothing else
    // reads them. See the template for why the control itself went.

    /**
     * The one place that knows `Disposition__c` must be forced onto the payload.
     *
     * 🔴 A `disabled` input-field is a DISPLAY affordance, not a transport guarantee — a disabled
     * control is conventionally excluded from a form submission, and relying on it would make
     * the parent lookup depend on a base-component implementation detail. Forcing it costs one
     * line and makes the dialog's central invariant — a response is logged against the sale the
     * user opened it from, and no other — true by construction.
     *
     * 🔴 AND SINCE 2026-08-24, THE ONE PLACE THAT KNOWS THE PREFERRED FLAG MUST BE FORCED TOO.
     * `Is_Preferred_Broker__c` has no input on the form (the flag is the MODE, not something the
     * user chooses inside it), so it is injected here — for exactly the same reason the parent
     * is: THERE ARE GENUINELY TWO SUBMIT PATHS and this is the only code both of them run
     * through. Putting it into `handleSave` alone would leave the ENTER path silently creating
     * an unflagged row.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 RETRACTED IN PLACE 2026-08-24 (LATER THE SAME DAY): THIS METHOD NO LONGER WRITES
     * `Submission_Status__c` AT ALL ON THE PREFERRED PATH.
     * ══════════════════════════════════════════════════════════════════════════════════════
     * It briefly forced `Submission_Status__c = STATUS_BACKUP` alongside the flag, and the
     * reasoning was sound at the time: *"a preferred row saved as Selected would enter
     * Broker_Finalize_Approval, whose entry criterion is Submission_Status__c = 'Selected' and
     * NOTHING ELSE, and would appoint a broker with no BOV amount."*
     *
     * THE USER RESOLVED THAT CONFLICT THE OTHER WAY (2026-08-24). A preferred broker is now
     * meant to BE the appointed broker: it takes the single `Selected` slot outright and the
     * highest-scoring submission is demoted to `Backup`. The premise of the `Backup` force is
     * therefore gone — but the fix is NOT to write `'Selected'` here instead, and that is the
     * half that matters:
     *
     * 🔴 THIS FORM CANNOT WRITE `'Selected'`. `BovSubmissionSelectionGuardService` runs in
     * `beforeInsert` (`BovSubmissionTriggerHandler.beforeInsert`, `oldMap = null`) and has NO
     * preferred-broker exemption — grep it, the word does not appear. Its PASS 2 skips only rows
     * present in `Trigger.new`, so a COMMITTED Selected sibling is counted, PASS 3 computes
     * `others = 1`, and it `addError`s the user's own insert with a message telling them to use
     * Replace Broker. Under automatic selection a scored broker holds `Selected` on every priced
     * disposition, so that refusal would be the NORMAL case, not an edge case.
     *
     * ⚠ SO THE STATUS IS NOT WRITTEN HERE AT ALL — not `Backup`, not `Selected`, not the key.
     * `Submission_Status__c`'s picklist DEFAULT is `Backup` (see that field's metadata), so the
     * row inserts guard-safe on its own, and `BovAutoSelectionService` then promotes it to
     * `Selected` while demoting the scored incumbent IN ONE BULK DML — the only shape the guard
     * permits, because both rows are in `Trigger.new` for that statement.
     * 🔴 THAT SERVICE IS THE SOLE WRITER OF `Submission_Status__c` ON THE PREFERRED PATH. Do not
     * reintroduce a status key here "to be explicit": two writers of one invariant is how this
     * repo has produced silent divergence before, and this one would additionally be refused.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 RETRACTED IN PLACE 2026-08-24 (LATER STILL): "ON THE PREFERRED PATH" IS NOW "ON EVERY
     * PATH". Only the SCOPE of everything above has widened — its reasoning is what keeps the
     * key out, so it is kept verbatim.
     * ══════════════════════════════════════════════════════════════════════════════════════
     * This method never wrote the status on the RESPONSE path either. That path sent the key
     * because `handleSave` gathered it from a RENDERED input carrying `value="Backup"`. That
     * input is gone from the template, so `handleSave` has nothing to gather and the native
     * (ENTER) submit — which carries only the form's own rendered fields — has nothing to send.
     * `BovAutoSelectionService` is the sole writer of `Submission_Status__c` for every row
     * created by this dialog, in both modes.
     * ⚠ THE ANSWER TO "the status should be X" IS NEVER A KEY IN THIS PAYLOAD. It is the record
     * page (the layout still offers the field) or the matrix's Replace Broker action — both of
     * which can see which sibling already holds the single `Selected` slot, and this create
     * dialog cannot.
     *
     * ⚠ THE PREFERRED KEY IS OMITTED ENTIRELY IN RESPONSE MODE — not sent as `false`. Two
     * reasons, and the second is the load-bearing one:
     *   1. The default path's payload stays byte-identical to what it has always sent, so the
     *      existing behaviour cannot regress through this method.
     *   2. 🔴 RETRACTED IN PLACE 2026-08-24 (LATER THE SAME DAY). This read: *"Is_Preferred_Broker__c
     *      DOES NOT EXIST IN THE ORG YET … an unconditional false would break the working Add
     *      Broker Response dialog the moment this deploys."* THE FIELD IS NOW LIVE — verified by
     *      a FieldDefinition tooling query against usman-dpeg on 2026-08-24, alongside
     *      Is_Manually_Appointed__c. The outage argument is therefore SPENT and must not be
     *      quoted as a live reason. Reason 1 above is the one still standing, and it is
     *      sufficient: there is no value in writing a field to the value it already defaults to,
     *      and every key added here is one more key lightning-record-edit-form FLS-checks.
     */
    withParent(fields) {
        const forced = { ...fields, Disposition__c: this.dispositionId };
        if (this.isPreferred === true) {
            forced.Is_Preferred_Broker__c = true;
        }
        return forced;
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
