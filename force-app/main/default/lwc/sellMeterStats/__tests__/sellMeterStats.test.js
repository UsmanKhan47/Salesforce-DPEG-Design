/**
 * c-sell-meter-stats — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1) + statCard child assertions.
 *
 * Data source: @wire(getMeterSummary) from SellMeterController.getMeterSummary ->
 * a scalar wrapper { green, yellow, red, upside }. The JS ALWAYS renders four
 * c-stat-card tiles, defaulting the three band counts to '0' and Portfolio Upside
 * (money) to '$0' — so the card renders before the wire emits.
 */
import { createElement } from 'lwc';
import SellMeterStats from 'c/sellMeterStats';
import getMeterSummary from '@salesforce/apex/SellMeterController.getMeterSummary';

jest.mock(
    '@salesforce/apex/SellMeterController.getMeterSummary',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const SUMMARY = { green: 3, yellow: 5, red: 2, upside: 12500000 };

describe('c-sell-meter-stats', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-sell-meter-stats', {
            is: SellMeterStats
        });
        document.body.appendChild(element);
        return element;
    }

    function cards(element) {
        return element.shadowRoot.querySelectorAll('c-stat-card');
    }

    it('EMPTY: renders four tiles at their 0 / $0 defaults before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        expect(values).toEqual(['0', '0', '0', '$0']);
    });

    it('DATA BRANCH: maps band counts and formats Portfolio Upside money', async () => {
        const element = createComponent();

        getMeterSummary.emit(SUMMARY);
        await Promise.resolve();

        const summaryCards = cards(element);
        expect(summaryCards.length).toBe(4);

        const values = [...summaryCards].map((c) => c.value);
        expect(values).toEqual(['3', '5', '2', '$12.5M']); // upside $12,500,000

        const labels = [...summaryCards].map((c) => c.label);
        expect(labels).toEqual([
            'Sell now',
            'Getting Close',
            'Hold - Not yet',
            'Portfolio Upside'
        ]);
    });

    it('DATA BRANCH: formats a sub-million upside in K', async () => {
        const element = createComponent();

        getMeterSummary.emit({ green: 0, yellow: 0, red: 0, upside: 750000 });
        await Promise.resolve();

        expect(cards(element)[3].value).toBe('$750K');
    });

    it('ERROR BRANCH: keeps the default tiles when the wire errors', async () => {
        const element = createComponent();

        getMeterSummary.error();
        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        expect(values).toEqual(['0', '0', '0', '$0']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getMeterSummary.emit(SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
