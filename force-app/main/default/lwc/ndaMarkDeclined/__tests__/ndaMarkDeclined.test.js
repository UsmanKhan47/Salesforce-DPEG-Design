/**
 * Same IMPERATIVE APEX pattern as c-loi-mark-completed, and the same reason for pinning the exact
 * argument pair rather than "Apex was called": TARGET_STAGE is a module constant precisely so
 * RecordStageAdvanceService can validate it against the DISPOSITION NDA's per-record-type
 * allow-list. A bundle that varied its own target would defeat that check, so the first test
 * asserts the payload, not the call.
 *
 * Uses the REAL c/recordStageGuard, so the guard's two dependencies are mocked here: lightning/confirm
 * (whose real stub throws on .open() by design) and the permission Apex (an un-mocked apex import
 * resolves undefined, which the guard's `=== true` check reads as DENIED and would redden every
 * happy path).
 *
 * flushPromises is a MACROTASK: invoke() awaits permission -> confirm -> Apex, so a bare
 * Promise.resolve() does not drain the chain.
 *
 * ⚠ WHAT THESE TESTS CANNOT PROVE, stated so nobody reads green as coverage of it: the record-type
 * gate and the record-type allow-list are both SERVER-side. Jest sees a mocked Apex boundary, so it
 * proves this bundle sends the right thing and reacts correctly — never that an acquisition NDA is
 * refused. RecordStageAdvanceServiceTest.acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget is
 * the test that proves the refusal.
 */
import { createElement } from 'lwc';
import NdaMarkDeclined from 'c/ndaMarkDeclined';
import advanceTo from '@salesforce/apex/RecordStageAdvanceController.advanceTo';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasStageActionAccess from '@salesforce/apex/RecordStageAdvanceController.hasStageActionAccess';

jest.mock(
    '@salesforce/apex/RecordStageAdvanceController.advanceTo',
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

const RECORD_ID = 'a0F5g00000AbCdEEAV';

describe('c-nda-mark-declined', () => {
    beforeEach(() => {
        hasStageActionAccess.mockResolvedValue(true);
        LightningConfirm.open.mockResolvedValue(true);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-nda-mark-declined', { is: NdaMarkDeclined });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS BRANCH: sends the hardcoded target, toasts success, notifies the record', async () => {
        advanceTo.mockResolvedValue('NDA moved to Declined.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        // The target is a module constant and must reach Apex unchanged - the per-record-type
        // allow-list check downstream is only meaningful if the client cannot vary it.
        expect(advanceTo).toHaveBeenCalledTimes(1);
        expect(advanceTo).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            target: 'Declined'
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe('NDA moved to Declined.');

        // MANDATORY: Apex DML bypasses the LDS cache, so without this the Path shows a stale status.
        expect(getRecordNotifyChange).toHaveBeenCalledTimes(1);
        expect(getRecordNotifyChange).toHaveBeenCalledWith([{ recordId: RECORD_ID }]);
    });

    it('PERMISSION IS ASKED PER RECORD, not per object', async () => {
        advanceTo.mockResolvedValue('NDA moved to Declined.');

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        // The recordId argument is the whole reason c/recordStageGuard is a third guard util
        // rather than a reuse of c/dealActionGuard: the server dispatches to the record TYPE's
        // gate (DISPOSITION_DRIVER here), which it cannot do without the Id.
        expect(hasStageActionAccess).toHaveBeenCalledTimes(1);
        expect(hasStageActionAccess).toHaveBeenCalledWith({ recordId: RECORD_ID });
    });

    it('ERROR BRANCH: surfaces the Apex message verbatim, no record notify', async () => {
        // The exact refusal an acquisition NDA gets from the per-record-type allow-list.
        advanceTo.mockRejectedValue({
            body: { message: 'That stage is not available from this action.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'That stage is not available from this action.'
        );
        // A failed write must NOT tell LDS the record changed - that would refresh the page into
        // showing the old value as if it were new.
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: a body-less rejection falls back to the fixed message', async () => {
        advanceTo.mockRejectedValue(new Error('transport'));

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        // No raw platform text ever reaches a toast (ARCHITECTURE.md §5).
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The NDA could not be marked declined.'
        );
    });

    it('DENIED: no permission means no Apex call and no confirmation prompt', async () => {
        hasStageActionAccess.mockResolvedValue(false);

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        // Order matters: never ask a user to confirm an action they cannot take.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(advanceTo).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('CANCELLED: declining the confirmation writes nothing', async () => {
        LightningConfirm.open.mockResolvedValue(false);

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        expect(advanceTo).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });
});
