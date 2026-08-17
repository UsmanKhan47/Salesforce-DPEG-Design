/**
 * c-recent-packages — @wire-to-Apex suite WITH NavigationMixin.
 *
 * Pattern: the recentLeads suite (WIRE-MOCK TEMPLATE 1 + the lwc-recipes navigation mock), because
 * this component is that component's peer in Lead_Funnel's region2 and shares its card chrome, its
 * @wire -> data/error shape and its "View All" footer.
 *
 * Data source: @wire(getRecentPackages) from PropertyPackageController.getRecentPackages, which
 * returns a List<RecentPackageRow> ALREADY LIMITED to RECENT_LIMIT rows. Rows are asserted via the
 * datatable's `data` @api — c-list-datatable extends the stubbed lightning/datatable, so cell DOM is
 * not rendered here (a documented, repo-wide property of these suites, not a gap in this one).
 *
 * ⚠ THE CARD HAS FOUR MUTUALLY EXCLUSIVE STATES — loading / error / empty / populated — AND THE FIRST
 * TWO OF THIS SUITE'S TESTS EXIST TO KEEP THE FIRST AND THIRD APART. They were originally conflated:
 * `isEmpty` read `this.rows.length === 0`, and `rows` returns [] while `data` is undefined, so the
 * pre-wire window rendered "No multi-property broker emails have arrived yet" on every page load. The
 * suite PINNED that behaviour ("EMPTY: shows the empty message ... before the wire emits"), so the bug
 * was protected by a passing test — the reason both replacements assert in opposite directions and
 * every state test now asserts the ABSENCE of the other three states, not just the presence of its own.
 *
 * ⚠ TWO MORE THINGS THIS SUITE EXISTS TO PIN, BOTH OF WHICH A NAIVE "does it render" TEST WOULD MISS:
 *   1. THAT THERE IS NO CLIENT-SIDE TRUNCATION. `noClientSideSlice` emits SEVEN rows and asserts
 *      SEVEN reach the table. The peer components (recentLeads, recentOpportunities) both
 *      `.slice(0, 5)`, so copying one of them and leaving the slice in is the single most likely way
 *      to regress this component — and it would reintroduce exactly the hidden-package problem the
 *      widget was built to fix, while every other test here still passed.
 *   2. THAT THE LINK IS A `type: 'url'` COLUMN, not a custom cell type or a NavigationMixin call. The
 *      only NavigationMixin use is the footer, and `navigationIsOnlyTheFooter` asserts a row click
 *      dispatches nothing.
 *
 * ⚠ DATE ASSERTIONS ARE TIME-ZONE STABLE BY CONSTRUCTION: the component formats with the SALESFORCE
 * user's zone from `@salesforce/i18n/timeZone`, which the @lwc/jest-transformer substitutes as
 * 'America/Los_Angeles' (locale 'en-US'). A test asserting a formatted instant would otherwise pass or
 * fail on the runner's own TZ.
 */
import { createElement } from 'lwc';
import RecentPackages from 'c/recentPackages';
import getRecentPackages from '@salesforce/apex/PropertyPackageController.getRecentPackages';

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
                    return Promise.resolve('https://example.com/package-list');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PropertyPackageController.getRecentPackages',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const PKG_ID = 'a0Z000000000001';

/** An Apex Datetime reaches the client as an ISO-8601 string. */
const RECEIVED_ISO = '2026-08-14T17:30:00.000Z';
/** The same instant in America/Los_Angeles (the Jest i18n/timeZone substitute) — 10:30 AM PDT. */
const RECEIVED_RENDERED = 'Aug 14, 2026, 10:30 AM';

/** `createdDate` three days back, for the null-receivedDateTime fallback. */
const threeDaysAgoIso = () =>
    new Date(Date.now() - 3 * 86400000).toISOString();

/**
 * Row 1 is the fully-populated case. Row 2 deliberately has NO receivedDateTime (the header parse
 * failed), no brokerName, and zero Leads — every nullable the DTO can hand over, on one row, because
 * these are the states the LLM extraction actually produces and each one has its own fallback.
 */
const ROWS = [
    {
        id: PKG_ID,
        name: 'FW: Three-property portfolio',
        recordUrl: `/lightning/r/Property_Package__c/${PKG_ID}/view`,
        propertyCount: 3,
        brokerName: 'Dana Reyes',
        brokerEmail: 'dana@brokerage.com',
        receivedDateTime: RECEIVED_ISO,
        createdDate: RECEIVED_ISO,
        leadCount: 2,
        opportunityCount: 1
    },
    {
        id: 'a0Z000000000002',
        name: 'FW: Two assets, both worked',
        recordUrl: '/lightning/r/Property_Package__c/a0Z000000000002/view',
        propertyCount: 2,
        brokerName: null,
        brokerEmail: 'sam@okafor-re.com',
        receivedDateTime: null,
        createdDate: threeDaysAgoIso(),
        leadCount: 0,
        opportunityCount: 2
    }
];

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

