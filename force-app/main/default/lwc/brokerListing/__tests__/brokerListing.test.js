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

/**
 * ⚠ THE FIXTURE MOVED OFF THE 6-WEEK CLOCK (D27.1 / D28-Q2, 2026-08-10). It used to carry
 * `weekLabel: 'Week 6'` / `daysOnMarket: 42`, which pinned the retired ladder. The payload now
 * carries `tractionBand` / `tractionLabel` / `tractionDetail`, computed server-side by
 * DispositionTractionService — this suite asserts that the card RENDERS what it is given and
 * deliberately re-derives no threshold of its own.
 */
const LISTING = {
    assetName: 'Sugar Land Town Center',
    brokerFirm: 'CBRE',
    contactName: 'Jane Doe',
    tractionBand: 'HARD_STOP',
    tractionLabel: 'Day 71 — Hard Stop: no offers',
    tractionDetail: 'The 60-day marketing period has elapsed with no offers.',
    daysOnMarket: 71,
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
        expect(tiles[0].value).toBe('71 days'); // Days On Market
        expect(tiles[1].value).toBe('Mar 15, 2026'); // List Date
        expect(tiles[2].value).toBe('Apr 10, 2026'); // Call For Offers Date
        expect(tiles[3].value).toBe('3'); // Offers Received
    });

    it('DATA BRANCH: shows the risk badge only when a traction label is present', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('Day 71 — Hard Stop');

        // Re-emit the same listing without a traction label.
        getListing.emit({ ...LISTING, tractionLabel: null });
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('.risk-badge')).toBeNull();
    });

    /**
     * 🔴 THE CLOCK-NEVER-TICKED REGRESSION, PINNED. The retired controller read the hand-keyed
     * Broker_Listing__c.Days_On_Market__c and defaulted a null to 0, so a listing with no
     * marketing clock rendered "0 days" — indistinguishable from "listed today" and the reason
     * a dead clock looked healthy. A null must now render as a dash.
     */
    it('DATA BRANCH: a null days-on-market renders a dash, never "0 days"', async () => {
        const element = createComponent();

        getListing.emit({
            ...LISTING,
            daysOnMarket: null,
            tractionBand: 'NOT_LISTED',
            tractionLabel: 'Not listed yet',
            isAtRisk: false
        });
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles[0].value).toBe('—');
    });

    it('ERROR BRANCH: renders an inline error state (not the data card) when the wire errors', async () => {
        const element = createComponent();

        getListing.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        const err = element.shadowRoot.querySelector('.bl-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
