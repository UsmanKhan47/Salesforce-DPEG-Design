/**
 * c-sell-meter-header — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1).
 *
 * Data source: @wire(getPortfolio) from SellMeterController.getPortfolio -> a LIST
 * of property-asset wrappers. This component is a static banner: the template only
 * renders a fixed title and the `assetCount` getter is NOT bound to the DOM. So the
 * suite exercises the wire's data-guard both ways (data / error) and proves the
 * banner renders stably regardless of the wire outcome.
 */
import { createElement } from 'lwc';
import SellMeterHeader from 'c/sellMeterHeader';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';

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

const PORTFOLIO = [
    { id: 'a0P0000000000001AAA', name: 'Gateway Plaza' },
    { id: 'a0P0000000000002AAA', name: 'Harbor Point' },
    { id: 'a0P0000000000003AAA', name: 'Cedar Commons' }
];

describe('c-sell-meter-header', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-sell-meter-header', {
            is: SellMeterHeader
        });
        document.body.appendChild(element);
        return element;
    }

    function title(element) {
        return element.shadowRoot.querySelector('.smh__title');
    }

    it('EMPTY: renders the portfolio banner before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(title(element)).not.toBeNull();
        expect(title(element).textContent).toContain('Portfolio');
        expect(title(element).textContent).toContain('All Properties');
    });

    it('DATA BRANCH: keeps rendering the banner after portfolio data arrives', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        // The count getter is internal (not bound to the DOM); the banner is stable.
        expect(title(element).textContent).toContain('Sell Meter');
    });

    it('ERROR BRANCH: renders the banner without throwing when the wire errors', async () => {
        const element = createComponent();

        getPortfolio.error();
        await Promise.resolve();

        expect(title(element)).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
