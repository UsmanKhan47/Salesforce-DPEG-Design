/**
 * c-broker-stats — @wire-to-Apex (no parameter) suite.
 * Pattern: brokerFirmCard template minus the reactive recordId param.
 *
 * Data source: @wire(getBrokerHub) from BrokerController.getBrokerHub -> a hub
 * wrapper whose `.stats` object drives four c-stat-card KPI tiles. Missing stats
 * render as '0'.
 */
import { createElement } from 'lwc';
import BrokerStats from 'c/brokerStats';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

jest.mock(
    '@salesforce/apex/BrokerController.getBrokerHub',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const HUB = {
    stats: {
        totalFirms: 8,
        totalBrokers: 15,
        activeListings: 6,
        offersReceived: 23
    }
};

describe('c-broker-stats', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-stats', { is: BrokerStats });
        document.body.appendChild(element);
        return element;
    }

    it('renders four zeroed KPI cards before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect([...cards].map((c) => c.value)).toEqual(['0', '0', '0', '0']);
    });

    it('DATA BRANCH: maps each stat onto its KPI card value + label', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect([...cards].map((c) => c.value)).toEqual([
            '8',
            '15',
            '6',
            '23'
        ]);
        expect([...cards].map((c) => c.label)).toEqual([
            'Total Broker Firms',
            'Total Brokers',
            'Active Listings',
            'Offers Received'
        ]);
    });

    it('ERROR BRANCH: renders an inline error state (not the KPI cards) when the wire errors', async () => {
        const element = createComponent();

        getBrokerHub.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('c-stat-card').length).toBe(0);
        const err = element.shadowRoot.querySelector('.bs-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
