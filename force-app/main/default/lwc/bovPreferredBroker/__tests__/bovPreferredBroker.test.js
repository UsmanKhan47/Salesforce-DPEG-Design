/**
 * PRESENTATIONAL-COMPONENT TEMPLATE — five `@api` strings in, markup out.
 * ---------------------------------------------------------------------------
 * No wire, no Apex, no modal, no navigation: this bundle renders values handed
 * down by its parent. Everything worth breaking is either in the markup or in
 * the stylesheet, and jsdom performs no layout, so this file gates BOTH —
 * rendered elements and text for the markup, and SOURCE TEXT for the stylesheet.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 REWRITTEN 2026-08-25 (3). TWO CHANGES, AND THE FIRST WAS OVERDUE.
 * ═════════════════════════════════════════════════════════════════════════════
 * 1. IT WAS RED BEFORE THIS CHANGE, ON `main`. Commit `eefa83e` ("Preferred
 *    broker panel compacted to a dense row") rewrote the `.html` and the `.css`
 *    and touched NEITHER Jest suite, leaving TEN failing tests here and one in
 *    `c/bovBrokerPanel`. They asserted a component that no longer exists: a
 *    "YES" pill (`.pref-pill`, deleted with its rule), `.pref-firm` as the BOLD
 *    PRIMARY line (it is now the muted firm, and `.pref-name` carries the
 *    contact), and `.pref-eyebrow` as a block paragraph with its OWN colour and
 *    margin (it is now an inline span that INHERITS both from `.pref-meta`).
 *    Every one of those assertions is rewritten below against what the bundle
 *    actually renders — not deleted, because each was pinning a real
 *    requirement that survived the compaction in a different shape.
 * 2. THE THREE STAT COLUMNS are new, and are pinned in three ways: the values
 *    render from the props, a missing value renders `—`, and the whole block is
 *    ABSENT when a parent supplies none of them (which is what keeps
 *    `c/dispositionBuyerTimeline`'s narrow sidebar row unchanged).
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THERE ARE CSS SOURCE ASSERTIONS AT ALL.
 * ═════════════════════════════════════════════════════════════════════════════
 * Five requirements of this panel are invisible to every other gate we have:
 *   1. the green must be the `*-base-95` TINT, not `*-container-1` — measured,
 *      `--slds-g-color-success-container-1` is a SOLID mid-green, so the
 *      natural-looking `container-1` + `base-30` pairing is dark-on-dark;
 *   2. the muted text must NOT be `on-surface-1`, which measures 4.16:1 on this
 *      panel's tint — under AA, and green on every other gate;
 *   3. the `gap`s are MARKUP — the LWC compiler discards whitespace-only text
 *      nodes between siblings, so deleting one removes ALL spacing and no
 *      rendered text changes;
 *   4. `min-width: 0` + `overflow-wrap: anywhere` are what stop a long name
 *      overflowing rather than wrapping;
 *   5. the stat block's `flex: none` and `.pref-detail`'s `flex-grow` are the
 *      whole of the right-hand layout.
 * The SLDS linter only checks that a hook was USED. axe's colour-contrast rule
 * is INERT in jsdom. `getComputedStyle` resolves no custom properties and does
 * no layout. Source text is the only automated falsifier that exists.
 *
 * ⚠ THE COMMENTS ARE STRIPPED BEFORE ANY OF THOSE ASSERTIONS RUN. The
 * stylesheet's own header explains at length why `container-1` and
 * `on-surface-1` are wrong and names both tokens repeatedly; without the strip,
 * `not.toMatch(/container-1/)` matches the PROSE and every absence assertion in
 * this file is vacuously green.
 */
import { createElement } from 'lwc';
import BovPreferredBroker from 'c/bovPreferredBroker';

const CONTACT = 'Jane Okafor';
const FIRM = 'Cushman & Wakefield';

/** The three formatted strings exactly as `c/bovBrokerPanel` builds them. */
const STATS = {
    valuationLabel: '$12.5M',
    daysToMarketLabel: '45d',
    capRateLabel: '6.25%'
};

/**
 * The real shape of the value that broke this in review: a name long enough that
 * a flex item with the default `min-width: auto` refuses to shrink below it and
 * pushes the whole panel wider than its container.
 */
const LONG_FIRM =
    'Whitfield Marcus Commercial Real Estate Advisory Partners International LLP';

const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'bovPreferredBroker.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

