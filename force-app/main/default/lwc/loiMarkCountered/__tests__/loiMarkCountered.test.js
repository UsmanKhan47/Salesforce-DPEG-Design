/**
 * Same IMPERATIVE APEX pattern as c-advance-record-stage, but this bundle calls advanceTo with a
 * HARDCODED target rather than letting the server derive one. That constant is the security-relevant
 * part: RecordStageAdvanceService validates it against the LOI's per-object allow-list, so a bundle
 * that computed its own target would defeat the allow-list. The first test therefore pins the exact
 * argument pair, not just that Apex was called.
 *
 * 🔴 THE PINNED LITERAL IS 'Negotiation' SINCE 2026-08-14 (observation 5); it was 'Counter'. This
 * assertion is the ONLY automated thing in the repo that would catch the bundle and
 * RecordStageAdvanceService.LOI_ACQUISITION_EXPLICIT_TARGETS drifting apart during a value rename
 * — Jest cannot see Apex and the Apex suite cannot see this module, so the two halves are pinned to
 * the same string in two places on purpose. Update BOTH or neither.
 *
 * Uses the REAL c/recordStageGuard, so the guard's two dependencies are mocked here: lightning/confirm
 * (whose real stub throws on .open() by design) and the permission Apex (an un-mocked apex import
 * resolves undefined, which the guard's `=== true` check reads as DENIED and would redden every
 * happy path).
 *
 * flushPromises is a MACROTASK: invoke() awaits permission -> confirm -> Apex, so a bare
 * Promise.resolve() does not drain the chain.
 */
import { createElement } from 'lwc';
import LoiMarkCountered from 'c/loiMarkCountered';
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

const RECORD_ID = 'a0E5g00000AbCdEEAV';

describe('c-loi-mark-countered', () => {
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
        const element = createElement('c-loi-mark-countered', { is: LoiMarkCountered });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS BRANCH: sends the hardcoded target, toasts success, notifies the record', async () => {
        advanceTo.mockResolvedValue('LOI moved to Negotiation.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        // The target is a module constant and must reach Apex unchanged - the allow-list check
        // downstream is only meaningful if the client cannot vary it.
        expect(advanceTo).toHaveBeenCalledTimes(1);
        expect(advanceTo).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            target: 'Negotiation'
        });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe('LOI moved to Negotiation.');

        // MANDATORY: Apex DML bypasses the LDS cache, so without this the Path shows a stale stage.
        expect(getRecordNotifyChange).toHaveBeenCalledTimes(1);
        expect(getRecordNotifyChange).toHaveBeenCalledWith([{ recordId: RECORD_ID }]);
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
