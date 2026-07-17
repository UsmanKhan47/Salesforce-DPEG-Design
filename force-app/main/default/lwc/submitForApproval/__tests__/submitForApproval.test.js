/**
 * WIRE-MOCK TEMPLATE 2 of 3 — IMPERATIVE APEX
 * -------------------------------------------
 * Copy this shape for any component that CALLS an Apex method imperatively
 * (from a handler / connectedCallback / @api invoke) rather than via @wire.
 *
 * Demonstrated here on c-submit-for-approval, a headless Record Action quick
 * action whose @api invoke() awaits:
 *   const message = await submitForApproval({ recordId: this.recordId });
 *
 * KEY TECHNIQUE — mock the imported Apex method as a plain `jest.fn()` and drive
 * each branch with a resolved / rejected Promise:
 *   - `submitForApproval.mockResolvedValue('...')`      -> success branch
 *   - `submitForApproval.mockRejectedValue({ body })`   -> error branch
 * Then `await` the imperative call (via the flushed microtask queue) before
 * asserting. Assert the call args (`toHaveBeenCalledWith`) and the *observable
 * side effects*. This component is headless (empty template), so its observable
 * output is the dispatched ShowToastEvent, not DOM — captured with
 * addEventListener. A component that renders after an imperative call would
 * additionally assert on element.shadowRoot here (same await, then query).
 *
 * getRecordNotifyChange (from lightning/uiRecordApi) is auto-mocked as a jest.fn
 * by the sfdx-lwc-jest lightning stub, so it is safe to call in the success path.
 *
 * Conventions inherited from the canonical c-stat-card template:
 *   createElement -> Object.assign props -> appendChild; afterEach clears the
 *   DOM + jest.clearAllMocks().
 */
import { createElement } from 'lwc';
import SubmitForApproval from 'c/submitForApproval';
import submitForApproval from '@salesforce/apex/OpportunityApprovalController.submitForApproval';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';

// Mock the imperative Apex method as a bare jest.fn resolving a Promise.
jest.mock(
    '@salesforce/apex/OpportunityApprovalController.submitForApproval',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = '0065g00000AbCdEAAV';

describe('c-submit-for-approval', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-submit-for-approval', {
            is: SubmitForApproval
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // Flush the microtask queue so the awaited Apex promise + its .then chain settle.
    function flushPromises() {
        return Promise.resolve();
    }

    it('SUCCESS BRANCH: calls Apex with the recordId and toasts success', async () => {
        submitForApproval.mockResolvedValue('Submitted to Regional VP.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(submitForApproval).toHaveBeenCalledTimes(1);
        expect(submitForApproval).toHaveBeenCalledWith({ recordId: RECORD_ID });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Submitted to Regional VP.'
        );

        // Record refresh requested on success.
        expect(getRecordNotifyChange).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('ERROR BRANCH: surfaces the Apex error message in an error toast', async () => {
        submitForApproval.mockRejectedValue({
            body: { message: 'Deal is not in an approvable stage.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Deal is not in an approvable stage.'
        );

        // No record refresh on the failure path.
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('is accessible', async () => {
        submitForApproval.mockResolvedValue('ok');

        const element = createComponent();

        await Promise.resolve();

        // Headless action: an empty shadow root is trivially accessible, but the
        // assertion is kept so every suite proves the sa11y matcher is wired.
        await expect(element).toBeAccessible();
    });
});
