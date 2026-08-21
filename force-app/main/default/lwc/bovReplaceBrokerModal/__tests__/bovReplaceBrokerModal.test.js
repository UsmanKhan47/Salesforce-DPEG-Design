/**
 * c-bov-replace-broker-modal — LightningModal + IMPERATIVE Apex suite.
 *
 * See jest-mocks/lightning/modal.js: sfdx-lwc-jest ships NO `lightning/modal` stub, so a repo-local
 * one is mapped in through jest.config.js. Because that stub extends LightningElement, the modal is
 * mounted DIRECTLY here and `close(result)` is observed through its `close` CustomEvent. The
 * platform `open()` path is exercised from the OPENER's suite (c-bov-comparison-matrix), which
 * mocks this module wholesale.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. THE SERVER'S RETURNED TEXT IS PASSED THROUGH UNTOUCHED. `BovSubmissionService` clears the
 *    outgoing submission's approval status as part of the swap, so a fresh approval is required —
 *    and the service's own String says so. A second copy of that sentence authored in JS would
 *    still be claiming "a fresh approval is required" the day the service changes to preserve the
 *    status. The test asserts the exact string round-trips, character for character.
 * 2. A FAILURE KEEPS THE MODAL OPEN — the opposite of c/sellMeterInitiateModal, and deliberately
 *    so: refusals here are about the CHOSEN SUBMISSION, so picking a different backup is a real
 *    remedy. There, refusals are properties of the asset and a retry is pointless.
 * 3. Confirm is disabled until a backup is chosen, and the Apex parameters are `dispositionId` /
 *    `newSubmissionId` / `reason` / `notes` verbatim — an imperative call binds by NAME.
 * 4. 🔴 THE REASON OPTIONS COME FROM `getPicklistValues` AND ARE NOT AUTHORED IN JS (2026-08-20,
 *    Tranche 2 Workstream B). The suite asserts the combobox's options are the wire's payload
 *    passed through, and — the falsifier that matters — that a value the wire emits which appears
 *    NOWHERE in this repo's source still reaches the combobox. That is what would fail if somebody
 *    "simplified" the wire into a constant array: a hardcoded list keeps passing an equality check
 *    against a fixture built from the same list.
 * 5. A FAILED PICKLIST READ BLOCKS THE ACTION, it does not degrade it into an unattributed swap.
 * 6. 🔴 ONE BUNDLE SERVES BOTH "Replace Broker" AND "Select Broker" (2026-08-21). `@api
 *    isFirstAppointment` switches the heading, the confirm label, the empty state and the reason
 *    — and NOTHING else. (It switched the INTRO COPY too until the 2026-08-21 UAT prose removal
 *    deleted both mode notes; T-NO-PROSE now pins their absence in BOTH modes.) The `describe('first-appointment mode')` block at the
 *    bottom re-asserts the SAME Apex method and the SAME four parameter names, which is what makes
 *    "one mechanism, two entry points" a tested claim rather than a comment. Point 5's block is
 *    deliberately NOT inherited by that mode, and the reason is asserted there.
 *
 * ⚠ THE PICKLIST FIXTURE IS THE PLATFORM'S REAL PAYLOAD SHAPE, not a convenient one. `data.values`
 * entries carry `attributes` / `validFor` alongside `label` / `value`; the component passes the
 * array straight to lightning-combobox, so a fixture trimmed to `{label, value}` would quietly
 * stop proving that pass-through works on what LDS actually sends.
 */
import { createElement } from 'lwc';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';
import replaceSelectedBroker from '@salesforce/apex/BovController.replaceSelectedBroker';

