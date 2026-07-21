/**
 * @wire-to-Apex (no-parameter) suite for c-top-brokers.
 * Emits the BrokerController.BrokerHub wrapper and asserts the ranked
 * topBrokers list, the empty state, and the lead-row highlight.
 */
import { createElement } from 'lwc';
import TopBrokers from 'c/topBrokers';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

jest.mock(
    '@salesforce/apex/BrokerController.getBrokerHub',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches BrokerController.BrokerRow[] under hub.topBrokers (ranked by active listings).
const HUB = {
    stats: {},
    brokers: [],
    topBrokers: [
        {
            id: '0035g00000TopAAAA',
            name: 'Dana Reyes',
            firm: 'Colliers International',
            activeListings: 9
        },
        {
            id: '0035g00000TopBAAA',
            name: 'Marcus Cole',
            firm: 'CBRE',
            activeListings: 6
        }
    ]
};

describe('c-top-brokers', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-top-brokers', { is: TopBrokers });
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.empty').textContent).toBe(
            'No broker listings yet.'
        );
    });

    it('DATA BRANCH: renders one ranked row per top broker', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.row');
        expect(rows.length).toBe(2);

        const names = [...element.shadowRoot.querySelectorAll('.name')].map(
            (el) => el.textContent
        );
        expect(names).toEqual(['Dana Reyes', 'Marcus Cole']);

        const ranks = [...element.shadowRoot.querySelectorAll('.rank')].map(
            (el) => el.textContent
        );
        expect(ranks).toEqual(['1', '2']);

        const counts = [...element.shadowRoot.querySelectorAll('.count')].map(
            (el) => el.textContent
        );
        expect(counts).toEqual(['9', '6']);
    });

    it('DATA BRANCH: highlights the #1 broker with the lead-row class', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.row');
        expect(rows[0].className).toContain('row--lead');
        expect(rows[1].className).not.toContain('row--lead');
    });

    it('ERROR BRANCH: renders a distinct error state (not the empty state) when the wire errors', async () => {
        const element = createComponent();

        getBrokerHub.error();
        await Promise.resolve();

        // Error is surfaced distinctly — it must NOT masquerade as "no broker listings".
        expect(element.shadowRoot.querySelector('.tb-error')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.empty')).toBeNull();
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(0);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
