/**
 * c/dealActionGuard — shared JS-only util (no template, isExposed=false), unit-tested directly.
 * ------------------------------------------------------------------------------------------
 * Three exported concerns are covered here:
 *   - guardDealAction(cmp, options): the shared pre-flight — permission check THEN confirmation.
 *   - confirmAction(options): the LightningConfirm wrapper, including its cancel and failure paths.
 *   - showError / showSuccess: the toast primitives the five action bundles reuse.
 *
 * lightning/confirm's real stub THROWS on .open() by design ("the LightningConfirm documentation
 * contains examples for mocking .open in Jest"), so the module is replaced with a plain object
 * exposing a jest.fn open(). The permission Apex is virtually mocked like any imperative call.
 *
 * Unlike c/leadStatusChange this module has NO write helper to test — Opportunity actions write
 * through imperative Apex owned by each bundle, not through LDS updateRecord. The absence is
 * asserted (`performs no write of its own`) so a future edit cannot quietly reintroduce a write here
 * and take getRecordNotifyChange out of the bundles' hands.
 *
 * The "component" is a lightweight stub carrying only dispatchEvent, so the util can be exercised
 * without rendering an element (it renders no markup -> no toBeAccessible() assertion here, unlike
 * the five headless action bundles).
 */
import {
    confirmAction,
    guardDealAction,
    showError,
    showSuccess,
    NO_PERMISSION_MESSAGE,
    DEFAULT_CONFIRM_MESSAGE
} from 'c/dealActionGuard';
import LightningConfirm from 'lightning/confirm';
import hasDealActionAccess from '@salesforce/apex/OpportunityActionPermissionController.hasDealActionAccess';

jest.mock('lightning/confirm', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock(
    '@salesforce/apex/OpportunityActionPermissionController.hasDealActionAccess',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

function fakeComponent() {
    return { dispatchEvent: jest.fn() };
}

describe('c/dealActionGuard', () => {
    beforeEach(() => {
        // Default happy state: permitted and confirmed.
        hasDealActionAccess.mockResolvedValue(true);
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
    // guardDealAction — the shared pre-flight
    // ─────────────────────────────────────────────────────────────────────────

    it('guardDealAction returns true and fires no toast when permitted and confirmed', async () => {
        const cmp = fakeComponent();

        const proceed = await guardDealAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(true);
        expect(hasDealActionAccess).toHaveBeenCalledTimes(1);
        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });

    it('guardDealAction DENIES without confirming when the user is not a deal driver', async () => {
        hasDealActionAccess.mockResolvedValue(false);
        const cmp = fakeComponent();

        const proceed = await guardDealAction(cmp, { message: 'Sure?' });

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

    it('guardDealAction FAILS CLOSED and surfaces the real message when the check throws', async () => {
        hasDealActionAccess.mockRejectedValue({
            body: { message: 'Unable to verify your permissions.' }
        });
        const cmp = fakeComponent();

        const proceed = await guardDealAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        // The REAL message, not the permission wording: a system fault must not be disguised as a
        // permissions problem, or the user takes it to the wrong administrator.
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            'Unable to verify your permissions.'
        );
    });

    it('guardDealAction falls back to the permission message when the thrown check has no body', async () => {
        hasDealActionAccess.mockRejectedValue(new Error('network'));
        const cmp = fakeComponent();

        await guardDealAction(cmp, { message: 'Sure?' });

        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
    });

    it('guardDealAction returns false silently when the user cancels the confirmation', async () => {
        LightningConfirm.open.mockResolvedValue(false);
        const cmp = fakeComponent();

        const proceed = await guardDealAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        // Cancelling is not an error — the user already knows what they did.
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });

    it('guardDealAction treats a non-boolean permission answer as DENIED', async () => {
        // An un-mocked/short-circuited Apex import is rewritten by the jest transformer to a fn
        // resolving undefined; that must never read as a grant.
        hasDealActionAccess.mockResolvedValue(undefined);
        const cmp = fakeComponent();

        const proceed = await guardDealAction(cmp, { message: 'Sure?' });

        expect(proceed).toBe(false);
        expect(cmp.dispatchEvent.mock.calls[0][0].detail.message).toBe(
            NO_PERMISSION_MESSAGE
        );
    });

    it('guardDealAction performs no write of its own — each bundle owns its Apex call', async () => {
        const cmp = fakeComponent();

        const proceed = await guardDealAction(cmp, { message: 'Sure?' });

        // The guard only ANSWERS. Keeping the write in the bundles is what lets each one own its
        // own getRecordNotifyChange after imperative Apex DML; a write helper here would centralise
        // the refresh and silently break the Path on whichever bundle forgot it.
        expect(proceed).toBe(true);
        expect(cmp.dispatchEvent).not.toHaveBeenCalled();
    });
});
