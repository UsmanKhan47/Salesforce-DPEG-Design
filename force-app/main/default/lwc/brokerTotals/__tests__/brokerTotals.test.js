/**
 * c-broker-totals — @wire-to-Apex (no parameter) suite.
 * Pattern: brokerFirmCard template minus the reactive recordId param.
 *
 * Data source: @wire(getBrokerTotals) from
 * BrokerAssignmentController.getBrokerTotals -> a list of brokers pre-sorted by
 * total properties (index = rank). Renders a ranked leaderboard; the #1 row gets
 * an extra `tb-row--top` class.
 */
import { createElement } from 'lwc';
import BrokerTotals from 'c/brokerTotals';
import getBrokerTotals from '@salesforce/apex/BrokerAssignmentController.getBrokerTotals';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getBrokerTotals',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const TOTALS = [
    { brokerId: 'b1', name: 'Ava Broker', firm: 'CBRE', totalProperties: 9 },
    { brokerId: 'b2', name: 'John Roe', firm: 'JLL', totalProperties: 4 }
];

describe('c-broker-totals', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-totals', { is: BrokerTotals });
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.tb-row').length).toBe(0);
        expect(
            element.shadowRoot.querySelector('.tb-empty').textContent
        ).toBe('No brokers assigned yet.');
    });

    it('DATA BRANCH: renders a ranked leaderboard with the top row highlighted', async () => {
        const element = createComponent();

        getBrokerTotals.emit(TOTALS);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.tb-row');
        expect(rows.length).toBe(2);

        const ranks = [
            ...element.shadowRoot.querySelectorAll('.tb-rank')
        ].map((el) => el.textContent);
        expect(ranks).toEqual(['1', '2']);

        expect(rows[0].className).toContain('tb-row--top');
        expect(rows[1].className).not.toContain('tb-row--top');

        const names = [...element.shadowRoot.querySelectorAll('.tb-n')].map(
            (el) => el.textContent
        );
        expect(names).toEqual(['Ava Broker', 'John Roe']);

        const counts = [
            ...element.shadowRoot.querySelectorAll('.tb-count')
        ].map((el) => el.textContent);
        expect(counts).toEqual(['9', '4']);
    });

    it('ERROR BRANCH: keeps the empty state when the wire errors', async () => {
        const element = createComponent();

        getBrokerTotals.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.tb-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.tb-empty')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getBrokerTotals.emit(TOTALS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
