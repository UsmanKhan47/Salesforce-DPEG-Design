/**
 * c-top-largest-deals — @wire-to-Apex suite WITH NavigationMixin.
 * Pattern: WIRE-MOCK TEMPLATE 1 + the lwc-recipes navigation mock (matches
 * c-recent-opportunities, the sibling card on the same home page).
 *
 * 🔴 THE CARD WAS RE-RANKED AND CUT TO TWO COLUMNS ON 2026-08-17 (user decision). It used
 * to render six columns from a wrapper of eight members and rank on `Amount`. The wire
 * contract is now a LIST of { id, name, askingPrice } and the card renders exactly two
 * columns: Property Name (a url column linking to the record, labelled from `name`) and
 * Asking Price. The removed PILLS test went with the Stage and Deal Type columns.
 *
 * 🔴 THREE TESTS HERE ARE FALSIFIERS RATHER THAN COVERAGE:
 *
 *   'COLUMNS: exactly two'  -> reds if a removed column creeps back, or if the Property Name
 *      column stops being a `url` type (the link is the part that would be silently lost).
 *   'renders rows in the SERVER order' -> reds if anyone adds a client-side sort. The
 *      fixture is deliberately NOT in asking-price order, so a component that re-sorts would
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
 * BEFORE `Cedar Commons` (4,200,000) — i.e. this list is NOT in asking-price order. That is
 * the point: it is how a client-side re-sort is detected.
 *
 * ⚠ The wrapper carries THREE members. If a fixture here ever grows a fourth, check that
 * `TopDealsController.TopDealRow` actually sends it — a test fixture is not the contract.
 */
const DEALS = [
    { id: '0060000000000001', name: 'Gateway Plaza', askingPrice: 12500000 },
    { id: '0060000000000002', name: 'Harbor Point', askingPrice: 850000 },
    { id: '0060000000000003', name: 'Cedar Commons', askingPrice: 4200000 },
    { id: '0060000000000004', name: 'Oak Ridge', askingPrice: null },
    { id: '0060000000000005', name: 'Pine Tower', askingPrice: 600 }
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

    it('COLUMNS: exactly two — a Property Name link and an Asking Price', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        const columns = datatable(element).columns;
        expect(columns.map((c) => c.label)).toEqual(['Property Name', 'Asking Price']);

        // 🔴 The link is the part a "simplification" would drop silently. "Property Name" is
        // Opportunity.Name relabelled (user decision) — it must stay a url column pointing at
        // the record, with `name` as the visible label.
        expect(columns[0].type).toBe('url');
        expect(columns[0].fieldName).toBe('recordUrl');
        expect(columns[0].typeAttributes.label.fieldName).toBe('name');

        expect(columns[1].fieldName).toBe('askingPriceLabel');
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

        // The fixture is deliberately NOT in asking-price order. A client-side sort would put
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
            { id: '0060000000000006', name: 'Maple Court', askingPrice: 300000 }
        ]);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(6);
        expect(title(element)).toBe('Top 5 Largest Deals (6)');
    });

    it('DATA BRANCH: transforms a row into a record URL and a compact asking price', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        const first = datatable(element).data[0];
        expect(first.recordUrl).toBe('/lightning/r/Opportunity/0060000000000001/view');
        expect(first.name).toBe('Gateway Plaza');
        expect(first.askingPriceLabel).toBe('$12.5M');

        // Thousands round to K, matching the sibling cards' currency presentation.
        expect(datatable(element).data[1].askingPriceLabel).toBe('$850K');
    });

    it('NULLS: a deal with no asking price renders an em dash, never $0', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        // 🔴 NOT '$0'. An unpriced deal is not one the seller wants nothing for. The server
        // sorts these last (ORDER BY ... NULLS LAST) for the same reason.
        expect(datatable(element).data[3].askingPriceLabel).toBe('—');
    });

    it('MONEY: a genuine small asking price is still rendered as a figure', async () => {
        const element = createComponent();

        getTopDeals.emit(DEALS);
        await Promise.resolve();

        // Guards the null check being written as a falsy check, which would turn 0 into '—'.
        expect(datatable(element).data[4].askingPriceLabel).toBe('$600');
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
