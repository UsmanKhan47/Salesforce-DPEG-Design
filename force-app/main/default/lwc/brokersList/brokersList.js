import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

// [background, dot] per broker status for the soft pills.
const STATUS = {
    Active:   ['#e8f5e9', '#43A047'],
    Inactive: ['#eceff1', '#90A4AE']
};
const FALLBACK = ['#eef1f4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

/**
 * Status RANK for sorting — never the pill's own text.
 *
 * 'Active' and 'Inactive' happen to sort correctly alphabetically today, which is exactly what
 * makes a text sort dangerous here: it would look right until a third value ('Dormant', 'Pending')
 * landed between them alphabetically and nowhere near them in meaning. The rank says what the
 * column MEANS; the alphabet is a coincidence.
 */
const STATUS_RANK = { Active: 0, Inactive: 1 };
const STATUS_RANK_UNKNOWN = 2;

// Rows shown in the card. The rest are reachable via View All.
const VISIBLE_ROWS = 5;

const STATUS_FILTER_ALL = 'All';

function fmtMoney(n) {
    if (n == null) {
        return '—';
    }
    if (n >= 1000000) {
        return '$' + (n / 1000000).toFixed(n >= 10000000 ? 0 : 1) + 'M';
    }
    if (n >= 1000) {
        return '$' + Math.round(n / 1000) + 'K';
    }
    return '$' + n;
}

/**
 * ⚠ EVERY COLUMN IS `sortable`, AND FOUR OF THE SIX BIND A PRE-FORMATTED STRING. That combination
 * is only safe because of `SORT_KEY` below — read it before touching a `fieldName` here.
 *
 * 🔴 THE `pill` COLUMN MARKED `sortable` IS A COMBINATION THIS REPO HAS NEVER SEEN RENDER.
 * `c/listDatatable` registers `pill` as a custom cell type, and Tranche 2 marked `sellMeterList`'s
 * pill column sortable without ever confirming in a browser that the header chevron appears and
 * responds on a custom type. This card INHERITS that open verification debt — it does not
 * establish a precedent and must not be cited as one. Jest cannot close it: the datatable stub
 * renders nothing, so the suite proves the sort FUNCTION and the attribute values and never that a
 * header is clickable.
 */
const COLUMNS = [
    { label: 'Broker', fieldName: 'recordUrl', type: 'url', sortable: true, typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'Firm', fieldName: 'firm', type: 'text', sortable: true },
    { label: 'Active Listings', fieldName: 'activeListings', type: 'text', sortable: true },
    { label: 'Offers', fieldName: 'offers', type: 'text', sortable: true },
    { label: 'Closed Volume', fieldName: 'volumeLabel', type: 'text', sortable: true },
    { label: 'Status', fieldName: 'status', type: 'pill', sortable: true, typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } } }
];

const STATUS_OPTIONS = [
    { label: 'All statuses', value: STATUS_FILTER_ALL },
    { label: 'Active', value: 'Active' },
    { label: 'Inactive', value: 'Inactive' }
];

/**
 * Column `fieldName` -> the RAW row key to order by.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE COLUMNS SORT ON RAW VALUES, NOT ON WHAT THEY DISPLAY, AND WITHOUT THIS MAP EVERY ONE OF
 *    THEM IS WRONG IN A WAY THAT LOOKS PLAUSIBLE ON THE FIRST SCREENFUL.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *   recordUrl      '/lightning/r/Contact/0035g.../view'  -> would sort by record ID
 *   activeListings String(n)                             -> would sort '1', '10', '2'
 *   offers         String(n)                             -> same
 *   volumeLabel    '$10.0M' / '$500K' / '—'              -> '$10.0M' sorts BEFORE '$2.0M'
 *   status         the pill's own text                   -> alphabetical, not rank
 * `firm` is the only column whose displayed value is nearly its raw one, and even it is redirected:
 * the display substitutes '—' for a blank, and a dash sorts as a character rather than as "absent".
 *
 * This is the pattern `lwc/sellMeterList` established in Tranche 2 (`SORT_KEY` + the
 * `SORT_KEY[this.sortedBy] || this.sortedBy` lookup), reused verbatim in shape including the
 * `recordUrl -> name` remap for a linked column.
 *
 * ⚠ A `fieldName` MISSING FROM THIS MAP FALLS BACK TO ITSELF, so a newly-added sortable column
 * silently sorts on its display string. If you add a column, add its key here in the same edit.
 */