/**
 * The body of a single top-level rule.
 *
 * ⚠ A REGEXP LITERAL WITH ONE CAPTURE GROUP, not a selector string. A
 * string-built `new RegExp(sel + ...)` needs escaping that is easy to get subtly
 * wrong, and a regex that silently fails to match returns null for EVERY rule
 * while the test still reads as though it were checking something. The
 * `expect(...).not.toBeNull()` on each call is what turns a bad anchor into a
 * red rather than into silence.
 */
function ruleBody(ruleRegExp) {
    const match = CSS_SOURCE.match(ruleRegExp);
    return match ? match[1] : null;
}

describe('c-bov-preferred-broker', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    /**
     * ⚠ THE DEFAULT PARAMETER IS USED WHEN NO ARGUMENT IS PASSED — and passing
     * `undefined` explicitly ALSO uses it. The "no props at all" tests below
     * therefore call `createComponent({})`, not `createComponent(undefined)`.
     *
     * ⚠ THE DEFAULT DELIBERATELY CARRIES NO STAT PROPS. The two names are what
     * every parent supplies; the three stats are opt-in, so the default fixture
     * is the OTHER parent's shape and each stats test has to ask for them.
     */
    function createComponent(props = { contactName: CONTACT, firmName: FIRM }) {
        const element = createElement('c-bov-preferred-broker', {
            is: BovPreferredBroker
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const q = (el, sel) => el.shadowRoot.querySelector(sel);
    /** Rendered text with runs of whitespace collapsed. */
    const flat = (node) => node.textContent.replace(/\s+/g, ' ').trim();

    /**
     * The VISIBLE broker name — the `.pref-name` line with its visually-hidden
     * subject ("Preferred broker: ") removed.
     *
     * ⚠ IT IS REMOVED BY ELEMENT, NOT BY STRING SURGERY. Stripping the prefix
     * with a `.replace()` would also silently pass if the hidden span vanished
     * and a broker were genuinely called that.
     */
    const visibleName = (el) => {
        const line = q(el, '.pref-name');
        if (!line) {
            return null;
        }
        return [...line.childNodes]
            .filter(
                (n) =>
                    !(
                        n.nodeType === Node.ELEMENT_NODE &&
                        n.classList.contains('pref-sr-only')
                    )
            )
            .map((n) => n.textContent)
            .join('')
            .trim();
    };

    const firmText = (el) => {
        const node = q(el, '.pref-firm');
        return node ? node.textContent : null;
    };

    /** The three stat columns as `{ value, label }`, in document order. */
    const statColumns = (el) =>
        [...el.shadowRoot.querySelectorAll('.pref-stat')].map((column) => ({
            value: flat(column.querySelector('.pref-stat-value')),
            label: flat(column.querySelector('.pref-stat-label'))
        }));

    // ═════════════════════════════════════════════════════════════════════════
    // THE ROW RENDERS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 REWRITTEN FOR THE DENSE ROW. This test asserted a "YES" pill and a firm
     * name on the BOLD line until 2026-08-25 (3); `eefa83e` had already deleted
     * the pill and moved the firm to the muted line without updating it.
     */
    it('renders the row: shield, the CONTACT name, and "Preferred Broker · <firm>"', () => {
        const element = createComponent();

        // 🔴 RENDERED ELEMENTS, NOT GETTERS. A getter-only assertion has passed
        // in this project while the rendered output was wrong.
        expect(q(element, '.pref-panel')).not.toBeNull();
        expect(q(element, 'lightning-icon')).not.toBeNull();
        expect(visibleName(element)).toBe(CONTACT);
        expect(flat(q(element, '.pref-eyebrow'))).toBe('Preferred Broker');
        expect(firmText(element)).toBe(FIRM);

        // ══════════════════════════════════════════════════════════════════════
        // 🔴 NOTE THE MISSING SPACES, AND DO NOT "FIX" THEM.
        // ══════════════════════════════════════════════════════════════════════
        // The DOM really does read "Preferred Broker·Cushman & Wakefield" with
        // no spaces: the eyebrow, the `·` and the firm are three sibling spans,
        // and the LWC template compiler DISCARDS the whitespace-only text nodes
        // between them. The spaces you see on screen are `.pref-meta`'s `gap`.
        // This assertion is therefore the DOM-side proof of the CSS pin below —
        // delete that gap and the line looks like this string, which is why no
        // amount of rendered-text assertion can catch it on its own.
        expect(flat(q(element, '.pref-meta'))).toBe(`Preferred Broker·${FIRM}`);

        // 🔴 THE PILL IS GONE AND MUST STAY GONE. It answered a question nobody
        // asked — the row only renders when a preferred broker exists — and
        // re-adding it would need the deleted `.pref-pill` rule, whose green was
        // measured. This is the only assertion standing between that comment and
        // a silent re-introduction.
        expect(q(element, '.pref-pill')).toBeNull();
    });

    /**
     * 🔴 STRUCTURE, NOT JUST PRESENCE. Every space in this row is a `gap` on a
     * PARENT: `.pref-panel`'s separates the shield from the text block (and from
     * the stats), and `.pref-detail`'s separates the two text lines. Wrap either
     * group in an extra element and the gap applies to the wrapper instead — the
     * children inside go flush again while every assertion above still passes.
     */
    it('🔴 the shield and the text block are the DIRECT children of .pref-panel', () => {
        const element = createComponent();

        const panel = q(element, '.pref-panel');
        expect([...panel.children].map((c) => c.tagName.toLowerCase())).toEqual([
            'lightning-icon',
            'div'
        ]);
        expect(panel.children[1].classList.contains('pref-detail')).toBe(true);

        // Document order inside the text block: the NAME leads, the muted line
        // follows. The compaction inverted this (the eyebrow used to be first)
        // and the order is the design — context reads better after its subject.
        const detail = q(element, '.pref-detail');
        expect([...detail.children].map((c) => c.className)).toEqual([
            'pref-name',
            'pref-meta'
        ]);

        // And the three spans of the muted line, in reading order.
        const meta = q(element, '.pref-meta');
        expect([...meta.children].map((c) => c.className)).toEqual([
            'pref-eyebrow',
            'pref-sep',
            'pref-firm'
        ]);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE BLANK NAMES — BOTH SOURCES ARE NULLABLE AND WERE NULL LIVE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ THREE SHAPES OF "BLANK", AND ALL THREE REACH THIS COMPONENT.
     *   - `''`        — what `c/bovBrokerPanel`'s getters return for a null
     *                   field. This is the live path.
     *   - undefined   — the prop never set at all (a future caller, or a mount
     *                   with no props). `undefined` is what renders the literal
     *                   string "undefined" if it reaches the DOM.
     *   - '   '       — whitespace. FALSY NOWHERE IN JAVASCRIPT, so a bare
     *                   `this.contactName || UNNAMED` renders a blank bold line
     *                   for it, visually identical to the null case.
     *
     * 🔴 BOTH NAMES ARE BLANK IN EVERY CASE HERE, AND THAT IS THE FIX TO THIS
     * TEST. It used to blank only `firmName` and still expect "Unnamed broker" —
     * which stopped being true on 2026-08-25 (1), when the CONTACT became the
     * primary line: with a contact present and no firm, the correct rendering is
     * the contact's name. That case is now its own test, below.
     */
    it.each([
        ['EMPTY STRINGS (what the panel passes for null fields)', { contactName: '', firmName: '' }],
        ['NO NAME PROPS AT ALL', {}],
        ['WHITESPACE-ONLY names', { contactName: '  ', firmName: '   ' }]
    ])('🔴 BLANK NAMES — %s render "Unnamed broker", never an empty row', (_label, props) => {
        const element = createComponent(props);

        // The row still renders: a preferred broker EXISTS, it just has no name.
        // The parent's `lwc:if` is what decides whether it exists.
        expect(q(element, '.pref-panel')).not.toBeNull();

        expect(visibleName(element)).toBe('Unnamed broker');
        // 🔴 THE TWO FAILURE MODES, NAMED. Both have shipped in this repo.
        expect(visibleName(element)).not.toBe('');
        expect(element.shadowRoot.textContent).not.toContain('undefined');

        // 🔴 AND NO MUTED FIRM BESIDE IT. With nothing to separate, a trailing
        // "Preferred Broker ·" would read as truncated text.
        expect(q(element, '.pref-firm')).toBeNull();
        expect(q(element, '.pref-sep')).toBeNull();
        expect(flat(q(element, '.pref-meta'))).toBe('Preferred Broker');
    });

    /**
     * 🔴 THE PROMOTION RULE, AND IT IS NOT "IS THE FIRM NON-EMPTY".
     * With no contact name the firm is promoted to the PRIMARY line — and must
     * then NOT also be repeated in grey underneath itself, which would read as
     * two different brokers on one row.
     */
    it('🔴 NO CONTACT NAME: the firm is PROMOTED to the name line, and not repeated below it', () => {
        const element = createComponent({ contactName: '', firmName: FIRM });

        expect(visibleName(element)).toBe(FIRM);
        // The muted line is the label ALONE — no separator, no second copy.
        expect(q(element, '.pref-firm')).toBeNull();
        expect(flat(q(element, '.pref-meta'))).toBe('Preferred Broker');
        // 🔴 AND IT IS NOT "Unnamed broker". A row that plainly carries a firm
        // name has no business claiming the broker is unnamed.
        expect(element.shadowRoot.textContent).not.toContain('Unnamed broker');
    });

    it('a long firm name reaches the DOM whole — wrapping is CSS, not truncation', () => {
        // 🔴 THE COMPONENT MUST NOT CHOP THE STRING. Overflow is solved in the
        // stylesheet (`min-width: 0` + `overflow-wrap: anywhere`, pinned below);
        // a JS `.slice()` would silently lose the end of a real firm's name and
        // would look identical on screen at narrow widths.
        const element = createComponent({
            contactName: CONTACT,
            firmName: LONG_FIRM
        });

        expect(firmText(element)).toBe(LONG_FIRM);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE THREE STAT COLUMNS (2026-08-25 (3))
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The user's instruction, pinned as one document-order assertion: Valuation,
     * Days to Market, Cap Rate, each a value over an eyebrow.
     *
     * ⚠ ONE `toEqual` OVER THE WHOLE LIST, NOT THREE `querySelector` LOOKUPS.
     * A per-column lookup passes with the columns in any order, and the order is
     * half of what was asked for.
     */
    it('🔴 renders the three columns IN ORDER, value over eyebrow', () => {
        const element = createComponent({
            contactName: CONTACT,
            firmName: FIRM,
            ...STATS
        });

        expect(statColumns(element)).toEqual([
            { value: '$12.5M', label: 'Valuation' },
            { value: '45d', label: 'Days to Market' },
            { value: '6.25%', label: 'Cap Rate' }
        ]);
    });

    /**
     * 🔴 THE LABEL TEXT IS TITLE CASE IN THE DOM. The eyebrow LOOK is
     * `text-transform: uppercase` in the stylesheet (pinned below), and the
     * distinction is not cosmetic: some screen readers spell an all-caps literal
     * out letter by letter, and "D-A-Y-S T-O M-A-R-K-E-T" is not a label.
     */
    it('🔴 the eyebrows are TEXT-TRANSFORMED, not upper-cased strings', () => {
        const element = createComponent({ ...STATS });

        const labels = statColumns(element).map((c) => c.label);
        expect(labels).toEqual(['Valuation', 'Days to Market', 'Cap Rate']);
        expect(element.shadowRoot.textContent).not.toContain('VALUATION');
    });

    /**
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 THE `—` IS THE ORDINARY STATE OF THIS ROW, NOT AN EDGE CASE.
     * ══════════════════════════════════════════════════════════════════════════
     * A broker is flagged PREFERRED before they have quoted — `c/bovBrokerPanel`'s
     * own fixture comment calls the preferred row "the THIN row a preferred
     * broker really is: no valuation, no days-to-market, no cap rate" — so all
     * three arrive as the em dash `c/utils.formatMillions` and its two new
     * siblings produce for a null. The block must still render: three labelled
     * dashes say the facts are not recorded yet, and withholding them would make
     * the row change shape the moment a response is logged.
     */
    it('🔴 ALL THREE NULL (the ordinary preferred row): three labelled em dashes, still rendered', () => {
        const element = createComponent({
            contactName: CONTACT,
            firmName: FIRM,
            valuationLabel: '—',
            daysToMarketLabel: '—',
            capRateLabel: '—'
        });

        expect(statColumns(element)).toEqual([
            { value: '—', label: 'Valuation' },
            { value: '—', label: 'Days to Market' },
            { value: '—', label: 'Cap Rate' }
        ]);
    });

    /**
     * 🔴 THE PARTIAL-SUPPLY GUARD. A caller that fills SOME of the three would
     * otherwise render a column with an empty value line hanging above its
     * label. `NO_VALUE` is the same em dash the parent's formatters produce, so
     * the two paths are indistinguishable on screen — which is the point.
     */
    it('🔴 a PARTIALLY supplied set still renders three whole columns', () => {
        const element = createComponent({ valuationLabel: '$9.4M' });

        expect(statColumns(element)).toEqual([
            { value: '$9.4M', label: 'Valuation' },
            { value: '—', label: 'Days to Market' },
            { value: '—', label: 'Cap Rate' }
        ]);
    });

    /**
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 PRESENCE **AND** ABSENCE, ON ONE INSTANCE, IN ONE TEST.
     * ══════════════════════════════════════════════════════════════════════════
     * A bare `expect(q('.pref-stats')).toBeNull()` passes for two entirely
     * different reasons — the gate correctly withheld the block, or the block was
     * deleted from the template altogether. The presence half is the control that
     * dies when the feature does; without it the absence half is vacuous.
     *
     * 🔴 WHAT THE ABSENCE HALF PROTECTS IS ANOTHER BUNDLE.
     * `c/dispositionBuyerTimeline` mounts this component in a ~276px record-page
     * sidebar and passes NONE of the three props. If `hasStats` ever became
     * "always true", that card would silently grow three em-dash columns it has
     * no room for — and nothing in ITS suite mentions these classes, so this is
     * the only test in the repo that would notice.
     */
    it('🔴 NO STAT PROPS: the block is absent entirely — and present the moment one arrives', async () => {
        const element = createComponent({ contactName: CONTACT, firmName: FIRM });

        // ── ABSENT: this is `c/dispositionBuyerTimeline`'s exact mount.
        expect(q(element, '.pref-stats')).toBeNull();
        expect(statColumns(element)).toEqual([]);
        // 🔴 AND THE ROW IS TWO ELEMENTS WIDE, NOT THREE. An empty `.pref-stats`
        // div would still be a flex item and would still take a `gap`.
        expect(
            [...q(element, '.pref-panel').children].map((c) =>
                c.tagName.toLowerCase()
            )
        ).toEqual(['lightning-icon', 'div']);

        // ── PRESENT: one prop, on the SAME instance, is enough.
        element.valuationLabel = '$12.5M';
        await Promise.resolve();

        expect(q(element, '.pref-stats')).not.toBeNull();
        expect(statColumns(element)).toHaveLength(3);
    });

    /**
     * 🔴 THE STATS ARE A SIBLING OF THE TEXT BLOCK, NOT A CHILD OF IT.
     * `.pref-panel`'s `gap` is what separates them; nested inside `.pref-detail`
     * they would stack UNDER the firm line instead of sitting beside it, and
     * every text assertion above would still pass.
     */
    it('🔴 the stats block is a DIRECT child of .pref-panel, after the text block', () => {
        const element = createComponent({ ...STATS });

        const panel = q(element, '.pref-panel');
        expect([...panel.children].map((c) => c.className)).toEqual([
            'pref-icon',
            'pref-detail',
            'pref-stats'
        ]);
        expect(q(element, '.pref-detail .pref-stats')).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ACCESSIBILITY
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ THE SHIELD SAYS NOTHING THE TEXT DOES NOT. Announced, it is noise on
     * every visit — so `aria-hidden` AND no `alternative-text`. Passing an
     * `alternative-text` is what makes `lightning-icon` announce itself, so the
     * absence of that property is half the assertion.
     */
    it('🔴 the shield is DECORATIVE: aria-hidden, and no alternative text', () => {
        const element = createComponent();

        const icon = q(element, 'lightning-icon');
        expect(icon.getAttribute('aria-hidden')).toBe('true');
        expect(icon.alternativeText).toBeUndefined();
        // The icon itself, pinned by name: `utility:shield` is a name already
        // live in this repo (`c/transactionTaskGroups`), not a guess.
        expect(icon.iconName).toBe('utility:shield');
        // 🔴 `small`, NOT `large`. It is the tallest thing in a centred flex row,
        // so it SET the row's height at `large` — the single biggest saving in
        // the 2026-08-25 compaction, and the easiest to undo by accident.
        expect(icon.size).toBe('small');
    });

    /**
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 THE NAME MUST NOT BE THE ONLY CARRIER OF MEANING.
     * ══════════════════════════════════════════════════════════════════════════
     * Read out of context a screen reader announces a bare personal name with no
     * subject. The name line therefore carries its own subject in a
     * visually-hidden span, so it announces as a sentence.
     *
     * 🔴 THIS OUTLIVED THE "YES" PILL IT WAS WRITTEN FOR. When the pill was
     * deleted the hidden subject MOVED onto the name line rather than going with
     * it — it was the half of the pill carrying information.
     *
     * ⚠ NOT AN `aria-label`, which a bare <p> (`role="generic"`) is not
     * permitted to carry.
     */
    it('🔴 the name line carries its own subject for a screen reader', () => {
        const element = createComponent();

        const hidden = q(element, '.pref-name .pref-sr-only');
        expect(hidden).not.toBeNull();
        expect(flat(hidden)).toBe('Preferred broker:');
        // The whole announced line, in reading order: subject then name.
        expect(flat(q(element, '.pref-name'))).toBe(`Preferred broker: ${CONTACT}`);
        // 🔴 AND THE VISIBLE HALF IS STILL JUST THE NAME.
        expect(visibleName(element)).toBe(CONTACT);
    });

    /**
     * ⚠ THE `·` IS HIDDEN. Announced, a middot is read aloud ("middle dot") or
     * skipped depending on the reader's verbosity — so the muted line announces
     * as "Preferred Broker Cushman & Wakefield", which is what its two spans
     * mean. That is also why it cannot simply be prefixed to the firm's text.
     */
    it('🔴 the middot separator is decorative and hidden from the accessibility tree', () => {
        const element = createComponent();

        const sep = q(element, '.pref-sep');
        expect(sep.getAttribute('aria-hidden')).toBe('true');
        expect(flat(sep)).toBe('·');
    });

    it('is accessible', async () => {
        const element = createComponent();

        await expect(element).toBeAccessible();
    });

    it('is accessible with the three stat columns', async () => {
        const element = createComponent({
            contactName: CONTACT,
            firmName: FIRM,
            ...STATS
        });

        await expect(element).toBeAccessible();
    });

    it('is accessible with no names at all', async () => {
        const element = createComponent({ contactName: '', firmName: '' });

        await expect(element).toBeAccessible();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE STYLESHEET — the only gate for everything jsdom cannot see
    // ═════════════════════════════════════════════════════════════════════════

    describe('the stylesheet', () => {
        /**
         * 🔴 THE DARK-ON-DARK TRAP, PINNED. MEASURED against
         * `node_modules/@salesforce-ux/sds-metadata/.../globalStylingHooks.metadata.json`:
         * `--slds-g-color-success-container-1` is `#2e844a`, a SOLID mid-green,
         * so pairing it with `-base-30` text is dark green on mid green wherever
         * the SLDS 2 base theme is active. `-base-95` is a real pale tint in
         * light (#ebf7e6) and near-black in dark (#010502), with `-base-30`
         * inverting to a bright #01c3b3 — which is why this pair reads in both.
         */
        it('takes its green from *-base-95 / *-base-30, NEVER from *-container-1', () => {
            const panel = ruleBody(/\.pref-panel\s*\{([^}]*)\}/);
            const name = ruleBody(/\.pref-name\s*\{([^}]*)\}/);
            const statValue = ruleBody(/\.pref-stat-value\s*\{([^}]*)\}/);
            expect(panel).not.toBeNull();
            expect(name).not.toBeNull();
            expect(statValue).not.toBeNull();

            expect(panel).toMatch(
                /background:\s*var\(\s*--slds-g-color-success-base-95\b/
            );
            expect(name).toMatch(
                /color:\s*var\(\s*--slds-g-color-success-base-30\b/
            );
            // The stat values are the same green as the name — see below.
            expect(statValue).toMatch(
                /color:\s*var\(\s*--slds-g-color-success-base-30\b/
            );

            for (const body of [panel, name, statValue]) {
                expect(body).not.toMatch(/container-1/);
            }
        });

        /**
         * 🔴 NEITHER MUTED LINE IS `on-surface-1`, AND THAT IS A MEASUREMENT.
         * `--slds-g-color-on-surface-1` is this repo's usual "secondary text"
         * hook and reads ~4.6:1 on white — but on this panel's #ebf7e6 tint it
         * is 4.16:1, under AA for text this small, and nothing else in the
         * pipeline would ever report it (axe's contrast rule is inert in jsdom).
         * `--slds-g-color-neutral-base-30` is #444 light / #aeaeae dark: muted,
         * inverting, and 8.8:1 on the tint.
         *
         * ⚠ THE STAT EYEBROW IS THE NEW HALF OF THIS PIN, AND IT IS THE LIKELIER
         * REGRESSION: it is modelled on `c/brokerListing`'s `.cfo-tile-label`,
         * which DOES use `on-surface-1` — legitimately, on a neutral #f3f3f3
         * tile. Copying that hook onto this green one is a single-word edit that
         * nothing else would catch.
         */
        it('🔴 the muted text uses neutral-base-30, not the sub-AA on-surface-1', () => {
            const meta = ruleBody(/\.pref-meta\s*\{([^}]*)\}/);
            const statLabel = ruleBody(/\.pref-stat-label\s*\{([^}]*)\}/);
            expect(meta).not.toBeNull();
            expect(statLabel).not.toBeNull();

            for (const body of [meta, statLabel]) {
                expect(body).toMatch(
                    /color:\s*var\(\s*--slds-g-color-neutral-base-30\b/
                );
                expect(body).not.toMatch(/on-surface-1/);
            }
        });

        /**
         * 🔴 THE ROW'S HEIGHT BUDGET, PINNED AS A SHARED FONT SCALE. The
         * 2026-08-25 compaction halved this panel by instruction, and the stat
         * columns were added inside that budget: each is TWO lines of the SAME
         * two scales as the text block beside it, so the row cannot get taller
         * than the taller of two equal blocks. A stat value bumped to
         * `font-scale-2` makes the whole row grow with nothing else changing.
         */
        it('🔴 the stat value shares the NAME font scale — that is the height budget', () => {
            const name = ruleBody(/\.pref-name\s*\{([^}]*)\}/);
            const statValue = ruleBody(/\.pref-stat-value\s*\{([^}]*)\}/);

            expect(name).toMatch(/font-size:\s*var\(\s*--slds-g-font-scale-1\b/);
            expect(statValue).toMatch(
                /font-size:\s*var\(\s*--slds-g-font-scale-1\b/
            );
            // And the eyebrow is the small tracked one — an eyebrow at body size
            // is just a second line of text.
            expect(ruleBody(/\.pref-stat-label\s*\{([^}]*)\}/)).toMatch(
                /text-transform:\s*uppercase\b/
            );
        });

        /**
         * 🔴 THE GAPS ARE MARKUP. The LWC template compiler discards
         * whitespace-only text nodes between sibling elements, so deleting a
         * `gap` does not "tighten" this panel — it removes ALL spacing, and no
         * rendered text changes to show it. `.pref-meta`'s gap is the most
         * dangerous of the four: it is the SPACES AROUND THE `·`, so without it
         * the line renders "Preferred Broker·JLL" with every character still
         * present, in the right order, and every text assertion still green.
         */
        it('🔴 keeps the load-bearing gaps that replace the compiler-stripped whitespace', () => {
            const panel = ruleBody(/\.pref-panel\s*\{([^}]*)\}/);
            const detail = ruleBody(/\.pref-detail\s*\{([^}]*)\}/);
            const meta = ruleBody(/\.pref-meta\s*\{([^}]*)\}/);
            const stats = ruleBody(/\.pref-stats\s*\{([^}]*)\}/);
            const stat = ruleBody(/\.pref-stat\s*\{([^}]*)\}/);
            for (const body of [panel, detail, meta, stats, stat]) {
                expect(body).not.toBeNull();
                expect(body).toMatch(/display:\s*flex\b/);
                expect(body).toMatch(/gap:\s*var\(\s*--slds-g-spacing-/);
            }

            expect(detail).toMatch(/flex-direction:\s*column\b/);
            expect(stat).toMatch(/flex-direction:\s*column\b/);
            // `margin: 0` on the paragraphs is part of the same claim: a default
            // block margin would stack on top of the gap and space the two lines
            // unevenly.
            expect(ruleBody(/\.pref-name\s*\{([^}]*)\}/)).toMatch(/margin:\s*0\b/);
            expect(meta).toMatch(/margin:\s*0\b/);
        });

        /**
         * ══════════════════════════════════════════════════════════════════════
         * 🔴 THE RIGHT-HAND LAYOUT IS TWO DECLARATIONS AND NEITHER IS OBVIOUS.
         * ══════════════════════════════════════════════════════════════════════
         *   · `.pref-detail { flex: 1 1 auto }` is the ONLY thing pushing the
         *     stats to the right edge — nothing here uses `justify-content` on
         *     the panel or an auto margin. Drop the grow and the three columns
         *     slide left against the broker's name on a wide card.
         *   · `.pref-stats { flex: none }` is what stops a long broker name
         *     stealing width from the numbers and wrapping `$12.5M` mid-token.
         *     The free text yields; the numbers do not.
         * jsdom performs no layout, so source text is the only falsifier.
         */
        it('🔴 the stats sit at the RIGHT EDGE and cannot be squashed', () => {
            const detail = ruleBody(/\.pref-detail\s*\{([^}]*)\}/);
            const stats = ruleBody(/\.pref-stats\s*\{([^}]*)\}/);

            expect(detail).toMatch(/flex:\s*1\s+1\s+auto\b/);
            expect(stats).toMatch(/flex:\s*none\b/);
        });

        /**
         * 🔴 THE PANEL ITSELF MUST NOT WRAP, AND THIS PIN PROTECTS ANOTHER
         * BUNDLE. `flex-wrap: wrap` on `.pref-panel` reads like the more general
         * narrow-width fix and is a regression: flex line-breaking uses each
         * item's base size BEFORE shrinking, so a wrapping panel drops the whole
         * text block onto its own line UNDER the shield as soon as a broker's
         * name is longer than the line. In `c/dispositionBuyerTimeline`'s ~276px
         * sidebar — which passes no stats and relies on `min-width: 0` +
         * `overflow-wrap: anywhere` instead — that is most names.
         */
        it('🔴 the ROW does not wrap (the wrap belongs to the stats block alone)', () => {
            const panel = ruleBody(/\.pref-panel\s*\{([^}]*)\}/);
            const stats = ruleBody(/\.pref-stats\s*\{([^}]*)\}/);

            expect(panel).not.toMatch(/flex-wrap/);
            expect(stats).toMatch(/flex-wrap:\s*wrap\b/);
        });

        /**
         * 🔴 THE OVERFLOW PAIR, AND IT IS A PAIR. A flex item defaults to
         * `min-width: auto` and refuses to shrink below its longest unbreakable
         * token, so one long firm name forces the panel wider than the card.
         * `overflow-wrap: anywhere` — `anywhere`, NOT `break-word`, because only
         * `anywhere` affects min-content sizing — is what lets `min-width: 0`
         * take effect. Either one alone does nothing.
         */
        it('🔴 a long name WRAPS: min-width 0 on the column, overflow-wrap anywhere on the text', () => {
            const detail = ruleBody(/\.pref-detail\s*\{([^}]*)\}/);
            const name = ruleBody(/\.pref-name\s*\{([^}]*)\}/);
            const firm = ruleBody(/\.pref-firm\s*\{([^}]*)\}/);
            expect(detail).not.toBeNull();
            expect(name).not.toBeNull();
            expect(firm).not.toBeNull();

            expect(detail).toMatch(/min-width:\s*0\b/);
            expect(name).toMatch(/overflow-wrap:\s*anywhere\b/);
            expect(firm).toMatch(/overflow-wrap:\s*anywhere\b/);
            // `break-word` does not affect min-content sizing, so it would leave
            // the panel overflowing while looking like the fix.
            expect(firm).not.toMatch(/overflow-wrap:\s*break-word\b/);
        });

        /**
         * 🔴 `flex: none` ON THE SHIELD. Flex items shrink; without it a long
         * name squashes the icon to a sliver rather than wrapping, and nothing
         * in a jsdom suite can see the difference. It matters MORE at
         * `size="small"`: there is less icon to lose before it disappears.
         */
        it('🔴 the shield cannot be squashed by a long name', () => {
            const icon = ruleBody(/\.pref-icon\s*\{([^}]*)\}/);
            expect(icon).not.toBeNull();
            expect(icon).toMatch(/flex:\s*none\b/);
        });

        /**
         * 🔴 THE HIDDEN SUBJECT MUST STAY IN THE ACCESSIBILITY TREE. The
         * clip-based recipe hides it visually; `display: none` and
         * `visibility: hidden` REMOVE it from the tree, which deletes the one
         * thing the span exists to provide while leaving the DOM assertion above
         * green.
         */
        it('🔴 .pref-sr-only hides visually WITHOUT leaving the accessibility tree', () => {
            const sr = ruleBody(/\.pref-sr-only\s*\{([^}]*)\}/);
            expect(sr).not.toBeNull();

            expect(sr).toMatch(/clip-path:\s*inset\(/);
            expect(sr).toMatch(/position:\s*absolute\b/);
            expect(sr).not.toMatch(/display:\s*none\b/);
            expect(sr).not.toMatch(/visibility:\s*hidden\b/);
        });

        /**
         * ⚠ EVERY COLOUR IS A HOOK. A literal survives the theme switch
         * unchanged and so reads correctly in exactly one of light and dark —
         * and this panel's whole premise is a colour.
         */
        it('uses no raw colour literal outside a var() fallback', () => {
            const withoutTokens = CSS_SOURCE.replace(/var\([^()]*\)/g, 'TOKEN');
            expect(withoutTokens).not.toMatch(/#[0-9a-fA-F]{3,8}/);
            expect(withoutTokens).not.toMatch(/\b(rgb|rgba|hsl|hsla)\(/);
            // Guard the guard: a stylesheet stripped to nothing passes the two
            // assertions above vacuously.
            expect(
                (CSS_SOURCE.match(/var\(\s*--slds-/g) || []).length
            ).toBeGreaterThan(8);
        });
    });
});
