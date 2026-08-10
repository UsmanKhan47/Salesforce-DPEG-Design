/**
 * The mirror of c-loi-mark-countered-by-dpeg's suite — read that one first; it carries the shared
 * rationale for mocking lightning/confirm and the permission Apex while using the REAL
 * c/recordStageGuard, and for pinning the exact argument pair rather than "Apex was called".
 *
 * ⚠ THE ONE THING THIS SUITE PROVES THAT THE SIBLING DOES NOT: this bundle's target is ALSO the
 * derived linear hop, so it is the half of the loop that OVERLAPS c/advanceRecordStage. The
 * overlap is deliberate (see the bundle header), and the payload assertion is what keeps the two
 * independent — if this bundle ever started deriving its target instead of hardcoding it, the
 * allow-list would stop being able to refuse it on an acquisition LOI.
 *
 * flushPromises is a MACROTASK: invoke() awaits permission -> confirm -> Apex, so a bare
 * Promise.resolve() does not drain the chain.
 */
import { createElement } from 'lwc';
import LoiMarkCounterReceived from 'c/loiMarkCounterReceived';
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

const RECORD_ID = 'a0G5g00000AbCdEEAV';

describe('c-loi-mark-counter-received', () => {
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
        const element = createElement('c-loi-mark-counter-received', {
            is: LoiMarkCounterReceived
        });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS BRANCH: sends the hardcoded target, toasts success, notifies the record', async () => {
        advanceTo.mockResolvedValue('LOI moved to Counter Received from Buyer.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        // ⚠ This target is ALSO the linear next hop, so it would be tempting to drop this bundle
        // and rely on c/advanceRecordStage. The explicit target is what makes this button
        // independent of RecordStageAdvanceService's map — and the constant is what lets the
        // per-record-type allow-list refuse it on an acquisition LOI.
        expect(advanceTo).toHaveBeenCalledTimes(1);
        expect(advanceTo).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            target: 'Counter Received from Buyer'
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'LOI moved to Counter Received from Buyer.'
        );

        // MANDATORY: Apex DML bypasses the LDS cache, so without this the Path shows a stale stage.
        expect(getRecordNotifyChange).toHaveBeenCalledTimes(1);
        expect(getRecordNotifyChange).toHaveBeenCalledWith([{ recordId: RECORD_ID }]);
    });

    it('PERMISSION IS ASKED PER RECORD, not per object', async () => {
        advanceTo.mockResolvedValue('LOI moved to Counter Received from Buyer.');

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        expect(hasStageActionAccess).toHaveBeenCalledTimes(1);
        expect(hasStageActionAccess).toHaveBeenCalledWith({ recordId: RECORD_ID });
    });

    it('ERROR BRANCH: surfaces the Apex message verbatim, no record notify', async () => {
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
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: a body-less rejection falls back to the fixed message', async () => {
        advanceTo.mockRejectedValue(new Error('transport'));

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The LOI could not be moved to Counter Received from Buyer.'
        );
    });

    it('DENIED: no permission means no Apex call and no confirmation prompt', async () => {
        hasStageActionAccess.mockResolvedValue(false);

        const element = createComponent();
        await element.invoke();
        await flushPromises();

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
