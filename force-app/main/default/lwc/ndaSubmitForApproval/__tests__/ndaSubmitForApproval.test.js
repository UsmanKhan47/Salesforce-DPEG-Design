/**
 * c-nda-submit-for-approval — the headless quick action behind
 * `quickActions/NDA__c.Submit_NDA_Approval`.
 *
 * IMPERATIVE APEX pattern (mirrors c-disposition-submit-for-approval). Its `@api invoke()` runs the
 * shared pre-flight in `c/recordStageGuard` (PER-RECORD permission check -> confirmation) and only
 * then awaits
 *   const message = await submitNdaForApproval({ ndaId: this.recordId });
 * before either toasting success + notifying the record, or toasting the error.
 *
 * The suite uses the REAL `c/recordStageGuard` (it does NOT mock the util), so the guard's two
 * dependencies are mocked here instead:
 *   - `lightning/confirm` — its real sfdx-lwc-jest stub THROWS on `.open()` by design.
 *   - `RecordStageAdvanceController.hasStageActionAccess` — an un-mocked `@salesforce/apex/...`
 *     import is rewritten by the transformer to a fn resolving `undefined`, which the guard's
 *     `=== true` check correctly reads as DENIED; that would silently turn every happy-path test
 *     red for the wrong reason.
 *
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE LOAD-BEARING FACTS
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * 1. 🔴 THIS BUTTON REPLACED A ONE-CLICK BYPASS. `NDA__c.Move_to_Approved` performed the SAME
 *    `Prepare` -> `Approved` transition directly, gated on `Disposition_Deal_Actions` — which the
 *    ANALYST permission set grants and the PRINCIPAL set is forbidden to hold. Both it and
 *    `RecordStageAdvanceService`'s map hop were retired in the same wave. So a build in which this
 *    component silently did nothing, or swallowed a refusal, would leave the transition
 *    unreachable rather than merely broken — and one in which it called the wrong Apex would
 *    reinstate the bypass.
 * 2. THE APEX PARAMETER IS `ndaId`, NOT `recordId` AND NOT `dispositionId`. An imperative call
 *    binds by NAME; a mismatch is not a compile error on either side, it simply arrives null and
 *    the user is told "No record was provided." from a button they clicked on a real record. This
 *    is the assertion that catches a copy-paste from `c/dispositionSubmitForApproval`, whose Apex
 *    takes `dispositionId`.
 * 3. `getRecordNotifyChange`. The submission is imperative Apex, so the write happens behind LDS's
 *    back. Without it the Path AND the Dynamic Actions rules that render this very button keep
 *    evaluating the OLD values — and the record has just become `AdminOnly` READ-ONLY, so the
 *    inline-edit pencils stay live and every save fails with `ENTITY_IS_LOCKED`. Both halves are
 *    pinned: called on success, NOT called on any failure or refusal path.
 * 4. 🔴 THE ALREADY-PENDING REFUSAL MUST REACH THE USER VERBATIM. A second submit while one is
 *    pending is refused, and `NdaApprovalService` authors that sentence precisely so the platform's
 *    own exception text never appears. A component that replaced it with generic wording would
 *    discard the whole reason the pre-check exists.
 * 5. THE PERMISSION GATE IS `c/recordStageGuard`, whose question is PER-RECORD — proved by
 *    asserting `hasStageActionAccess` receives the recordId. `c/dealActionGuard`'s
 *    `hasDealActionAccess()` takes NO argument and resolves the OPPORTUNITY controller at module
 *    scope, so it structurally cannot ask an NDA's question. Swapping the guards would compile and
 *    pass a naive suite.
 * 6. THE CONFIRMATION WARNS THAT THE RECORD LOCKS. `recordEditability = AdminOnly` makes the NDA
 *    read-only the instant this succeeds, including for the person who pressed the button. That is
 *    not discoverable any other way, and the way back (Recall, from the Approval History related
 *    list) is not on this component.
 */
import { createElement } from 'lwc';
import NdaSubmitForApproval from 'c/ndaSubmitForApproval';
import submitNdaForApproval from '@salesforce/apex/DispositionApprovalController.submitNdaForApproval';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import hasStageActionAccess from '@salesforce/apex/RecordStageAdvanceController.hasStageActionAccess';

