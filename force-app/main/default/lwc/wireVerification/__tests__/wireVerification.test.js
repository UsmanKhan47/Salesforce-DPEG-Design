/**
 * c-wire-verification — @wire-to-Apex READ + IMPERATIVE Apex WRITE in one suite.
 * Combines wire-mock template 1 (Apex @wire) and template 2 (imperative Apex):
 *   - @wire(getWire, { dispositionId: '$recordId' })  -> WireController.getWire
 *   - handleSave() -> saveWire({...}).then(() => refreshApex(this._wired))
 *
 * getWire is registered as an Apex test wire adapter (createApexTestWireAdapter)
 * so the fixture is pushed with getWire.emit(...) / getWire.error(). saveWire is a
 * plain jest.fn resolving a Promise; assert its call args + observable DOM.
 *
 * refreshApex (from '@salesforce/apex') is left to the toolchain — the LWC jest
 * transformer rewrites it to a resolved-Promise stub, so the .then() chain settles
 * without a throw. It is not asserted here (not a jest.fn under that transform).
 *
 * The Verified Date/Time label runs `new Date(...)` math, which drifts by timezone,
 * so date-derived text is only asserted in the empty state (the deterministic
 * "Waiting…" fallback); the data branch asserts the timezone-stable field values.
 *
 * REAL fields the WireController wrapper surfaces: verbalVerificationCompleted,
 * verifierName, verifierPhone, wireInstructionsSource, confirmedWireAmount,
 * fieldsComplete, verifiedDateTime (and id).
 */
import { createElement } from 'lwc';
import WireVerification from 'c/wireVerification';
import getWire from '@salesforce/apex/WireController.getWire';
import saveWire from '@salesforce/apex/WireController.saveWire';

jest.mock(
    '@salesforce/apex/WireController.getWire',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/WireController.saveWire',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0D5g00000WireAEAV';

const WIRE = {
    id: 'a0E5g00000Wrec1AAF',
    verbalVerificationCompleted: true,
    verifierName: 'Jane Doe',
    verifierPhone: '555-0100',
    wireInstructionsSource: 'Title Company',
    confirmedWireAmount: 4500000,
    fieldsComplete: 6,
    verifiedDateTime: '2026-05-08T15:30:00.000Z'
};

describe('c-wire-verification', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-wire-verification', {
            is: WireVerification
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function flushPromises() {
        return Promise.resolve();
    }

    it('shows the 0/6 empty state until the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const badge = element.shadowRoot.querySelector('.progress-badge');
        expect(badge.textContent).toBe('0/6 fields complete');
        // Amber (incomplete) tone, not the green complete tone.
        expect(badge.getAttribute('style')).toContain('#fef3c7');

        // Field 3 (read-only Verified Date/Time) shows its deterministic fallback.
        expect(
            element.shadowRoot.querySelector('.readonly-val').textContent
        ).toBe('Waiting for field 1 checkbox…');

        expect(element.shadowRoot.querySelector('.save-btn').textContent.trim()).toBe(
            'Save'
        );
    });

    it('DATA BRANCH: hydrates the six fields + green complete badge from the wire', async () => {
        const element = createComponent();

        getWire.emit(WIRE);
        await Promise.resolve();

        const badge = element.shadowRoot.querySelector('.progress-badge');
        expect(badge.textContent).toBe('6/6 fields complete');
        // fieldsComplete === 6 -> green complete tone.
        expect(badge.getAttribute('style')).toContain('#e6f4ea');

        const inputs = element.shadowRoot.querySelectorAll('lightning-input');
        // Fields 1,2,4,5 are text/number inputs; field 6 is the checkbox.
        expect(inputs[0].value).toBe('Jane Doe'); //   Verifier Name
        expect(inputs[1].value).toBe('555-0100'); //   Verifier Phone
        expect(inputs[2].value).toBe('Title Company'); // Wire Instructions Source
        expect(inputs[3].value).toBe(4500000); //      Confirmed Wire Amount
        expect(inputs[4].checked).toBe(true); //       Verbal Verification Completed
    });

    it('SAVE BRANCH: calls saveWire with the hydrated field values on click', async () => {
        saveWire.mockResolvedValue({});

        const element = createComponent();
        getWire.emit(WIRE);
        await Promise.resolve();

        element.shadowRoot.querySelector('.save-btn').click();
        // Drain all microtasks (saveWire -> .then(refreshApex) -> .finally) + the
        // subsequent re-render via a macrotask tick.
        await new Promise((resolve) => setTimeout(resolve, 0));

        expect(saveWire).toHaveBeenCalledTimes(1);
        expect(saveWire).toHaveBeenCalledWith({
            dispositionId: RECORD_ID,
            wireId: WIRE.id,
            verbalDone: true,
            verifierName: 'Jane Doe',
            verifierPhone: '555-0100',
            wireSource: 'Title Company',
            confirmedAmount: 4500000
        });

        // isSaving toggled back off in .finally() -> button label reset to "Save".
        expect(element.shadowRoot.querySelector('.save-btn').textContent.trim()).toBe(
            'Save'
        );
    });

    it('SAVE BRANCH: brand-new record saves with wireId=null and null blanks', async () => {
        saveWire.mockResolvedValue({});

        const element = createComponent();
        // No wire emit -> _wireData is undefined, form fields stay at their defaults.
        await Promise.resolve();

        element.shadowRoot.querySelector('.save-btn').click();
        await flushPromises();
        await flushPromises();

        expect(saveWire).toHaveBeenCalledWith({
            dispositionId: RECORD_ID,
            wireId: null,
            verbalDone: false,
            verifierName: null,
            verifierPhone: null,
            wireSource: null,
            confirmedAmount: null
        });
    });

    it('ERROR BRANCH: falls back to the empty 0/6 state + shows an inline error when the wire errors', async () => {
        const element = createComponent();

        getWire.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.progress-badge').textContent
        ).toBe('0/6 fields complete');
        expect(
            element.shadowRoot.querySelector('.readonly-val').textContent
        ).toBe('Waiting for field 1 checkbox…');
        // Inline read-error banner surfaces the failure instead of a silent blank.
        expect(element.shadowRoot.querySelector('.wire-error')).not.toBeNull();
    });

    it('SAVE FAILURE: toasts a sticky error and re-enables the Save button on reject', async () => {
        saveWire.mockRejectedValue({
            body: { message: 'Wire verification could not be saved.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getWire.emit(WIRE);
        await Promise.resolve();

        element.shadowRoot.querySelector('.save-btn').click();
        // Drain saveWire -> .catch (toast) -> .finally (isSaving=false) + re-render.
        await new Promise((resolve) => setTimeout(resolve, 0));

        expect(saveWire).toHaveBeenCalledTimes(1);
        // The anti-fraud save failed loudly — an error toast was raised.
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.mode).toBe('sticky');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Wire verification could not be saved.'
        );
        // Button is re-enabled (label reset) so the user can retry — the form stays open.
        expect(element.shadowRoot.querySelector('.save-btn').textContent.trim()).toBe(
            'Save'
        );
        expect(element.shadowRoot.querySelector('.save-btn').disabled).toBe(false);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getWire.emit(WIRE);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
