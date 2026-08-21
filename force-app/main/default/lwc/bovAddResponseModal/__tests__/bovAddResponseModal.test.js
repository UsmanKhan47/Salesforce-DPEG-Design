/**
 * c-bov-add-response-modal
 * ---------------------------------------------------------------------------
 * The in-place replacement for the "Add Broker Response" navigation-create that
 * threw the user off the Disposition page on save (UAT, 2026-08-21).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 THE THREE FALSIFIERS THAT MATTER MOST HERE
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE FORM IS NOT EMPTY, AND IT IS NOT A GUESS. This project has a measured
 *    incident of a modal that looked empty because the layouts behind it were
 *    four-field stubs. T-FIELDS pins the exact field list against
 *    `BOV Submission Layout` — and pins the FOUR EXCLUSIONS too, because
 *    `Broker_Firm__c` / `Contact_Name__c` are stamped in the before-save
 *    trigger and offering them would hand the user inputs whose values are
 *    discarded with a success toast.
 * 2. `Disposition__c` REACHES THE SERVER ON BOTH SUBMIT PATHS. The field is
 *    rendered `disabled`, and a disabled control is conventionally omitted from
 *    a form submission — so the parent is FORCED in JS. There are genuinely two
 *    paths (footer button; ENTER inside a text input) and both are asserted.
 * 3. THE DIALOG NEVER NAVIGATES. It resolves the new record's Id back to
 *    c/bovComparisonMatrix, which is what refreshes the matrix in place. A
 *    regression to any form of navigation is the original bug returning.
 *
 * ⚠ `LightningModal` HAS NO sfdx-lwc-jest STUB — this repo supplies its own at
 * jest-mocks/lightning/modal.js, wired in through jest.config.js's
 * moduleNameMapper. Its `close(result)` dispatches a catchable `close` event,
 * which is the ONLY handle a test has on the return value when the modal is
 * mounted directly (there is no promise to await). ⚠ STUB ARTEFACT: a bare
 * `close()` arrives as `detail === null`, not `undefined` — CustomEvent's own
 * coercion, not LightningModal's behaviour.
 *
 * ⚠ The `lightning-record-edit-form` and `lightning-input-field` stubs are the
 * ones sfdx-lwc-jest ships. The form stub renders `<slot></slot>` (so children
 * render) and exposes `submit()` as a NO-OP @api method — `jest.spyOn` on the
 * rendered element is therefore the only way to see what was submitted, and it
 * is what these tests do rather than fabricating a payload shape the platform
 * never sends.
 */
import { createElement } from 'lwc';
import BovAddResponseModal from 'c/bovAddResponseModal';

