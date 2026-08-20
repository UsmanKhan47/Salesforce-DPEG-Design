/**
 * c-sell-meter-list — @wire + MODAL + NavigationMixin + toast suite.
 *   - WIRE-MOCK TEMPLATE 1 (@wire Apex): getPortfolio drives the paged datatable.
 *   - lwc-recipes navigation mock: [Navigate] dispatches a catchable 'navigate' event.
 *   - c/sellMeterInitiateModal replaced with `{ open: jest.fn() }` (see below).
 *
 * Data source: @wire(getPortfolio) from SellMeterController.getPortfolio -> a LIST
 * of property-asset wrappers sorted GREEN/YELLOW/RED and paged 5-at-a-time into a
 * c-list-datatable.
 *
 * Peak sell dates use PAST dates so the countdown resolves to a stable 'Now',
 * keeping the derived Sell Meter label independent of the run date.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * ⚠ THE ROW ACTION NO LONGER CALLS APEX DIRECTLY — IT OPENS A MODAL
 * ─────────────────────────────────────────────────────────────────────────────
 * This suite previously asserted `DispositionController.findOrCreate` was called
 * from `handleRowAction`. That call is GONE. `findOrCreate` still exists in Apex
 * and is deliberately untouched, but it creates WITHOUT a record type choice and
 * WITHOUT submitting an approval, which is no longer what this button means.
 * The row now opens `c/sellMeterInitiateModal`, which owns the
 * `DispositionController.initiateAndSubmit` call; this component owns every
 * toast and the navigation.
 *
 * 🔴 `LightningModal.open()` IS A STATIC ON A CLASS, so it CANNOT be driven the
 * way a wire adapter or an imperative Apex import can — the repo-local
 * `lightning/modal` stub throws from `open()` on purpose (mirroring
 * lightning/confirm's own shipped stub) precisely so that a suite which forgot
 * to mock it fails loudly instead of silently resolving `undefined` and passing
 * every "the caller acts on the result" test while asserting nothing. Hence the
 * jest.mock of the whole modal module below.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING PAIRS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. confirm-then-open vs cancel-opens-nothing (YELLOW band). A confirmation
 *    that does not actually gate the next step is worse than none.
 * 2. THE BAND GATE STILL SITS IN FRONT OF THE MODAL. RED never opens it; YELLOW
 *    answers the override question FIRST. Opening the modal first and asking
 *    inside it would let a user pick a record type before being told the
 *    property is not at peak.
 * 3. `submitted === false` STILL NAVIGATES. The Disposition exists —
 *    `dispositionId` is always populated on a non-throwing return — so treating
 *    it as a failure would tell the user nothing was created about a record that
 *    is sitting there. Only the toast VARIANT differs (warning vs success).
 */
import { createElement } from 'lwc';
import SellMeterList from 'c/sellMeterList';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';
import LightningConfirm from 'lightning/confirm';
import SellMeterInitiateModal from 'c/sellMeterInitiateModal';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', { detail: { pageReference } })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('https://example.com/asset-list');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/SellMeterController.getPortfolio',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock('lightning/confirm', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

