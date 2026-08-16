/**
 * c-top-largest-deals — @wire-to-Apex suite WITH NavigationMixin.
 * Pattern: WIRE-MOCK TEMPLATE 1 + the lwc-recipes navigation mock (matches
 * c-recent-opportunities, the sibling card on the same home page).
 *
 * Data source: @wire(getTopDeals) from TopDealsController.getTopDeals -> a LIST of deal
 * wrappers { id, name, stage, dealType, assetType, amount, closeDate, days }. The JS maps
 * every row (no client-side slice or sort — the server already applied ORDER BY / LIMIT 5)
 * into a c-list-datatable, with the count in the title; connectedCallback resolves a
 * "View All" URL and the footer link navigates to the Opportunity list view.
 *
 * 🔴 TWO TESTS HERE ARE FALSIFIERS RATHER THAN COVERAGE:
 *
 *   'renders rows in the SERVER order' -> reds if anyone adds a client-side sort. The
 *      fixture is deliberately NOT in Amount order, so a component that re-sorts would
 *      "correct" it and fail.
 *   'does not slice'                   -> reds if anyone re-adds a `.slice(0, 5)`. Capping
 *      in two places means a future change to TOP_N silently only half-applies.
 */
import { createElement } from 'lwc';
import TopLargestDeals from 'c/topLargestDeals';
import getTopDeals from '@salesforce/apex/TopDealsController.getTopDeals';

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
    '@salesforce/apex/TopDealsController.getTopDeals',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

/**
 * Five deals as the SERVER would return them.
 *
 * ⚠ `Harbor Point` (850,000) deliberately sits AFTER `Gateway Plaza` (12,500,000) but
 * BEFORE `Cedar Commons` (4,200,000) — i.e. this list is NOT in Amount order. That is the
 * point: it is how a client-side re-sort is detected.
 */
const DEALS = [
    { id: '0060000000000001', name: 'Gateway Plaza', stage: 'Underwriting', dealType: 'Retail', amount: 12500000, closeDate: '2026-11-30', days: 3 },
    { id: '0060000000000002', name: 'Harbor Point', stage: 'LOI', dealType: 'Land', amount: 850000, closeDate: '2026-09-15', days: 7 },
    { id: '0060000000000003', name: 'Cedar Commons', stage: 'Under Contract (PSA)', dealType: 'Retail', amount: 4200000, closeDate: '2026-10-01', days: 15 },
    { id: '0060000000000004', name: 'Oak Ridge', stage: 'New', dealType: null, amount: null, closeDate: null, days: 1 },
    { id: '0060000000000005', name: 'Pine Tower', stage: 'About to Close', dealType: 'Retail', amount: 600, closeDate: '2026-08-20', days: 40 }
];

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

function title(element) {
    return element.shadowRoot.querySelector('span[slot="title"]').textContent;
}

describe('c-top-largest-deals', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-top-largest-deals', {
            is: TopLargestDeals
        });
        document.body.appendChild(element);
        return element;
    }

    it('EMPTY: shows a zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(title(element)).toBe('Top 5 Largest Deals (0)');
        expect(datatable(element).data).toEqual([]);
    });

    it('DATA BRANCH: renders every row the server returned and counts them', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(5);
        expect(title(element)).toBe('Top 5 Largest Deals (5)');
    });

    it('ORDER: renders rows in the SERVER order and never re-sorts them', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        // The fixture is deliberately NOT in Amount order. A client-side sort would put
        // Cedar Commons (4.2M) second; the server's order puts Harbor Point (850K) there.
        expect(datatable(element).data.map((r) => r.name)).toEqual([
            'Gateway Plaza',
            'Harbor Point',
            'Cedar Commons',
            'Oak Ridge',
            'Pine Tower'
        ]);
    });

    it('does not slice: a server that returned six rows would render six', async () => {
        const element = createComponent();

        // The cap belongs to TopDealsController.TOP_N. A `.slice(0, 5)` here would be a
        // second, drifting copy of it.
        getTopDeals.emit([
            ...DEALS,
            { id: '0060000000000006', name: 'Maple Court', stage: 'New', dealType: 'Land', amount: 300000, closeDate: '2026-12-01', days: 2 }
        ]);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(6);
        expect(title(element)).toBe('Top 5 Largest Deals (6)');
    });

    it('DATA BRANCH: transforms a row (record URL, compact money, ISO close date, age)', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        const first = datatable(element).data[0];
        expect(first.recordUrl).toBe('/lightning/r/Opportunity/0060000000000001/view');
        expect(first.amountLabel).toBe('$12.5M');
        expect(first.age).toBe('3d');

        // The close date passes through VERBATIM. Parsing it into a JS Date would shift the
        // displayed day backwards for every user west of GMT.
        expect(first.closeDateLabel).toBe('2026-11-30');
    });

    it('NULLS: a deal with no amount, deal type or close date renders em dashes, never $0', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        const oakRidge = datatable(element).data[3];
        expect(oakRidge.dealType).toBe('—');
        expect(oakRidge.closeDateLabel).toBe('—');
        // 🔴 NOT '$0'. An un-costed deal is not a worthless one.
        expect(oakRidge.amountLabel).toBe('—');
    });

    it('MONEY: a genuine zero-and-small amount is still rendered as a figure', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        // Guards the null check being written as a falsy check, which would turn 0 into '—'.
        expect(datatable(element).data[4].amountLabel).toBe('$600');
    });

    it('PILLS: an unmapped stage or deal type degrades to the grey fallback, not an error', async () => {
        const element = createComponent();

        getTopDeals.emit([
            { id: '0060000000000009', name: 'Odd One', stage: 'Some Future Stage', dealType: 'Industrial', amount: 100000, closeDate: '2026-10-10', days: 5 }
        ]);
        await Promise.resolve();

        const row = datatable(element).data[0];
        expect(row.stage).toBe('Some Future Stage');
        expect(row.stageWrap).toContain('#eef1f4'); // FALLBACK background
        expect(row.dtWrap).toContain('#eef1f4');
    });

    it('VIEW ALL: clicking the footer link navigates to the Opportunity list view', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('Opportunity');
        expect(pageRef.attributes.actionName).toBe('list');
    });

    it('ERROR BRANCH: renders an inline alert and HIDES the datatable when the wire errors', async () => {
        const element = createComponent();

        // The Apex boundary shape: AuraHandledException -> error.body.message.
        getTopDeals.error({
            message: 'The largest deals could not be loaded. Refresh the page or contact your administrator.'
        });
        await Promise.resolve();

        // The table is hidden rather than left showing stale rows: an error state that still
        // rendered a ranking would assert one the server just refused to confirm.
        expect(datatable(element)).toBeNull();

        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err).not.toBeNull();
        expect(err.getAttribute('role')).toBe('alert');
        expect(err.textContent).toBe(
            'The largest deals could not be loaded. Refresh the page or contact your administrator.'
        );
        expect(title(element)).toBe('Top 5 Largest Deals (0)');
    });

    it('ERROR BRANCH: an error carrying no readable body still shows a message, never undefined', async () => {
        const element = createComponent();

        getTopDeals.error({});
        await Promise.resolve();

        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err.textContent).toBe('Unable to load the largest deals.');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible in the error state', async () => {
        const element = createComponent();

        getTopDeals.error({ message: 'Boom.' });
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