jest.mock(
    '@salesforce/apex/DispositionApprovalController.submitNdaForApproval',
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

const RECORD_ID = 'a0N5g000000NdaAEAW';
const SUCCESS = 'The NDA has been submitted for the NDA Issue approval.';

describe('c-nda-submit-for-approval', () => {
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
        const element = createElement('c-nda-submit-for-approval', {
            is: NdaSubmitForApproval
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    function listen(element) {
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        return toastHandler;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // SUCCESS
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('SUCCESS: calls Apex with ndaId, toasts the server message, notifies the record', async () => {
        submitNdaForApproval.mockResolvedValue(SUCCESS);

        const element = createComponent();
        const toastHandler = listen(element);

        await element.invoke();
        await flushPromises();

        expect(submitNdaForApproval).toHaveBeenCalledTimes(1);
        // 🔴 `ndaId`, NOT `recordId` and NOT `dispositionId` — an imperative Apex call binds by
        // NAME. A copy-paste from c/dispositionSubmitForApproval would send `dispositionId`, the
        // server would receive null, and the user would be told "No record was provided." from a
        // button they clicked on a real record.
        expect(submitNdaForApproval).toHaveBeenCalledWith({ ndaId: RECORD_ID });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        // THE SERVER'S message, verbatim — it names WHICH approval, which is the only way the user
        // can confirm they pressed the right one of five actions on the page.
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(SUCCESS);

        // 🔴 MANDATORY. Apex DML bypasses the LDS cache; without this the Path, the action bar and
        // the record's new READ-ONLY state all keep showing the pre-submission page.
        expect(getRecordNotifyChange).toHaveBeenCalledTimes(1);
        expect(getRecordNotifyChange).toHaveBeenCalledWith([{ recordId: RECORD_ID }]);
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 REFUSALS — the reason this bundle exists rather than the platform button
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('REFUSAL: the already-pending message reaches the user VERBATIM and sticky', async () => {
        // 🔴 THE FAILURE THE BRIEF SINGLED OUT. A second submit while one is pending is refused.
        // `Approval.process`'s own exception text is not a sentence to show a user, so
        // NdaApprovalService authors this one — and it is only worth authoring if the client shows
        // it unchanged.
        submitNdaForApproval.mockRejectedValue({
            body: { message: 'This NDA is already pending approval.' }
        });

        const element = createComponent();
        const toastHandler = listen(element);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const detail = toastHandler.mock.calls[0][0].detail;
        expect(detail.variant).toBe('error');
        expect(detail.message).toBe('This NDA is already pending approval.');
        // ⚠ STICKY. The message tells the user what to DO — recall the pending approval, or wait —
        // and an auto-dismissing toast loses the instruction before it can be acted on.
        expect(detail.mode).toBe('sticky');

        // 🔴 NOTHING WAS WRITTEN, so notifying LDS would force a pointless re-render and, worse,
        // would suggest to a reader of this file that a refusal changes the record.
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('REFUSAL: a status refusal reaches the user verbatim too — it names the required status', async () => {
        const authored =
            'An NDA can only be submitted for the NDA Issue approval from the Prepare status. ' +
            'This NDA is at Approved.';
        submitNdaForApproval.mockRejectedValue({ body: { message: authored } });

        const element = createComponent();
        const toastHandler = listen(element);

        await element.invoke();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(authored);
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('REFUSAL: an error with no readable body falls back to a component-owned sentence', async () => {
        // A transport failure carries no `body.message`. The fallback must still be a sentence,
        // never `undefined` or `[object Object]`.
        submitNdaForApproval.mockRejectedValue(new Error('network'));

        const element = createComponent();
        const toastHandler = listen(element);

        await element.invoke();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'This NDA could not be submitted for approval.'
        );
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // THE PRE-FLIGHT
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('GUARD: the permission question is PER-RECORD and receives the recordId', async () => {
        // 🔴 c/dealActionGuard's `hasDealActionAccess()` takes NO argument and resolves the
        // OPPORTUNITY permission controller at module scope, so it structurally cannot ask an
        // NDA's question. Only the recordId-taking signature can, because the server dispatches on
        // `Id.getSObjectType()` and — for NDA__c — on the RECORD TYPE.
        submitNdaForApproval.mockResolvedValue(SUCCESS);

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        expect(hasStageActionAccess).toHaveBeenCalledWith({ recordId: RECORD_ID });
    });

    it('GUARD: a denied user never reaches Apex', async () => {
        hasStageActionAccess.mockResolvedValue(false);

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(submitNdaForApproval).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('GUARD: cancelling the confirmation submits nothing', async () => {
        LightningConfirm.open.mockResolvedValue(false);

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        expect(submitNdaForApproval).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('CONFIRM: the dialog warns that the record LOCKS, and is themed as a warning', async () => {
        // 🔴 THE LOCK IS NOT DISCOVERABLE ANY OTHER WAY. `recordEditability = AdminOnly` makes the
        // NDA read-only the instant this succeeds, including for the person who pressed the button,
        // and the way back is Recall from the Approval History related list — not this component.
        // ⚠ theme 'warning', not 'info': this is not a write the user can simply repeat. It creates
        // a pending instance, notifies the approvers and a SECOND submit is refused.
        submitNdaForApproval.mockResolvedValue(SUCCESS);

        const element = createComponent();
        await element.invoke();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        const config = LightningConfirm.open.mock.calls[0][0];
        expect(config.theme).toBe('warning');
        expect(config.message).toContain('locked');
        // ⚠ IT NAMES THE APPROVAL, unlike c/dispositionSubmitForApproval, which is deliberately
        // generic because ONE bundle there backs FOUR actions and cannot know which. Here there is
        // exactly one action, one object and one process — the vagueness would be a copied habit.
        expect(config.message).toContain('NDA Issue approval');
    });

    /**
     * ⚠ A HEADLESS QUICK ACTION RENDERS AN EMPTY TEMPLATE, so this is a near-trivial pass and is
     * kept for the same reason `c/dispositionSubmitForApproval` and `c/submitForApproval` keep
     * theirs: it is the tripwire that fires the day somebody adds markup to this bundle. The
     * platform's action bar owns the button, and the confirmation dialog is `lightning/confirm`'s
     * own accessible surface, not this component's.
     */
    it('A11Y: the headless bundle is accessible', async () => {
        submitNdaForApproval.mockResolvedValue(SUCCESS);

        const element = createComponent();
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
