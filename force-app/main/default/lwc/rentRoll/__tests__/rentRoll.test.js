/**
 * c-rent-roll — @wire-to-Apex (parameterised by $recordId) READ-ONLY Yardi mirror.
 *
 * Data source: @wire(getRentRoll, { propertyAssetId: '$recordId' }) on
 * RentRollController, returning { summary, units[] } where each unit may carry a
 * steps[] rent schedule. getRentRoll is registered as an Apex test wire adapter;
 * .emit() drives loading -> empty / data, .error() drives the error card.
 *
 * The component has four visible states: error, loading (no data + no error),
 * data-with-no-units, and data-with-units (the table). Each is asserted below.
 *
 * DATE-STABILITY: the `rows` getter compares lease dates against `new Date()` to
 * pick a lease-expiry dot colour and to flag the "active now" rent step. Those
 * are purely cosmetic, so this suite deliberately asserts only on date-invariant
 * output (suite #, tenant, formatted rent, counts) and never on dot colour or
 * step-active state — keeping every assertion stable across run dates. The
 * accessibility assertion runs on the table-free empty-units state to stay
 * independent of the data grid's day-sensitive markup.
 */
import { createElement } from 'lwc';
import RentRoll from 'c/rentRoll';
import getRentRoll from '@salesforce/apex/RentRollController.getRentRoll';

jest.mock(
    '@salesforce/apex/RentRollController.getRentRoll',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a3P5g000000AssetEAK';

const SUMMARY = {
    totalSqFt: 25000,
    occupiedSqFt: 18000,
    vacantSqFt: 7000,
    occupiedPct: 72,
    vacantPct: 28,
    monthlyRent: 62500,
    occupiedCount: 2,
    vacantCount: 1,
    blendedPsf: 30,
    nnnMonthlyTotal: 8000,
    lastSynced: '2026-03-14T06:00:00.000Z'
};

const EMPTY_DATA = {
    summary: { ...SUMMARY, totalSqFt: 0, occupiedSqFt: 0, vacantSqFt: 0, monthlyRent: 0, occupiedCount: 0, vacantCount: 0 },
    units: []
};

const RENT_ROLL = {
    summary: SUMMARY,
    units: [
        {
            unitId: 'a3U5g000000Unit1EAG',
            suite: '100',
            tenant: 'Blue Bottle Coffee',
            status: 'Occupied',
            squareFeet: 10000,
            currentRent: 30000,
            currentRentPsf: 36,
            leaseStart: '2022-01-01',
            leaseEnd: '2027-12-31',
            nnnTax: 2000,
            nnnInsurance: 1000,
            nnnCam: 1500,
            nnnMonthlyTotal: 4500,
            nnnPsf: 5.4,
            steps: [
                {
                    periodStart: '2022-01-01',
                    periodEnd: '2027-12-31',
                    periodLabel: 'Years 1-6',
                    monthlyRent: 30000,
                    rentPsf: 36,
                    stepType: 'Base'
                }
            ]
        },
        {
            unitId: 'a3U5g000000Unit2EAG',
            suite: '200',
            tenant: 'Sunbelt Rentals',
            status: 'Occupied',
            squareFeet: 8000,
            currentRent: 32500,
            currentRentPsf: 48.75,
            leaseStart: '2023-06-01',
            leaseEnd: '2028-05-31',
            nnnTax: 1500,
            nnnInsurance: 800,
            nnnCam: 1200,
            nnnMonthlyTotal: 3500,
            nnnPsf: 5.25,
            steps: []
        },
        {
            unitId: 'a3U5g000000Unit3EAG',
            suite: '300',
            tenant: null,
            status: 'Vacant',
            squareFeet: 7000,
            currentRent: null,
            askingRentPsf: 34,
            estimatedNnnPsf: 4.8,
            steps: []
        }
    ]
};

describe('c-rent-roll', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-rent-roll', { is: RentRoll });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('LOADING: shows the spinner before the wire settles', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('lightning-spinner')
        ).not.toBeNull();
        expect(element.shadowRoot.querySelector('table')).toBeNull();
    });

    it('ERROR BRANCH: renders the error card when the wire errors', async () => {
        const element = createComponent();

        getRentRoll.error({ message: 'Insufficient access on Unit__c.' });
        await Promise.resolve();

        const errCard = element.shadowRoot.querySelector('.state-card--error');
        expect(errCard).not.toBeNull();
        expect(errCard.textContent).toContain('Rent roll could not be loaded');
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('EMPTY DATA: renders KPI cards and the "no data yet" notice', async () => {
        const element = createComponent();

        getRentRoll.emit(EMPTY_DATA);
        await Promise.resolve();

        // Four summary KPI stat cards render regardless of unit count.
        expect(
            element.shadowRoot.querySelectorAll('c-stat-card').length
        ).toBe(4);
        // No table, but the empty-state card is shown.
        expect(element.shadowRoot.querySelector('table')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.state-card').textContent
        ).toBe('No rent roll data yet — units sync from Yardi.');
    });

    it('DATA BRANCH: renders one table row per unit with stable values', async () => {
        const element = createComponent();

        getRentRoll.emit(RENT_ROLL);
        await Promise.resolve();

        const bodyRows = element.shadowRoot.querySelectorAll('tbody tr');
        expect(bodyRows.length).toBe(3); // no rows expanded by default

        const suites = [...element.shadowRoot.querySelectorAll('.suite')].map(
            (el) => el.textContent
        );
        expect(suites).toEqual(['100', '200', '300']);

        const tenants = [...element.shadowRoot.querySelectorAll('.tenant')].map(
            (el) => el.textContent
        );
        expect(tenants).toEqual([
            'Blue Bottle Coffee',
            'Sunbelt Rentals',
            '— Vacant —'
        ]);

        // Occupied rent formats as money; vacant unit shows an em dash.
        const rentCells = [
            ...element.shadowRoot.querySelectorAll('td.strong')
        ].map((el) => el.textContent);
        expect(rentCells[0]).toContain('30,000');
        expect(rentCells[2]).toBe('—');

        // Card title reflects the unit count.
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toContain('(3)');
    });

    it('DATA BRANCH: expands a unit to reveal its rent-step schedule', async () => {
        const element = createComponent();

        getRentRoll.emit(RENT_ROLL);
        await Promise.resolve();

        // Click the first (occupied) row to expand its schedule panel.
        const firstRow = element.shadowRoot.querySelector('tbody tr');
        firstRow.click();
        await Promise.resolve();

        // Expanding adds a panel row containing the rent-step sub-table.
        expect(element.shadowRoot.querySelector('.panel')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.panel-title').textContent
        ).toContain('Blue Bottle Coffee');
    });

    it('is accessible (empty-units state, table-free)', async () => {
        const element = createComponent();

        getRentRoll.emit(EMPTY_DATA);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
