/**
 * c-recent-opportunities — @wire-to-Apex suite WITH NavigationMixin.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1) + the lwc-recipes
 * navigation mock (matches c-broker-scorecard).
 *
 * Data source: @wire(getRecentOpportunities) from
 * OpportunityFunnelController.getRecentOpportunities -> a LIST of deal wrappers
 * { id, name, stage, dealType, price, noi, days }. The JS feeds the first 5 rows to
 * a c-list-datatable with the count in the title; connectedCallback resolves a
 * "View All" URL and the footer link navigates to the Opportunity list view.
 *
 * lightning/navigation is mocked so [Navigate] dispatches a catchable 'navigate'
 * event. Rows are asserted via the datatable's `data` @api.
 */
import { createElement } from 'lwc';
import RecentOpportunities from 'c/recentOpportunities';
import getRecentOpportunities from '@salesforce/apex/OpportunityFunnelController.getRecentOpportunities';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', { detail: { pageReference } })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('https://example.com/opp-list');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/OpportunityFunnelController.getRecentOpportunities',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// 6 recent opportunities -> the JS slices to the first 5.
const OPPS = [
    { id: '0060000000000001', name: 'Gateway Plaza', stage: 'Underwriting', dealType: 'Retail', price: 4200000, noi: 310000, days: 3 },
    { id: '0060000000000002', name: 'Harbor Point', stage: 'LOI', dealType: 'Land', price: 850000, noi: null, days: 7 },
    { id: '0060000000000003', name: 'Cedar Commons', stage: 'PSA', dealType: 'Retail', price: 12500000, noi: 900000, days: 15 },
    { id: '0060000000000004', name: 'Oak Ridge', stage: 'New', dealType: null, price: null, noi: null, days: 1 },
    { id: '0060000000000005', name: 'Pine Tower', stage: 'Closed Won', dealType: 'Retail', price: 6000000, noi: 450000, days: 40 },
    { id: '0060000000000006', name: 'Maple Court', stage: 'Under Review', dealType: 'Land', price: 300000, noi: null, days: 2 }
];

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

describe('c-recent-opportunities', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-recent-opportunities', {
            is: RecentOpportunities
        });
        document.body.appendChild(element);
        return element;
    }

    it('EMPTY: shows a zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Opportunities (0)');
        expect(datatable(element).data).toEqual([]);
    });

    it('DATA BRANCH: caps the datatable at the 5 most recent and counts them', async () => {
        const element = createComponent();

        getRecentOpportunities.emit(OPPS);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(5); // 6 emitted, sliced to 5
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Opportunities (5)');
    });

    it('DATA BRANCH: transforms a row (record URL, compact money, age, dealType fallback)', async () => {
        const element = createComponent();

        getRecentOpportunities.emit(OPPS);
        await Promise.resolve();

        const first = datatable(element).data[0];
        expect(first.recordUrl).toBe(
            '/lightning/r/Opportunity/0060000000000001/view'
        );
        expect(first.priceLabel).toBe('$4.2M'); // 4,200,000
        expect(first.noiLabel).toBe('$310K'); // 310,000
        expect(first.age).toBe('3d');

        // Null dealType / price / noi degrade to em dashes.
        const oakRidge = datatable(element).data[3];
        expect(oakRidge.dealType).toBe('—');
        expect(oakRidge.priceLabel).toBe('—');
        expect(oakRidge.noiLabel).toBe('—');
    });

    it('VIEW ALL: clicking the footer link navigates to the Opportunity list view', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getRecentOpportunities.emit(OPPS);
        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('Opportunity');
        expect(pageRef.attributes.actionName).toBe('list');
    });

    it('ERROR BRANCH: renders an inline error state and hides the datatable when the wire errors', async () => {
        const element = createComponent();

        getRecentOpportunities.error({ message: 'Opportunity feed unavailable.' });
        await Promise.resolve();

        expect(datatable(element)).toBeNull();
        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Opportunity feed unavailable.');
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Opportunities (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecentOpportunities.emit(OPPS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
