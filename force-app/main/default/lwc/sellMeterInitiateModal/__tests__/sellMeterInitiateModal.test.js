/**
 * c-sell-meter-initiate-modal — LightningModal + IMPERATIVE Apex suite.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 sfdx-lwc-jest SHIPS NO `lightning/modal` STUB — READ jest-mocks/lightning/modal.js
 * ─────────────────────────────────────────────────────────────────────────────
 * Verified against @salesforce/sfdx-lwc-jest 7.9.0: `src/lightning-stubs/` has
 * modalHeader / modalBody / modalFooter but NOT `modal`. A repo-local stub is
 * mapped in via `jest.config.js` -> moduleNameMapper. Without it this whole file
 * dies with "Cannot find module 'lightning/modal'" — a resolution error that
 * reads like a typo rather than like a missing stub.
 *
 * Because the stub extends LightningElement, the modal is mounted DIRECTLY with
 * createElement here and driven like any other component; `close(result)` is
 * observed through the stub's `close` CustomEvent. There is no promise to await,
 * because there is no platform `open()` in play — that path is exercised from
 * the OPENER's suite (`c-sell-meter-list`), which mocks this module wholesale.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING ASSERTIONS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. The Sell Type picklist has NO DEFAULT and the confirm button is DISABLED
 *    until it is answered. A default would silently decide the entire downstream
 *    path (On-Market gets BOV Outreach + Active Listing; Off-Market gets neither)
 *    for a user who never looked at the control.
 * 2. The values sent to Apex are RECORD TYPE DEVELOPER NAMES ('On_Market' /
 *    'Off_Market'), not labels. The service allow-lists them character-for-
 *    character and masks the resulting exception as a generic write failure, so
 *    a label leaking through here surfaces as an unexplained "could not create".
 *    🔴 THE LABELS AND THE VALUES DIVERGED ON 2026-08-24 and the suite asserts
 *    them SEPARATELY for exactly that reason: the labels gained a hyphen
 *    ('On-Market'), the values did not ('On_Market'), and no `Sell_Type__c` field
 *    was created. A test asserting only the option objects wholesale still passes
 *    if someone "harmonises" the two — the split assertions below do not.
 * 3. `submitted === false` closes with the OUTCOME, not with an error. It is a
 *    success path — the record exists — and only the caller's toast variant
 *    differs. Turning it into `{ error }` would tell a user nothing was created
 *    about a record that is sitting there.
 * 4. A THROW closes with `{ error }` rather than keeping the form open. Every
 *    refusal reachable here is a property of the ASSET (RED band, already-open
 *    disposition), so re-picking the other record type and retrying produces the
 *    identical refusal.
 * 5. The modal is titled "Decide to Sell - Approval" and the control is a
 *    PICKLIST labelled "Sell Type" (both user instructions, 2026-08-24). Pinned
 *    exactly, never by substring — the point of those assertions is to detect
 *    the rename being reverted, and a substring match survives a revert.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 WHY THESE ASSERT ELEMENT PROPERTIES, NOT GETTERS (2026-08-24 rework)
 * ─────────────────────────────────────────────────────────────────────────────
 * `lightning-combobox`'s Jest stub renders `<template></template>` — an EMPTY
 * template — so no option label ever reaches the jsdom text content and
 * `textContent` cannot be asserted on. The strongest available statement is
 * therefore the property read off the `<lightning-combobox>` ELEMENT IN THE
 * SHADOW ROOT, which is what the TEMPLATE passed it.
 * ⚠ That is deliberately NOT `element.recordTypeOptions`. This repo has a
 * measured defect where a getter-only assertion stayed green while the rendered
 * attribute was wrong (a getter bound into markup is written unconditionally),
 * so reading the getter proves the array exists, never that the markup binds it.
 * Every assertion below goes through `sellType(element)` / `modalHeader(element)`.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 T-GRID-* — THE SUMMARY LAYOUT, AND WHY IT IS TESTED THE WAY IT IS
 * ─────────────────────────────────────────────────────────────────────────────
 * The summary renders TWO label/value pairs per row (2026-08-24), produced
 * ENTIRELY by CSS grid tracks over one flat dt/dd iteration. jsdom performs no
 * layout, so no test available here can observe a rendered column position —
 * "it looks like two columns" is not a provable statement and no assertion
 * below pretends to make one.
 *
 * What IS provable, and what T-GRID-1..6 actually pin:
 *   1. the rendered DOM is a flat dt/dd stream with NO wrapper element and no
 *      per-position class or style — i.e. the markup encodes no column at all;
 *   2. the REAL stylesheet declares an EVEN, FIXED number of grid tracks in
 *      both states (2 narrow / 4 wide), read out of the .css file itself;
 *   3. laying the REAL rendered items into that REAL track count, row-major
 *      the way grid auto-placement does, keeps every dt beside its own dd and
 *      never splits a pair across rows — checked at 3, 4 AND 5 rows.
 * (3) is the count-independence proof this layout exists to guarantee. It is a
 * simulation and is labelled as one; its inputs are both real (the track count
 * comes from the stylesheet, the 4-row case is cross-checked against the live
 * DOM in T-GRID-2) so it cannot go green on a layout that was never written.
 *
 * ⚠ WHY THE ROW COUNT IS SIMULATED RATHER THAN RENDERED: `summaryRows` takes no
 * input that varies its LENGTH — every one of the four entries renders an em
 * dash when its @api value is absent, deliberately (see the JS). So there is no
 * way to mount this component with 3 or 5 rows today, and hand-building a <dl>
 * in the test would prove only that the fabrication was fabricated. When a
 * fifth entry is added for real, T-GRID-2's expected list is the ONE place that
 * needs updating — every other assertion is already count-agnostic.
 *
 * 🔴 T-NO-RADIO — the control was a `lightning-radio-group` until 2026-08-24
 * ("Don't show radio button", user instruction). The picklist assertions alone
 * would all pass with BOTH controls rendered side by side, so the absence of the
 * radio group is pinned separately below.
 */
