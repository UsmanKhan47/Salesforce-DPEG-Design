/**
 * c/recordStageGuard — shared JS-only util (no template, isExposed=false), unit-tested directly.
 * ------------------------------------------------------------------------------------------
 * Three exported concerns are covered here:
 *   - guardStageAction(cmp, recordId, options): the shared pre-flight — PER-RECORD permission check
 *     THEN confirmation.
 *   - confirmAction(options): the LightningConfirm wrapper, including its cancel and failure paths.
 *   - showError / showSuccess: the toast primitives the action bundle reuses.
 *
 * lightning/confirm's real sfdx-lwc-jest stub THROWS on .open() by design ("the LightningConfirm
 * documentation contains examples for mocking .open in Jest"), so the module is replaced with a
 * plain object exposing a jest.fn open(). The permission Apex is virtually mocked like any
 * imperative call.
 *
 * THE DIFFERENCE FROM c/dealActionGuard, and why this suite is not a copy: the permission question
 * here takes a recordId, because the server dispatches to the object's own gate. The
 * `passes the recordId through to Apex` test pins that — a guard that dropped the parameter would
 * still "work" today (Apex would receive null and throw, which fails closed) but would silently
 * make every action unusable, and a copy-pasted suite would not notice.
 *
 * Like c/dealActionGuard this module has NO write helper to test — the stage write is imperative
 * Apex owned by the bundle. The absence is asserted (`performs no write of its own`) so a future
 * edit cannot quietly reintroduce a write here and take getRecordNotifyChange out of the bundle's
 * hands.
 *
 * The "component" is a lightweight stub carrying only dispatchEvent, so the util can be exercised
 * without rendering an element (it renders no markup -> no toBeAccessible() assertion here).
 */
import {
    confirmAction,
    guardStageAction,
    showError,
    showSuccess,
    NO_PERMISSION_MESSAGE,
    DEFAULT_CONFIRM_MESSAGE
} from 'c/recordStageGuard';
import LightningConfirm from 'lightning/confirm';
import hasStageActionAccess from '@salesforce/apex/RecordStageAdvanceController.hasStageActionAccess';

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

function fakeComponent() {
    return { dispatchEvent: jest.fn() };
}

