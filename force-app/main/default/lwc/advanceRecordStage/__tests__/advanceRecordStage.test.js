/**
 * IMPERATIVE APEX pattern (mirrors c-advance-deal-stage).
 * c-advance-record-stage is a headless quick action whose @api invoke() runs the shared pre-flight
 * in c/recordStageGuard (PER-RECORD permission check -> confirmation) and only then awaits
 *   const message = await advance({ recordId: this.recordId });
 * before either toasting success + notifying the record, or toasting the error.
 * Drive each branch with mockResolvedValue / mockRejectedValue and assert the dispatched
 * ShowToastEvent + getRecordNotifyChange side effects.
 *
 * The suite uses the REAL c/recordStageGuard (it does NOT mock the util), so the guard's two
 * dependencies must be mocked here instead:
 *   - lightning/confirm — its real sfdx-lwc-jest stub THROWS on .open() by design, so the module is
 *     replaced with a jest.fn. Reset to resolve(true) in beforeEach so the happy-path tests pass.
 *   - the permission Apex — an un-mocked `@salesforce/apex/...` import is rewritten by the
 *     transformer to a fn resolving undefined, which the guard's `=== true` check correctly reads as
 *     DENIED; that would silently turn every happy-path test red.
 *
 * 🔴 THE LOAD-BEARING ASSERTION IN THIS SUITE IS getRecordNotifyChange. The stage write is
 * imperative Apex, so the DML happens behind LDS's back and the Path would keep showing the OLD
 * stage without it — the exact symptom this feature exists to fix. Both halves are pinned: it IS
 * called on success, and it is NOT called on failure.
 *
 * flushPromises is a MACROTASK, not a bare microtask: invoke() awaits the guard (permission promise
 * -> confirm promise) before the Apex promise, so a single Promise.resolve() does not reliably drain
 * the chain.
 */
import { createElement } from 'lwc';
import AdvanceRecordStage from 'c/advanceRecordStage';
import advance from '@salesforce/apex/RecordStageAdvanceController.advance';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasStageActionAccess from '@salesforce/apex/RecordStageAdvanceController.hasStageActionAccess';

jest.mock(
    '@salesforce/apex/RecordStageAdvanceController.advance',
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

const RECORD_ID = 'a0X5g00000AbCdEEAV';
const NO_PERMISSION = "You don't have permission to perform this action.";

describe('c-advance-record-stage', () => {
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
        const element = createElement('c-advance-record-stage', {
            is: AdvanceRecordStage
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS BRANCH: calls Apex with the recordId, toasts success, notifies the record', async () => {
        advance.mockResolvedValue('LOI moved to Sent.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(advance).toHaveBeenCalledTimes(1);
        expect(advance).toHaveBeenCalledWith({ recordId: RECORD_ID });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'LOI moved to Sent.'
        );

        // 🔴 MANDATORY. Apex DML bypasses the LDS cache; without this the Path shows a stale stage.
        expect(getRecordNotifyChange).toHaveBeenCalledTimes(1);
        expect(getRecordNotifyChange).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('ERROR BRANCH: surfaces the Apex message in an error toast, no record notify', async () => {
        // The controller surfaces a validation rule's own text verbatim — that is the whole reason
        // this write goes through Apex rather than LDS updateRecord.
        advance.mockRejectedValue({
            body: { message: 'A signed NDA is required before this stage.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Cannot advance the stage'
        );
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'A signed NDA is required before this stage.'
        );

        // A failed write must NOT notify: telling LDS the record changed when it did not would
        // refresh the Path back to the same stage and read as "the button did nothing".
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: falls back to a generic message when the error carries no body', async () => {
        advance.mockRejectedValue(new Error('network'));

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The stage could not be advanced.'
        );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Guard path (permission -> confirm -> act)
    // ─────────────────────────────────────────────────────────────────────────

    it('CONFIRM: asks a GENERIC advance question before calling Apex', async () => {
        advance.mockResolvedValue('ok');

        const element = createComponent();

        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        // Pins the deliberately generic wording. This ONE bundle backs FIVE actions on FIVE objects
        // and the target stage is derived server-side in RecordStageAdvanceService, so the prompt
        // cannot name it. If someone "improves" this to name a stage, they have duplicated five
        // Apex maps in JS.
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Advance this record to the next stage?',
            label: 'Advance Stage',
            theme: 'info',
            variant: 'header'
        });
    });

    it('PERMISSION: the check is PER-RECORD and runs BEFORE the confirmation', async () => {
        advance.mockResolvedValue('ok');
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
        // The server dispatches to the object's own gate, so the recordId must reach it.
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

        expect(advance).not.toHaveBeenCalled();
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
        expect(advance).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(NO_PERMISSION);
    });

    it('PERMISSION CHECK FAILS: fails closed — surfaces the real message and calls no Apex', async () => {
        hasStageActionAccess.mockRejectedValue({
            body: { message: 'Unable to verify your permissions.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(advance).not.toHaveBeenCalled();
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Unable to verify your permissions.'
        );
    });

    it('is accessible', async () => {
        advance.mockResolvedValue('ok');

        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