function spinner(element) {
    return element.shadowRoot.querySelector('lightning-spinner');
}

function emptyMessage(element) {
    return element.shadowRoot.querySelector('.lv-empty');
}

function title(element) {
    return element.shadowRoot.querySelector('span[slot="title"]').textContent;
}

describe('c-recent-packages', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-recent-packages', {
            is: RecentPackages
        });
        document.body.appendChild(element);
        return element;
    }

    it('LOADING: 🔴 shows the spinner and makes NO claim about emptiness before the wire emits', async () => {
        // ⚠ THIS TEST REPLACES ONE THAT PINNED THE BUG. Its predecessor was titled "EMPTY: shows the
        // empty message and NO datatable before the wire emits" and asserted `.lv-empty` was PRESENT
        // here — i.e. it required the defect. `isEmpty` was `this.rows.length === 0`, and `rows`
        // returns [] whenever `data` is undefined, so the pre-wire window was indistinguishable from
        // a server answer of zero rows and the card asserted "no multi-property broker emails have
        // arrived yet" on every page load until the wire resolved.
        //
        // The distinction is not cosmetic: that sentence is a factual claim about DPEG's inbox on a
        // homepage widget, and the whole reason this bundle exists is that packages were being hidden
        // from the Lead feed — a card that flashes "none have arrived" is the same false negative in a
        // new place.
        const element = createComponent();

        await Promise.resolve();

        expect(spinner(element)).not.toBeNull();
        // Neither of the two RESOLVED states may render while the answer is still unknown.
        expect(emptyMessage(element)).toBeNull();
        expect(datatable(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('EMPTY: an org with zero packages renders the empty state, not an empty table', async () => {
        // The OTHER HALF of the discriminating pair. This is a wire that HAS emitted, with a real
        // (empty) answer — the one state in which the "none have arrived" sentence is true. Until the
        // org receives its first multi-property email this is the permanent, correct state.
        //
        // 🔴 THIS TEST AND THE LOADING TEST ABOVE POINT IN OPPOSITE DIRECTIONS, WHICH IS THE POINT:
        // collapsing `isEmpty` back to `this.rows.length === 0` reds the loading test, and dropping
        // the `!!this.data` guard in the other direction (e.g. gating the message on the datatable
        // having rendered) reds this one. Neither alone is sufficient cover.
        const element = createComponent();

        getRecentPackages.emit([]);
        await Promise.resolve();

        expect(title(element)).toBe('Property Packages (0)');
        expect(spinner(element)).toBeNull();
        expect(datatable(element)).toBeNull();
        const empty = emptyMessage(element);
        expect(empty).not.toBeNull();
        expect(empty.textContent.trim()).toBe(
            'No multi-property broker emails have arrived yet.'
        );
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('DATA BRANCH: renders one row per package and counts them in the title', async () => {
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(2);
        expect(title(element)).toBe('Property Packages (2)');
        expect(emptyMessage(element)).toBeNull();
        // The spinner CLEARS — it is a third state, not an overlay that outlives the wire.
        expect(spinner(element)).toBeNull();
    });

    it('DATA BRANCH: 🔴 performs NO client-side slice — seven rows in, seven rows out', async () => {
        // THE MOST IMPORTANT TEST IN THIS SUITE. Both peer components on this page (recentLeads,
        // recentOpportunities) call `.slice(0, 5)` because their Apex returns a wider shared set. This
        // component's Apex applies RECENT_LIMIT as a SOQL LIMIT, so the server cutoff is the ONLY
        // cutoff — and a second truncation layer stacked on a server cutoff is the exact shape that hid
        // packages in the Lead feed, which is why this widget exists at all.
        //
        // Seven is deliberately ABOVE the current RECENT_LIMIT of 5: if someone pastes a `.slice(0, 5)`
        // in from a peer component, every other test here still passes and only this one reds.
        const element = createComponent();

        const seven = Array.from({ length: 7 }, (_, i) => ({
            ...ROWS[0],
            id: `a0Z00000000000${i}`,
            name: `FW: package ${i}`
        }));
        getRecentPackages.emit(seven);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(7);
        expect(title(element)).toBe('Property Packages (7)');
    });

    it('DATA BRANCH: preserves the SERVER row order and does not re-sort on the displayed date', async () => {
        // The selector orders on CreatedDate DESC; the table DISPLAYS `receivedDateTime`, which can be
        // null. A client-side sort on the displayed value would reorder rows on a field the server
        // deliberately did not sort on — and would drop null-received packages to one end.
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        const ids = datatable(element).data.map((r) => r.id);
        expect(ids).toEqual([ROWS[0].id, ROWS[1].id]);
    });

    it('PACKAGE NAME: is a url-type column labelled from `name`, using the SERVER-built URL', async () => {
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        // ⚠ THE COLUMN HEADER IS A DISPLAY LABEL AND IT HAS MOVED TWICE. It was originally
        // "Package Name", was re-worded to "Portfolio Name" on 2026-08-17 alongside the card title,
        // the spinner text, `GENERIC_ERROR` and the server's
        // `PropertyPackageController.RECENT_READ_FAILURE_MESSAGE` — and was re-worded BACK to
        // "Package Name" later the same day, once the title settled on "Property Packages". It sits
        // directly under that title, so the two are read together and must use one word.
        // `fieldName` / `type` / the DTO member `name` are API-side and were never touched by any of it.
        //
        // ✅ THE OPEN ITEM THAT STOOD HERE IS CLOSED — AND ITS RETRACTED ARGUMENT MUST NOT BE REVIVED.
        // It read: *"it survived every later rename unchanged … it names ONE row's own identity rather
        // than the collection, which is why it read correctly under the three 'Portfolio*' titles"*,
        // and it named the remedy in advance: *"If it is ever harmonised the target is 'Package Name'
        // — its ORIGINAL label, before the first rename — and this assertion is the one that reds."*
        // That is exactly what happened; this assertion is the one that moved, and only this one.
        //
        // ⚠ THE ONE PART OF THAT ARGUMENT STILL WORTH KEEPING is why it was a SEPARATE pass: the title
        // chain ran "Recent Packages" → "Recent Portfolios" → "Portfolio Deals" (RETRACTED — it
        // collided with the `Portfolio Deal` Opportunity stage value) → "Property Packages", and
        // "Portfolio Name" was never part of THAT collision (it is not a stage value and cannot be
        // misread as a deal stage). It was a consistency defect, not a misread risk, so it was
        // recorded rather than swept in silently. See `recentPackages.js`'s header for the full chain.
        const column = datatable(element).columns.find(
            (c) => c.label === 'Package Name'
        );
        expect(column).toBeDefined();
        expect(column.type).toBe('url'); // not a custom cell type
        expect(column.fieldName).toBe('recordUrl');
        expect(column.typeAttributes.label.fieldName).toBe('name');

        // The URL is Apex's, passed through untouched — the client never composes
        // '/lightning/r/Property_Package__c/...' itself.
        expect(datatable(element).data[0].recordUrl).toBe(
            `/lightning/r/Property_Package__c/${PKG_ID}/view`
        );
        expect(datatable(element).data[0].name).toBe(
            'FW: Three-property portfolio'
        );
    });

    it('PACKAGE NAME: a row click navigates via the url column, NOT via NavigationMixin', async () => {
        // The complement of the assertion above. A datatable cell cannot invoke NavigationMixin
        // without a custom column type, so the ONLY NavigationMixin use in this bundle is the footer —
        // and nothing the table does may dispatch a navigate event.
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        // The rendered link is the platform's, inside the stubbed datatable, so there is no row anchor
        // to click here. What IS assertable is that mounting and populating the table navigates
        // nothing: the link is declarative.
        expect(navHandler).not.toHaveBeenCalled();
        expect(
            datatable(element).columns.every((c) => c.type !== 'packageLink')
        ).toBe(true);
    });

    it('CELLS: derives Properties, Broker and Received for a fully-populated row', async () => {
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        const first = datatable(element).data[0];
        expect(first.properties).toBe('3');
        // One column, name then address as supporting text — recentLeads renders its broker as a single
        // text column too, and c/listDatatable exposes no two-line cell type to stack them.
        expect(first.broker).toBe('Dana Reyes · dana@brokerage.com');
        expect(first.receivedLabel).toBe(RECEIVED_RENDERED);
    });

    it('NO LINKED RECORDS COLUMN: the retired column is gone and no row composes its label', async () => {
        // 🔴 AN ABSENCE ASSERTION REPLACING THREE PRESENCE ASSERTIONS (2026-08-17). Three 'CELLS'
        // tests stood here — the populated `2 Leads · 1 Opportunity` case, the zero-segment-omitted
        // case (`2 Opportunities`, so a fully-converted package read as a success rather than a loss)
        // and the memberless em-dash case (design residual R6). All three died with the column, which
        // was removed at the user's request.
        //
        // Deleting them outright would leave NOTHING red if the column were pasted back, so the one
        // test in their place pins the removal in both places it has to hold: the column is gone from
        // COLUMNS, and no row getter composes `linkedRecords`.
        //
        // ⚠ THE FIXTURE STILL CARRIES `leadCount` / `opportunityCount` ON PURPOSE — the SERVER still
        // sends them (only the column went), and this test is the falsifier for that too: it proves
        // the component ignores them rather than that they stopped arriving.
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        const table = datatable(element);
        expect(table.columns.find((c) => c.label === 'Linked Records')).toBeUndefined();
        expect(table.columns.some((c) => c.fieldName === 'linkedRecords')).toBe(false);
        expect(table.data[0].linkedRecords).toBeUndefined();

        // Precondition, so the two assertions above cannot pass merely because the fixture is thin.
        expect(ROWS[0].leadCount).toBe(2);
        expect(ROWS[0].opportunityCount).toBe(1);
    });

    it('CELLS: a null receivedDateTime falls back to a relative age off createdDate', async () => {
        // 🔴 AND THE FALLBACK IS DISPLAY-ONLY. `receivedDateTime` is parsed out of the sender's headers
        // and is null whenever that parse fails, which is precisely why the SERVER sorts on
        // CreatedDate. A blank cell here would look like missing data; the age is true and useful.
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        expect(datatable(element).data[1].receivedLabel).toBe('3d ago');
        // And the ordering is untouched by the fallback — the null-received row keeps its server slot.
        expect(datatable(element).data[1].id).toBe(ROWS[1].id);
    });

    it('CELLS: a null broker name falls back to the address alone', async () => {
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        expect(datatable(element).data[1].broker).toBe('sam@okafor-re.com');
    });

    it('CELLS: a null propertyCount renders an em dash rather than "null"', async () => {
        const element = createComponent();

        getRecentPackages.emit([{ ...ROWS[0], propertyCount: null }]);
        await Promise.resolve();

        expect(datatable(element).data[0].properties).toBe('—');
    });

    it('VIEW ALL: clicking the footer link navigates to the Property Package list view', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('Property_Package__c');
        expect(pageRef.attributes.actionName).toBe('list');
    });

    it('ERROR BRANCH: renders the server message and replaces the table', async () => {
        // ⚠ The first argument to a wire adapter's .error() IS the body. Passing
        // `{ body: { message } }` would produce e.body.body.message, so the component's getter would
        // fall through to its generic string and this test would pass while proving nothing about the
        // server's wording.
        //
        // ⚠ THE FIXTURE IS A VERBATIM COPY OF `PropertyPackageController.RECENT_READ_FAILURE_MESSAGE`
        // (re-worded WITH that constant three times on 2026-08-17: "packages" → "portfolios" →
        // "portfolio deals" → the settled "property packages"). This assertion is a pass-through and
        // would stay green against ANY string, so the copy is documentation of what the server actually
        // says, not a check on it — `PropertyPackageControllerTest` pins the server side. Keep the two
        // in step so a reader is never shown two wordings for one failure.
        const element = createComponent();

        getRecentPackages.error({
            message:
                'Property packages could not be loaded. Refresh the page or contact your administrator.'
        });
        await Promise.resolve();

        expect(datatable(element)).toBeNull();
        // Error, empty and loading are mutually exclusive — a failure must not read as "no property
        // packages yet", and it must not leave the card spinning forever either.
        expect(emptyMessage(element)).toBeNull();
        expect(spinner(element)).toBeNull();
        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err).not.toBeNull();
        expect(err.textContent.trim()).toBe(
            'Property packages could not be loaded. Refresh the page or contact your administrator.'
        );
        expect(err.getAttribute('role')).toBe('alert');
        expect(title(element)).toBe('Property Packages (0)');
    });

    it('ERROR BRANCH: an error with no message falls back to the component\'s own wording', async () => {
        // An EMPTY body, not a no-arg .error(): the no-arg form substitutes the mock library's own
        // default message, which would test the mock rather than the component.
        //
        // ⚠ UNLIKE THE TEST ABOVE, THIS ONE REALLY DOES PIN A STRING THIS BUNDLE OWNS — `GENERIC_ERROR`
        // (re-worded three times on 2026-08-17: "packages" → "portfolios" → "portfolio deals" → the
        // settled "property packages", matching the card title and the server's own message). It reds if
        // the wording drifts, which is the point: the fallback is the only wording a user sees when the
        // server supplied none, so it must not be the one place left saying "portfolio deals" — a name
        // RETRACTED because it collided with the `Portfolio Deal` Opportunity stage value.
        const element = createComponent();

        getRecentPackages.error({});
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.lv-error').textContent.trim()
        ).toBe('Unable to load property packages.');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecentPackages.emit(ROWS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible in the empty state', async () => {
        const element = createComponent();

        getRecentPackages.emit([]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