describe('c/recordStageGuard', () => {
    beforeEach(() => {
        // Default happy state: permitted and confirmed.
        hasStageActionAccess.mockResolvedValue(true);
        LightningConfirm.open.mockResolvedValue(true);
    });

    afterEach(() => {
        jest.clearAllMocks();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // toast primitives
    // ─────────────────────────────────────────────────────────────────────────

    it('showError / showSuccess dispatch the right toast variants from the component', () => {
        const cmp = fakeComponent();

        showError(cmp, 'boom');
        showSuccess(cmp, 'yay');

        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(2);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail).toEqual(
            expect.objectContaining({
                title: 'Error',
                message: 'boom',
                variant: 'error'
            })
        );
        expect(cmp.dispatchEvent.mock.calls[1][0].detail).toEqual(
            expect.objectContaining({
                title: 'Success',
                message: 'yay',
                variant: 'success'
            })
        );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // confirmAction
    // ─────────────────────────────────────────────────────────────────────────

    it('confirmAction opens a header-variant dialog with the supplied wording and returns the answer', async () => {
        const accepted = await confirmAction({
            message: 'Really?',
            label: 'Do It',
            theme: 'warning'
        });

        expect(accepted).toBe(true);
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Really?',
            label: 'Do It',
            theme: 'warning',
            variant: 'header'
        });
    });

    it('confirmAction falls back to the default wording when no options are supplied', async () => {
        // `label` matters: LightningConfirm REQUIRES one when variant is 'header', so a bundle that
        // forgets it must still get a usable dialog rather than a broken one.
        await confirmAction();

        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: DEFAULT_CONFIRM_MESSAGE,
            label: 'Confirm',
            theme: 'info',
            variant: 'header'
        });
    });

    it('confirmAction returns false when the user cancels', async () => {
        LightningConfirm.open.mockResolvedValueOnce(false);

        await expect(confirmAction({ message: 'x' })).resolves.toBe(false);
    });

    it('confirmAction treats a modal failure as "cancelled" rather than as consent', async () => {
        LightningConfirm.open.mockRejectedValueOnce(new Error('modal blew up'));

        await expect(confirmAction({ message: 'x' })).resolves.toBe(false);
    });

    it('confirmAction treats a non-boolean answer as NOT confirmed', async () => {
        LightningConfirm.open.mockResolvedValueOnce(undefined);

        await expect(confirmAction({ message: 'x' })).resolves.toBe(false);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // guardStageAction — the shared pre-flight
    // ─────────────────────────────────────────────────────────────────────────

    it('guardStageAction returns true and fires no toast when permitted and confirmed', async () => {
        const cmp = fakeComponent();

        const proceed = await guardStageAction(cmp, RECORD_ID, {
            message: 'Sure?'
        });

        expect(proceed).toBe(true);
        expect(hasStageActionAccess).toHaveBeenCalledTimes(1);
        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });

    it('guardStageAction passes the recordId through to Apex — the gate is PER-RECORD', async () => {
        const cmp = fakeComponent();

        await guardStageAction(cmp, RECORD_ID, { message: 'Sure?' });

        // The server dispatches to the object's own permission gate, so dropping this parameter
        // would send null and make every action fail closed org-wide. Unlike
        // c/dealActionGuard's check, this one is NOT parameterless.
        expect(hasStageActionAccess).toHaveBeenCalledWith({ recordId: RECORD_ID });
    });

    it('guardStageAction DENIES without confirming when the user lacks permission', async () => {
        hasStageActionAccess.mockResolvedValue(false);
        const cmp = fakeComponent();

        const proceed = await guardStageAction(cmp, RECORD_ID, {
            message: 'Sure?'
        });

        expect(proceed).toBe(false);
        // Permission is checked FIRST — an unauthorized user is never asked to confirm an action
        // they cannot take, because asking would imply the action was available to them.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(cmp.dispatchEvent).toHaveBeenCalledTimes(1);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.variant).toBe('error');
    });

    it('guardStageAction FAILS CLOSED and surfaces the real message when the check throws', async () => {
        hasStageActionAccess.mockRejectedValue({
            body: { message: 'Unable to verify your permissions.' }
        });
        const cmp = fakeComponent();

        const proceed = await guardStageAction(cmp, RECORD_ID, {
            message: 'Sure?'
        });

        expect(proceed).toBe(false);
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        // The REAL message, not the permission wording: a system fault must not be disguised as a
        // permissions problem, or the user takes it to the wrong administrator.
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'Unable to verify your permissions.'
        );
    });

    it('guardStageAction falls back to the permission message when the thrown check has no body', async () => {
        hasStageActionAccess.mockRejectedValue(new Error('network'));
        const cmp = fakeComponent();

        await guardStageAction(cmp, RECORD_ID, { message: 'Sure?' });

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
    });

    it('guardStageAction returns false silently when the user cancels the confirmation', async () => {
        LightningConfirm.open.mockResolvedValue(false);
        const cmp = fakeComponent();

        const proceed = await guardStageAction(cmp, RECORD_ID, {
            message: 'Sure?'
        });

        expect(proceed).toBe(false);
        // Cancelling is not an error — the user already knows what they did.
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });

    it('guardStageAction treats a non-boolean permission answer as DENIED', async () => {
        // An un-mocked/short-circuited Apex import is rewritten by the jest transformer to a fn
        // resolving undefined; that must never read as a grant.
        hasStageActionAccess.mockResolvedValue(undefined);
        const cmp = fakeComponent();

        const proceed = await guardStageAction(cmp, RECORD_ID, {
            message: 'Sure?'
        });

        expect(proceed).toBe(false);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
    });

    it('guardStageAction performs no write of its own — the bundle owns its Apex call', async () => {
        const cmp = fakeComponent();

        const proceed = await guardStageAction(cmp, RECORD_ID, {
            message: 'Sure?'
        });

        // The guard only ANSWERS. Keeping the write in the bundle is what lets it own its own
        // getRecordNotifyChange after imperative Apex DML; a write helper here would centralise the
        // refresh and silently break the Path.
        expect(proceed).toBe(true);
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });
});
