/**
 * IMPERATIVE APEX pattern (mirrors c-advance-record-stage).
 * c-disposition-submit-for-approval is a headless quick action whose @api invoke() runs the shared
 * pre-flight in c/recordStageGuard (PER-RECORD permission check -> confirmation) and only then
 * awaits
 *   const message = await submitForApproval({ dispositionId: this.recordId });
 * before either toasting success + notifying the record, or toasting the error.
 *
 * The suite uses the REAL c/recordStageGuard (it does NOT mock the util), so the guard's two
 * dependencies are mocked here instead:
 *   - lightning/confirm — its real sfdx-lwc-jest stub THROWS on .open() by design.
 *   - RecordStageAdvanceController.hasStageActionAccess — an un-mocked `@salesforce/apex/...`
 *     import is rewritten by the transformer to a fn resolving `undefined`, which the guard's
 *     `=== true` check correctly reads as DENIED; that would silently turn every happy-path test
 *     red for the wrong reason.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE THREE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. getRecordNotifyChange. The submission is imperative Apex, so the DML happens behind LDS's
 *    back. Without it the Path AND the Dynamic Actions visibility rules keep evaluating the OLD
 *    field values — and since those rules are what show and hide these very buttons, the button the
 *    user just pressed stays on screen. Both halves are pinned: called on success, NOT called on
 *    any failure or refusal path.
 * 2. The Apex parameter is `dispositionId`, NOT `recordId`. An imperative call binds by NAME; a
 *    mismatch is not a compile error on either side, it simply arrives null at the server. This is
 *    the assertion that catches a copy-paste from c/advanceRecordStage, whose Apex DOES take
 *    `recordId`.
 * 3. The permission gate is c/recordStageGuard, whose question is PER-RECORD — proved by asserting
 *    `hasStageActionAccess` receives the recordId. c/dealActionGuard's `hasDealActionAccess()`
 *    takes NO argument and resolves the OPPORTUNITY controller at module scope, so it structurally
 *    cannot ask a Disposition's question. Swapping the guards would compile and pass a naive suite.
 */
import { createElement } from 'lwc';
import DispositionSubmitForApproval from 'c/dispositionSubmitForApproval';
import submitForApproval from '@salesforce/apex/DispositionApprovalController.submitForApproval';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasStageActionAccess from '@salesforce/apex/RecordStageAdvanceController.hasStageActionAccess';

