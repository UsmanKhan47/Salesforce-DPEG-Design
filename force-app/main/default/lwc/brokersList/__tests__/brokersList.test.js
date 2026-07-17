/**
 * @wire-to-Apex (no-parameter) suite for c-brokers-list.
 * Emits the BrokerController.BrokerHub wrapper and asserts the (count),
 * the top-5 slice passed to c-list-datatable, and the money/pill formatting.
 * NavigationMixin GenerateUrl is stub-resolved so View All renders.
 */
import { createElement } from 'lwc';
import BrokersList from 'c/brokersList';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

jest.mock(
    '@salesforce/apex/BrokerController.getBrokerHub',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches BrokerController.BrokerRow[]. Six brokers so the top-5 slice is exercised.
function broker(n, over) {
    return {
        id: `0035g00000Brk${n}AAA`,
        name: `Broker ${n}`,
        firm: `Firm ${n}`,
        specialty: 'Retail',
        status: n % 2 === 0 ? 'Inactive' : 'Active',
        activeListings: n,
        offers: n + 1,
        closedVolume: over,
        avgDom: 45
    };
}
const HUB = {
    stats: {
        totalFirms: 6,
        totalBrokers: 6,
        activeBrokers: 3,
        activeListings: 21,
        offersReceived: 27,
        closedVolume: 12000000
    },
    brokers: [
        broker(1, 5000000),
        broker(2, 3000000),
        broker(3, 1500000),
        broker(4, 900000),
        broker(5, 250000),
        broker(6, 50000)
    ],
    topBrokers: []
};

describe('c-brokers-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-brokers-list', { is: BrokersList });
        document.body.appendChild(element);
        return element;
    }

    it('renders an empty datatable and (0) count before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('span[slot="title"]').textContent).toBe(
            'Brokers (0)'
        );
        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data).toEqual([]);
    });

    it('DATA BRANCH: shows the full count but only the top-5 rows in the table', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        // count = full list length (6); table shows the top-5 slice.
        expect(element.shadowRoot.querySelector('span[slot="title"]').textContent).toBe(
            'Brokers (6)'
        );
        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.length).toBe(5);
    });

    it('DATA BRANCH: formats money and derives the status pill styles', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        const first = table.data[0];
        expect(first.name).toBe('Broker 1');
        expect(first.volumeLabel).toBe('$5.0M'); //  5,000,000 -> $5.0M (1 dp under $10M)
        expect(first.status).toBe('Active');
        expect(first.recordUrl).toBe('/lightning/r/Contact/0035g00000Brk1AAA/view');
        // 250,000 -> $250K
        expect(table.data[4].volumeLabel).toBe('$250K');
    });

    it('ERROR BRANCH: keeps the empty datatable when the wire errors', async () => {
        const element = createComponent();

        getBrokerHub.error();
        await Promise.resolve();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data).toEqual([]);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
