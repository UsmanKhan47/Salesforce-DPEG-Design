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
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 A FOURTH FALSIFIER, ADDED 2026-08-24: THIS BUNDLE NOW HAS TWO MODES.
 * ═══════════════════════════════════════════════════════════════════════════
 * `@api isPreferred` (default false) switches it into "Add Preferred Broker".
 * The T-PREFERRED-* block at the end of this file is the falsifier set for it,
 * and it is written around ONE failure mode that produces NO ERROR ANYWHERE:
 * `Is_Preferred_Broker__c` is INJECTED into the payload rather than rendered as
 * a field, so if it is ever dropped from `withParent()` the dialog still saves,
 * still closes, still toasts success — and creates an ordinary response that
 * appears in the WRONG CARD. Nothing on screen says so. The payload assertions
 * on BOTH submit paths are the only thing that catches it.
 *
 * ⚠ THOSE SAME ASSERTIONS ALSO PIN A SINGLE-WRITER CONTRACT (2026-08-24):
 * `Submission_Status__c` must be ABSENT from the preferred payload, because
 * `BovAutoSelectionService` owns that field on this path. Writing it here would
 * be a second writer AND would be refused by
 * `BovSubmissionSelectionGuardService` on any disposition that already has an
 * appointed broker — a failure that happens in the ORG, never in Jest.
 *
 * 🔴 WIDENED 2026-08-24 (LATER STILL) TO **BOTH** PAYLOADS AND BOTH RENDERS.
 * `Submission_Status__c` was removed from the form in RESPONSE mode too, so the
 * control exists in neither mode and no submit path sends the key. Three things
 * moved with it, listed so nothing looks dropped:
 *   - `STATUS: defaults to Backup …` (asserted `.bar-field-status`'s value) and
 *     `T-PREFERRED-STATUS …` (asserted its absence in ONE mode, and asserted the
 *     default mode still OFFERED it — a line that is now false) are both
 *     replaced by the single T-NO-STATUS pin, which carries their reasoning.
 *   - the two payload assertions that read `.toBe('Backup')` are now
 *     `not.toHaveProperty`. 🔴 THAT DIFFERENCE IS THE WHOLE POINT: an equality
 *     assertion still passes when the key is sent with the expected value, so
 *     only the absence form catches a regression that starts sending the key.
 *   - T-PARENT-BUTTON lost the assertion that proved `handleSave` GATHERS input
 *     values at all (the status control was the only Jest-visible input with a
 *     value the parent injection did not already force). T-GATHER replaces it.
 *
 * ⚠ EVERY DEFAULT-MODE TEST ABOVE IS ALSO THE REGRESSION PIN FOR MODE ONE.
 * `createComponent()` uses its default parameter — which does NOT set
 * `isPreferred` — so the whole existing suite runs in response mode and fails
 * if the preferred branch ever leaks into it. That is deliberate; do not
 * "modernise" those tests by passing `isPreferred: false` explicitly, because
 * the absent-prop case is the one every real opener that predates this change
 * would produce.
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
        // 🔴 BOV_Score__c IS NO LONGER IN THIS LIST (2026-08-22, formula conversion completed,
        // manifest/bov-score-formula-conversion/). It was here from 2026-08-21 while the
        // conversion was deferred and the field was hand-enterable; it is now a FORMULA field and
        // `lightning-input-field` cannot render a formula field as an editable input at all. The
        // dedicated "BOV_Score__c is rendered and OPTIONAL" test that used to follow this one is
        // retired for good — see "the stamped / derived / withdrawn fields are NOT offered" below,
        // which now asserts its absence instead.
        expect(fieldNames(element)).toEqual([
            'Disposition__c',
            'Broker__c',
            'BOV_Amount__c',
            'Cap_Rate__c',
            'Commission_Rate__c',
            'Days_To_Market__c',
            'Hist_Success_Rate__c'
            // 🔴 `Submission_Status__c` LEFT THIS LIST 2026-08-24. It is the one
            // field on `BOV Submission Layout` this form deliberately withholds:
            // automatic selection by score owns the value now, and an insert
            // naming 'Selected' is refused by BovSubmissionSelectionGuardService.
            // Its absence is pinned by name in T-NO-STATUS below.
        ]);

        expect(form(element).objectApiName).toBe('BOV_Submission__c');
        // 🔴 CREATE ONLY. A `record-id` would turn this into an edit form against
        // whatever Id leaked in.
        expect(form(element).recordId).toBeUndefined();
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
        // 🔴 ADDED 2026-08-22 (manifest/bov-score-formula-conversion/, Step 3). BOV_Score__c is a
        // FORMULA field again — `lightning-input-field` cannot render a formula field as an
        // editable input at all. This is what catches a future regression if someone re-adds the
        // input, the same protective role the retracted HTML/JS comments serve for a human reader.
        expect(rendered).not.toContain('BOV_Score__c');
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

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-STATUS — THE SINGLE ABSENCE PIN FOR `Submission_Status__c`
    //     (2026-08-24, and it covers BOTH modes)
    //
    // REPLACES TWO TESTS, both of which are gone and neither of which was
    // dropped silently:
    //   1. `STATUS: defaults to Backup — appointment is the Replace Broker path`
    //      asserted `.bar-field-status`'s value was 'Backup'. It existed to make
    //      the 2026-08-21 removal of the `.bar-note` prose safe ("the user still
    //      SEES Backup in the control"). With the control gone, that argument is
    //      retracted in the template: a new row's status is no longer a
    //      user-facing fact at create time, because BovAutoSelectionService may
    //      overturn it in the same transaction.
    //   2. `T-PREFERRED-STATUS: … NOT rendered on this path` asserted the same
    //      absence for preferred mode ONLY, and closed with
    //      `expect(fieldNames(createComponent())).toContain('Submission_Status__c')`
    //      — a line that is now FALSE. Its comment recorded that the control was
    //      hidden because the status is decided by BovAutoSelectionService, not
    //      typed; that reasoning survives here and now applies to both modes.
    //
    // 🔴 WHY ONE PIN AND NOT TWO: an absence assertion passes for ANY reason the
    // node is missing, including "the component never rendered". Two of them
    // would rot independently. This one guards the guard, names the field, and
    // checks both modes in a single place.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-STATUS: the Submission_Status__c input is rendered in NEITHER mode', () => {
        [createComponent(), preferredComponent()].forEach((element) => {
            // Guard the guard: the form rendered and has fields, so each absence
            // below is a real absence and not an unmounted component.
            expect(form(element)).not.toBeNull();
            expect(inputs(element).length).toBeGreaterThan(0);

            // 1. BY FIELD NAME — catches the control returning under any class.
            expect(fieldNames(element)).not.toContain('Submission_Status__c');
            // 2. BY CLASS — catches it returning under its original class with a
            //    fieldName typo, which a `not.toContain` on names would miss.
            expect(
                element.shadowRoot.querySelector('.bar-field-status')
            ).toBeNull();
        });
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
        // 🔴 AND NO STATUS KEY — not 'Backup', not any value (2026-08-24).
        // `not.toHaveProperty`, deliberately, rather than an equality check:
        // the regression worth catching is the key COMING BACK at all, and
        // `.toBe('Backup')` would pass for exactly that regression.
        expect(payload).not.toHaveProperty('Submission_Status__c');
    });

    it('🔴 T-GATHER: the footer Save carries what the user typed, not just the forced parent', () => {
        // ⚠ THIS REPLACES A FALSIFIER THAT LEFT WITH THE STATUS CONTROL.
        // T-PARENT-BUTTON above used to prove `handleSave`'s gather loop runs by
        // asserting `payload.Submission_Status__c === 'Backup'` — in Jest the
        // stub leaves every input's `value` undefined except the ones the
        // template binds, and that was the only bound one whose value was not
        // ALSO forced by `withParent()`. Delete the gather loop today and every
        // other payload assertion in this file still passes, because
        // `Disposition__c` and `Is_Preferred_Broker__c` are both injected.
        // This test puts a value on a stub input and demands it reach submit().
        const element = createComponent();
        element.shadowRoot.querySelector('.bar-field-amount').value = 12500000;
        const submit = jest.spyOn(form(element), 'submit');

        element.shadowRoot.querySelector('.bar-save').click();

        expect(submit).toHaveBeenCalledTimes(1);
        expect(submit.mock.calls[0][0].BOV_Amount__c).toBe(12500000);
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

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-PREFERRED — "Add Preferred Broker" mode (2026-08-24)
    //
    // ⚠ EVERY TEST HERE PASSES THE FULL PROPS OBJECT INCLUDING `dispositionId`.
    // `createComponent(props = {...})` has a DEFAULT PARAMETER, so passing a
    // partial object silently drops the parent — and `undefined` would restore
    // the default rather than clearing it.
    //
    // ⚠ ASSERTIONS READ RENDERED PROPERTIES (`label`, `required`, `value`) AND
    // THE SUBMITTED PAYLOAD — never `shadowRoot.textContent`. Every base
    // component in this template is an sfdx-lwc-jest stub that renders an EMPTY
    // template, so the modal header's label appears in NO text node and a
    // `textContent` assertion on it is vacuously green in both directions.
    // ─────────────────────────────────────────────────────────────────────────

    const modalHeader = (el) =>
        el.shadowRoot.querySelector('lightning-modal-header');

    const preferredComponent = () =>
        createComponent({
            dispositionId: DISPOSITION_ID,
            isPreferred: true
        });

    it('🔴 T-PREFERRED-TITLE: the header and Save button follow the mode', () => {
        // DEFAULT MODE FIRST, so the assertion below is a DIFFERENCE and not a
        // coincidence. Without this half, a getter hardcoded to the preferred
        // string would pass the preferred test and break the real one.
        const response = createComponent();
        expect(modalHeader(response).label).toBe('Add Broker Response');
        expect(response.shadowRoot.querySelector('.bar-save').label).toBe(
            'Save response'
        );

        const preferred = preferredComponent();
        // The exact string the user asked for.
        expect(modalHeader(preferred).label).toBe('Add Preferred Broker');
        // "Save response" is wrong wording on this path — a preferred broker is
        // not a response to anything.
        expect(preferred.shadowRoot.querySelector('.bar-save').label).toBe(
            'Save preferred broker'
        );
    });

    it('🔴 T-PREFERRED-REQUIRED: ONLY Broker__c stays required — everything else is optional', () => {
        const element = preferredComponent();

        const required = inputs(element)
            .filter((i) => i.required)
            .map((i) => i.fieldName);

        // 🔴 EXACT EQUALITY, NOT `toContain`. The user's decision was "every
        // field optional EXCEPT Broker__c", so the falsifier has to be the whole
        // SET: a `toContain('Broker__c')` assertion would pass unchanged if all
        // six stayed required, which is the pre-change behaviour this test
        // exists to rule out.
        expect(required).toEqual(['Broker__c']);

        // ...and named individually, because `toEqual` on an array failing tells
        // you the set is wrong but not which field regressed.
        expect(required).not.toContain('BOV_Amount__c');
        expect(required).not.toContain('Cap_Rate__c');
        expect(required).not.toContain('Commission_Rate__c');
        expect(required).not.toContain('Days_To_Market__c');
    });

    it('🔴 T-PREFERRED-REQUIRED: Broker__c is required in BOTH modes — this is the deliberate exception', () => {
        // ⚠ THE POINT OF A SEPARATE TEST: the requiredness of Broker__c is the
        // ONE thing the mode does NOT change, and a shared `required={getter}`
        // binding applied to it by mistake would be invisible in the
        // default-mode suite (where the getter is true anyway). Only the
        // preferred-mode half of this assertion can catch it.
        expect(
            createComponent().shadowRoot.querySelector('.bar-field-broker')
                .required
        ).toBe(true);
        expect(
            preferredComponent().shadowRoot.querySelector('.bar-field-broker')
                .required
        ).toBe(true);
    });


    it('🔴 T-PREFERRED-PAYLOAD-BUTTON: the footer Save forces the flag and writes NO status', () => {
        const element = preferredComponent();
        const submit = jest.spyOn(form(element), 'submit');

        element.shadowRoot.querySelector('.bar-save').click();

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        // 🔴 THE CENTRAL ASSERTION OF THIS BLOCK. The flag has no input on the
        // form — it IS the mode — so it can only reach the server by being
        // injected. If this line ever goes missing the dialog still saves, still
        // toasts success, and quietly creates an ordinary Backup response in the
        // matrix below instead of a preferred broker above.
        expect(payload.Is_Preferred_Broker__c).toBe(true);

        // 🔴 THE STATUS KEY IS ABSENT ENTIRELY — not 'Backup', not 'Selected'.
        // REVISED 2026-08-24 (this test asserted 'Backup' for a few hours).
        // The user decided a preferred broker BECOMES the appointed broker, so
        // 'Backup' is the wrong end state — but 'Selected' cannot be written
        // from here either: BovSubmissionSelectionGuardService runs in
        // beforeInsert with no preferred exemption and addErrors an
        // insert-as-Selected while a committed Selected sibling exists, which
        // under automatic selection is every priced disposition. So the field
        // has exactly ONE writer, BovAutoSelectionService, and this assertion is
        // what keeps it that way — a well-meaning 'Selected' added here would
        // fail in the ORG, not in Jest, and only on dispositions that already
        // have an appointed broker.
        expect(payload).not.toHaveProperty('Submission_Status__c');

        // The parent is still forced, exactly as on the default path.
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
    });

    it('🔴 T-PREFERRED-PAYLOAD-ENTER: a native submit (ENTER in a field) forces it too, and still writes NO status', () => {
        const element = preferredComponent();
        const submit = jest.spyOn(form(element), 'submit');

        // ⚠ THE SECOND SUBMIT PATH, WHICH THE FOOTER BUTTON NEVER TOUCHES.
        // Pressing ENTER inside a text input submits the form natively and fires
        // `onsubmit`. Injecting the flag in `handleSave` alone would leave THIS
        // path creating unflagged rows — and a user pressing ENTER is not doing
        // anything unusual.
        form(element).dispatchEvent(
            new CustomEvent('submit', {
                detail: { fields: { BOV_Amount__c: 12500000 } }
            })
        );

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        expect(payload.Is_Preferred_Broker__c).toBe(true);
        // Same single-writer pin as the button path above. Both paths, because
        // there are genuinely two and withParent() is the only shared code.
        expect(payload).not.toHaveProperty('Submission_Status__c');
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        expect(payload.BOV_Amount__c).toBe(12500000);
    });

    it('🔴 T-PREFERRED-PAYLOAD: the DEFAULT path does not send the flag AT ALL', () => {
        const element = createComponent();
        const submit = jest.spyOn(form(element), 'submit');

        element.shadowRoot.querySelector('.bar-save').click();

        const payload = submit.mock.calls[0][0];
        // 🔴 ABSENT, NOT `false`, AND THE DIFFERENCE IS AN OUTAGE.
        // `Is_Preferred_Broker__c` DOES NOT EXIST IN THE ORG YET. A payload key
        // naming a field that does not exist is an error from
        // lightning-record-edit-form — so an unconditional `false` here would
        // break the working "Add Broker Response" dialog the moment this
        // deploys, in order to set a flag to the value it already defaults to.
        // ⚠ RETRACTED IN PLACE 2026-08-24: the field IS now live on usman-dpeg
        // (FieldDefinition query, see the component header), so the OUTAGE half
        // of that reasoning is spent. The assertion stands on the other half —
        // there is no value in writing a field to the value it already defaults
        // to, and every key added here is one more key the form FLS-checks.
        expect(payload).not.toHaveProperty('Is_Preferred_Broker__c');
        // And the default path's payload is otherwise unchanged.
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        // 🔴 …EXCEPT THAT IT NO LONGER SENDS A STATUS KEY EITHER (2026-08-24).
        // This line read `expect(payload.Submission_Status__c).toBe('Backup')`
        // until the input was removed from response mode too. The two payloads
        // are now identical apart from the preferred flag.
        expect(payload).not.toHaveProperty('Submission_Status__c');
    });
    it('T-PREFERRED: is accessible', async () => {
        const element = preferredComponent();

        await flushPromises();

        await expect(element).toBeAccessible();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-REPLACEMENT — "Replace Preferred Broker" mode (2026-08-24)
    //
    // The THIRD mode. `c/bovBrokerPanel`'s Replace Broker button opens this
    // dialog instead of the backup picker when the disposition already has a
    // preferred broker: the successor is usually a broker who has submitted no
    // BOV at all, and so has no row for a picker to offer.
    //
    // 🔴 IT IS ALWAYS OPENED WITH `isPreferred: true` AS WELL, and every test
    // below passes both flags for that reason. A test that passed
    // `isReplacement` alone would be exercising a combination the opener never
    // produces, and would hide the fact that the flag injection is keyed on
    // `isPreferred`.
    //
    // ⚠ THIS DIALOG STILL ONLY CREATES. The outgoing row is retired by the
    // opener afterwards, through `BovController.replacePreferredBroker`. Keeping
    // the Apex out of this bundle is what preserves the property that
    // `lightning-record-edit-form` owns CRUD/FLS and validation-rule surfacing
    // for all three modes.
    // ─────────────────────────────────────────────────────────────────────────

    const OUTGOING_LABEL = 'Cushman & Wakefield — Ada Lin';

    const replacementComponent = (props = {}) =>
        createComponent({
            dispositionId: DISPOSITION_ID,
            isPreferred: true,
            isReplacement: true,
            outgoingBrokerLabel: OUTGOING_LABEL,
            ...props
        });

    const outgoingLine = (el) =>
        el.shadowRoot.querySelector('.bar-field-outgoing');

    it('🔴 T-REPLACEMENT-TITLE: the header and Save button name the REPLACEMENT, not an appointment', () => {
        // ALL THREE MODES IN ONE TEST, so each assertion is a DIFFERENCE and not
        // a coincidence. A getter hardcoded to the replacement string would pass
        // a replacement-only test and break the other two.
        expect(modalHeader(createComponent()).label).toBe('Add Broker Response');
        expect(modalHeader(preferredComponent()).label).toBe(
            'Add Preferred Broker'
        );

        const replacement = replacementComponent();
        // 🔴 THE ORDER OF THE GETTER'S TESTS IS WHAT THIS CATCHES. Replacement
        // mode carries `isPreferred: true` too, so an `isPreferred`-first chain
        // labels this dialog "Add Preferred Broker" and never reaches the
        // replacement string at all — a title promising an addition over a form
        // that is about to retire a row.
        expect(modalHeader(replacement).label).toBe('Replace Preferred Broker');
        expect(replacement.shadowRoot.querySelector('.bar-save').label).toBe(
            'Replace preferred broker'
        );
    });

    it('🔴 T-REPLACEMENT-OUTGOING: the existing preferred broker is shown, READ-ONLY', () => {
        const element = replacementComponent();

        const line = outgoingLine(element);
        expect(line).not.toBeNull();
        // ⚠ THE RENDERED TEXT, not the getter. A getter-only assertion has passed
        // in this repo while the rendered output was wrong.
        expect(line.textContent).toContain('Current preferred broker');
        expect(line.textContent).toContain(OUTGOING_LABEL);

        // 🔴 STATIC MARKUP, NOT A `lightning-input-field` — not even a disabled
        // one. A field here would put a key in the payload that
        // `lightning-record-edit-form` FLS-checks and, for a persona without edit
        // on it, DROPS SILENTLY behind a success toast.
        expect(line.querySelector('lightning-input-field')).toBeNull();
        expect(fieldNames(element)).not.toContain('Broker_Firm__c');
        expect(fieldNames(element)).not.toContain('Contact_Name__c');
    });

    it('🔴 T-REPLACEMENT-OUTGOING: the line renders in NEITHER other mode', () => {
        // ABSENCE PIN WITH ITS GUARD. Without the positive test above this would
        // be green on a component that renders nothing at all.
        expect(outgoingLine(createComponent())).toBeNull();
        expect(outgoingLine(preferredComponent())).toBeNull();
        expect(outgoingLine(replacementComponent())).not.toBeNull();
    });

    it('🔴 T-REPLACEMENT-OUTGOING: an EMPTY label renders nothing rather than an empty heading', () => {
        // A form element with a heading and no value reads as data that failed to
        // load — worse than absent. The opener returns `''` (never `undefined`)
        // when it holds no preferred row, so this is the state to handle.
        const element = replacementComponent({ outgoingBrokerLabel: '' });

        expect(outgoingLine(element)).toBeNull();
        // Guard the guard: the dialog itself still rendered.
        expect(element.shadowRoot.querySelector('.bar-save')).not.toBeNull();
    });

    it('🔴 T-REPLACEMENT-CHOOSER: Broker__c is the control that picks the INCOMING broker, and it is required', () => {
        const element = replacementComponent();

        const broker = element.shadowRoot.querySelector('.bar-field-broker');
        expect(broker).not.toBeNull();
        expect(broker.fieldName).toBe('Broker__c');
        // ⚠ REQUIRED IN THIS MODE TOO. `Broker_Firm__c` and `Contact_Name__c` are
        // STAMPED from this lookup, so a blank one produces a preferred-broker
        // card whose Firm and Contact columns both render "—": a row identifying
        // nobody, replacing a row that identified somebody.
        expect(broker.required).toBe(true);

        // 🔴 AND THERE IS NO SECOND PICKER. A `lightning-combobox` or
        // `lightning-radio-group` here would mean the successor had to be an
        // existing BOV submission — which is exactly what this mode exists to
        // avoid.
        expect(
            element.shadowRoot.querySelector('lightning-radio-group')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('lightning-combobox')
        ).toBeNull();
    });

    it('🔴 T-REPLACEMENT-PAYLOAD: the flag is still forced, the status is still absent, and the outgoing broker is NOT sent', () => {
        const element = replacementComponent();
        const submit = jest.spyOn(form(element), 'submit');

        element.shadowRoot.querySelector('.bar-save').click();

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];

        // The incoming row is a preferred broker, created exactly as the
        // first-appointment path creates one.
        expect(payload.Is_Preferred_Broker__c).toBe(true);
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        // `BovAutoSelectionService` remains the sole writer of the status.
        expect(payload).not.toHaveProperty('Submission_Status__c');

        // 🔴 THE READ-ONLY LINE CANNOT REACH THE PAYLOAD. `handleSave` gathers
        // only rendered `lightning-input-field`s, so static markup is structurally
        // incapable of contributing a key — this asserts that structure, and it
        // is the assertion that reds if the line is ever "upgraded" to a disabled
        // input field for the sake of alignment.
        expect(payload).not.toHaveProperty('Broker_Firm__c');
        expect(payload).not.toHaveProperty('Contact_Name__c');
        expect(
            Object.keys(payload).some((k) => /outgoing/i.test(k))
        ).toBe(false);
    });

    it('🔴 T-REPLACEMENT-PAYLOAD-ENTER: the native (ENTER) submit path carries the same three facts', () => {
        // THERE ARE GENUINELY TWO SUBMIT PATHS. The footer button never fires
        // `onsubmit`; ENTER inside a text input does, and only `withParent()` is
        // on both. A fix applied to `handleSave` alone leaves this path creating
        // an UNFLAGGED row under a "Replace Preferred Broker" header.
        const element = replacementComponent();
        const submit = jest.spyOn(form(element), 'submit');

        form(element).dispatchEvent(
            new CustomEvent('submit', {
                detail: { fields: { Broker__c: '003000000000001' } }
            })
        );

        expect(submit).toHaveBeenCalledTimes(1);
        const payload = submit.mock.calls[0][0];
        expect(payload.Is_Preferred_Broker__c).toBe(true);
        expect(payload.Disposition__c).toBe(DISPOSITION_ID);
        expect(payload.Broker__c).toBe('003000000000001');
        expect(payload).not.toHaveProperty('Submission_Status__c');
    });

    it('T-REPLACEMENT: is accessible', async () => {
        const element = replacementComponent();

        await flushPromises();

        await expect(element).toBeAccessible();
    });
});
