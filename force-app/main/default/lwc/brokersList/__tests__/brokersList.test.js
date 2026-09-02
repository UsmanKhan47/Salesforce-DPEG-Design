/**
 * @wire-to-Apex (no-parameter) suite for c-brokers-list.
 * Emits the BrokerController.BrokerHub wrapper and asserts the (count),
 * the top-5 slice passed to c-list-datatable, and the money/pill formatting.
 * NavigationMixin GenerateUrl is stub-resolved so View All renders.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * TRANCHE 4 ITEM 4 (2026-09-01) — SORT AND FILTER. WHAT THIS SUITE CAN AND CANNOT PROVE.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * CAN: the sort FUNCTION (that it orders on raw values, before the slice), the filter function,
 * the header count string, and the three attributes the datatable needs (`sorted-by`,
 * `sorted-direction`, `onsort`).
 *
 * 🔴 CANNOT: that a sortable column HEADER renders and responds to a click. `c-list-datatable`
 * resolves to a stub that renders nothing, so every assertion below reads props off the stub
 * element. The `Status` column is a CUSTOM `pill` cell type marked `sortable`, a combination this
 * repo deployed once in Tranche 2 and has never watched render. That is a BROWSER check and it is
 * still open — do not let a green run here be read as closing it.
 *
 * 🔴 AND THE PRE-EXISTING TOP-5 TEST PASSES VACUOUSLY UNDER SORTING. `sortedBy` is undefined until
 * a header is clicked, so the default order is the server's and the old assertion holds whatever
 * the sort code does. `sortReordersTheTop5` below is the non-vacuous replacement: its fixture is
 * built so the closed-volume order and the alphabetical order put DIFFERENT brokers in the top
 * five, and it asserts the swap.
 */
import { createElement } from 'lwc';
import BrokersList from 'c/brokersList';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