jest.mock(
    '@salesforce/apex/BovController.replaceSelectedBroker',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const DISPOSITION_ID = 'a0D5g000000DispEAG';
const SUB_B = 'a0X010000000002';
const SUB_C = 'a0X010000000003';

/** getObjectInfo's only load-bearing member here: the master record type. */
const OBJECT_INFO = {
    apiName: 'BOV_Broker_Change__c',
    defaultRecordTypeId: '012000000000000AAA',
    fields: {}
};

const picklistValue = (v) => ({
    attributes: null,
    label: v,
    validFor: [],
    value: v
});

/**
 * ⚠ 'Deliberately Not In Source' is not a real picklist value and that is the point — it stands in
 * for a value an admin adds in Setup tomorrow. A hardcoded options array in the component could
 * never produce it, so any test asserting it reaches the combobox is a genuine falsifier for
 * "the options are sourced from LDS".
 */
const REASON_PAYLOAD = {
    controllerValues: {},
    defaultValue: null,
    url: '/services/data/v67.0/ui-api/object-info/BOV_Broker_Change__c/picklist-values/012000000000000AAA/Reason__c',
    values: [
        picklistValue('Performance Issue'),
        picklistValue('Better BOV Received'),
        picklistValue('Deliberately Not In Source')
    ]
};

const PROPS = {
    dispositionId: DISPOSITION_ID,
    currentBroker: 'Colliers International',
    backupOptions: [
        { label: 'JLL — $11.0M', value: SUB_B },
        { label: 'CBRE — $10.4M', value: SUB_C }
    ]
};

/** The service's own wording. Not re-authored anywhere in the client. */
const SERVER_MESSAGE =
    'JLL is now the selected broker. The previous broker approval was cleared, so a fresh broker approval is required before this disposition can leave BOV Outreach.';

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-bov-replace-broker-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    /**
     * Mounts and drives BOTH LDS wires to a loaded state, which is the state every test other than
     * the picklist-failure one assumes. Emits are UNFILTERED, so they broadcast regardless of
     * whether each wire's config has settled yet — a filtered emit here would silently reach nobody
     * before the first microtask.
     */
    function createComponent(props = PROPS) {
        const element = createElement('c-bov-replace-broker-modal', {
            is: BovReplaceBrokerModal
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        getObjectInfo.emit(OBJECT_INFO);
        getPicklistValues.emit(REASON_PAYLOAD);
        return element;
    }

    /** Mounts WITHOUT resolving the reason picklist — for the load-failure path. */
    function createComponentWithFailedReasons(props = PROPS) {
        const element = createElement('c-bov-replace-broker-modal', {
            is: BovReplaceBrokerModal
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        getObjectInfo.emit(OBJECT_INFO);
        getPicklistValues.error();
        return element;
    }

    /** Mounts in FIRST-APPOINTMENT mode, with both wires driven as usual. */
    function createAppointmentComponent(overrides = {}) {
        return createComponent({
            dispositionId: DISPOSITION_ID,
            backupOptions: PROPS.backupOptions,
            isFirstAppointment: true,
            ...overrides
        });
    }

    const radio = (el) => el.shadowRoot.querySelector('lightning-radio-group');
    const reasonBox = (el) => el.shadowRoot.querySelector('.brb-reason');
    const fixedReason = (el) => el.shadowRoot.querySelector('.brb-fixed-reason');
    const notesBox = (el) => el.shadowRoot.querySelector('.brb-notes');
    const confirmBtn = (el) => el.shadowRoot.querySelector('.brb-confirm');
    const cancelBtn = (el) => el.shadowRoot.querySelector('.brb-cancel');
    const header = (el) => el.shadowRoot.querySelector('lightning-modal-header');
    // ⚠ THE `note` HELPER WAS DELETED ON 2026-08-21 with `.brb-note` / `.brb-note_info` (UAT prose
    // removal). Do not reintroduce it as a convenience — a helper for a selector that must not
    // exist is an invitation to re-add the element. T-NO-PROSE asserts its absence instead.

    function chooseBackup(element, value) {
        radio(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        return Promise.resolve();
    }

    function chooseReason(element, value) {
        reasonBox(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        return Promise.resolve();
    }

    function typeNotes(element, value) {
        notesBox(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        return Promise.resolve();
    }

    /** The minimum a user must supply before Confirm enables. */
    async function fillRequiredFields(element, submissionId = SUB_B) {
        await chooseBackup(element, submissionId);
        await chooseReason(element, 'Performance Issue');
    }

    it('lists the caller-supplied backups verbatim', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(radio(element).options).toEqual(PROPS.backupOptions);
    });

    it('renders no "undefined" anywhere when the caller supplies no incumbent name', async () => {
        // ⚠ THIS TEST USED TO ALSO ASSERT THE INCUMBENT WAS NAMED ("Colliers
        // International", falling back to "the current broker"). Both halves were
        // DELETED on 2026-08-21 with `.brb-note`, not softened — the dialog no
        // longer names the incumbent at all, and `incumbentLabel` went with it.
        // What survives is the reason the fallback existed: a getter bound into
        // the DOM is written unconditionally, so an undefined renders as the
        // literal string "undefined". Still worth pinning for the bindings that
        // remain (`effectiveReason`, `emptyMessage`, `confirmLabel`).
        const element = createComponent({
            dispositionId: DISPOSITION_ID,
            backupOptions: PROPS.backupOptions
        });

        await Promise.resolve();

        // Guard the guard: the options branch genuinely rendered.
        expect(radio(element)).not.toBeNull();
        // Asserted on the RENDERED markup, not on a getter.
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // BOTH mode intro notes were removed at the user's request:
    //   .brb-note       "<incumbent> moves back to Backup and the broker you
    //                    choose becomes Selected. The broker approval is cleared
    //                    by this change."
    //   .brb-note_info  "The broker you choose becomes this sale's Selected
    //                    broker. They must still be approved before the sale can
    //                    proceed, and the appointment is recorded in the broker
    //                    change history."
    //
    // 🔴 WHAT THIS PIN MUST NOT BE READ AS. It does NOT say "this component may
    // not display consequential text". The SERVER'S returned warning — authored
    // by BovSubmissionService, carried out through close({ message }) — is
    // untouched and is asserted character-for-character elsewhere in this file.
    // The rule is: this component authors no prose of its own. It never rendered
    // the server string, and it still must not re-author it.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: no mode intro note in EITHER mode — the removal must not come back', async () => {
        const replacement = createComponent();
        const appointment = createAppointmentComponent();

        await Promise.resolve();

        [replacement, appointment].forEach((element) => {
            // Guard the guard: the options branch genuinely rendered in both modes.
            expect(radio(element).options.length).toBeGreaterThan(0);

            // 1. THE OLD SELECTORS.
            expect(element.shadowRoot.querySelector('.brb-note')).toBeNull();
            expect(element.shadowRoot.querySelector('.brb-note_info')).toBeNull();

            // 2. 🔴 THE RENDERED WORDS — a re-added note usually arrives under a
            //    new class name, so the selectors alone would stay green.
            const text = element.shadowRoot.textContent.toLowerCase();
            expect(text).not.toContain('moves back to backup');
            expect(text).not.toContain('approval is cleared by this change');
            expect(text).not.toContain('must still be approved');
            expect(text).not.toContain('the current broker');
        });
    });

    it('GATE: confirm needs BOTH a backup and a reason, and clicking it early calls no Apex', async () => {
        const element = createComponent();

        await Promise.resolve();
        expect(confirmBtn(element).disabled).toBe(true);
        confirmBtn(element).click();
        await flushPromises();
        expect(replaceSelectedBroker).not.toHaveBeenCalled();

        // A backup alone is NOT enough — the reason is half the gate, matching the server rule.
        await chooseBackup(element, SUB_B);
        expect(confirmBtn(element).disabled).toBe(true);
        confirmBtn(element).click();
        await flushPromises();
        expect(replaceSelectedBroker).not.toHaveBeenCalled();

        await chooseReason(element, 'Performance Issue');
        expect(confirmBtn(element).disabled).toBe(false);
    });

    it('GATE: a reason alone, with no backup chosen, also leaves confirm disabled', async () => {
        const element = createComponent();

        await chooseReason(element, 'Company Decision');

        expect(confirmBtn(element).disabled).toBe(true);
        confirmBtn(element).click();
        await flushPromises();
        expect(replaceSelectedBroker).not.toHaveBeenCalled();
    });

    it('REASONS: offers exactly what getPicklistValues emitted — including a value found NOWHERE in this repo', async () => {
        const element = createComponent();

        await Promise.resolve();

        // Pass-through, not re-mapped: the wire's own option shape IS lightning-combobox's.
        expect(reasonBox(element).options).toEqual(REASON_PAYLOAD.values);
        // 🔴 THE FALSIFIER for "the options are not hardcoded". No array authored in
        // bovReplaceBrokerModal.js could contain this value; it exists only in the wire payload.
        expect(
            reasonBox(element).options.map((o) => o.value)
        ).toContain('Deliberately Not In Source');
        expect(reasonBox(element).required).toBe(true);
        // No load error while the wire is healthy.
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('REASONS: a failed picklist read BLOCKS the replace and explains itself', async () => {
        const element = createComponentWithFailedReasons();

        await Promise.resolve();

        expect(reasonBox(element).options).toEqual([]);
        const banner = element.shadowRoot.querySelector('.lv-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toContain('could not be loaded');
        expect(banner.getAttribute('role')).toBe('alert');

        // 🔴 NOT DEGRADED INTO AN UNATTRIBUTED SWAP. Choosing a backup is still not enough, because
        // no reason can be chosen — and an unexplained broker change is the exact row the history
        // object exists to prevent.
        await chooseBackup(element, SUB_B);
        expect(confirmBtn(element).disabled).toBe(true);
        confirmBtn(element).click();
        await flushPromises();
        expect(replaceSelectedBroker).not.toHaveBeenCalled();
    });

    it('SUCCESS: calls Apex by NAME with reason and notes, and closes carrying the SERVER message unchanged', async () => {
        replaceSelectedBroker.mockResolvedValue(SERVER_MESSAGE);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await fillRequiredFields(element, SUB_B);
        await typeNotes(element, 'Missed two marketing deadlines.');
        confirmBtn(element).click();
        await flushPromises();

        expect(replaceSelectedBroker).toHaveBeenCalledTimes(1);
        // 🔴 ALL FOUR NAMES, VERBATIM. An imperative Apex call binds by NAME: a misspelt key does
        // not fail the build or throw — it arrives at Apex as a null, and `reason` arriving null is
        // a refusal the user cannot explain.
        expect(replaceSelectedBroker).toHaveBeenCalledWith({
            dispositionId: DISPOSITION_ID,
            newSubmissionId: SUB_B,
            reason: 'Performance Issue',
            notes: 'Missed two marketing deadlines.'
        });

        // 🔴 CHARACTER FOR CHARACTER. The "fresh approval is required" warning is the SERVER's
        // sentence; the client must not append to it, trim it or restate it.
        expect(closeHandler).toHaveBeenCalledTimes(1);
        expect(closeHandler.mock.calls[0][0].detail).toEqual({
            message: SERVER_MESSAGE
        });
    });

    it('FAILURE: shows the refusal inline, STAYS OPEN, does not close', async () => {
        replaceSelectedBroker.mockRejectedValue({
            body: {
                message:
                    'That submission already has a pending approval and cannot be promoted.'
            }
        });

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await fillRequiredFields(element, SUB_C);
        confirmBtn(element).click();
        await flushPromises();

        const banner = element.shadowRoot.querySelector('.lv-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toContain('pending approval');
        expect(banner.getAttribute('role')).toBe('alert');

        // Picking a different backup is a real remedy, so the form is still useful.
        expect(closeHandler).not.toHaveBeenCalled();
        expect(radio(element)).not.toBeNull();
    });

    it('FAILURE: falls back to a generic message when the error carries no body', async () => {
        replaceSelectedBroker.mockRejectedValue(new Error('network'));

        const element = createComponent();

        await fillRequiredFields(element, SUB_B);
        confirmBtn(element).click();
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.lv-error').textContent
        ).toContain('The selected broker could not be replaced.');
    });

    it('NOTES ARE OPTIONAL: an untouched textarea sends undefined, not an empty string', async () => {
        replaceSelectedBroker.mockResolvedValue(SERVER_MESSAGE);

        const element = createComponent();

        await fillRequiredFields(element, SUB_B);
        confirmBtn(element).click();
        await flushPromises();

        // Apex maps both undefined and '' to a null/blank String, so this is a claim about the
        // CLIENT: it must not invent a value for a field the user chose not to fill in.
        expect(replaceSelectedBroker).toHaveBeenCalledWith({
            dispositionId: DISPOSITION_ID,
            newSubmissionId: SUB_B,
            reason: 'Performance Issue',
            notes: undefined
        });
    });

    it('NO BACKUPS: explains, hides the confirm button entirely, calls no Apex', async () => {
        const element = createComponent({
            dispositionId: DISPOSITION_ID,
            currentBroker: 'Colliers International',
            backupOptions: []
        });

        await Promise.resolve();

        expect(radio(element)).toBeNull();
        // The reason and notes inputs live inside the same hasOptions branch — asking WHY a broker
        // was replaced makes no sense on a modal that cannot replace one.
        expect(reasonBox(element)).toBeNull();
        expect(notesBox(element)).toBeNull();
        expect(confirmBtn(element)).toBeNull();
        expect(element.shadowRoot.textContent).toContain(
            'no backup submissions to promote'
        );
        // Cancel is still the way out.
        expect(cancelBtn(element)).not.toBeNull();
    });

    it('CANCEL: closes with nothing and calls no Apex', async () => {
        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await Promise.resolve();
        cancelBtn(element).click();
        await flushPromises();

        expect(replaceSelectedBroker).not.toHaveBeenCalled();
        expect(closeHandler).toHaveBeenCalledTimes(1);
        // ⚠ `null`, not `undefined` — a STUB ARTEFACT (CustomEvent defaults an omitted `detail` to
        // null). The real LightningModal resolves `undefined`. Asserted as falsy so the test pins
        // the contract the caller relies on (`if (!result || !result.message) return;`).
        expect(closeHandler.mock.calls[0][0].detail).toBeFalsy();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // FIRST-APPOINTMENT MODE (@api isFirstAppointment, 2026-08-21)
    // ═════════════════════════════════════════════════════════════════════════
    //
    // 🔴 THE MODE CHANGES COPY AND THE REASON. IT DOES NOT CHANGE THE MECHANISM.
    // Every test below that reaches Apex asserts the SAME method with the SAME
    // four parameter names as the replacement tests above — because there is one
    // server path, and a second one would duplicate the exclusivity swap, the
    // approval revocation, the savepoint and the history writer.
    describe('first-appointment mode', () => {
        it('relabels the heading, the confirm button and the empty state', async () => {
            const element = createAppointmentComponent();

            await Promise.resolve();

            expect(header(element).label).toBe('Select Broker');
            expect(confirmBtn(element).label).toBe('Appoint broker');

            const empty = createAppointmentComponent({ backupOptions: [] });
            await Promise.resolve();
            // "No BACKUP submissions to promote" is wrong on a disposition that
            // has no broker at all — there is nothing to promote FROM.
            expect(empty.shadowRoot.textContent).toContain(
                'no broker responses on this disposition yet'
            );
            expect(empty.shadowRoot.textContent).not.toContain(
                'backup submissions to promote'
            );
        });

        // ⚠ THE TEST THAT USED TO SIT HERE — 'does NOT name an incumbent — there is
        // none, not even a generic one' — WAS DELETED ON 2026-08-21, not softened.
        // Every one of its assertions read `.brb-note`, which no longer exists in
        // EITHER mode after the UAT prose removal, so retargeting it would have
        // produced a test whose name claimed a mode difference that no longer
        // exists and which could never fail. The absence is now covered once, for
        // both modes, by T-NO-PROSE above.

        it('🔴 hides the reason combobox and DISCLOSES the value it will record', async () => {
            const element = createAppointmentComponent();

            await Promise.resolve();

            // Hidden, not disabled: a disabled combobox invites a click and
            // announces as a dead form field.
            expect(reasonBox(element)).toBeNull();
            // But the value is stated, so nothing is written to the append-only
            // history that the user was not shown.
            expect(fixedReason(element)).not.toBeNull();

            // 🔴 THE WHOLE RENDERED SENTENCE, NOT A SUBSTRING OF IT — and this is the
            // assertion, not a stylistic preference. The LWC template compiler DROPS
            // the trailing whitespace of a text node that ends a source line before an
            // inline element, so `…history as\n<strong>{effectiveReason}</strong>`
            // renders "…history asInitial Appointment". A `toContain('Initial
            // Appointment')` passes on BOTH the correct and the broken markup because
            // the substring stops short of the seam — which is exactly how that defect
            // survived in this repo before. Normalising runs of whitespace is safe here
            // and does NOT mask the bug: the dropped space is gone from the DOM before
            // any normalisation can see it, so a missing space stays missing.
            const disclosed = fixedReason(element)
                .textContent.replace(/\s+/g, ' ')
                .trim();
            expect(disclosed).toBe(
                'Recorded in the broker change history as Initial Appointment.'
            );
        });

        it('🔴 sends `Initial Appointment` as the reason, with the SAME four parameter names', async () => {
            replaceSelectedBroker.mockResolvedValue(
                'Broker appointed. The broker must be approved before the sale can proceed.'
            );

            const element = createAppointmentComponent();
            const closeHandler = jest.fn();
            element.addEventListener('close', closeHandler);

            // No reason is chosen — there is no control to choose one with. The
            // gate reduces to "pick a broker", which is the only choice this path
            // offers.
            await chooseBackup(element, SUB_B);
            expect(confirmBtn(element).disabled).toBe(false);
            confirmBtn(element).click();
            await flushPromises();

            expect(replaceSelectedBroker).toHaveBeenCalledWith({
                dispositionId: DISPOSITION_ID,
                newSubmissionId: SUB_B,
                reason: 'Initial Appointment',
                notes: undefined
            });
            expect(closeHandler).toHaveBeenCalledTimes(1);
        });

        it('GATE: with no broker chosen, confirm stays disabled and calls no Apex', async () => {
            const element = createAppointmentComponent();

            await Promise.resolve();

            expect(confirmBtn(element).disabled).toBe(true);
            confirmBtn(element).click();
            await flushPromises();
            expect(replaceSelectedBroker).not.toHaveBeenCalled();
        });

        it('🔴 a failed picklist read does NOT block an appointment (it DOES block a replacement)', async () => {
            const element = createComponentWithFailedReasons({
                dispositionId: DISPOSITION_ID,
                backupOptions: PROPS.backupOptions,
                isFirstAppointment: true
            });
            replaceSelectedBroker.mockResolvedValue('Broker appointed.');

            await Promise.resolve();

            // The block above exists to prevent an UNATTRIBUTED history row. On a
            // first appointment the attribution is fixed and known without reading
            // the picklist, so blocking here would refuse a safe action for a
            // reason that cannot occur on it. No banner, and the action proceeds.
            expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
            await chooseBackup(element, SUB_B);
            confirmBtn(element).click();
            await flushPromises();
            expect(replaceSelectedBroker).toHaveBeenCalledTimes(1);
            expect(
                replaceSelectedBroker.mock.calls[0][0].reason
            ).toBe('Initial Appointment');
        });

        it('🔴 passes the SERVER\'s appointment sentence back untouched', async () => {
            const APPOINTED =
                'Broker appointed. The broker must be approved before the sale can proceed.';
            replaceSelectedBroker.mockResolvedValue(APPOINTED);

            const element = createAppointmentComponent();
            const closeHandler = jest.fn();
            element.addEventListener('close', closeHandler);

            await chooseBackup(element, SUB_B);
            confirmBtn(element).click();
            await flushPromises();

            // CHARACTER FOR CHARACTER, exactly as on the replacement path. The
            // appoint-vs-replace wording is the SERVER's, decided from whether it
            // actually demoted anyone — a client copy would be deciding from the
            // same stale wire that chose the button.
            expect(closeHandler.mock.calls[0][0].detail).toEqual({
                message: APPOINTED
            });
        });

        it('🔴 surfaces the server\'s stale-mode refusal INLINE and stays open', async () => {
            // The reachable race: a colleague appoints a broker between this modal
            // opening and Confirm. The server refuses `Initial Appointment` when an
            // incumbent exists rather than logging a misattributed history row.
            replaceSelectedBroker.mockRejectedValue({
                body: {
                    message:
                        'This disposition already has a selected broker, so this is a replacement rather than a first appointment. Refresh the page and use Replace Broker, which records why the broker is changing.'
                }
            });

            const element = createAppointmentComponent();
            const closeHandler = jest.fn();
            element.addEventListener('close', closeHandler);

            await chooseBackup(element, SUB_B);
            confirmBtn(element).click();
            await flushPromises();

            const banner = element.shadowRoot.querySelector('.lv-error');
            expect(banner).not.toBeNull();
            expect(banner.textContent).toContain('Replace Broker');
            expect(banner.getAttribute('role')).toBe('alert');
            expect(closeHandler).not.toHaveBeenCalled();
        });

        it('falls back to an APPOINT-shaped generic message when the error has no body', async () => {
            replaceSelectedBroker.mockRejectedValue(new Error('network'));

            const element = createAppointmentComponent();

            await chooseBackup(element, SUB_B);
            confirmBtn(element).click();
            await flushPromises();

            // "could not be replaced" would send the reader looking for a broker
            // that never existed.
            expect(
                element.shadowRoot.querySelector('.lv-error').textContent
            ).toContain('The broker could not be appointed.');
        });

        it('an ABSENT isFirstAppointment prop reads as a REPLACEMENT, the safer default', async () => {
            // `=== true`, not truthiness: the matrix passes an explicit boolean, but
            // a caller that forgot the prop must not silently get appointment
            // semantics — that would send `Initial Appointment` on a replacement.
            const element = createComponent();

            await Promise.resolve();

            expect(header(element).label).toBe('Replace Selected Broker');
            expect(reasonBox(element)).not.toBeNull();
            expect(fixedReason(element)).toBeNull();
        });

        it('is accessible', async () => {
            const element = createAppointmentComponent();

            await Promise.resolve();

            await expect(element).toBeAccessible();
        });
    });
});