const SORT_KEY = {
    recordUrl:      'name',
    firm:           '_firm',
    activeListings: '_activeListings',
    offers:         '_offers',
    volumeLabel:    '_closedVolume',
    status:         '_statusRank'
};

export default class BrokersList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    statusOptions = STATUS_OPTIONS;
    data;
    error;
    listUrl = '#';

    /**
     * Undefined until the user clicks a column header, and `undefined` IS a state rather than a
     * missing value — see `_ordered`. Do not initialise it to a column: that would put the table
     * into user-sorted mode before the user has sorted anything, and would silently retire the
     * server's closed-volume ranking that gives the opening screen its meaning.
     */
    sortedBy;
    sortedDirection = 'asc';

    searchTerm = '';
    statusFilter = STATUS_FILTER_ALL;

    @wire(getBrokerHub)
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.data = undefined;
        }
    }

    get hasError() {
        return !!this.error;
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Contact', actionName: 'list' },
            state: { filterName: '__Recent' }
        };
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    /** Every broker in the payload, in the SERVER's order (closed volume DESC, then Name). */
    get _all() {
        return this.data && this.data.brokers ? this.data.brokers : [];
    }

    /**
     * Free-text search over the broker's NAME or FIRM, plus the status combobox.
     *
     * ⚠ IT MATCHES THE RAW `firm`, NOT THE DISPLAYED ONE. The display substitutes '—' for a blank
     * firm, so a search for "—" would otherwise "find" every broker with no firm at all — a result
     * nobody asked for and nobody could explain.
     *
     * ⚠ NO FIRM PICKLIST AND NO SPECIALTY FILTER, DELIBERATELY (design D-7). Firms are free text
     * and this org holds duplicate and near-duplicate firm strings — `BrokerController` lower-cases
     * and trims them just to COUNT them — so a picklist of firms would list the same firm twice.
     * `specialty` is in the payload but is NOT a column, and filtering on a field the table does
     * not show is a control nobody can reason about.
     */
    get _filtered() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        const status = this.statusFilter;
        if (!term && status === STATUS_FILTER_ALL) {
            return this._all;
        }
        return this._all.filter((b) => {
            if (status !== STATUS_FILTER_ALL && b.status !== status) {
                return false;
            }
            if (!term) {
                return true;
            }
            const name = (b.name || '').toLowerCase();
            const firm = (b.firm || '').toLowerCase();
            return name.includes(term) || firm.includes(term);
        });
    }

    /**
     * The user's sort, on RAW values — or the server's order when nothing has been sorted.
     *
     * ⚠ NULLS ALWAYS SORT LAST, IN BOTH DIRECTIONS, AND THAT IS A CHOICE RATHER THAN A FALLOUT.
     * `firm` and `closedVolume` are genuinely nullable and those rows render '—'. Letting them
     * float to the top of a descending sort would bury the largest values — the answer the user
     * clicked the header to see — under rows that have no value at all. `Array.prototype.sort` is
     * stable, so ties keep the server's ranking.
     */
    _ordered(rows) {
        if (!this.sortedBy) {
            return rows;
        }
        const field = SORT_KEY[this.sortedBy] || this.sortedBy;
        const dir = this.sortedDirection === 'asc' ? 1 : -1;
        return [...rows].sort((a, b) => {
            const av = a[field];
            const bv = b[field];
            const aMissing = av === null || av === undefined;
            const bMissing = bv === null || bv === undefined;
            if (aMissing && bMissing) return 0;
            if (aMissing) return 1;
            if (bMissing) return -1;
            if (av > bv) return dir;
            if (av < bv) return -dir;
            return 0;
        });
    }

    /**
     * One payload row -> one datatable row.
     *
     * 🔴 EACH ROW CARRIES BOTH SHAPES ON PURPOSE: the strings the columns DISPLAY, and the raw
     * `_`-prefixed values `SORT_KEY` ORDERS by. The raw keys bind to no column and render nowhere.
     * Dropping them to "tidy" the row silently reverts sorting to lexicographic nonsense — see
     * SORT_KEY's header for what each column then does.
     */
    _toRow(b) {
        const [bg, dot] = STATUS[b.status] || FALLBACK;
        return {
            id: b.id,
            recordUrl: `/lightning/r/Contact/${b.id}/view`,
            name: b.name,
            firm: b.firm || '—',
            activeListings: String(b.activeListings),
            offers: String(b.offers),
            volumeLabel: fmtMoney(b.closedVolume),
            status: b.status,
            statusWrap: pillWrap(bg),
            statusDot: pillDot(dot),
            // ── Raw values for SORT_KEY. Bound to no column; rendered nowhere. ──
            _firm: b.firm,
            _activeListings: b.activeListings,
            _offers: b.offers,
            _closedVolume: b.closedVolume,
            _statusRank: STATUS_RANK[b.status] ?? STATUS_RANK_UNKNOWN
        };
    }

    /**
     * 🔴 FILTER, THEN SORT, THEN SLICE — AND THE ORDER OF THOSE THREE IS THE WHOLE FEATURE
     * (design decision D-6).
     *
     * This card has always rendered only the top 5. Sorting AFTER the slice would reorder five rows
     * that were already chosen by closed volume, so "sort by Broker" could never surface the
     * alphabetically-first broker and "sort by Offers" could never surface the broker with the most
     * offers — the control would appear to work and would answer the wrong question. Sorting the
     * FULL list first is what makes a sort mean "the top five by this column".
     *
     * ⚠ IT THEREFORE CHANGES WHAT THE CARD SHOWS THE MOMENT A USER SORTS, WHICH IS INTENDED. With
     * no sort applied the order is byte-identical to what shipped before this change, because
     * `_ordered` returns the server's list untouched while `sortedBy` is undefined.
     *
     * 🔴 `_toRow` RUNS **BEFORE** `_ordered`, AND THAT SEQUENCE IS NOT INTERCHANGEABLE — THIS IS
     * THE ONE MISTAKE THIS PIPELINE INVITES, AND IT WAS MADE HERE FIRST TIME ROUND.
     * The `_`-prefixed keys `SORT_KEY` orders by (`_firm`, `_activeListings`, `_offers`,
     * `_closedVolume`, `_statusRank`) are CREATED BY `_toRow`. They do not exist on the raw
     * `BrokerController.BrokerRow` objects the wire delivers. Mapping after sorting therefore
     * hands the comparator five `undefined`s, every pair compares "both missing", `Array.sort` is
     * stable, and the table silently keeps the SERVER order — a sort control that renders, moves
     * its header arrow, and does nothing.
     * ⚠ IT FAILS SILENTLY ON FIVE OF SIX COLUMNS AND WORKS ON THE SIXTH, which is what makes it
     * so easy to miss: `recordUrl -> name` maps to a key that exists on the raw payload too, so
     * the Broker column sorts correctly while the other five do not. A smoke test that clicked one
     * header would have confirmed the feature worked.
     * Mapping the FULL filtered list costs one extra transform per row over mapping only the five
     * that survive the slice — irrelevant at this org's broker population, and the price of the
     * sort being applied to the whole list at all (decision D-6).
     */
    get rows() {
        return this._ordered(this._filtered.map((b) => this._toRow(b))).slice(0, VISIBLE_ROWS);
    }

    /** The unfiltered population — what the card has always counted. */
    get count() {
        return this._all.length;
    }

    get _filteredCount() {
        return this._filtered.length;
    }

    get isFiltered() {
        return !!(this.searchTerm || '').trim() || this.statusFilter !== STATUS_FILTER_ALL;
    }

    /**
     * The card title's count.
     *
     * ⚠ IT READS `7 of 19` ONLY WHILE A FILTER IS APPLIED, and is the bare total otherwise. A
     * header that said "Brokers (19)" above a filtered table would contradict the table beneath it;
     * a header that always said "19 of 19" would be noise on the 99% of loads with no filter. The
     * unfiltered string is unchanged from what shipped, which is why the existing pin on it stays
     * green — the new string needs its own assertion, and has one.
     */
    get countLabel() {
        return this.isFiltered ? `${this._filteredCount} of ${this.count}` : `${this.count}`;
    }

    /** True when a filter is active and has excluded everything — the table would be blank. */
    get hasNoMatches() {
        return this.isFiltered && this._filteredCount === 0 && this.count > 0;
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
    }

    handleStatusFilter(event) {
        this.statusFilter = event.detail.value;
    }

    /**
     * Column-header sort.
     *
     * 🔴 THE DATATABLE DOES NOT SORT THE DATA. It raises `onsort` carrying the clicked column's
     * `fieldName` and the next direction, and renders its header arrow from `sorted-by` /
     * `sorted-direction`. The PARENT performs the sort. All three bindings are required: without
     * `onsort` the click does nothing, and without the two `sorted-*` bindings the arrow never
     * moves while the data reorders underneath the user.
     */
    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
    }
}
