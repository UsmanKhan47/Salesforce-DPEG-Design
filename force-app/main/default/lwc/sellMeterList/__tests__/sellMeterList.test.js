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
 */
import { createElement } from 'lwc';
import SellMeterList from 'c/sellMeterList';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';
import findOrCreate from '@salesforce/apex/DispositionController.findOrCreate';

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

function flushPromises() {
    return Promise.resolve();
}

describe('c-sell-meter-list', () => {
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

    it('ROW ACTION (non-initiate): Hold/Override are inert — no Apex call', async () => {
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

        expect(findOrCreate).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: empty datatable when the portfolio wire errors', async () => {
        const element = createComponent();

        getPortfolio.error();
        await Promise.resolve();

        expect(datatable(element).data).toEqual([]);
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Sell Meter (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
