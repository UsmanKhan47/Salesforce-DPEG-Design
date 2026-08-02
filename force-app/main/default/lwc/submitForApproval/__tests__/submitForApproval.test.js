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
 * SECOND KEY TECHNIQUE — GUARDED ACTIONS. This component's invoke() now runs the shared pre-flight
 * in c/dealActionGuard (permission check -> LightningConfirm) before its Apex call. The suite uses
 * the REAL util rather than mocking it, so it asserts the true dialog shape; that means the util's
 * OWN two dependencies must be mocked here. Both are easy to get wrong:
 *   1. `lightning/confirm` — the real sfdx-lwc-jest stub implements `open()` as
 *      `throw new Error('The LightningConfirm documentation contains examples for mocking .open in
 *      Jest')`. It MUST be module-mocked (an instance spy is not enough). No `{ virtual: true }` —
 *      the real stub resolves, so the module exists.
 *   2. the permission Apex — an UN-mocked `@salesforce/apex/...` import is rewritten by the jest
 *      transformer into a fn returning `Promise.resolve()`, i.e. `undefined`, which the guard's
 *      `=== true` check correctly reads as DENIED. Forget this and every happy-path test in the
 *      suite goes red for a reason that looks nothing like the cause.
 * Reset both to their permitted/confirmed state in `beforeEach` so happy-path tests are unaffected,
 * and override per-test for the denied / cancelled / check-failed branches.
 *
 * Conventions inherited from the canonical c-stat-card template:
 *   createElement -> Object.assign props -> appendChild; afterEach clears the
 *   DOM + jest.clearAllMocks().
 */
import { createElement } from 'lwc';
import SubmitForApproval from 'c/submitForApproval';
import submitForApproval from '@salesforce/apex/OpportunityApprovalController.submitForApproval';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasDealActionAccess from '@salesforce/apex/OpportunityActionPermissionController.hasDealActionAccess';

// Mock the imperative Apex method as a bare jest.fn resolving a Promise.
jest.mock(
    '@salesforce/apex/OpportunityApprovalController.submitForApproval',
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

describe('c-submit-for-approval', () => {
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
        const element = createElement('c-submit-for-approval', {
            is: SubmitForApproval
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // A macrotask, not a bare microtask: invoke() now awaits the guard (permission promise ->
    // confirm promise) before the Apex promise, so a single Promise.resolve() no longer drains the
    // whole chain reliably.
    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

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

    // ─────────────────────────────────────────────────────────────────────────
    // Guard path (permission -> confirm -> act)
    // ─────────────────────────────────────────────────────────────────────────

    it('CONFIRM: asks the approval question with a WARNING theme before calling Apex', async () => {
        submitForApproval.mockResolvedValue('ok');

        const element = createComponent();

        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        // theme 'warning', unlike the stage advances' 'info': this creates a pending approval,
        // notifies the approver, and cannot simply be repeated (a second submit while pending is
        // refused). The theme difference is intentional and is pinned here.
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Submit this deal for principal approval?',
            label: 'Submit for Approval',
            theme: 'warning',
            variant: 'header'
        });
    });

    it('CANCELLED: a declined confirmation submits nothing and toasts nothing', async () => {
        LightningConfirm.open.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(submitForApproval).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
        // Cancelling is not an error — the user already knows what they did.
        expect(toastHandler).not.toHaveBeenCalled();
    });

    it('NO PERMISSION: toasts the denial, never confirms, never submits', async () => {
        hasDealActionAccess.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        // Permission FIRST: an unauthorized user is never asked to confirm.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(submitForApproval).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(NO_PERMISSION);
    });

    it('PERMISSION CHECK FAILS: fails closed — surfaces the real message and never submits', async () => {
        hasDealActionAccess.mockRejectedValue({
            body: { message: 'Unable to verify your permissions.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(submitForApproval).not.toHaveBeenCalled();
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Unable to verify your permissions.'
        );
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