jest.mock(
    '@salesforce/apex/DispositionApprovalController.submitForApproval',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock('lightning/confirm', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock(
    '@salesforce/apex/RecordStageAdvanceController.hasStageActionAccess',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0D5g000000DispEAG';
const NO_PERMISSION = "You don't have permission to perform this action.";

describe('c-disposition-submit-for-approval', () => {
    beforeEach(() => {
        // Default happy state: permitted and confirmed.
        hasStageActionAccess.mockResolvedValue(true);
        LightningConfirm.open.mockResolvedValue(true);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-submit-for-approval', {
            is: DispositionSubmitForApproval
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS BRANCH: calls Apex with dispositionId, toasts success, notifies the record', async () => {
        submitForApproval.mockResolvedValue(
            'Submitted for the Sale Decision approval.'
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(submitForApproval).toHaveBeenCalledTimes(1);
        // 🔴 `dispositionId`, NOT `recordId` — an imperative Apex call binds by NAME.
        expect(submitForApproval).toHaveBeenCalledWith({
            dispositionId: RECORD_ID
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Submitted for the Sale Decision approval.'
        );

        // 🔴 MANDATORY. Apex DML bypasses the LDS cache; without this both the Path and the
        // Dynamic Actions rules that render this button keep showing the pre-submission state.
        expect(getRecordNotifyChange).toHaveBeenCalledTimes(1);
        expect(getRecordNotifyChange).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('SUCCESS: the toast carries the SERVER message — one bundle backs four different approvals', async () => {
        // The four Submit quick actions all point here and the service derives the target from
        // stage + record type, so the only component that knows what was submitted is the server.
        submitForApproval.mockResolvedValue(
            'Colliers International was submitted for broker approval.'
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Colliers International was submitted for broker approval.'
        );
    });

    it('ERROR BRANCH: surfaces the authored Apex refusal VERBATIM and does not notify', async () => {
        // The wire-verification pre-check exists precisely so the user sees THIS instead of the
        // platform's useless "no applicable approval process was found".
        submitForApproval.mockRejectedValue({
            body: {
                message:
                    'Wire verification must be complete before the closing approval can be submitted.'
            }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.variant).toBe('error');
        expect(toast.title).toBe('Cannot submit for approval');
        expect(toast.message).toBe(
            'Wire verification must be complete before the closing approval can be submitted.'
        );
        // Sticky: a refusal that names a precondition is something the user has to act on.
        expect(toast.mode).toBe('sticky');

        // Nothing was written, so LDS must not be told the record changed.
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: falls back to a generic message when the error carries no body', async () => {
        submitForApproval.mockRejectedValue(new Error('network'));

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'This disposition could not be submitted for approval.'
        );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Guard path (permission -> confirm -> act)
    // ─────────────────────────────────────────────────────────────────────────

    it('CONFIRM: asks a GENERIC submit question, warning-themed, before calling Apex', async () => {
        submitForApproval.mockResolvedValue('ok');

        const element = createComponent();

        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        // Pins the deliberately generic wording. One bundle backs FOUR Submit actions targeting
        // three different approval processes on two different objects, and the target is derived
        // server-side — so the prompt cannot name it. "Improving" this to name an approval means
        // copying the service's stage+record-type derivation table into JS, where nothing links it
        // to the Apex and it drifts the first time a stage is inserted.
        //
        // theme 'warning', not 'info': a submission creates a pending approval instance, notifies
        // the approver, LOCKS the record (recordEditability = AdminOnly) and cannot simply be
        // repeated. It must not look like a routine forward hop.
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Submit this disposition for approval?',
            label: 'Submit for Approval',
            theme: 'warning',
            variant: 'header'
        });
    });

    it('PERMISSION: the check is PER-RECORD and runs BEFORE the confirmation', async () => {
        submitForApproval.mockResolvedValue('ok');
        const callOrder = [];
        hasStageActionAccess.mockImplementation(() => {
            callOrder.push('permission');
            return Promise.resolve(true);
        });
        LightningConfirm.open.mockImplementation(() => {
            callOrder.push('confirm');
            return Promise.resolve(true);
        });

        const element = createComponent();

        await element.invoke();
        await flushPromises();

        expect(callOrder).toEqual(['permission', 'confirm']);
        // 🔴 THE recordId REACHING THE GATE IS THE WHOLE REASON c/recordStageGuard IS USED HERE
        // RATHER THAN c/dealActionGuard: the server dispatches on Id.getSObjectType() and resolves
        // Disposition__c to the DISPOSITION_DRIVER gate. dealActionGuard's hasDealActionAccess()
        // takes NO argument and could only ever ask the Opportunity's question.
        expect(hasStageActionAccess).toHaveBeenCalledWith({
            recordId: RECORD_ID
        });
    });

    it('CANCELLED: a declined confirmation calls no Apex and toasts nothing', async () => {
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

    it('NO PERMISSION: toasts the denial, never confirms, never calls Apex', async () => {
        hasStageActionAccess.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(submitForApproval).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(NO_PERMISSION);
    });

    it('PERMISSION CHECK FAILS: fails closed — surfaces the real message and calls no Apex', async () => {
        // A FAULT must not be disguised as a denial, but it must still refuse.
        hasStageActionAccess.mockRejectedValue({
            body: { message: 'Unable to verify your permissions.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(submitForApproval).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Unable to verify your permissions.'
        );
    });

    it('is accessible', async () => {
        submitForApproval.mockResolvedValue('ok');

        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
