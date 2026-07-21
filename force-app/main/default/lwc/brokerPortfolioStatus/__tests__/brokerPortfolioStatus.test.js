/**
 * c-broker-portfolio-status — @wire-to-Apex (no parameter) suite.
 * Pattern: brokerFirmCard template minus the reactive recordId param.
 *
 * Data source: @wire(getPortfolio) from BrokerAssignmentController.getPortfolio
 * -> { total, active, leased, disposed }. Drives a donut (active %) plus a
 * stacked bar + legend of the three status segments.
 */
import { createElement } from 'lwc';
import BrokerPortfolioStatus from 'c/brokerPortfolioStatus';
import getPortfolio from '@salesforce/apex/BrokerAssignmentController.getPortfolio';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getPortfolio',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const PORTFOLIO = { total: 20, active: 12, leased: 5, disposed: 3 };

describe('c-broker-portfolio-status', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-portfolio-status', {
            is: BrokerPortfolioStatus
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders a zeroed donut before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ps-pct').textContent).toBe(
            '0%'
        );
        expect(
            element.shadowRoot.querySelector('.ps-rd-active').textContent
        ).toBe('0');
        // Three legend rows are always mapped from the SEG constant.
        expect(
            element.shadowRoot.querySelectorAll('.ps-leg-row').length
        ).toBe(3);
    });

    it('DATA BRANCH: computes the active percentage and segment counts', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        // round(100 * 12 / 20) = 60
        expect(element.shadowRoot.querySelector('.ps-pct').textContent).toBe(
            '60%'
        );
        expect(
            element.shadowRoot.querySelector('.ps-rd-active').textContent
        ).toBe('12');
        expect(
            element.shadowRoot.querySelector('.ps-rd-total').textContent
        ).toContain('/ 20');

        const counts = [
            ...element.shadowRoot.querySelectorAll('.ps-leg-cnt')
        ].map((el) => el.textContent);
        expect(counts).toEqual(['12', '5', '3']); // active, leased, disposed
    });

    it('ERROR BRANCH: renders an inline error state (not the donut) when the wire errors', async () => {
        const element = createComponent();

        getPortfolio.error();
        await Promise.resolve();

        // The donut is replaced by a user-safe error message.
        expect(element.shadowRoot.querySelector('.ps-pct')).toBeNull();
        const err = element.shadowRoot.querySelector('.ps-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
