/**
 * c-disposition-buyer-timeline
 * ---------------------------------------------------------------------------
 * Read-only: a single @wire(getTimeline, { dispositionId: '$recordId' }).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 RETARGETED 2026-08-21 — ONE ROW PER **NDA**, NOT PER BUYER
 * ═══════════════════════════════════════════════════════════════════════════
 * DPEG communicates only with the appointed listing broker; buyers sit behind
 * them and are not tracked. Three things changed and each has its own pin below:
 *   - the tile HEADING is the NDA number and the broker is its subtitle;
 *   - the "First offer" column and the "Days to respond" duration are GONE —
 *     nothing links an offer to a specific NDA any more, so any attribution
 *     would be fiction (T-NO-OFFER is the pin);
 *   - the card TITLE says "Broker Activity Timeline" (user instruction,
 *     2026-08-21 — it was briefly "NDA Activity Timeline") while the BUNDLE is
 *     still called buyerTimeline, deliberately (a rename is a FlexiPage edit plus
 *     a destructive Apex delete — see the component header).
 *     🔴 THE TITLE ASSERTIONS BELOW ARE EXACT (`toBe`), NEVER `toContain`. A
 *     substring match on "Activity Timeline" would pass for BOTH the old and the
 *     new name, i.e. it would not detect the rename being reverted — which is
 *     the only thing those assertions exist to detect.
 *     ⚠ "Broker" IS NOT A GROUPING CLAIM. One broker per sale, so the same name
 *     repeats on every tile and the count in the title counts NDAs, not brokers.
 * The old per-buyer assertions were DELETED, not softened into always-true
 * negations inside tests still named for buyers.
 *
 * 🔴 THE TWO FALSIFIERS THAT MATTER MOST HERE ARE STILL THE DECLINED-ROW ONES.
 *   1. A declined party must render EM-DASHES IN ALL THREE VALUE COLUMNS. The
 *      payload below deliberately gives the declined row a real
 *      `ndaSignedDate`, because that is EXACTLY THE STATE THE PRODUCTION DATA
 *      IS IN: `NDA_Signed_Status_Sync` never clears `Date_Signed__c`, so a
 *      `Signed -> Declined` party keeps a non-null date forever. (The service
 *      suppresses it before it crosses the boundary; this test proves the
 *      component would not render it even if it arrived.)
 *   2. The word "Declined" must be present as READABLE TEXT, and the row must
 *      carry an aria-label naming the state. This repo has a measured incident
 *      of a text->badge swap deleting accessible content a test had pinned —
 *      these assertions are that pin. A colour-only state would pass a visual
 *      review and fail a screen reader.
 *
 * Also pinned: server ordering is preserved (the component must NOT sort), a
 * negative duration never renders (the service nulls it and raises
 * `hasDateAnomaly`, which surfaces as a "Check dates" badge), and the error
 * branch renders a visible alert rather than a silent blank.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 THE SIX-COLUMN TABLE IS GONE AND MUST NOT COME BACK (2026-08-21).
 * ═══════════════════════════════════════════════════════════════════════════
 * This card moved to the ~340px record-page sidebar, where the old grid
 * (`minmax(0, 2fr) repeat(5, minmax(0, 1fr))` plus a shared heading row) gave
 * every value column ~35px. It is now a <ul>/<li> of self-labelling tiles, and
 * T-NARROW / T-CSS below are anti-regression pins for that — modelled on the
 * identical pair in c/competingBrokerSubmissions, which solved the same problem
 * on Lead_Record_Page.
 */
import { createElement } from 'lwc';
import DispositionBuyerTimeline from 'c/dispositionBuyerTimeline';
import getTimeline from '@salesforce/apex/DispositionBuyerTimelineController.getTimeline';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not
// cosmetic: T-CSS's assertions are deliberately broad (e.g. /nowrap/), so a
// comment that merely NAMED a banned value would fail them — which is what
// forces a stylesheet to describe its own rules in circumlocutions. With the
// strip in place the .css above says `overflow-x` and `nowrap` plainly.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(
            __dirname,
            '..',
            'dispositionBuyerTimeline.css'
        ),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