const DISPOSITION_ID = 'a0D5g000000DispEAG';
const NEW_RECORD_ID = 'a0X010000000009AAA';

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-bov-add-response-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { dispositionId: DISPOSITION_ID }) {
        const element = createElement('c-bov-add-response-modal', {
            is: BovAddResponseModal
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const form = (el) =>
        el.shadowRoot.querySelector('lightning-record-edit-form');
    const inputs = (el) => [
        ...el.shadowRoot.querySelectorAll('lightning-input-field')
    ];
    const fieldNames = (el) => inputs(el).map((i) => i.fieldName);

    // ─────────────────────────────────────────────────────────────────────────
    // T-FIELDS — the form is not an empty shell
    // ─────────────────────────────────────────────────────────────────────────

    it('T-FIELDS: renders every field the BOV Submission Layout asks an analyst for', () => {
        const element = createComponent();

        // Order is template order, and it is the layout's reading order:
        // parent, who responded, then the BOV terms.
        expect(fieldNames(element)).toEqual([
            'Disposition__c',
            'Broker__c',
            'BOV_Amount__c',
            'Cap_Rate__c',
            'Commission_Rate__c',
            'Days_To_Market__c',
            'Hist_Success_Rate__c',
            'BOV_Score__c',
            'Submission_Status__c'
        ]);

        expect(form(element).objectApiName).toBe('BOV_Submission__c');
        // 🔴 CREATE ONLY. A `record-id` would turn this into an edit form against
        // whatever Id leaked in.
        expect(form(element).recordId).toBeUndefined();
    });

    it('🔴 T-FIELDS: BOV_Score__c is rendered and OPTIONAL (2026-08-21, formula conversion deferred)', () => {
        const element = createComponent();
        const rendered = inputs(element);
        const score = rendered.find((i) => i.fieldName === 'BOV_Score__c');

        // 🔴 RETRACTED 2026-08-21 (later the same day). This test used to pin
        // BOV_Score__c as ABSENT, on the grounds that it was removed from `BOV
        // Submission Layout` by hand in Setup on 2026-08-20 and this dialog
        // replaces that screen. The formula conversion that removal was clearing
        // the way for is now evaluated and deferred (cancelled for now); the
        // user's explicit instruction is to make the field hand-enterable here.
        // The field is back on the layout too — see that file's own
        // reconciliation comment.
        expect(score).toBeDefined();
        // Optional, not required — a broker response with no score must still
        // save. No validation rule names this field, so nothing server-side
        // would refuse an empty one either.
        expect(score.required).toBeFalsy();
    });

    it('🔴 T-FIELDS: the stamped / derived / withdrawn fields are NOT offered', () => {
        const element = createComponent();
        const rendered = fieldNames(element);

        // Broker_Firm__c and Contact_Name__c are written by
        // BovSubmissionBrokerStampService in the before-save trigger, from the
        // chosen Broker__c Contact. Anything typed into them is overwritten in
        // the same save — an input whose value is discarded with a success
        // toast is worse than no input at all.
        expect(rendered).not.toContain('Broker_Firm__c');
        expect(rendered).not.toContain('Contact_Name__c');
        // Written only by the approval process, and editable=false in
        // DPEG_Disposition_Edit — rendering it raises an FLS error in the form.
        expect(rendered).not.toContain('Approval_Status__c');
        // AutoNumber (BOV-{0000}).
        expect(rendered).not.toContain('Name');
    });

    it('🔴 T-FIELDS: the two validation-rule fields are marked required on the client', () => {
        const element = createComponent();
        const required = inputs(element)
            .filter((i) => i.required)
            .map((i) => i.fieldName);

        // Broker_Required_On_Submission and BOV_Amount_Required_On_Submission
        // both refuse the save server-side. Marking them here turns a round trip
        // into an inline message.
        expect(required).toContain('Broker__c');
        expect(required).toContain('BOV_Amount__c');
        // ...and the three the PAGE LAYOUT marks Required, so this dialog is no
        // laxer than the standard New screen it replaced.
        expect(required).toEqual([
            'Broker__c',
            'BOV_Amount__c',
            'Cap_Rate__c',
            'Commission_Rate__c',
            'Days_To_Market__c'
        ]);
    });

    it('PARENT: the disposition is shown, and shown LOCKED', () => {
        const element = createComponent();
        const parent = element.shadowRoot.querySelector(
            '.bar-field-disposition'
        );

        expect(parent.value).toBe(DISPOSITION_ID);
        // Disabled so a dialog opened on one sale cannot log a response against
        // another. (The value still reaches the server — see T-PARENT-*.)
        expect(parent.disabled).toBe(true);
    });

    it('STATUS: defaults to Backup — appointment is the Replace Broker path', () => {
        const element = createComponent();

        // 🔴 THE CONTROL ITSELF IS THE VISIBLE STEER, AND SINCE 2026-08-21 IT IS THE
        // ONLY ONE. `.bar-note` ("New responses are logged as Backup. Use Replace
        // Broker on the comparison matrix to appoint one.") was removed in the UAT
        // prose pass, and this assertion is what makes that removal safe: the field
        // renders WITH the value, so a user still sees "Backup" before saving.
        // If this default is ever dropped, the removal stops being safe — see
        // T-NO-PROSE below.
        expect(
            element.shadowRoot.querySelector('.bar-field-status').value
        ).toBe('Backup');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // TWO paragraphs were removed at the user's request:
    //   .bar-intro  "Log a broker's opinion of value against this sale. It is
    //                saved here on the disposition — you stay on this page and the
    //                comparison matrix refreshes behind this dialog."
    //   .bar-note   "New responses are logged as Backup. Use Replace Broker on the
    //                comparison matrix to appoint one."
    // Only the second was asserted anywhere, and that assertion was deleted rather
    // than weakened. This pin replaces both.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: neither the intro nor the closing note is rendered — the removal must not come back', () => {
        const element = createComponent();

        // Guard the guard: the form genuinely rendered, so every absence below is a
        // real absence rather than an unrendered component.
        expect(
            element.shadowRoot.querySelector('lightning-record-edit-form')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelectorAll('lightning-input-field').length
        ).toBeGreaterThan(0);

        // 1. THE OLD SELECTORS.
        expect(element.shadowRoot.querySelector('.bar-intro')).toBeNull();
        expect(element.shadowRoot.querySelector('.bar-note')).toBeNull();

        // 2. 🔴 THE RENDERED WORDS — a re-added paragraph usually arrives under a
        //    new class name, so the selector assertions alone would stay green.
        const text = element.shadowRoot.textContent.toLowerCase();
        expect(text).not.toContain('you stay on this page');
        expect(text).not.toContain('refreshes behind this dialog');
        expect(text).not.toContain('opinion of value against this sale');
        expect(text).not.toContain('are logged as backup');
        expect(text).not.toContain('to appoint one');
    });

    it('surfaces platform field errors through lightning-messages', () => {
        const element = createComponent();

        // The two validation rules carry AUTHORED messages naming their own
        // field. lightning-messages renders them against that field; a
        // hand-rolled banner rebuilt from error.detail loses the attribution.
        expect(
            element.shadowRoot.querySelector('lightning-messages')
        ).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // T-PARENT — Disposition__c reaches the server on BOTH submit paths
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-PARENT-BUTTON: the footer Save forces Disposition__c onto the payload', () => {
        const element = createComponent();
        const submit = jest.spyOn(form(element), 'submit');

        element.shadowRoot.querySelector('.bar-save').click();

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        // 🔴 THE CENTRAL ASSERTION OF THIS FILE. A `disabled` input is a DISPLAY
        // affordance; a disabled control is conventionally excluded from a form
        // submission, so relying on it would make the parent lookup depend on a
        // base-component implementation detail. It is forced in JS instead.
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        // The gathered input values ride along. (In Jest only the two fields
        // with a bound `value` have one — the stub leaves the rest undefined,
        // and undefined values are dropped rather than sent as nulls.)
        expect(payload.Submission_Status__c).toBe('Backup');
    });

    it('🔴 T-PARENT-ENTER: a native submit (ENTER in a field) forces it too', () => {
        const element = createComponent();
        const submit = jest.spyOn(form(element), 'submit');

        // The REAL shape the platform dispatches: a `submit` event carrying the
        // form's own field map in `detail.fields`. Nothing here fabricates a
        // payload the platform never sends.
        form(element).dispatchEvent(
            new CustomEvent('submit', {
                detail: { fields: { BOV_Amount__c: 12500000 } }
            })
        );

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        // ⚠ THIS PATH EXISTS AND THE FOOTER BUTTON NEVER TOUCHES IT. Pressing
        // ENTER inside a text input submits the form natively and fires
        // `onsubmit`; the footer button's `submit(fields)` does NOT fire it.
        // Without this handler the parent would be missing on exactly this path.
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        expect(payload.BOV_Amount__c).toBe(12500000);
    });

    it('VALIDITY: an invalid field aborts the save before any round trip', () => {
        const element = createComponent();
        const submit = jest.spyOn(form(element), 'submit');

        // ⚠ THE STUB'S `reportValidity()` RETURNS UNDEFINED, so the component
        // aborts only on an explicit `false` — a truthiness test there would
        // abort every save in Jest and leave the whole submit path unexercised
        // (a green suite proving nothing). This test overrides one field's
        // return value to prove the branch is live rather than decorative.
        jest.spyOn(
            element.shadowRoot.querySelector('.bar-field-broker'),
            'reportValidity'
        ).mockReturnValue(false);

        element.shadowRoot.querySelector('.bar-save').click();

        expect(submit).not.toHaveBeenCalled();
        // The dialog stays open: a refusal here is about what was typed, and
        // closing would throw away the user's other eight values.
        expect(form(element)).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome handling
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 SUCCESS: closes with the new record Id and NEVER navigates', async () => {
        const element = createComponent();
        const closed = jest.fn();
        element.addEventListener('close', closed);

        form(element).dispatchEvent(
            new CustomEvent('success', {
                detail: {
                    id: NEW_RECORD_ID,
                    fields: { Name: { value: 'BOV-0021' } }
                }
            })
        );
        await flushPromises();

        expect(closed).toHaveBeenCalledTimes(1);
        // 🔴 The Id is the product: c/bovComparisonMatrix uses it to decide
        // whether anything actually happened, then calls refreshApex on its own
        // wire. Returning nothing would silently reinstate a stale matrix.
        expect(closed.mock.calls[0][0].detail).toEqual({
            recordId: NEW_RECORD_ID,
            name: 'BOV-0021'
        });
    });

    it('SUCCESS: a missing Name still returns a usable result', async () => {
        const element = createComponent();
        const closed = jest.fn();
        element.addEventListener('close', closed);

        form(element).dispatchEvent(
            new CustomEvent('success', { detail: { id: NEW_RECORD_ID } })
        );
        await flushPromises();

        // ⚠ Never `undefined` for the name — the opener interpolates it into a
        // toast message, and an undefined there renders the literal string
        // "undefined" in front of the user.
        expect(closed.mock.calls[0][0].detail).toEqual({
            recordId: NEW_RECORD_ID,
            name: ''
        });
    });

    it('🔴 ERROR: the dialog STAYS OPEN and keeps what the user typed', async () => {
        const element = createComponent();
        const closed = jest.fn();
        element.addEventListener('close', closed);

        element.shadowRoot.querySelector('.bar-save').click();
        form(element).dispatchEvent(
            new CustomEvent('error', {
                detail: { message: 'Enter the BOV Amount this broker submitted.' }
            })
        );
        await flushPromises();

        // 🔴 Every realistic refusal here is about WHAT WAS TYPED. Closing would
        // throw away both the message lightning-messages just rendered and the
        // user's other values.
        expect(closed).not.toHaveBeenCalled();
        expect(form(element)).not.toBeNull();
        // The spinner is released, so Save is usable again.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        expect(element.shadowRoot.querySelector('.bar-save').disabled).toBe(false);
    });

    it('SAVING: the spinner appears and Save is disabled while in flight', async () => {
        const element = createComponent();

        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();

        element.shadowRoot.querySelector('.bar-save').click();
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('lightning-spinner')
        ).not.toBeNull();
        expect(element.shadowRoot.querySelector('.bar-save').disabled).toBe(true);
    });

    it('SAVING: a second click while in flight does not submit twice', async () => {
        const element = createComponent();
        const submit = jest.spyOn(form(element), 'submit');

        element.shadowRoot.querySelector('.bar-save').click();
        await flushPromises();
        element.shadowRoot.querySelector('.bar-save').click();

        expect(submit).toHaveBeenCalledTimes(1);
    });

    it('CANCEL: closes with nothing, so the opener says nothing', async () => {
        const element = createComponent();
        const closed = jest.fn();
        element.addEventListener('close', closed);

        element.shadowRoot.querySelector('.bar-cancel').click();
        await flushPromises();

        expect(closed).toHaveBeenCalledTimes(1);
        // ⚠ STUB ARTEFACT: `close()` with no argument arrives as `detail === null`,
        // not `undefined` — CustomEvent's own coercion. The real LightningModal
        // resolves `undefined`. The opener treats both the same way (`if (!result
        // || !result.recordId) return;`), which is what makes the difference safe.
        expect(closed.mock.calls[0][0].detail).toBeFalsy();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await flushPromises();

        await expect(element).toBeAccessible();
    });
});
