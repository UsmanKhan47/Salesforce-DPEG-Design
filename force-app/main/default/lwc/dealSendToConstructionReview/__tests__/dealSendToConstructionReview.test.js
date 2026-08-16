/**
 * c-deal-send-to-construction-review — IMPERATIVE APEX (headless quick action).
 * ----------------------------------------------------------------------------
 * A headless Record Action whose @api invoke() runs the shared pre-flight in c/dealActionGuard
 * (permission check -> confirmation) and only then awaits:
 *   const message = await advanceTo({ recordId, target: 'Construction Review' });
 * On success it toasts the returned message and requests an LDS refresh via
 * getRecordNotifyChange; on failure it toasts the Apex error (or a fallback).
 *
 * Follows the imperative-Apex template (c-submit-for-approval): the imported
 * Apex method is a bare jest.fn driven with mockResolvedValue / mockRejectedValue,
 * and the observable output is the dispatched ShowToastEvent (empty template =
 * no DOM), captured with addEventListener. getRecordNotifyChange is auto-mocked
 * as a jest.fn by the sfdx-lwc-jest lightning/uiRecordApi stub.
 *
 * The suite uses the REAL c/dealActionGuard, so the guard's two dependencies are mocked here:
 * lightning/confirm (whose real stub THROWS on .open() by design) and the permission Apex (an
 * un-mocked Apex import resolves undefined, which the guard's `=== true` check reads as DENIED —
 * that would silently turn every happy-path test red).
 */
import { createElement } from 'lwc';
import DealSendToConstructionReview from 'c/dealSendToConstructionReview';
import advanceTo from '@salesforce/apex/StageAdvanceController.advanceTo';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasDealActionAccess from '@salesforce/apex/OpportunityActionPermissionController.hasDealActionAccess';

// Mock the imperative Apex method as a bare jest.fn resolving a Promise.
jest.mock(
    '@salesforce/apex/StageAdvanceController.advanceTo',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock('lightning/confirm', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock(
    '@salesforce/apex/OpportunityActionPermissionController.hasDealActionAccess',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = '0065g00000AbCdEAAV';
const NO_PERMISSION = "You don't have permission to perform this action.";

describe('c-deal-send-to-construction-review', () => {
    beforeEach(() => {
        // Default happy state: permitted and confirmed.
        hasDealActionAccess.mockResolvedValue(true);
        LightningConfirm.open.mockResolvedValue(true);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-deal-send-to-construction-review', {
            is: DealSendToConstructionReview
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // A macrotask, not a bare microtask: invoke() now awaits the guard (permission promise ->
    // confirm promise) before the Apex promise, so a single Promise.resolve() no longer drains the
    // whole chain reliably.
    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS BRANCH: advances to Construction Review and toasts the Apex message', async () => {
        advanceTo.mockResolvedValue('Deal moved to Construction Review.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(advanceTo).toHaveBeenCalledTimes(1);
        expect(advanceTo).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            target: 'Construction Review'
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe('Success');
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Deal moved to Construction Review.'
        );

        // Record refresh requested on success.
        expect(getRecordNotifyChange).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('ERROR BRANCH: surfaces the Apex error message and does NOT refresh the record', async () => {
        advanceTo.mockRejectedValue({
            body: { message: 'Only Retail deals go to Construction Review.' }
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
            'Only Retail deals go to Construction Review.'
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

    // ─────────────────────────────────────────────────────────────────────────
    // Guard path (permission -> confirm -> act)
    // ─────────────────────────────────────────────────────────────────────────

    it('CONFIRM: asks the Construction Review question before calling Apex', async () => {
        advanceTo.mockResolvedValue('ok');

        const element = createComponent();

        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        // Asserting the exact wording is what pins the UX copy — the only place it is verified.
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Send this deal to Construction Review?',
            label: 'Send to Construction Review',
            theme: 'info',
            variant: 'header'
        });
    });

    it('CANCELLED: a declined confirmation calls no Apex and toasts nothing', async () => {
        LightningConfirm.open.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(advanceTo).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
        // Cancelling is not an error — the user already knows what they did.
        expect(toastHandler).not.toHaveBeenCalled();
    });

    it('NO PERMISSION: toasts the denial, never confirms, never calls Apex', async () => {
        hasDealActionAccess.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        // Permission FIRST: an unauthorized user is never asked to confirm.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(advanceTo).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(NO_PERMISSION);
    });

    it('PERMISSION CHECK FAILS: fails closed — surfaces the real message and calls no Apex', async () => {
        hasDealActionAccess.mockRejectedValue({
            body: { message: 'Unable to verify your permissions.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(advanceTo).not.toHaveBeenCalled();
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Unable to verify your permissions.'
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
