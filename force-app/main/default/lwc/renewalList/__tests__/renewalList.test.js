/**
 * c-renewal-list — @wire-to-Apex (no-param) list on the Lease Renewals home.
 *
 * Data source: @wire(getRecentRenewals) on LeaseRenewalController. Mixes in
 * NavigationMixin (GenerateUrl stub resolves a Promise, so connectedCallback
 * settles). The wired wrapper exposes
 * { id, tenant, property, leaseEnd, daysToExpiry, closed, stage,
 *   daysSinceContact, nonResponsive }. daysToExpiry is a pre-computed integer
 * from Apex — the JS never calls new Date() — so the "days left" pill is stable.
 * Derived rows are handed to the shared c-list-datatable, inspected here via its
 * public `data` property.
 */
import { createElement } from 'lwc';
import RenewalList from 'c/renewalList';
import getRecentRenewals from '@salesforce/apex/LeaseRenewalController.getRecentRenewals';

jest.mock(
    '@salesforce/apex/LeaseRenewalController.getRecentRenewals',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RENEWALS = [
    {
        id: 'a2R5g000000RnwAEAS',
        tenant: 'Blue Bottle Coffee',
        property: 'Northgate Commons',
        leaseEnd: '2026-09-30',
        daysToExpiry: 20,
        closed: false,
        stage: 'Negotiating',
        daysSinceContact: 18,
        nonResponsive: true
    },
    {
        id: 'a2R5g000000RnwBEAS',
        tenant: 'Sunbelt Rentals',
        property: 'Midtown Tower',
        leaseEnd: '2025-12-31',
        daysToExpiry: -60,
        closed: true,
        stage: 'Renewed',
        daysSinceContact: 3,
        nonResponsive: false
    }
];

describe('c-renewal-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-renewal-list', {
            is: RenewalList
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders a zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Recent Renewals (0)');

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table).not.toBeNull();
        expect(table.data.length).toBe(0);
    });

    it('DATA BRANCH: feeds derived rows into the datatable and updates the count', async () => {
        const element = createComponent();

        getRecentRenewals.emit(RENEWALS);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Recent Renewals (2)');

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.length).toBe(2);

        // Open renewal: positive daysToExpiry -> "Nd left"; non-responsive
        // tenant surfaces the days-since-contact pill.
        expect(table.data[0].daysText).toBe('20d left');
        expect(table.data[0].contactText).toBe('18d ago');
        expect(table.data[0].stage).toBe('Negotiating');

        // Closed + Renewed collapses the days/contact pills to terminal labels.
        expect(table.data[1].daysText).toBe('Renewed');
        expect(table.data[1].contactText).toBe('—');
    });

    it('ERROR BRANCH: renders an inline error state and hides the datatable when the wire errors', async () => {
        const element = createComponent();

        getRecentRenewals.error({ message: 'Renewal feed unavailable.' });
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Renewal feed unavailable.');
        expect(
            element.shadowRoot.querySelector('.hdr-title').textContent
        ).toBe('Recent Renewals (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecentRenewals.emit(RENEWALS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