import { createElement } from 'lwc';
import SellMeterInitiateModal from 'c/sellMeterInitiateModal';
import initiateAndSubmit from '@salesforce/apex/DispositionController.initiateAndSubmit';

jest.mock(
    '@salesforce/apex/DispositionController.initiateAndSubmit',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const ASSET_ID = 'a0P000000000GRN';
const DISPOSITION_ID = 'a0D0000000000001';

const PROPS = {
    assetId: ASSET_ID,
    propertyName: 'Gateway Plaza',
    noiLabel: '$2.0M',
    capRateLabel: '6.5%',
    targetLabel: '$30.0M',
    peakDateLabel: 'Aug 12, 2027'
};

// The stylesheet and the template, read once, WITH THEIR COMMENTS STRIPPED.
// Stripping first is not cosmetic and it is not optional here: both files
// DESCRIBE the banned constructions by name ("do NOT simplify this into
// repeat(auto-fit, ...)", "DO NOT SPLIT THIS INTO TWO COLUMN <div>s"), so every
// ban below would otherwise fail against its own documentation. Same convention
// as c-competing-broker-submissions' T2.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'sellMeterInitiateModal.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

const HTML_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'sellMeterInitiateModal.html'),
        'utf8'
    )
    .replace(/<!--[\s\S]*?-->/g, '');

/**
 * Cut a top-level at-rule out of `css` by BRACE MATCHING, returning its
 * prelude, its body, and the stylesheet with the whole block removed.
 * Brace-matched rather than regexed because the block contains nested rules — a
 * lazy `[^}]*` would stop at the first inner `}` and report an EMPTY at-rule,
 * which is precisely the shape a "the wide state is missing" assertion must not
 * mistake for success.
 */
function sliceAtRule(css, at) {
    const start = css.indexOf(at);
    if (start === -1) {
        return { prelude: null, body: null, rest: css };
    }
    const open = css.indexOf('{', start);
    let depth = 0;
    let i = open;
    for (; i < css.length; i++) {
        if (css[i] === '{') {
            depth++;
        } else if (css[i] === '}') {
            depth--;
            if (depth === 0) {
                break;
            }
        }
    }
    return {
        prelude: css.slice(start, open).trim(),
        body: css.slice(open + 1, i),
        rest: css.slice(0, start) + css.slice(i + 1)
    };
}

/** One declaration's value out of one rule, or undefined. */
function declaration(css, selector, prop) {
    const rule = new RegExp(
        '(?:^|[};])\\s*' +
            selector.replace(/\./g, '\\.') +
            '(?![\\w-])\\s*\\{([^}]*)\\}'
    ).exec(css);
    if (!rule) {
        return undefined;
    }
    const decl = new RegExp('(?:^|;)\\s*' + prop + '\\s*:\\s*([^;]+)').exec(
        rule[1]
    );
    return decl ? decl[1].trim().replace(/\s+/g, ' ') : undefined;
}

