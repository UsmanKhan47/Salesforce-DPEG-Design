/**
 * c-deal-send-to-development-review — IMPERATIVE APEX (headless quick action).
 * ---------------------------------------------------------------------------
 * A headless Record Action whose @api invoke() awaits:
 *   const message = await advanceTo({ recordId, target: 'Development Review' });
 * On success it toasts the returned message and requests an LDS refresh via
 * getRecordNotifyChange; on failure it toasts the Apex error (or a fallback).
 *
 * Follows the imperative-Apex template (c-submit-for-approval): the imported
 * Apex method is a bare jest.fn driven with mockResolvedValue / mockRejectedValue,
 * and the observable output is the dispatched ShowToastEvent (empty template =
 * no DOM), captured with addEventListener. getRecordNotifyChange is auto-mocked
 * as a jest.fn by the sfdx-lwc-jest lightning/uiRecordApi stub.
 */
import { createElement } from 'lwc';
import DealSendToDevelopmentReview from 'c/dealSendToDevelopmentReview';
import advanceTo from '@salesforce/apex/StageAdvanceController.advanceTo';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';

// Mock the imperative Apex method as a bare jest.fn resolving a Promise.
jest.mock(
    '@salesforce/apex/StageAdvanceController.advanceTo',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = '0065g00000AbCdEAAV';

describe('c-deal-send-to-development-review', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-deal-send-to-development-review', {
            is: DealSendToDevelopmentReview
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // Flush the microtask queue so the awaited Apex promise settles.
    function flushPromises() {
        return Promise.resolve();
    }

    it('SUCCESS BRANCH: advances to Development Review and toasts the Apex message', async () => {
        advanceTo.mockResolvedValue('Deal moved to Development Review.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(advanceTo).toHaveBeenCalledTimes(1);
        expect(advanceTo).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            target: 'Development Review'
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe('Success');
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Deal moved to Development Review.'
        );

        // Record refresh requested on success.
        expect(getRecordNotifyChange).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('ERROR BRANCH: surfaces the Apex error message and does NOT refresh the record', async () => {
        advanceTo.mockRejectedValue({
            body: { message: 'Only Land deals go to Development Review.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Cannot advance the deal'
        );
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Only Land deals go to Development Review.'
        );

        // No record refresh on the failure path.
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('ERROR FALLBACK: uses the generic message when the error carries no body', async () => {
        advanceTo.mockRejectedValue(new Error('network'));

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The deal could not be advanced.'
        );
    });

    it('is accessible', async () => {
        advanceTo.mockResolvedValue('ok');

        const element = createComponent();

        await Promise.resolve();

        // Headless action: an empty shadow root is trivially accessible, but the
        // assertion is kept so every suite proves the sa11y matcher is wired.
        await expect(element).toBeAccessible();
    });
});