// The modal is replaced wholesale: only its static `open()` is part of this
// component's contract. The modal's OWN behaviour is proved in
// lwc/sellMeterInitiateModal/__tests__.
jest.mock('c/sellMeterInitiateModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

// Mixed-band portfolio (emitted out of band order to prove the GREEN/YELLOW/RED sort).
const PORTFOLIO = [
    { id: 'a0P0000000000RED', name: 'Cedar Commons', noi: 500000, mktCapRate: 8.0, targetPrice: 6000000, peakSellDate: '2020-06-01', projectedValueAtPeak: 6500000, sellMeter: 'RED' },
    { id: 'a0P000000000GRN', name: 'Gateway Plaza', noi: 2000000, mktCapRate: 6.5, targetPrice: 30000000, peakSellDate: '2020-01-01', projectedValueAtPeak: 34000000, sellMeter: 'GREEN' },
    { id: 'a0P000000000YEL', name: 'Harbor Point', noi: 1200000, mktCapRate: 7.2, targetPrice: 15000000, peakSellDate: '2020-03-01', projectedValueAtPeak: 16000000, sellMeter: 'YELLOW' }
];

// 6 GREEN rows (no RED -> no page-1 reorder) to exercise the pager cleanly.
const SIX_GREEN = Array.from({ length: 6 }, (_, i) => ({
    id: `a0P00000000000${i}`,
    name: `Asset ${i}`,
    noi: 1000000,
    mktCapRate: 6.0,
    targetPrice: 10000000,
    peakSellDate: '2020-01-01',
    projectedValueAtPeak: 11000000,
    sellMeter: 'GREEN'
}));

/**
 * 🔴 THE MEMBER NAMES BELOW ARE THE SERVER'S — `DispositionService.InitiateOutcome`
 * declares `dispositionId`, `submitted`, `message`. A Jest fixture DEFINES the
 * payload locally, so it proves the component reads its OWN fixture and never
 * that the fixture matches Apex. If the Apex DTO is renamed, this file and
 * `sellMeterList._handleOutcome` stay green while the component reads
 * `undefined` and navigates nowhere. Re-check against the Apex, not against a
 * green suite.
 */
const OUTCOME_SUBMITTED = {
    dispositionId: 'a0D0000000000001',
    submitted: true,
    message: 'Disposition created and submitted for approval.'
};
const OUTCOME_NOT_SUBMITTED = {
    dispositionId: 'a0D0000000000002',
    submitted: false,
    message: 'Created, but no approval process accepted the submission.'
};

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

// A MACROTASK, not a bare microtask. The override path awaits the confirm promise
// BEFORE the modal promise, so a single Promise.resolve() does not reliably drain
// the chain.
function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-sell-meter-list', () => {
    beforeEach(() => {
        // Default happy state for the override dialog: the user confirms.
        LightningConfirm.open.mockResolvedValue(true);
        // Default modal result: dismissed. Each test that cares sets its own.
        SellMeterInitiateModal.open.mockResolvedValue(undefined);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-sell-meter-list', {
            is: SellMeterList
        });
        document.body.appendChild(element);
        return element;
    }

    /**
     * ⚠ LEGACY / STATIC-COLUMN SHAPE — `detail.action.name` as a real STRING.
     *
     * 🔴 THE PLATFORM DOES NOT SEND THIS for the Action column in this component.
     * It is retained ON PURPOSE for exactly two jobs, and no other test may use it:
     *   1. driving an ARBITRARY action name that no row could ever produce (the
     *      unknown-action guard), and
     *   2. covering the defensive string branch of `_resolveActionName`, which
     *      must keep winning for a statically-named column or a future platform
     *      version that does resolve `typeAttributes`.
     *
     * Every band-behaviour test uses `fireRealRowAction` instead. This helper
     * being the DEFAULT is what let the silent-no-op defect ship green.
     *
     * `row` must be the FORMATTED row (`c-list-datatable`.data[i]), not a
     * hand-written `{ id, name }` stub — that is what the platform datatable
     * passes back, and the component reads `noiLabel` / `capRateLabel` /
     * `targetLabel` / `peakDateLabel` off it to populate the modal.
     */
    function fireLegacyStringRowAction(element, name, row) {
        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', { detail: { action: { name }, row } })
        );
    }

    /**
     * ─────────────────────────────────────────────────────────────────────────
     * 🔴 THE PAYLOAD THE REAL `lightning-datatable` ACTUALLY EMITS
     * ─────────────────────────────────────────────────────────────────────────
     * `lightning-datatable` does NOT resolve `fieldName` references inside a
     * column's `typeAttributes` when it builds the `rowaction` event. It passes
     * the RAW COLUMN DEFINITION through as `detail.action`, so
     * `detail.action.name` is the OBJECT `{ fieldName: 'actionName' }` — never
     * the string `'initiate'`. Only `detail.row` carries the resolved per-row
     * values.
     *
     * Measured in the live org (Copperfield Town Center, 2026-08-20):
     *   resolved name='[object Object]'  →  handler returned silently
     *
     * ⚠ THIS HELPER EXISTS BECAUSE THE SUITE PREVIOUSLY LIED. `fireRowAction`
     * used to send `detail.action = { name: 'initiate' }` — a plain string,
     * which the platform never sends. Every row-action test was green while the
     * button did nothing in production. Do NOT "simplify" this back to a string;
     * the string shape is covered by exactly one deliberately-labelled legacy
     * test below.
     */
    function fireRealRowAction(element, row) {
        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: {
                        label: { fieldName: 'actionLabel' },
                        name: { fieldName: 'actionName' },
                        variant: { fieldName: 'actionVariant' },
                        disabled: { fieldName: 'actionDisabled' }
                    },
                    row
                }
            })
        );
    }

    /** Sorted GREEN, YELLOW, RED — see the DATA BRANCH test. */
    const GREEN = 0;
    const YELLOW = 1;
    const RED = 2;
    const rowAt = (element, i) => datatable(element).data[i];

    // ── THE REAL DATATABLE PAYLOAD ───────────────────────────────────────────
    // These three are the regression net for the silent-no-op defect. They send
    // the UNRESOLVED column definition the platform really emits; the action
    // name must be recovered from the ROW.

    it('🔴 REAL PAYLOAD (GREEN): unresolved action.name still opens the modal', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });

        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        const row = rowAt(element, GREEN);
        // Precondition: the ROW is where the real name lives.
        expect(row.actionName).toBe('initiate');

        fireRealRowAction(element, row);
        await flushPromises();
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).toHaveBeenCalledTimes(1);
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000GRN'
        );
    });

    it('🔴 REAL PAYLOAD (YELLOW): unresolved action.name still confirms, then opens', async () => {
        const callOrder = [];
        LightningConfirm.open.mockImplementation(() => {
            callOrder.push('confirm');
            return Promise.resolve(true);
        });
        SellMeterInitiateModal.open.mockImplementation(() => {
            callOrder.push('modal');
            return Promise.resolve({ outcome: OUTCOME_SUBMITTED });
        });

        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        const row = rowAt(element, YELLOW);
        expect(row.actionName).toBe('override');

        fireRealRowAction(element, row);
        await flushPromises();
        await flushPromises();
        await flushPromises();

        // The band gate still sits IN FRONT of the modal.
        expect(callOrder).toEqual(['confirm', 'modal']);
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000YEL'
        );
    });

    it('🔴 REAL PAYLOAD (RED): unresolved action.name is still inert for a hold', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        const row = rowAt(element, RED);
        expect(row.actionName).toBe('hold');

        fireRealRowAction(element, row);
        await flushPromises();

        // Recovering the name from the row must not accidentally make RED live.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    it('EMPTY: zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Sell Meter (0)');
        expect(datatable(element).data).toEqual([]);
        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '0 of 0'
        );
    });

    it('DATA BRANCH: sorts GREEN/YELLOW/RED and formats each row', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        const rows = datatable(element).data;
        expect(rows.length).toBe(3);
        // Emitted RED/GREEN/YELLOW -> sorted GREEN, YELLOW, RED.
        expect(rows.map((r) => r.name)).toEqual([
            'Gateway Plaza',
            'Harbor Point',
            'Cedar Commons'
        ]);

        // GREEN row: compact money, cap-rate %, actionable "Initiate" button.
        expect(rows[0].noiLabel).toBe('$2.0M');
        expect(rows[0].capRateLabel).toBe('6.5%');
        expect(rows[0].actionLabel).toBe('Initiate');
        expect(rows[0].actionName).toBe('initiate');
        expect(rows[0].actionDisabled).toBe(false);

        // RED row: Hold action is disabled.
        expect(rows[2].actionLabel).toBe('Hold');
        expect(rows[2].actionDisabled).toBe(true);

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Sell Meter (3)');
    });

    it('PAGER: 6 rows page into 5 + 1 and next advances the window', async () => {
        const element = createComponent();

        getPortfolio.emit(SIX_GREEN);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(5); // page 1
        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '1–5 of 6'
        );
        expect(element.shadowRoot.querySelector('.sm-pager')).not.toBeNull();

        // Buttons: [0] prev (disabled on page 1), [1] next.
        const btns = element.shadowRoot.querySelectorAll('.sm-pgbtn');
        expect(btns[0].disabled).toBe(true);
        btns[1].click();
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(1); // page 2 remainder
        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '6–6 of 6'
        );
    });

    // ── GREEN: straight to the modal, no confirmation ────────────────────────

    it('ROW ACTION (initiate): opens the modal with the PRE-FORMATTED row summary', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });

        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        // GREEN goes straight there — no override question.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).toHaveBeenCalledTimes(1);

        const args = SellMeterInitiateModal.open.mock.calls[0][0];
        expect(args.assetId).toBe('a0P000000000GRN');
        expect(args.propertyName).toBe('Gateway Plaza');
        // Handed over ALREADY FORMATTED, so the popup and the row behind it
        // cannot show different numbers for the same property.
        expect(args.noiLabel).toBe('$2.0M');
        expect(args.capRateLabel).toBe('6.5%');
        expect(args.targetLabel).toBe('$30.0M');
        expect(args.peakDateLabel).toBe('Jan 1, 2020');
    });

    it('SUCCESS: toasts success and navigates to the new Disposition', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        // The server's authored message is shown, not a re-authored client copy.
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            OUTCOME_SUBMITTED.message
        );

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__recordPage');
        expect(pageRef.attributes.recordId).toBe('a0D0000000000001');
    });

    it('🔴 NOT SUBMITTED: WARNING toast and STILL NAVIGATES — the record exists', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_NOT_SUBMITTED
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.variant).toBe('warning');
        expect(toast.message).toBe(OUTCOME_NOT_SUBMITTED.message);
        // Sticky: this is the only notice that an approval still has to be
        // raised by hand, and the navigation below happens in the same tick.
        expect(toast.mode).toBe('sticky');

        // The whole point: navigation is NOT conditional on `submitted`.
        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(
            navHandler.mock.calls[0][0].detail.pageReference.attributes.recordId
        ).toBe('a0D0000000000002');
    });

    it('DISMISSED: closing the modal creates nothing and says nothing', async () => {
        SellMeterInitiateModal.open.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('REFUSED SERVER-SIDE: surfaces the sell-meter message VERBATIM and does not navigate', async () => {
        // DispositionService's gate refuses with an authored, user-safe message.
        // It must reach the toast intact rather than being replaced by generic
        // wording — that is the whole reason DispositionController has a
        // dedicated SellMeterGateException catch.
        SellMeterInitiateModal.open.mockResolvedValue({
            error: {
                body: {
                    message:
                        'This property is not ready to sell - its peak sell date is more than 90 days away, so a disposition cannot be initiated yet.'
                }
            }
        });
        const consoleError = jest
            .spyOn(console, 'error')
            .mockImplementation(() => {});

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.variant).toBe('error');
        expect(toast.mode).toBe('sticky');
        expect(toast.message).toContain('not ready to sell');
        expect(navHandler).not.toHaveBeenCalled();

        consoleError.mockRestore();
    });

    // ── RED: inert. The band gate is IN FRONT of the modal, not inside it ────

    it('ROW ACTION (hold): the red row is inert — no confirm, no modal', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, RED));
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    it('ROW ACTION (unknown action): still inert — the guard accepts exactly two names', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        // Unknown name via the ROW (the branch that now decides in production).
        fireRealRowAction(element, {
            ...rowAt(element, GREEN),
            actionName: 'somethingElse'
        });
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    it('LEGACY STRING SHAPE: a real string action.name still wins over the row', async () => {
        // Covers the defensive branch of `_resolveActionName`. A statically-named
        // column (or a future platform version that DOES resolve typeAttributes)
        // sends a genuine string, and it must take precedence over `row.actionName`
        // rather than being ignored in favour of it.
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        // Row says 'hold' (RED, inert); the explicit string says 'somethingElse'.
        // If the string branch were dropped, this would fall through to the row.
        fireLegacyStringRowAction(element, 'somethingElse', rowAt(element, GREEN));
        await flushPromises();

        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();

        // And the accepted string name drives the modal off a resolved row.
        fireLegacyStringRowAction(element, 'initiate', rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).toHaveBeenCalledTimes(1);
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000GRN'
        );
    });

    // ── YELLOW: the override confirmation comes FIRST ────────────────────────

    it('ROW ACTION (override confirmed): confirms FIRST, then opens the same modal', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });
        const callOrder = [];
        LightningConfirm.open.mockImplementation(() => {
            callOrder.push('confirm');
            return Promise.resolve(true);
        });
        SellMeterInitiateModal.open.mockImplementation(() => {
            callOrder.push('modal');
            return Promise.resolve({ outcome: OUTCOME_SUBMITTED });
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();
        await flushPromises();

        // 🔴 ORDER IS THE POINT. Asking inside the modal instead would let a user
        // fill in a record type before being told the property is not at peak.
        expect(callOrder).toEqual(['confirm', 'modal']);

        // The prompt has to name the property and say what "override" means, or
        // the user is confirming a word rather than a decision.
        const confirmArgs = LightningConfirm.open.mock.calls[0][0];
        expect(confirmArgs.message).toContain('Harbor Point');
        expect(confirmArgs.theme).toBe('warning');

        // Identical modal call to the Initiate path — an override must not diverge.
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000YEL'
        );

        // A DISTINCT success toast: the user must be able to tell an override
        // apart from a routine initiate.
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.title).toContain('override');

        expect(navHandler).toHaveBeenCalledTimes(1);
    });

    it('ROW ACTION (override cancelled): opens nothing and says nothing', async () => {
        LightningConfirm.open.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
        // No toast on cancel — the user already knows they cancelled.
        expect(toastHandler).not.toHaveBeenCalled();
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('ROW ACTION with no asset id: toasts and never opens the modal', async () => {
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        // Legacy string shape ON PURPOSE: the row is deliberately malformed (no id
        // and no actionName), so the accepted action name has to come from the
        // string branch for the missing-id guard to be reachable at all.
        fireLegacyStringRowAction(element, 'initiate', { name: 'Orphan row' });
        await flushPromises();

        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
    });

    it('MODAL FAILS TO OPEN: distinct message, no navigation', async () => {
        SellMeterInitiateModal.open.mockRejectedValue(
            new Error('modal layer unavailable')
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        // Nothing was created and nothing was even attempted, so this must NOT
        // reuse the server-refusal wording.
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Could not open the initiate dialog'
        );
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: empty datatable + inline error banner when the portfolio wire errors', async () => {
        const element = createComponent();

        getPortfolio.error();
        await Promise.resolve();

        expect(datatable(element).data).toEqual([]);
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Sell Meter (0)');
        // Wire failure surfaces an inline error banner instead of a silent empty list.
        expect(element.shadowRoot.querySelector('.sm-error')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