/** `grid-template-columns` as a list of tracks. */
function tracks(css, selector) {
    const value = declaration(css, selector, 'grid-template-columns');
    return value === undefined ? undefined : value.split(' ');
}

// The two layout states, READ FROM THE REAL STYLESHEET rather than restated.
const WIDE = sliceAtRule(CSS_SOURCE, '@media');
const NARROW_TRACKS = tracks(WIDE.rest, '.smi-summary');
const WIDE_TRACKS = tracks(WIDE.body, '.smi-summary');

/**
 * CSS grid auto-placement, row-major, for `rowCount` label/value pairs laid
 * into `trackCount` columns — the same flat dt,dd,dt,dd,... stream the template
 * emits.
 */
function placePairs(rowCount, trackCount) {
    const cells = [];
    for (let i = 0; i < rowCount; i++) {
        cells.push({ tag: 'DT', pair: i }, { tag: 'DD', pair: i });
    }
    const rows = [];
    for (let i = 0; i < cells.length; i += trackCount) {
        rows.push(cells.slice(i, i + trackCount));
    }
    return rows;
}

/** Chunk a flat list of rendered cells into visual rows of `trackCount`. */
function chunk(cells, trackCount) {
    const rows = [];
    for (let i = 0; i < cells.length; i += trackCount) {
        rows.push(cells.slice(i, i + trackCount));
    }
    return rows;
}

/**
 * Every pair in `rows` is intact: a dt immediately followed, IN THE SAME ROW,
 * by its own dd. False the moment the track count is odd — which is the single
 * failure an auto-fit / auto-fill track list would introduce, and it corrupts
 * every row, not just the last one.
 */
