/**
 * IMPERATIVE APEX pattern (mirrors c-submit-for-approval).
 * c-advance-deal-stage is a headless quick action whose @api invoke() runs the shared pre-flight in
 * c/dealActionGuard (permission check -> confirmation) and only then awaits
 *   const message = await advance({ recordId: this.recordId });
 * before either toasting success + notifying the record, or toasting the error.
 * Drive each branch with mockResolvedValue / mockRejectedValue and assert the
 * dispatched ShowToastEvent + getRecordNotifyChange side effects.
 *
 * The suite uses the REAL c/dealActionGuard (it does NOT mock the util), so the guard's two
 * dependencies must be mocked here instead:
 *   - lightning/confirm — its real sfdx-lwc-jest stub THROWS on .open() by design, so the module is
 *     replaced with a jest.fn. Reset to resolve(true) in beforeEach so the pre-existing happy-path
 *     tests keep passing.
 *   - the permission Apex — an un-mocked `@salesforce/apex/...` import is rewritten by the
 *     transformer to a fn resolving undefined, which the guard's `=== true` check correctly reads as
 *     DENIED; that would silently turn every happy-path test red.
 */
import { createElement } from 'lwc';
import AdvanceDealStage from 'c/advanceDealStage';
import advance from '@salesforce/apex/StageAdvanceController.advance';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasDealActionAccess from '@salesforce/apex/OpportunityActionPermissionController.hasDealActionAccess';

jest.mock(
    '@salesforce/apex/StageAdvanceController.advance',
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

describe('c-advance-deal-stage', () => {
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
        const element = createElement('c-advance-deal-stage', {
            is: AdvanceDealStage
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // A macrotask, not a bare microtask: invoke() now awaits the guard (permission promise ->
    // confirm promise) before the Apex promise, so a single Promise.resolve() no longer drains the
    // whole chain reliably.
    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    it('SUCCESS BRANCH: calls Apex with the recordId, toasts success, notifies the record', async () => {
        advance.mockResolvedValue('Deal advanced to Due Diligence.');

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
            'Deal advanced to Due Diligence.'
        );

        expect(getRecordNotifyChange).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('ERROR BRANCH: surfaces the Apex message in an error toast, no record notify', async () => {
        advance.mockRejectedValue({
            body: { message: 'The deal is not in an advanceable stage.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Cannot advance the deal'
        );
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The deal is not in an advanceable stage.'
        );

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
            'The deal could not be advanced.'
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
        // Pins the deliberately generic wording. This bundle backs FIVE actions and the target stage
        // is derived server-side in StageAdvanceService.NEXT_STAGE, so the prompt cannot name it.
        // If someone "improves" this to name a stage, they have duplicated the Apex map in JS.
        //
        // BOTH STRINGS CHANGED ON 2026-08-27 and this exact-object match pins the ABSENCE of the
        // retired pair as well as the presence of the new one — restoring either reds this test.
        //   label:   'Advance Deal' matched NO button. All five actions are named for what they do
        //            ("Initiate LOI", "Close Deal" …), so a fixed 'Advance Deal' header contradicted
        //            whichever one the user clicked. Now neutral, and identical to the header
        //            c/advanceRecordStage adopted the same day.
        //   message: 'Advance this deal to the next stage?' was FALSE on the Underwriting hop behind
        //            "Initiate LOI" — StageAdvanceService.advance submits that one into the
        //            principal approval instead of writing a stage ('Underwriting' is absent from
        //            NEXT_STAGE). 'next step' covers both outcomes and is the service's own wording.
        expect(LightningConfirm.open).toHaveBeenCalledWith({
            message: 'Move this deal to its next step?',
            label: 'Confirm Stage Change',
            theme: 'info',
            variant: 'header'
        });
    });

    it('PERMISSION ORDER: the permission check runs BEFORE the confirmation', async () => {
        advance.mockResolvedValue('ok');
        const callOrder = [];
        hasDealActionAccess.mockImplementation(() => {
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
        hasDealActionAccess.mockResolvedValue(false);

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
        hasDealActionAccess.mockRejectedValue({
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