jest.mock(
    '@salesforce/apex/DispositionBuyerTimelineController.getTimeline',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a0Y0000000000001AAA';
const EM_DASH = '—';

/** Active, fully progressed: both dates and the duration. */
const COMPLETE_ROW = {
    ndaId: 'a0Z0000000000001AAA',
    ndaName: 'NDA-0101',
    brokerName: 'Derek Simmons',
    status: 'Signed',
    isDeclined: false,
    ndaSignedDate: '2026-03-02',
    materialsReleasedDate: '2026-03-09',
    daysToRelease: 7,
    hasDateAnomaly: false
};

/** Active, mid-journey: nothing signed yet — the common early state. */
const IN_FLIGHT_ROW = {
    ndaId: 'a0Z0000000000002AAA',
    ndaName: 'NDA-0102',
    brokerName: 'Derek Simmons',
    status: 'Sent',
    isDeclined: false,
    ndaSignedDate: null,
    materialsReleasedDate: null,
    daysToRelease: null,
    hasDateAnomaly: false
};

/**
 * Active, dates out of order. The service has ALREADY suppressed the negative
 * duration to null and raised the flag — that is the contract this component
 * renders against, and it is why `daysToRelease` is null and not -4.
 */
const ANOMALY_ROW = {
    ndaId: 'a0Z0000000000003AAA',
    ndaName: 'NDA-0103',
    brokerName: 'Derek Simmons',
    status: 'Signed',
    isDeclined: false,
    ndaSignedDate: '2026-04-10',
    materialsReleasedDate: '2026-04-06',
    daysToRelease: null,
    hasDateAnomaly: true
};

/**
 * 🔴 DECLINED, CARRYING A RETAINED `ndaSignedDate`. See the header — this is the
 * real production shape, not a contrived one, and it is the whole reason this
 * fixture is not simply all-nulls.
 *
 * ⚠ IT ALSO CARRIES THE "no broker" PLACEHOLDER, because `NDA__c.Broker__c` is a
 * 2026-08-21 field with NO BACKFILL: every NDA older than that date has a null
 * lookup, and the service resolves it to this fixed string rather than to blank.
 */
const DECLINED_ROW = {
    ndaId: 'a0Z0000000000004AAA',
    ndaName: 'NDA-0104',
    brokerName: 'No broker recorded',
    status: 'Declined',
    isDeclined: true,
    ndaSignedDate: '2026-02-14',
    materialsReleasedDate: '2026-02-20',
    daysToRelease: 6,
    hasDateAnomaly: false
};

// Server order: actives first, declined last. The component must not re-sort.
const TIMELINE = [COMPLETE_ROW, IN_FLIGHT_ROW, ANOMALY_ROW, DECLINED_ROW];

describe('c-disposition-buyer-timeline', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-buyer-timeline', {
            is: DispositionBuyerTimeline
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    /**
     * One element per NDA. There is no shared heading row to filter out — each
     * tile carries its own <dt> labels, which is exactly what makes it readable
     * at 340px.
     */
    function dataRows(element) {
        return [...element.shadowRoot.querySelectorAll('.dbt-tile')];
    }

    /** The three value cells of a tile, in template order, as text. */
    function valueCells(row) {
        return [...row.querySelectorAll('.dbt-c')].map((cell) =>
            cell.textContent.trim()
        );
    }

    const title = (element) =>
        element.shadowRoot.querySelector('span[slot="title"]').textContent.trim();

    it('BEFORE THE WIRE ANSWERS: the titled card renders, but it claims nothing', async () => {
        const element = createComponent();

        await Promise.resolve();

        // 🔴 The card CHROME is unconditional — an untitled fragment of text
        // floating between two proper cards is the UAT defect this rework fixed.
        expect(element.shadowRoot.querySelector('lightning-card')).not.toBeNull();

        // 🔴 ...but the card says nothing about the sale yet. No tiles, no empty
        // state, and NO "(0)" in the title: "Broker Activity Timeline (0)" would
        // state, in the same words it uses for a genuinely empty sale, that no
        // NDA has been raised — before anything is known.
        expect(dataRows(element).length).toBe(0);
        expect(element.shadowRoot.querySelector('.dbt-empty')).toBeNull();
        expect(element.shadowRoot.querySelector('.dbt-error')).toBeNull();
        expect(title(element)).toBe('Broker Activity Timeline');
        // No spinner either — a spinner is the only element on this card capable
        // of hanging forever if the wire never emits.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('HEADER: the card carries the Broker Activity Timeline title and a contract icon once the wire answers', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const card = element.shadowRoot.querySelector('lightning-card');
        // 🔴 NOT `standard:buyer_group`. The icon moved with the subject of the
        // card; a buyer-group icon over a list of NDAs is the visual half of the
        // claim the retarget removed.
        expect(card.iconName).toBe('standard:contract');
        // 🔴 EXACT MATCH, AND THE COUNT IS A COUNT OF NDAs. The fixture holds
        // FOUR NDAs naming just TWO distinct brokers ("Derek Simmons" x3 and the
        // no-broker placeholder), so a future "group by broker" would render (2)
        // here and fail. That is the point: the title names the counterparty, it
        // does not promise a per-broker rollup.
        expect(title(element)).toBe('Broker Activity Timeline (4)');
    });

    it('EMPTY BRANCH: an empty list renders an empty state, not an error', async () => {
        const element = createComponent();

        getTimeline.emit([]);
        await Promise.resolve();

        const empty = element.shadowRoot.querySelector('.dbt-empty');
        expect(empty).not.toBeNull();
        expect(element.shadowRoot.querySelector('.dbt-error')).toBeNull();
        expect(dataRows(element).length).toBe(0);

        // The empty state is a STATUS, not an alert: no NDA having been raised
        // yet is the ordinary early state of a disposition, not a problem.
        expect(empty.getAttribute('role')).toBe('status');
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();

        // An icon AND the explanatory line — the UAT complaint was that this
        // state was a bare grey sentence with no structure. The wording's INTENT
        // is preserved: rows appear as NDAs are raised.
        expect(
            empty.querySelector('lightning-icon').iconName
        ).toBe('utility:groups');
        expect(empty.querySelector('.dbt-empty-text').textContent.trim()).toBe(
            'No NDAs yet'
        );
        expect(empty.querySelector('.dbt-empty-sub').textContent).toContain(
            'as NDAs are raised on this disposition'
        );
    });

    it('🔴 DATA BRANCH: one row per NDA, headed by its NUMBER, in the order the server returned', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const names = [...element.shadowRoot.querySelectorAll('.dbt-nda')].map((el) =>
            el.textContent.trim()
        );
        expect(names).toEqual(['NDA-0101', 'NDA-0102', 'NDA-0103', 'NDA-0104']);
        // Declined is last, and it is last because the SERVER put it last — the
        // component does not sort. Reordering the payload would reorder this.
        expect(names[names.length - 1]).toBe('NDA-0104');
    });

    it('🔴 DATA BRANCH: the broker is the SUBTITLE, and it is allowed to repeat', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const brokers = [...element.shadowRoot.querySelectorAll('.dbt-broker')].map(
            (el) => el.textContent.trim()
        );
        // 🔴 THE SAME NAME ON THREE ROWS IS CORRECT HERE AND IS NOT THE DEFECT THE
        // DELETED "first offer" COLUMN WOULD HAVE BEEN. There is genuinely ONE
        // appointed broker per disposition, so repeating it is the data being
        // true. It sits as a subtitle rather than as the heading precisely so the
        // repetition reads as context, not as a per-row identity claim.
        expect(brokers).toEqual([
            'Derek Simmons',
            'Derek Simmons',
            'Derek Simmons',
            // A pre-2026-08-21 NDA has no broker lookup and no backfill exists —
            // the service resolves it to a fixed string rather than to blank,
            // because a blank cell reads as a rendering failure.
            'No broker recorded'
        ]);
    });

    it('DATA BRANCH: a complete row shows both dates and the duration', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        expect(valueCells(dataRows(element)[0])).toEqual([
            'Mar 2, 2026',
            'Mar 9, 2026',
            '7 days'
        ]);
    });

    it('DATA BRANCH: a mid-journey row em-dashes only the values it lacks', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        expect(valueCells(dataRows(element)[1])).toEqual([
            EM_DASH,
            EM_DASH,
            EM_DASH
        ]);
        // It is ACTIVE, so it must not be styled or announced as terminated.
        expect(dataRows(element)[1].classList.contains('dbt-tile--declined')).toBe(
            false
        );
    });

    it('🔴 DECLINED: em-dashes in ALL THREE value columns, including the retained signed date', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const declinedRow = dataRows(element)[3];
        expect(valueCells(declinedRow)).toEqual([EM_DASH, EM_DASH, EM_DASH]);
        // The payload carried a real 2026-02-14 signature date and a real
        // 6-day duration. Neither may appear anywhere in the row.
        expect(declinedRow.textContent).not.toContain('Feb 14');
        expect(declinedRow.textContent).not.toContain('6 days');
    });

    it('🔴 DECLINED: the state is READABLE TEXT plus an aria-label, not colour alone', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const declinedRow = dataRows(element)[3];

        // 1. Visible text. A future text->badge->icon swap that deletes this word
        //    fails HERE rather than silently in production.
        const badge = declinedRow.querySelector('.dbt-badge--declined');
        expect(badge).not.toBeNull();
        expect(badge.textContent.trim()).toBe('Declined');

        // 2. Accessible name for the whole row group. It names the NDA now — it
        //    used to name the buyer, and there is no buyer to name.
        expect(declinedRow.getAttribute('role')).toBe('group');
        expect(declinedRow.getAttribute('aria-label')).toContain('NDA-0104');
        expect(declinedRow.getAttribute('aria-label')).toContain('declined');

        // 3. Colour/style is reinforcement only — present, but never the sole signal.
        expect(declinedRow.classList.contains('dbt-tile--declined')).toBe(true);
    });

    it('ANOMALY: out-of-order dates render no duration and raise a visible flag', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const anomalyRow = dataRows(element)[2];
        const cells = valueCells(anomalyRow);
        // The third cell is the duration. Never a negative, never a number.
        expect(cells[2]).toBe(EM_DASH);
        expect(anomalyRow.textContent).not.toContain('-4');

        const flag = anomalyRow.querySelector('.dbt-badge--anomaly');
        expect(flag).not.toBeNull();
        expect(flag.textContent.trim()).toBe('Check dates');
    });

    it('ANOMALY: an ordinary row carries no flag', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        expect(dataRows(element)[0].querySelector('.dbt-badge--anomaly')).toBeNull();
    });

    it('DURATION: 1 renders singular, so the card never says "1 days"', async () => {
        const element = createComponent();

        getTimeline.emit([{ ...COMPLETE_ROW, daysToRelease: 1 }]);
        await Promise.resolve();

        expect(valueCells(dataRows(element)[0])[2]).toBe('1 day');
    });

    it('🔴 DURATION: ZERO is a real duration and must not fall into the em-dash branch', async () => {
        const element = createComponent();

        getTimeline.emit([{ ...COMPLETE_ROW, daysToRelease: 0 }]);
        await Promise.resolve();

        // Same-day release is meaningful. A truthiness check instead of an
        // explicit null/undefined test is exactly how that regression happens.
        expect(valueCells(dataRows(element)[0])[2]).toBe('0 days');
    });

    it('DATE PARSING: an ISO date renders as the same calendar day, not UTC-shifted', async () => {
        const element = createComponent();

        // 2026-01-01 is the canonical off-by-one trap: `new Date('2026-01-01')`
        // is UTC midnight, which renders as Dec 31 for any viewer west of GMT.
        getTimeline.emit([{ ...COMPLETE_ROW, ndaSignedDate: '2026-01-01' }]);
        await Promise.resolve();

        expect(valueCells(dataRows(element)[0])[0]).toBe('Jan 1, 2026');
    });

    it('ERROR BRANCH: a visible alert — never a silent blank', async () => {
        const element = createComponent();

        getTimeline.error();
        await Promise.resolve();

        const alert = element.shadowRoot.querySelector('.dbt-error');
        expect(alert).not.toBeNull();
        expect(alert.getAttribute('role')).toBe('alert');
        // Uses the cross-bundle banner class shared with recentLeads /
        // recentOpportunities / renewalList / competingBrokerSubmissions.
        expect(alert.classList.contains('lv-error')).toBe(true);
        // An empty timeline would be a confident wrong answer. Neither the tiles
        // nor the "no NDAs yet" empty state may appear on the error branch.
        expect(dataRows(element).length).toBe(0);
        expect(element.shadowRoot.querySelector('.dbt-empty')).toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-OFFER / T-NO-BUYER — THE DELIBERATE ABSENCE PIN (2026-08-21)
    //
    // The per-buyer and first-offer assertions were DELETED. This is the single
    // pin standing between the repo and their return, and it runs against the
    // FULL four-row fixture so it cannot pass merely because nothing rendered.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-OFFER: no buyer identity and no offer column anywhere — the removal must not come back', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        // Guard the guard: four tiles genuinely rendered, so every absence below
        // is a real absence rather than an empty component.
        expect(dataRows(element).length).toBe(4);

        // 1. THE OLD SELECTOR. `.dbt-buyer` was the tile heading's class.
        expect(element.shadowRoot.querySelector('.dbt-buyer')).toBeNull();

        // 2. THE COLUMN COUNT. Five dt/dd pairs was the old shape; three is the
        //    new one. A re-added column shows up here before it shows up
        //    anywhere else.
        dataRows(element).forEach((tile) => {
            expect(tile.querySelectorAll('dt').length).toBe(3);
            expect(tile.querySelectorAll('dd').length).toBe(3);
        });

        // 3. 🔴 THE RENDERED WORDS. A re-added surface usually arrives under a new
        //    class name, so the selector assertions above would stay green while
        //    a "First offer" label sat on every tile. These are the assertions
        //    that catch that.
        const text = element.shadowRoot.textContent.toLowerCase();
        expect(text).not.toContain('first offer');
        expect(text).not.toContain('days to respond');
        // "buyer" must not appear as a rendered word at all — not in the title,
        // not in a label, not in the empty state. (It could once also have
        // appeared in the intro line; that line was removed on 2026-08-21 — see
        // T-NO-PROSE below.)
        expect(text).not.toContain('buyer');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // The intro line above the tile list — "Every NDA raised on this
    // disposition, in order. NDAs that were declined are kept as a record and
    // shown last." — was removed at the user's request. Nothing in this file
    // asserted it, so its deletion left nothing to fail if it returns.
    //
    // 🔴 THE EMPTY STATE'S SUB-LINE WAS **KEPT**, and this pin is deliberately
    // scoped so it does not fight the EMPTY BRANCH test that asserts it
    // positively. The user kept empty states explicitly — they distinguish empty
    // from loading from broken. Do not widen this pin to "no explanatory copy
    // anywhere" without re-reading that decision.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: no intro line above the tile list — the removal must not come back', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        // Guard the guard: four tiles genuinely rendered.
        expect(dataRows(element).length).toBe(4);

        // 1. THE OLD SELECTOR.
        expect(element.shadowRoot.querySelector('.dbt-intro')).toBeNull();

        // 2. 🔴 THE RENDERED WORDS — a re-added line usually arrives under a new
        //    class name, so the selector alone would stay green.
        const words = element.shadowRoot.textContent.toLowerCase();
        expect(words).not.toContain('every nda raised on this disposition');
        expect(words).not.toContain('kept as a record and shown last');

        // 3. 🔴 NO DANGLING aria-describedby. The paragraph carried `id="dbt-intro"`
        //    and the list pointed at it; an aria-describedby naming a removed
        //    element promises a description that resolves to nothing, which is
        //    strictly worse than having none. This catches "deleted the <p>, left
        //    the attribute".
        const list = element.shadowRoot.querySelector('.dbt-list');
        expect(list.getAttribute('aria-describedby')).toBeNull();
        // The list's own accessible NAME is unaffected and must stay — it has to
        // keep matching the card title (see T-NARROW).
        expect(list.getAttribute('aria-label')).toBe('Broker activity timeline');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Narrow-column anti-regression pins (2026-08-21)
    // ─────────────────────────────────────────────────────────────────────────

    // T-NARROW — the direct pin. A test that merely renders would not catch a
    // revert to the six-column table; this does, in four lines.
    it('T-NARROW: renders no table, no shared heading row and no scroll wrapper', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('table')).toBeNull();
        expect(element.shadowRoot.querySelector('thead')).toBeNull();
        // `.dbt-head` was the shared column-heading row of the old grid, and
        // `.lv-scroll` is this repo's retired horizontal-overflow wrapper.
        expect(element.shadowRoot.querySelector('.dbt-head')).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-scroll')).toBeNull();

        // The tile list is what replaced it, and it keeps the label + explicit
        // role="list" the <ul> needs (list-style:none makes WebKit drop the
        // implicit list role, and aria-label is only exposed on an element whose
        // role supports naming; axe has no rule for this, so `is accessible`
        // passing is not evidence against it).
        const list = element.shadowRoot.querySelector('.dbt-list');
        expect(list).not.toBeNull();
        expect(list.getAttribute('role')).toBe('list');
        // Renamed with the card on 2026-08-21. It must keep MATCHING the card
        // title — a list announced under a different name than the card wrapping
        // it reads to a screen-reader user as a second, unrelated region.
        expect(list.getAttribute('aria-label')).toBe('Broker activity timeline');
    });

    // T-LABELS — proves the old <th scope="col"> semantics were REPLACED, not
    // deleted. In a 340px tile a bare date is unidentifiable without a label,
    // and the labels are now per-tile visible text rather than a heading row
    // sitting far away at the top of the card.
    it('T-LABELS: every value keeps a visible label on its own tile', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const labels = [...dataRows(element)[0].querySelectorAll('dt')].map((d) =>
            d.textContent.trim()
        );
        expect(labels).toEqual([
            'NDA signed',
            'Materials released',
            'Days to release'
        ]);
    });

    // T-RAIL — the milestone marker is DECORATION and must be derived from the
    // rendered value, never from the raw payload. The declined fixture is the
    // falsifier: it carries a real ndaSignedDate, so a marker computed from the
    // DTO would show "done" beside an em-dash.
    it('T-RAIL: milestone markers agree with the cell beside them, declined rows included', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        const stepState = (tile) =>
            [...tile.querySelectorAll('.dbt-step')].map((dt) =>
                dt.classList.contains('dbt-step--done') ? 'done' : 'pending'
            );

        // COMPLETE_ROW — both dates present.
        expect(stepState(dataRows(element)[0])).toEqual(['done', 'done']);
        // IN_FLIGHT_ROW — nothing recorded yet.
        expect(stepState(dataRows(element)[1])).toEqual(['pending', 'pending']);
        // 🔴 DECLINED_ROW — carries a RETAINED ndaSignedDate in the payload. The
        // cell is em-dashed, so the marker must be pending too.
        expect(stepState(dataRows(element)[3])).toEqual(['pending', 'pending']);

        // The connector is suppressed below the LAST milestone only — which is
        // now "Materials released", not "First offer".
        const ends = [
            ...dataRows(element)[0].querySelectorAll('.dbt-step--end')
        ];
        expect(ends.length).toBe(1);
        expect(ends[0].textContent.trim()).toBe('Materials released');
    });

    // T-CSS — the stylesheet pin, and it is deliberately a SOURCE-TEXT assertion
    // rather than a measurement. WHY (do not "improve" this into a measurement):
    // jsdom performs NO LAYOUT. scrollWidth, clientWidth, offsetWidth and
    // getBoundingClientRect() all return 0, so the obvious test —
    // expect(el.scrollWidth).toBeLessThanOrEqual(el.clientWidth) — is `0 <= 0`
    // and passes vacuously WHETHER OR NOT the component overflows. A source-text
    // assertion is coarse but falsifiable.
    it('T-CSS: the stylesheet cannot produce sideways scroll at 340px', () => {
        // --- BANNED --------------------------------------------------------
        // Matches the `overflow` SHORTHAND as well as `overflow-x`. An
        // /overflow-x/-only assertion is a hole: `.dbt-list { overflow: auto }`
        // restores exactly the horizontal scrollbar this rework removed.
        expect(CSS_SOURCE).not.toMatch(/overflow(-x)?\s*:\s*(auto|scroll)/);

        // Deliberately broader than /white-space:\s*nowrap/: the value that
        // actually threatens this layout is `flex-wrap: nowrap` on
        // .dbt-tile-head, which the white-space-specific form does not see.
        expect(CSS_SOURCE).not.toMatch(/nowrap/);

        // No fixed pixel width on content. `min-width` / `max-width` are not
        // matched (the char before "width" is a hyphen, not a boundary), and
        // neither is the decorative marker's `width: var(--slds-g-sizing-3,…)`.
        expect(CSS_SOURCE).not.toMatch(/(^|[\s;{])width\s*:\s*\d+px/);

        // The old six-column track list, named outright so a revert is caught
        // even if the class names are kept.
        expect(CSS_SOURCE).not.toMatch(/repeat\(\s*5\s*,/);

        // --- REQUIRED, and every one SELECTOR-ANCHORED ----------------------
        // An unanchored /min-width:\s*0/ passes while ANY ONE of the many
        // occurrences survives. The LOAD-BEARING one is on the grid item.
        expect(CSS_SOURCE).toMatch(/\.dbt-tile\s*\{[^}]*min-width\s*:\s*0/);

        // overflow-wrap must be on :host, not .dbt-tile — that is what makes it
        // reach the .lv-error banner (a server message this component cannot
        // pre-wrap) and the empty state, not just the tiles.
        expect(CSS_SOURCE).toMatch(/:host\s*\{[^}]*overflow-wrap\s*:\s*anywhere/);

        // The grid minimum. A bare `minmax(18rem, 1fr)` bursts any container
        // narrower than 288px — invisible at desktop width, and the ONLY place
        // it shows is the sidebar this rework exists for.
        expect(CSS_SOURCE).toMatch(/minmax\(\s*min\(\s*18rem\s*,\s*100%\s*\)/);

        // The broker subtitle, added 2026-08-21, must shrink like everything
        // else on the tile — it is the longest free-text value on the card now
        // that the buyer name is gone.
        expect(CSS_SOURCE).toMatch(/\.dbt-broker\s*\{[^}]*min-width\s*:\s*0/);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTimeline.emit(TIMELINE);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible on the empty state', async () => {
        const element = createComponent();

        getTimeline.emit([]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