function pairsIntact(rows) {
    return rows.every(
        (row) =>
            row.length % 2 === 0 &&
            row.every((cell, i) =>
                i % 2 === 0
                    ? cell.tag === 'DT'
                    : cell.tag === 'DD' && cell.pair === row[i - 1].pair
            )
    );
}

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-sell-meter-initiate-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = PROPS) {
        const element = createElement('c-sell-meter-initiate-modal', {
            is: SellMeterInitiateModal
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    // The RENDERED control — read every property off this element, never off the
    // component's getters (see the header).
    const sellType = (el) => el.shadowRoot.querySelector('lightning-combobox');
    const modalHeader = (el) =>
        el.shadowRoot.querySelector('lightning-modal-header');
    const confirmBtn = (el) => el.shadowRoot.querySelector('.smi-confirm');
    const cancelBtn = (el) => el.shadowRoot.querySelector('.smi-cancel');

    function chooseRecordType(element, value) {
        sellType(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        return Promise.resolve();
    }

    it('renders the caller-supplied property summary verbatim — it formats nothing itself', async () => {
        const element = createComponent();

        await Promise.resolve();

        const values = [
            ...element.shadowRoot.querySelectorAll('.smi-value')
        ].map((n) => n.textContent);
        expect(values).toEqual([
            '$2.0M',
            '6.5%',
            '$30.0M',
            'Aug 12, 2027'
        ]);
        // ⚠ THE ASSERTION THAT `.smi-intro` NAMED THE PROPERTY WAS DELETED ON
        // 2026-08-21, NOT SOFTENED. The intro paragraph went with the UAT prose
        // removal and it was the only surface rendering `propertyName`, so there is
        // no weaker version of that assertion to keep — the value is not displayed
        // at all now. See T-NO-PROSE below, which records the consequence.
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 T-GRID-1..6 — THE TWO-PAIRS-PER-ROW SUMMARY LAYOUT (2026-08-24)
    // Read the "T-GRID-*" section of the file header before changing any of
    // these — in particular, why the ROW COUNT is simulated and not rendered.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 T-GRID-1: the <dl> is ONE flat dt/dd stream — the markup encodes no column', async () => {
        const element = createComponent();

        await Promise.resolve();

        const list = element.shadowRoot.querySelector('dl.smi-summary');
        expect(list).not.toBeNull();
        const items = [...list.children];

        // Four pairs, strictly alternating, nothing in between.
        expect(items.map((n) => n.tagName)).toEqual([
            'DT',
            'DD',
            'DT',
            'DD',
            'DT',
            'DD',
            'DT',
            'DD'
        ]);

        // 🔴 NO WRAPPER ELEMENTS. Grid items are the <dl> element's DIRECT children, so
        // wrapping the iteration leaves the grid holding ONE item and no
        // columns at all — and hardcoded halves would need rebalancing by hand
        // the day a fifth row lands.
        //
        // ⚠ THIS LINE IS THE ONLY THING STANDING BETWEEN THE LAYOUT AND THAT
        // EDIT, AND `is accessible` IS NOT A BACKSTOP FOR IT. Measured by
        // mutation on 2026-08-24: wrapping the iteration in
        // `<div class="smi-col">` left the accessibility test GREEN — the HTML
        // spec permits <div> grouping inside a <dl> and axe follows the spec.
        // T-GRID-1, T-GRID-2 and T-GRID-6 went red; nothing else did.
        expect(list.querySelectorAll('div, span, ul, li').length).toBe(0);
        items.forEach((n) => expect(n.children.length).toBe(0));

        // 🔴 NO PER-POSITION STYLING. Every dt carries the SAME class and every
        // dd the same class — no first/last/left/right variant, no inline
        // style. That is what makes an element's index irrelevant to the
        // layout, and it is the property a later "just target the 3rd one" edit
        // destroys.
        expect([
            ...new Set(
                items.filter((n) => n.tagName === 'DT').map((n) => n.className)
            )
        ]).toEqual(['smi-label']);
        expect([
            ...new Set(
                items.filter((n) => n.tagName === 'DD').map((n) => n.className)
            )
        ]).toEqual(['smi-value']);
        expect(items.some((n) => n.getAttribute('style'))).toBe(false);
    });

    it('🔴 T-GRID-2: two pairs per row, ACROSS-THEN-DOWN — at the stylesheet REAL track count', async () => {
        const element = createComponent();

        await Promise.resolve();

        // The rendered stream...
        const cells = [
            ...element.shadowRoot.querySelectorAll('dl.smi-summary > *')
        ].map((n) => n.textContent);

        // ...chunked by the track count read out of the REAL .css file. Both
        // halves are real, so changing the DOM order OR the track count fails
        // this test.
        expect(WIDE_TRACKS).toBeDefined();

        // 🔴 THE COLUMN-ORDER DECISION, STATED ONCE. Row-major: pairs read
        // left-to-right, then wrap. Column-major (NOI above Market Cap Rate in
        // a left-hand column) was rejected — it cannot be expressed without
        // baking ceil(N / 2) into grid-template-rows, and adding a 5th entry
        // would MOVE an existing entry between columns instead of appending.
        expect(chunk(cells, WIDE_TRACKS.length)).toEqual([
            ['NOI', '$2.0M', 'Market Cap Rate', '6.5%'],
            ['Target Price', '$30.0M', 'Peak Sell Date', 'Aug 12, 2027']
        ]);

        // And the fallback state stacks one pair per row, same source order.
        expect(chunk(cells, NARROW_TRACKS.length)).toEqual([
            ['NOI', '$2.0M'],
            ['Market Cap Rate', '6.5%'],
            ['Target Price', '$30.0M'],
            ['Peak Sell Date', 'Aug 12, 2027']
        ]);
    });

    it('🔴 T-GRID-3: the track count is EVEN and FIXED in both states — 2 narrow, 4 wide', () => {
        // Read from the stylesheet, not restated here: `.smi-summary`
        // unconditionally declares one pair per row and the @container block
        // raises it to two.
        expect(declaration(WIDE.rest, '.smi-summary', 'display')).toBe('grid');
        expect(NARROW_TRACKS).toEqual(['auto', '1fr']);
        expect(WIDE_TRACKS).toEqual(['auto', '1fr', 'auto', '1fr']);

        // 🔴 EVEN, AND LITERAL. An odd track count interleaves every dd under
        // the wrong dt (T-GRID-4 proves that), and repeat(auto-fit/auto-fill,…)
        // — the "simplification" this shape invites — resolves to whatever
        // number of tracks happens to fit, odd counts included.
        [NARROW_TRACKS, WIDE_TRACKS].forEach((list) => {
            expect(list.length % 2).toBe(0);
            expect(list.join(' ')).not.toMatch(/auto-fit|auto-fill|repeat\(/);
        });

        // Nothing may reorder or re-flow the stream: column-major placement and
        // positional selectors each re-introduce the ROW COUNT into the CSS.
        expect(CSS_SOURCE).not.toMatch(/grid-auto-flow\s*:\s*column/);
        expect(CSS_SOURCE).not.toMatch(/grid-template-rows/);
        expect(CSS_SOURCE).not.toMatch(
            /nth-child|nth-of-type|:first-child|:last-child/
        );
    });

    it('🔴 T-GRID-4: the layout survives 3, 4 and 5 rows — no split pair, no stranded value', () => {
        // SIMULATION — see the header for why the row count cannot be rendered.
        // Its inputs are the REAL track counts above, and its 4-row case is
        // cross-checked against the live DOM in T-GRID-2.
        [NARROW_TRACKS.length, WIDE_TRACKS.length].forEach((trackCount) => {
            [3, 4, 5].forEach((rowCount) => {
                const rows = placePairs(rowCount, trackCount);
                const where = rowCount + ' rows at ' + trackCount + ' tracks';

                // Every dt sits beside its OWN dd, in the same row. Asserted
                // with the case in the expected value so a failure names the
                // combination instead of just saying "false".
                expect(where + ': ' + pairsIntact(rows)).toBe(where + ': true');

                // Nothing lost, nothing duplicated.
                expect(rows.reduce((n, r) => n + r.length, 0)).toBe(
                    rowCount * 2
                );

                // The last row of an ODD row count is a COMPLETE pair in the
                // leftmost tracks — a half-filled row, never a stranded <dd>
                // under an empty label. That is the orphan case this design
                // exists to prevent.
                const last = rows[rows.length - 1];
                expect(where + ': ' + (last.length % 2)).toBe(where + ': 0');
                expect(where + ': ' + last[0].tag).toBe(where + ': DT');
            });
        });

        // Positive control for the loop above: the SAME simulation at an ODD
        // track count must come back false, otherwise pairsIntact() is vacuous.
        expect(pairsIntact(placePairs(4, 3))).toBe(false);
        expect(pairsIntact(placePairs(5, 3))).toBe(false);
    });

    it('🔴 T-GRID-5: degrades to one pair per row — the wide state is CONDITIONAL and MIN-width', () => {
        // The 4-track rule exists ONLY inside the at-rule. Unconditional 4
        // tracks would burst a narrow modal body, which is worse than the stack
        // it replaced.
        expect(WIDE.prelude).not.toBeNull();
        expect(WIDE.rest).not.toMatch(/auto 1fr auto 1fr/);
        expect(WIDE.body).toMatch(/auto 1fr auto 1fr/);

        // 🔴 MIN-WIDTH, NOT MAX-WIDTH — this is the whole degradation contract
        // and it is a one-word edit away from being inverted. `min-width` makes
        // the STACK the default and two-up the exception, so anywhere the query
        // does not apply (a narrow screen, a context that never matches) falls
        // back to the layout this component shipped with for months. A
        // `max-width` query renders identically on a desktop and is broken
        // everywhere else, which is exactly the kind of regression that reaches
        // production.
        expect(WIDE.prelude).toMatch(/^@media\b/);
        expect(WIDE.prelude).toMatch(/min-width/);
        expect(WIDE.prelude).not.toMatch(/max-width/);

        // ⚠ A CONTAINER QUERY WOULD MEASURE THE RIGHT BOX AND WAS STILL BACKED
        // OUT — see the stylesheet for the two reasons (size containment on a
        // production modal nobody can open here; jsdom discarding the entire
        // stylesheet on @container, measured as the ONLY such error in the
        // repo's suite). Recorded so this line is understood as a decision and
        // not as an oversight; it is not asserted, because a future @container
        // would be a legitimate change and should not have to fight a test.

        // SLDS 2 tokens for everything the wide state adds. The breakpoint
        // itself is a bare 64rem BY NECESSITY — an at-rule prelude cannot
        // resolve var(), so a token there would not fall back, it would
        // disable the query outright.
        expect(
            declaration(WIDE.body, '.smi-value', 'padding-inline-end')
        ).toMatch(/^var\(--slds-g-[\w-]+, /);

        // No hardcoded colour anywhere, in the new block or out of it: strip
        // every var() FALLBACK first, then hunt for a hex that survived.
        expect(
            CSS_SOURCE.replace(/var\(\s*(--[\w-]+)\s*,[^()]*\)/g, 'var($1)')
        ).not.toMatch(/#[0-9a-f]{3,8}\b/i);
    });

    it('🔴 T-GRID-6: the template ITERATES the rows — it never enumerates or halves them', () => {
        const list = /<dl[\s\S]*?<\/dl>/.exec(HTML_SOURCE);
        expect(list).not.toBeNull();
        const markup = list[0];

        // Exactly one iteration over summaryRows, and it is the only content.
        expect((markup.match(/for:each=\{summaryRows\}/g) || []).length).toBe(1);
        expect(markup).not.toMatch(/<div|slds-grid|slds-col|lwc:if|lwc:else/);

        // No row's label may be written into the markup — a literal here IS a
        // hardcoded row, and the count follows it.
        expect(markup).not.toMatch(/NOI|Cap Rate|Target Price|Peak Sell/);

        // Positive control for the two bans above: the scan really is looking
        // at the rendered template and not at an empty string. (HTML_SOURCE has
        // its comments stripped, so the `<div>` the comment warns against does
        // not reach the ban.)
        expect(markup).toContain('<dt key={row.labelKey}');
        expect(markup).toContain('<dd key={row.valueKey}');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // `.smi-intro` — "Initiating a disposition for <property> creates the record
    // and sends it straight into the Sale Decision approval." — was removed at
    // the user's request. It is the same shape as the string they quoted: a
    // sentence restating what the button below does.
    //
    // ⚠ IT WAS ALSO THE ONLY PLACE THIS DIALOG NAMED THE PROPERTY. That is a real
    // cost, recorded here rather than hidden: the modal is only ever opened from
    // a row the user just clicked in c/sellMeterList, and `@api propertyName` is
    // still accepted. If the name is wanted back it belongs as a fifth
    // `summaryRows` entry — a label/value pair — NOT as a restored sentence, and
    // the row-count assertion below is what would then need updating.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: no intro paragraph — the removal must not come back', async () => {
        const element = createComponent();

        await Promise.resolve();

        // Guard the guard: the summary genuinely rendered, so the absences below
        // are real absences and not an unrendered component.
        expect(element.shadowRoot.querySelectorAll('.smi-value').length).toBe(4);
        expect(sellType(element)).not.toBeNull();

        // 1. THE OLD SELECTOR.
        expect(element.shadowRoot.querySelector('.smi-intro')).toBeNull();

        // 2. 🔴 THE RENDERED WORDS — a re-added paragraph usually arrives under a
        //    new class name, so the selector alone would stay green.
        const text = element.shadowRoot.textContent.toLowerCase();
        expect(text).not.toContain('initiating a disposition for');
        expect(text).not.toContain('creates the record');
        expect(text).not.toContain('straight into the sale decision approval');

        // 3. 🔴 WHAT MUST SURVIVE. The behaviour the sentence described is now
        //    stated ONLY by the button label, so this half of the pin is what
        //    stops a later edit renaming it to something that says nothing.
        expect(confirmBtn(element).label).toBe('Send for Approval');
    });

    it('renders an em dash — NOT "undefined" — for a summary value the caller omitted', async () => {
        const element = createComponent({ assetId: ASSET_ID });

        await Promise.resolve();

        const values = [
            ...element.shadowRoot.querySelectorAll('.smi-value')
        ].map((n) => n.textContent);
        expect(values).toEqual(['—', '—', '—', '—']);
        // Asserted on the RENDERED text, not on the getter: a getter bound into
        // the DOM is written unconditionally, and `undefined` renders as the
        // literal string "undefined".
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    it('HEADER: the modal is titled "Decide to Sell - Approval"', async () => {
        const element = createComponent();

        await Promise.resolve();

        // Read off the RENDERED <lightning-modal-header>, which is what the
        // template bound — a hardcoded literal in the markup has no getter to
        // check, and this is the only place the string is observable.
        expect(modalHeader(element)).not.toBeNull();
        expect(modalHeader(element).label).toBe('Decide to Sell - Approval');
        // 🔴 EXACT, NEVER `toContain`. The retitle (2026-08-24) is the whole
        // assertion; a substring match on "Approval" would pass for a revert to
        // anything that merely mentions it.
        expect(modalHeader(element).label).not.toBe('Initiate Disposition');
    });

    it('SELL TYPE: renders a combobox labelled "Sell Type" — required, with no default', async () => {
        const element = createComponent();

        await Promise.resolve();

        const control = sellType(element);
        expect(control).not.toBeNull();
        // The FIELD label the user reads above the picklist.
        expect(control.label).toBe('Sell Type');
        // No default. The choice is mandatory and the platform must not pick.
        expect(control.value).toBeUndefined();
        expect(control.required).toBe(true);
    });

    it('SELL TYPE: the option LABELS are hyphenated — "On-Market" / "Off-Market"', async () => {
        const element = createComponent();

        await Promise.resolve();

        const options = sellType(element).options;
        // Asserted as its own list, separately from the values below. The hyphen
        // is a 2026-08-24 user instruction that exists ONLY here — the record
        // type labels were deliberately not changed and no Sell_Type__c field
        // was created — so this is the single surface that can regress it.
        expect(options.map((o) => o.label)).toEqual(['On-Market', 'Off-Market']);
    });

    it('SELL TYPE: offers exactly two options, and their VALUES are record type developer names', async () => {
        const element = createComponent();

        await Promise.resolve();

        const options = sellType(element).options;
        expect(options).toHaveLength(2);
        // 🔴 THE VALUES DID NOT GAIN THE HYPHEN. They are matched
        // character-for-character by DispositionService's record type allow-list;
        // 'On-Market' here would surface to the user as an unexplained "could not
        // create", because the resulting exception is masked as a generic write
        // failure.
        expect(options.map((o) => o.value)).toEqual(['On_Market', 'Off_Market']);
        expect(options).toEqual([
            { label: 'On-Market', value: 'On_Market' },
            { label: 'Off-Market', value: 'Off_Market' }
        ]);
    });

    it('🔴 T-NO-RADIO: the radio group is GONE — the picklist did not join it', async () => {
        const element = createComponent();

        await Promise.resolve();

        // Guard the guard: the body genuinely rendered, so the absence below is
        // a real absence and not an unrendered component.
        expect(element.shadowRoot.querySelectorAll('.smi-value').length).toBe(4);
        expect(sellType(element)).not.toBeNull();

        // "Don't show radio button" (user instruction, 2026-08-24). Every other
        // assertion in this file passes with BOTH controls on screen — this is
        // the only one that does not.
        expect(
            element.shadowRoot.querySelector('lightning-radio-group')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('.smi-radio')).toBeNull();

        // The old field label went with it. A re-added control usually arrives
        // under a new class name, so the selectors alone would stay green.
        // ⚠ ASSERTED OVER `label` PROPERTIES, NOT `textContent`: every lightning
        // stub in sfdx-lwc-jest renders an EMPTY template, so the label of a
        // re-added radio group would never appear in the shadow root's text and
        // a `textContent` version of this line would be vacuously green.
        const labels = [...element.shadowRoot.querySelectorAll('*')].map(
            (n) => n.label
        );
        expect(labels).not.toContain('How is this property going to market?');
        // Positive control for the line above — the scan really does see labels.
        expect(labels).toContain('Sell Type');
    });

    it('GATE: "Send for Approval" is disabled until a record type is chosen', async () => {
        const element = createComponent();

        await Promise.resolve();
        expect(confirmBtn(element).disabled).toBe(true);

        await chooseRecordType(element, 'Off_Market');
        expect(confirmBtn(element).disabled).toBe(false);
    });

    it('GATE: clicking the disabled confirm button calls no Apex', async () => {
        const element = createComponent();

        await Promise.resolve();
        confirmBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).not.toHaveBeenCalled();
    });

    it('SUCCESS: sends the chosen developer name to Apex and closes with the outcome', async () => {
        const outcome = {
            dispositionId: DISPOSITION_ID,
            submitted: true,
            message: 'Disposition created and submitted for approval.'
        };
        initiateAndSubmit.mockResolvedValue(outcome);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await chooseRecordType(element, 'On_Market');
        confirmBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).toHaveBeenCalledTimes(1);
        // Parameter names ARE the Apex signature — an imperative call binds by name.
        // ⚠ `overrideReason` (added 2026-08-31, item 5b) is `undefined` here because this
        // fixture is the GREEN Initiate path, which never has one. `toHaveBeenCalledWith`
        // matches the WHOLE argument object, so this assertion also pins that the key is
        // SENT rather than omitted — the misspelling failure mode for that parameter is
        // completely silent on both sides (a wrong key simply arrives as a null argument
        // the server cannot distinguish from a GREEN initiate).
        expect(initiateAndSubmit).toHaveBeenCalledWith({
            assetId: ASSET_ID,
            recordTypeDeveloperName: 'On_Market',
            overrideReason: undefined
        });

        expect(closeHandler).toHaveBeenCalledTimes(1);
        expect(closeHandler.mock.calls[0][0].detail).toEqual({ outcome });
    });

    it('OFF-MARKET: the other picklist choice reaches Apex unchanged', async () => {
        initiateAndSubmit.mockResolvedValue({
            dispositionId: DISPOSITION_ID,
            submitted: true,
            message: 'ok'
        });

        const element = createComponent();

        await chooseRecordType(element, 'Off_Market');
        confirmBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).toHaveBeenCalledWith({
            assetId: ASSET_ID,
            recordTypeDeveloperName: 'Off_Market',
            overrideReason: undefined
        });
    });

    // ═════════════════════════════════════════════════════════════════════════
    // `overrideReason` — A PASS-THROUGH (2026-08-31, Tranche 2 item 5b)
    //
    // 🔴 THE TWO TESTS BELOW ARE A PAIR AND NEITHER MEANS ANYTHING ALONE. One says the
    // value REACHES APEX; the other says it is NEVER RENDERED. Together they pin the
    // design decision: the reason is collected one dialog earlier by
    // c/sellMeterOverrideModal, and this dialog stays byte-identical in its UI on both
    // paths — which its own class header requires ("deliberately identical apart from the
    // toast title, so an override can never diverge from an initiate"). The cheaper
    // alternative that was rejected — an override-only textarea in THIS dialog — passes
    // the first test and fails the second.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 OVERRIDE REASON: forwarded verbatim to Apex as the third argument', async () => {
        initiateAndSubmit.mockResolvedValue({
            dispositionId: DISPOSITION_ID,
            submitted: true,
            message: 'ok'
        });

        const reason = 'Fund matures in Q3 and the buyer pool is unusually deep.';
        const element = createComponent({ ...PROPS, overrideReason: reason });

        await chooseRecordType(element, 'On_Market');
        confirmBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).toHaveBeenCalledWith({
            assetId: ASSET_ID,
            recordTypeDeveloperName: 'On_Market',
            overrideReason: reason
        });
    });

    it('🔴 OVERRIDE REASON: never appears anywhere in the rendered dialog', async () => {
        const reason = 'ZZTOPSECRETREASONZZ';
        const element = createComponent({ ...PROPS, overrideReason: reason });

        await Promise.resolve();

        // Presence control: the value IS set (the test above proves it reaches Apex from
        // exactly this property), so an absent string here cannot be passing because the
        // property was ignored.
        expect(element.overrideReason).toBe(reason);
        expect(element.shadowRoot.innerHTML).not.toContain(reason);
        expect(element.shadowRoot.textContent).not.toContain(reason);
        // And no new input appeared to hold it — the Override path must not gain a field
        // the Initiate path lacks.
        expect(element.shadowRoot.querySelector('lightning-textarea')).toBeNull();
    });

    it('NOT-SUBMITTED IS A SUCCESS PATH: closes with the outcome, not with an error', async () => {
        const outcome = {
            dispositionId: DISPOSITION_ID,
            submitted: false,
            message: 'Created, but the approval could not be submitted.'
        };
        initiateAndSubmit.mockResolvedValue(outcome);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await chooseRecordType(element, 'On_Market');
        confirmBtn(element).click();
        await flushPromises();

        const detail = closeHandler.mock.calls[0][0].detail;
        expect(detail.outcome).toBe(outcome);
        expect(detail.error).toBeUndefined();
        // The Id is populated, which is the whole reason the caller still navigates.
        expect(detail.outcome.dispositionId).toBe(DISPOSITION_ID);
    });

    it('FAILURE: a thrown Apex error CLOSES the modal carrying the error', async () => {
        const error = {
            body: {
                message:
                    'This property is not ready to sell - its peak sell date is more than 90 days away.'
            }
        };
        initiateAndSubmit.mockRejectedValue(error);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await chooseRecordType(element, 'On_Market');
        confirmBtn(element).click();
        await flushPromises();

        expect(closeHandler).toHaveBeenCalledTimes(1);
        expect(closeHandler.mock.calls[0][0].detail).toEqual({ error });
    });

    it('CANCEL: closes with undefined and calls no Apex', async () => {
        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await Promise.resolve();
        cancelBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).not.toHaveBeenCalled();
        expect(closeHandler).toHaveBeenCalledTimes(1);
        // ⚠ `null`, not `undefined`, and that is a STUB ARTEFACT: CustomEvent's
        // own spec defaults an omitted `detail` to null. The real LightningModal
        // resolves `undefined` on a dismiss. Asserted as falsy so the test states
        // the contract the caller actually relies on (`if (!result) return;`)
        // rather than pinning the stub's coercion.
        expect(closeHandler.mock.calls[0][0].detail).toBeFalsy();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