jest.mock(
    '@salesforce/apex/BrokerController.getBrokerHub',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches BrokerController.BrokerRow[]. Six brokers so the top-5 slice is exercised.
function broker(n, over) {
    return {
        id: `0035g00000Brk${n}AAA`,
        name: `Broker ${n}`,
        firm: `Firm ${n}`,
        specialty: 'Retail',
        status: n % 2 === 0 ? 'Inactive' : 'Active',
        activeListings: n,
        offers: n + 1,
        closedVolume: over,
        avgDom: 45
    };
}
const HUB = {
    stats: {
        totalFirms: 6,
        totalBrokers: 6,
        activeBrokers: 3,
        activeListings: 21,
        offersReceived: 27,
        closedVolume: 12000000
    },
    brokers: [
        broker(1, 5000000),
        broker(2, 3000000),
        broker(3, 1500000),
        broker(4, 900000),
        broker(5, 250000),
        broker(6, 50000)
    ],
    topBrokers: []
};

/**
 * 🔴 THE NON-VACUOUS SORTING FIXTURE, AND EVERY VALUE IN IT IS CHOSEN TO BREAK A NAIVE SORT.
 *
 * Arrives in SERVER order (closed volume DESC), exactly as `ContactSelector
 * .selectBrokersRankedByClosedVolume` returns it. The properties that matter:
 *
 *  - `Zeta` is FIRST by volume and LAST alphabetically, and `Alpha` is the reverse. So an
 *    ascending name sort must PUSH Zeta out of the top five and PULL Alpha in — a swap that is
 *    impossible if the sort is applied after `slice(0, 5)`.
 *  - the numeric columns carry 1, 2 and 10 so a lexicographic sort ('1','10','2') is visibly wrong.
 *  - closed volumes straddle $10M so `fmtMoney` produces both '$12M' (0 dp) and '$2.0M' (1 dp),
 *    which is the pair that makes a string sort put '$12M' before '$2.0M'.
 *  - the two statuses alternate so a rank sort and an alphabetical sort of the pill text would
 *    coincidentally agree — which is why the status test asserts the RANK ORDER of a specific pair
 *    rather than just "it changed".
 */
const SORT_HUB = {
    stats: HUB.stats,
    brokers: [
        { ...broker(1, 12000000), name: 'Zeta',    firm: 'Zeta Realty',    activeListings: 2,  offers: 10, status: 'Inactive' },
        { ...broker(2, 9000000),  name: 'Yankee',  firm: 'Yankee Realty',  activeListings: 10, offers: 2,  status: 'Active' },
        { ...broker(3, 8000000),  name: 'Xray',    firm: 'Xray Realty',    activeListings: 1,  offers: 1,  status: 'Inactive' },
        { ...broker(4, 7000000),  name: 'Whiskey', firm: 'Whiskey Realty', activeListings: 4,  offers: 4,  status: 'Active' },
        { ...broker(5, 6000000),  name: 'Victor',  firm: 'Victor Realty',  activeListings: 5,  offers: 5,  status: 'Inactive' },
        { ...broker(6, 2000000),  name: 'Alpha',   firm: 'Alpha Realty',   activeListings: 6,  offers: 6,  status: 'Active' }
    ],
    topBrokers: []
};

describe('c-brokers-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-brokers-list', { is: BrokersList });
        document.body.appendChild(element);
        return element;
    }

    const table = (el) => el.shadowRoot.querySelector('c-list-datatable');
    const title = (el) => el.shadowRoot.querySelector('span[slot="title"]').textContent;
    const names = (el) => table(el).data.map((r) => r.name);

    /** Drives the datatable's `onsort` exactly as LightningDatatable does. */
    async function sortBy(el, fieldName, sortDirection) {
        table(el).dispatchEvent(
            new CustomEvent('sort', { detail: { fieldName, sortDirection } })
        );
        await Promise.resolve();
    }

    async function search(el, value) {
        const input = el.shadowRoot.querySelector('.bkl-search');
        input.value = value;
        input.dispatchEvent(new CustomEvent('change', { target: { value } }));
        await Promise.resolve();
    }

    async function filterStatus(el, value) {
        el.shadowRoot
            .querySelector('.bkl-status-filter')
            .dispatchEvent(new CustomEvent('change', { detail: { value } }));
        await Promise.resolve();
    }

    it('renders an empty datatable and (0) count before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(title(element)).toBe('Brokers (0)');
        expect(table(element).data).toEqual([]);
    });

    it('DATA BRANCH: shows the full count but only the top-5 rows in the table', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        // count = full list length (6); table shows the top-5 slice.
        expect(title(element)).toBe('Brokers (6)');
        expect(table(element).data.length).toBe(5);
    });

    it('DATA BRANCH: formats money and derives the status pill styles', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        const first = table(element).data[0];
        expect(first.name).toBe('Broker 1');
        expect(first.volumeLabel).toBe('$5.0M'); //  5,000,000 -> $5.0M (1 dp under $10M)
        expect(first.status).toBe('Active');
        expect(first.recordUrl).toBe('/lightning/r/Contact/0035g00000Brk1AAA/view');
        // 250,000 -> $250K
        expect(table(element).data[4].volumeLabel).toBe('$250K');
    });

    it('ERROR BRANCH: renders an inline error state (not the datatable) when the wire errors', async () => {
        const element = createComponent();

        getBrokerHub.error();
        await Promise.resolve();

        expect(table(element)).toBeNull();
        const err = element.shadowRoot.querySelector('.bkl-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // SORTING (Tranche 4 item 4)
    // ══════════════════════════════════════════════════════════════════════════════════════════

    it('SORT: every column is sortable and the sort attributes start unset', async () => {
        const element = createComponent();

        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        const cols = table(element).columns;
        expect(cols.map((c) => c.fieldName)).toEqual([
            'recordUrl',
            'firm',
            'activeListings',
            'offers',
            'volumeLabel',
            'status'
        ]);
        expect(cols.every((c) => c.sortable === true)).toBe(true);
        // 🔴 `sorted-by` MUST START UNDEFINED. A default would put the table into user-sorted mode
        // before the user has sorted anything and would silently retire the server's ranking.
        expect(table(element).sortedBy).toBeUndefined();
    });

    it('SORT: the untouched order is the SERVER order, byte-identical to before this change', async () => {
        const element = createComponent();

        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        expect(names(element)).toEqual(['Zeta', 'Yankee', 'Xray', 'Whiskey', 'Victor']);
    });

    it('🔴 SORT: sorting reorders the FULL list before the top-5 slice, not the slice', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();
        expect(names(element)).not.toContain('Alpha'); // PREMISE: Alpha is outside the default top 5

        await sortBy(element, 'recordUrl', 'asc');

        // 🔴 THE WHOLE POINT OF DECISION D-6. Alpha is 6th by closed volume and 1st
        // alphabetically; Zeta is the reverse. Sorting AFTER the slice could never produce this —
        // it would reorder the five rows already chosen by volume and Alpha would stay invisible.
        expect(names(element)[0]).toBe('Alpha');
        expect(names(element)).not.toContain('Zeta');
        expect(names(element).length).toBe(5);
        // The header still reports the full population; only the WINDOW moved.
        expect(title(element)).toBe('Brokers (6)');
    });

    it('🔴 SORT: the Broker column sorts by NAME, never by the record URL it displays', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await sortBy(element, 'recordUrl', 'desc');

        // Every recordUrl shares the '/lightning/r/Contact/0035g00000Brk<n>AAA/view' shape, so a
        // sort on the bound field would order by record ID.
        //
        // 🔴 THE FULL LIST IS ASSERTED, NOT JUST POSITION 0, AND THAT IS DELIBERATE. On this
        // fixture the descending-name order and the server's closed-volume order AGREE on the
        // first five rows, so `names[0] === 'Zeta'` is TRUE EVEN IF NO SORT RUNS AT ALL. That is
        // not a hypothetical: the first implementation of this component sorted before mapping,
        // every non-name column silently kept the server order, and a position-0 assertion here
        // went green throughout. The ASCENDING case in the test above is what discriminates for
        // this column; this one pins the descending direction without pretending to be a
        // falsifier on its own.
        expect(names(element)).toEqual(['Zeta', 'Yankee', 'Xray', 'Whiskey', 'Victor']);
    });

    it('🔴 SORT: numeric columns sort numerically (1, 2, 10 — not "1", "10", "2")', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await sortBy(element, 'activeListings', 'asc');

        // Displayed values are String(n). A lexicographic sort gives '1','10','2','4','5';
        // the raw-value sort gives 1,2,4,5,6 and puts 10 last (outside the top 5).
        expect(table(element).data.map((r) => r.activeListings)).toEqual(['1', '2', '4', '5', '6']);

        await sortBy(element, 'offers', 'desc');
        expect(table(element).data.map((r) => r.offers)).toEqual(['10', '6', '5', '4', '2']);
    });

    it('🔴 SORT: Closed Volume sorts by the raw decimal, not by "$12M" vs "$2.0M"', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await sortBy(element, 'volumeLabel', 'asc');

        // fmtMoney renders 12,000,000 as '$12M' (0 dp) and 2,000,000 as '$2.0M' (1 dp), so a
        // string sort would place '$12M' FIRST. Ascending on the raw value must start at $2.0M.
        expect(table(element).data[0].volumeLabel).toBe('$2.0M');
        expect(table(element).data[0].name).toBe('Alpha');
        expect(table(element).data[4].volumeLabel).toBe('$9.0M');
    });

    it('🔴 SORT: the pill column sorts by RANK, not by the pill text', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await sortBy(element, 'status', 'asc');

        // Active = 0, Inactive = 1. Ascending must group every Active row first, and — because
        // Array.prototype.sort is stable — preserve the server's volume order within each group.
        expect(table(element).data.map((r) => r.status)).toEqual([
            'Active',
            'Active',
            'Active',
            'Inactive',
            'Inactive'
        ]);
        expect(names(element).slice(0, 3)).toEqual(['Yankee', 'Whiskey', 'Alpha']);
    });

    it('SORT: nulls sort LAST in both directions rather than burying the real values', async () => {
        const element = createComponent();
        getBrokerHub.emit({
            ...SORT_HUB,
            brokers: [
                { ...SORT_HUB.brokers[0], name: 'HasVolume', closedVolume: 5000000 },
                { ...SORT_HUB.brokers[1], name: 'NoVolume', closedVolume: null },
                { ...SORT_HUB.brokers[2], name: 'AlsoHas', closedVolume: 1000000 }
            ]
        });
        await Promise.resolve();

        await sortBy(element, 'volumeLabel', 'desc');
        expect(names(element)).toEqual(['HasVolume', 'AlsoHas', 'NoVolume']);

        await sortBy(element, 'volumeLabel', 'asc');
        // 🔴 STILL LAST. A naive comparator would float the null to the top here, burying nothing
        // on ascending but burying the LARGEST values on the descending pass above.
        expect(names(element)).toEqual(['AlsoHas', 'HasVolume', 'NoVolume']);
        expect(table(element).data[2].volumeLabel).toBe('—');
    });

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // FILTERING (Tranche 4 item 4, decision D-7)
    // ══════════════════════════════════════════════════════════════════════════════════════════

    it('FILTER: search matches the broker name, case-insensitively', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await search(element, 'alph');

        expect(names(element)).toEqual(['Alpha']);
    });

    it('FILTER: search ALSO matches the firm, not only the name', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        // 'Whiskey Realty' is the firm; the broker's own name does not contain 'whiskey r'.
        await search(element, 'whiskey r');

        expect(names(element)).toEqual(['Whiskey']);
    });

    it('🔴 FILTER: the header count reads "n of m" while filtered, and the bare total otherwise', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();
        expect(title(element)).toBe('Brokers (6)');

        await search(element, 'realty'); // matches every firm
        expect(title(element)).toBe('Brokers (6 of 6)');

        await search(element, 'alpha');
        // A header reading "Brokers (6)" above a one-row table contradicts the table beneath it.
        expect(title(element)).toBe('Brokers (1 of 6)');

        await search(element, '');
        expect(title(element)).toBe('Brokers (6)');
    });

    it('FILTER: the status combobox narrows to one status and composes with the search', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await filterStatus(element, 'Active');
        expect(names(element)).toEqual(['Yankee', 'Whiskey', 'Alpha']);
        expect(title(element)).toBe('Brokers (3 of 6)');

        await search(element, 'alpha');
        expect(names(element)).toEqual(['Alpha']);
        expect(title(element)).toBe('Brokers (1 of 6)');
    });

    it('🔴 FILTER: filtering happens BEFORE the sort and the slice', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await filterStatus(element, 'Inactive');
        await sortBy(element, 'recordUrl', 'asc');

        // Only the three Inactive brokers survive, ordered by name. If the filter ran after the
        // slice, the table would show at most the Inactive rows that happened to be in the
        // volume-ordered top five — and Victor (5th by volume) would be at risk of vanishing.
        expect(names(element)).toEqual(['Victor', 'Xray', 'Zeta']);
    });

    it('FILTER: a search matching nothing shows a message instead of an empty table', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await search(element, 'nobody-by-this-name');

        // A datatable rendering only its header row reads as a rendering fault, not as a result.
        expect(table(element)).toBeNull();
        const empty = element.shadowRoot.querySelector('.bkl-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toContain('No brokers match');
        expect(title(element)).toBe('Brokers (0 of 6)');
    });

    it('FILTER: an empty payload shows the table, not the no-matches message', async () => {
        const element = createComponent();

        getBrokerHub.emit({ ...SORT_HUB, brokers: [] });
        await Promise.resolve();

        // "no brokers exist" and "your filter excluded them all" are different states. Only the
        // second gets the message; the first keeps the datatable's own empty rendering.
        expect(element.shadowRoot.querySelector('.bkl-empty')).toBeNull();
        expect(table(element)).not.toBeNull();
        expect(title(element)).toBe('Brokers (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getBrokerHub.emit(HUB);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible after sorting and filtering', async () => {
        const element = createComponent();
        getBrokerHub.emit(SORT_HUB);
        await Promise.resolve();

        await sortBy(element, 'volumeLabel', 'desc');
        await filterStatus(element, 'Active');

        // The controls are the new markup, so the pre-existing a11y test above cannot cover them:
        // it runs on a card whose filter row has never been touched. This one also covers the
        // no-matches branch's `role="status"`.
        await expect(element).toBeAccessible();

        await search(element, 'nobody-by-this-name');
        await expect(element).toBeAccessible();
    });
});
