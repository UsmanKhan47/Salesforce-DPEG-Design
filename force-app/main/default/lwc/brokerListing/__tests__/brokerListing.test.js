/**
 * c-broker-listing — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (createApexTestWireAdapter + emit/error).
 *
 * Data source: @wire(getListing, { dispositionId: '$recordId' }) from
 * BrokerListingController.getListing -> a single listing wrapper. Renders a card
 * with four c-onboarding-card-child stat tiles; falls back to an empty card when
 * no listing exists.
 */
import { createElement } from 'lwc';
import BrokerListing from 'c/brokerListing';
import getListing from '@salesforce/apex/BrokerListingController.getListing';

jest.mock(
    '@salesforce/apex/BrokerListingController.getListing',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const LISTING = {
    assetName: 'Sugar Land Town Center',
    brokerFirm: 'CBRE',
    contactName: 'Jane Doe',
    weekLabel: 'Week 6',
    daysOnMarket: 42,
    isAtRisk: true,
    listDate: '2026-03-15',
    callForOffersDate: '2026-04-10',
    offersReceived: 3
};

describe('c-broker-listing', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-broker-listing', {
            is: BrokerListing
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty card until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.empty-card').textContent
        ).toBe('No broker listing on record.');
    });

    it('DATA BRANCH: renders the listing header and four stat tiles', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.card-title').textContent
        ).toBe('Sugar Land Town Center');
        expect(
            element.shadowRoot.querySelector('.card-sub').textContent
        ).toBe('CBRE · Jane Doe');

        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles.length).toBe(4);
        expect(tiles[0].value).toBe('42 days'); // Days On Market
        expect(tiles[1].value).toBe('Mar 15, 2026'); // List Date
        expect(tiles[2].value).toBe('Apr 10, 2026'); // Call For Offers Date
        expect(tiles[3].value).toBe('3'); // Offers Received
    });

    it('DATA BRANCH: shows the risk badge only when a week label is present', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('Week 6');

        // Re-emit the same listing without a week label.
        getListing.emit({ ...LISTING, weekLabel: null });
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('.risk-badge')).toBeNull();
    });

    it('ERROR BRANCH: keeps the empty card when the wire errors', async () => {
        const element = createComponent();

        getListing.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        expect(element.shadowRoot.querySelector('.empty-card')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
