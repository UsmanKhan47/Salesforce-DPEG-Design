/**
 * c-sell-meter-list — @wire + IMPERATIVE Apex + NavigationMixin + toast suite.
 * Combines all three wire-mock templates:
 *   - WIRE-MOCK TEMPLATE 1 (@wire Apex): getPortfolio drives the paged datatable.
 *   - WIRE-MOCK TEMPLATE 2 (imperative Apex): findOrCreate on the "Initiate" row action.
 *   - lwc-recipes navigation mock: [Navigate] dispatches a catchable 'navigate' event.
 *
 * Data source: @wire(getPortfolio) from SellMeterController.getPortfolio -> a LIST
 * of property-asset wrappers sorted GREEN/YELLOW/RED and paged 5-at-a-time into a
 * c-list-datatable. The row "Initiate" button calls DispositionController.findOrCreate
 * then toasts + navigates to the new Disposition record; failures toast an error.
 *
 * Peak sell dates use PAST dates so the countdown resolves to a stable 'Now',
 * keeping the derived Sell Meter label independent of the run date.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE 'override' ROW ACTION (Gate 1 Q2 = confirm-then-create)
 * ─────────────────────────────────────────────────────────────────────────────
 * The yellow row's ENABLED button used to be a silent no-op — handleRowAction
 * early-returned on anything but 'initiate'. It now confirms via
 * LightningConfirm.open() and then makes the IDENTICAL findOrCreate call.
 *
 * lightning/confirm's real sfdx-lwc-jest stub THROWS on .open() by design, so the
 * module is replaced with a jest.fn here (the pattern every c/dealActionGuard
 * consumer suite uses). It is reset to resolve(true) in beforeEach so the
 * happy-path tests pass; the cancel test overrides it to resolve(false).
 *
 * 🔴 The load-bearing pair is confirm-then-create vs cancel-creates-nothing: a
 * confirmation that does not actually gate the Apex call is worse than none.
 */
import { createElement } from 'lwc';
import SellMeterList from 'c/sellMeterList';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';
import findOrCreate from '@salesforce/apex/DispositionController.findOrCreate';
import LightningConfirm from 'lightning/confirm';

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

jest.mock(
    '@salesforce/apex/DispositionController.findOrCreate',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock('lightning/confirm', () => ({
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

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

// A MACROTASK, not a bare microtask. The override path awaits the confirm promise
// BEFORE the Apex promise, so a single Promise.resolve() does not reliably drain the
// chain (the c-advance-record-stage suite hit the same trap). Strictly more draining
// than the microtask version this replaced, so the pre-existing tests are unaffected.
function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-sell-meter-list', () => {
    beforeEach(() => {
        // Default happy state for the override dialog: the user confirms.
        LightningConfirm.open.mockResolvedValue(true);
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

    it('ROW ACTION (initiate success): calls findOrCreate, toasts success, navigates', async () => {
        findOrCreate.mockResolvedValue('a0D0000000000001');

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'initiate' },
                    row: { id: 'a0P000000000GRN', name: 'Gateway Plaza' }
                }
            })
        );
        await flushPromises();
        await flushPromises();

        expect(findOrCreate).toHaveBeenCalledTimes(1);
        expect(findOrCreate).toHaveBeenCalledWith({ assetId: 'a0P000000000GRN' });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__recordPage');
        expect(pageRef.attributes.recordId).toBe('a0D0000000000001');
    });

    it('ROW ACTION (initiate failure): surfaces the Apex error in a toast, no navigation', async () => {
        findOrCreate.mockRejectedValue({
            body: { message: 'Asset already has an open disposition.' }
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

        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'initiate' },
                    row: { id: 'a0P000000000GRN', name: 'Gateway Plaza' }
                }
            })
        );
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Asset already has an open disposition.'
        );
        expect(navHandler).not.toHaveBeenCalled();

        consoleError.mockRestore();
    });

    it('ROW ACTION (hold): the red row is inert — no confirm, no Apex call', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'hold' },
                    row: { id: 'a0P0000000000RED', name: 'Cedar Commons' }
                }
            })
        );
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(findOrCreate).not.toHaveBeenCalled();
    });

    // ── The 'override' action (yellow band). Previously unhandled: the enabled ──
    // ── button was a silent no-op. These four tests are the fence.             ──

    it('ROW ACTION (override confirmed): confirms first, then calls the SAME findOrCreate', async () => {
        findOrCreate.mockResolvedValue('a0D0000000000002');

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'override' },
                    row: { id: 'a0P000000000YEL', name: 'Harbor Point' }
                }
            })
        );
        await flushPromises();
        await flushPromises();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        // The prompt has to name the property and say what "override" means, or the user
        // is confirming a word rather than a decision.
        const confirmArgs = LightningConfirm.open.mock.calls[0][0];
        expect(confirmArgs.message).toContain('Harbor Point');
        expect(confirmArgs.theme).toBe('warning');

        // Identical to the Initiate call — an override must not diverge from an initiate.
        expect(findOrCreate).toHaveBeenCalledTimes(1);
        expect(findOrCreate).toHaveBeenCalledWith({ assetId: 'a0P000000000YEL' });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        // A DISTINCT success toast: the user must be able to tell an override apart from
        // a routine initiate in the record's history.
        expect(toastHandler.mock.calls[0][0].detail.title).toContain('override');

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(
            navHandler.mock.calls[0][0].detail.pageReference.attributes.recordId
        ).toBe('a0D0000000000002');
    });

    it('ROW ACTION (override cancelled): creates nothing and says nothing', async () => {
        LightningConfirm.open.mockResolvedValue(false);

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'override' },
                    row: { id: 'a0P000000000YEL', name: 'Harbor Point' }
                }
            })
        );
        await flushPromises();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(findOrCreate).not.toHaveBeenCalled();
        // No toast on cancel — the user already knows they cancelled.
        expect(toastHandler).not.toHaveBeenCalled();
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('ROW ACTION (override refused server-side): surfaces the sell-meter message verbatim', async () => {
        // DispositionService's gate refuses a RED asset with an authored, user-safe
        // message. It must reach the toast intact rather than being replaced by
        // generic wording — that is the whole reason DispositionController has a
        // dedicated SellMeterGateException catch.
        findOrCreate.mockRejectedValue({
            body: {
                message:
                    'This property is not ready to sell - its peak sell date is more than 90 days away, so a disposition cannot be initiated yet.'
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

        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'override' },
                    row: { id: 'a0P000000000YEL', name: 'Harbor Point' }
                }
            })
        );
        await flushPromises();
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toContain(
            'not ready to sell'
        );
        expect(navHandler).not.toHaveBeenCalled();

        consoleError.mockRestore();
    });

    it('ROW ACTION (unknown action): still inert — the guard accepts exactly two names', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'somethingElse' },
                    row: { id: 'a0P000000000GRN', name: 'Gateway Plaza' }
                }
            })
        );
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(findOrCreate).not.toHaveBeenCalled();
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
