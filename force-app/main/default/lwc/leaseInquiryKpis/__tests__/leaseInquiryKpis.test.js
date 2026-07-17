/**
 * leaseInquiryKpis — Lease Activity Tracker home KPI strip.
 * WIRE-MOCK TEMPLATE 1 (@wire to Apex, no params) applied.
 *
 * Data source: @wire(getHomeKpis) from LeaseInquiryController (NOT opened/edited).
 * DTO shape ({ active, waitingLandlord, stalled, signed }) is derived only from
 * leaseInquiryKpis.js. The component always renders four c-stat-card children;
 * before/without data every value defaults to 0.
 */
import { createElement } from 'lwc';
import LeaseInquiryKpis from 'c/leaseInquiryKpis';
import getHomeKpis from '@salesforce/apex/LeaseInquiryController.getHomeKpis';

jest.mock(
    '@salesforce/apex/LeaseInquiryController.getHomeKpis',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const KPIS = { active: 12, waitingLandlord: 5, stalled: 3, signed: 8 };

describe('c-lease-inquiry-kpis', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lease-inquiry-kpis', {
            is: LeaseInquiryKpis
        });
        document.body.appendChild(element);
        return element;
    }

    function cards(element) {
        return [...element.shadowRoot.querySelectorAll('c-stat-card')];
    }

    it('EMPTY BRANCH: renders four zeroed cards before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const c = cards(element);
        expect(c.length).toBe(4);
        expect(c.map((x) => x.value)).toEqual([0, 0, 0, 0]);
        expect(c.map((x) => x.label)).toEqual([
            'Active Inquiries',
            'Waiting on Landlord',
            'Stalled (over 14d)',
            'Signed Leases (YTD)'
        ]);
    });

    it('DATA BRANCH: pushes each KPI onto its stat card', async () => {
        const element = createComponent();

        getHomeKpis.emit(KPIS);
        await Promise.resolve();

        const c = cards(element);
        expect(c.map((x) => x.value)).toEqual([12, 5, 3, 8]);
        // icon-name passes through to each card.
        expect(c[2].iconName).toBe('utility:warning');
    });

    it('DATA BRANCH: missing KPI keys fall back to 0', async () => {
        const element = createComponent();

        getHomeKpis.emit({ active: 4 });
        await Promise.resolve();

        expect(cards(element).map((x) => x.value)).toEqual([4, 0, 0, 0]);
    });

    it('ERROR BRANCH: keeps the zeroed cards when the wire errors', async () => {
        const element = createComponent();

        getHomeKpis.error();
        await Promise.resolve();

        expect(cards(element).map((x) => x.value)).toEqual([0, 0, 0, 0]);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getHomeKpis.emit(KPIS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
