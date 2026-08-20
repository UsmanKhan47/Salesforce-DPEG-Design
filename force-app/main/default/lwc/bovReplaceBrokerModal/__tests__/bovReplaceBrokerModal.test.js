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
 *    `newSubmissionId` verbatim — an imperative call binds by NAME.
 */
import { createElement } from 'lwc';
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

    function createComponent(props = PROPS) {
        const element = createElement('c-bov-replace-broker-modal', {
            is: BovReplaceBrokerModal
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const radio = (el) => el.shadowRoot.querySelector('lightning-radio-group');
    const confirmBtn = (el) => el.shadowRoot.querySelector('.brb-confirm');
    const cancelBtn = (el) => el.shadowRoot.querySelector('.brb-cancel');

    function chooseBackup(element, value) {
        radio(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        return Promise.resolve();
    }

    it('lists the caller-supplied backups verbatim and names the incumbent', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(radio(element).options).toEqual(PROPS.backupOptions);
        expect(element.shadowRoot.querySelector('.brb-note').textContent).toContain(
            'Colliers International'
        );
    });

    it('names a generic incumbent — NOT "undefined" — when the caller supplies none', async () => {
        const element = createComponent({
            dispositionId: DISPOSITION_ID,
            backupOptions: PROPS.backupOptions
        });

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.brb-note').textContent).toContain(
            'the current broker'
        );
        // Asserted on the RENDERED markup, not on the getter.
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    it('GATE: confirm is disabled until a backup is chosen, and clicking it calls no Apex', async () => {
        const element = createComponent();

        await Promise.resolve();
        expect(confirmBtn(element).disabled).toBe(true);
        confirmBtn(element).click();
        await flushPromises();
        expect(replaceSelectedBroker).not.toHaveBeenCalled();

        await chooseBackup(element, SUB_B);
        expect(confirmBtn(element).disabled).toBe(false);
    });

    it('SUCCESS: calls Apex by NAME and closes carrying the SERVER message unchanged', async () => {
        replaceSelectedBroker.mockResolvedValue(SERVER_MESSAGE);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await chooseBackup(element, SUB_B);
        confirmBtn(element).click();
        await flushPromises();

        expect(replaceSelectedBroker).toHaveBeenCalledTimes(1);
        expect(replaceSelectedBroker).toHaveBeenCalledWith({
            dispositionId: DISPOSITION_ID,
            newSubmissionId: SUB_B
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

        await chooseBackup(element, SUB_C);
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

        await chooseBackup(element, SUB_B);
        confirmBtn(element).click();
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.lv-error').textContent
        ).toContain('The selected broker could not be replaced.');
    });

    it('NO BACKUPS: explains, hides the confirm button entirely, calls no Apex', async () => {
        const element = createComponent({
            dispositionId: DISPOSITION_ID,
            currentBroker: 'Colliers International',
            backupOptions: []
        });

        await Promise.resolve();

        expect(radio(element)).toBeNull();
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
});
