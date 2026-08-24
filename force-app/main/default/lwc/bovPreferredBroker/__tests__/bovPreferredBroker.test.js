/**
 * PRESENTATIONAL-COMPONENT TEMPLATE — one `@api` string in, markup out.
 * ---------------------------------------------------------------------------
 * No wire, no Apex, no modal, no navigation: this bundle renders a firm name
 * handed down by `c/bovBrokerPanel`. Everything worth breaking is either in the
 * markup or in the stylesheet, and jsdom performs no layout, so this file gates
 * BOTH — rendered elements and attributes for the markup, and SOURCE TEXT for
 * the stylesheet.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THERE ARE CSS SOURCE ASSERTIONS AT ALL.
 * ═════════════════════════════════════════════════════════════════════════════
 * Three requirements of this panel are invisible to every other gate we have:
 *   1. the green must be the `*-base-95` TINT, not `*-container-1` — measured,
 *      `--slds-g-color-success-container-1` is `#2e844a`, a SOLID mid-green, so
 *      the natural-looking `container-1` + `base-30` pairing is dark-on-dark;
 *   2. the `gap`s are MARKUP — the LWC compiler discards whitespace-only text
 *      nodes between siblings, so deleting one removes ALL spacing and no
 *      rendered text changes;
 *   3. `min-width: 0` + `overflow-wrap: anywhere` are what stop a long firm name
 *      overflowing rather than wrapping.
 * The SLDS linter only checks that a hook was USED. axe's colour-contrast rule
 * is INERT in jsdom. `getComputedStyle` resolves no custom properties and does
 * no layout. Source text is the only automated falsifier that exists.
 *
 * ⚠ THE COMMENTS ARE STRIPPED BEFORE ANY OF THOSE ASSERTIONS RUN. The
 * stylesheet's own header explains at length why `container-1` is wrong and
 * names the token repeatedly; without the strip, `not.toMatch(/container-1/)`
 * matches the PROSE and every absence assertion in this file is vacuously green.
 */
import { createElement } from 'lwc';
import BovPreferredBroker from 'c/bovPreferredBroker';

const FIRM = 'Cushman & Wakefield';

/**
 * The real shape of the value that broke this in review: a firm name long
 * enough that a flex item with the default `min-width: auto` refuses to shrink
 * below it and pushes the whole panel wider than its container.
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
     * `undefined` explicitly ALSO uses it. The "no firm name at all" test below
     * therefore calls `createComponent({})`, not `createComponent(undefined)`.
     */
    function createComponent(props = { firmName: FIRM }) {
        const element = createElement('c-bov-preferred-broker', {
            is: BovPreferredBroker
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const q = (el, sel) => el.shadowRoot.querySelector(sel);
    const firmText = (el) => {
        const node = q(el, '.pref-firm');
        return node ? node.textContent : null;
    };
    /** Rendered text with runs of whitespace collapsed — see the pill test. */
    const flat = (node) => node.textContent.replace(/\s+/g, ' ').trim();

    // ═════════════════════════════════════════════════════════════════════════
    // THE PANEL RENDERS
    // ═════════════════════════════════════════════════════════════════════════

    it('renders the panel: shield, "Preferred Broker" label, firm name, YES pill', () => {
        const element = createComponent();

        // 🔴 RENDERED ELEMENTS, NOT GETTERS. A getter-only assertion has passed
        // in this project while the rendered output was wrong.
        expect(q(element, '.pref-panel')).not.toBeNull();
        expect(q(element, 'lightning-icon')).not.toBeNull();
        expect(flat(q(element, '.pref-eyebrow'))).toBe('Preferred Broker');
        expect(firmText(element)).toBe(FIRM);
        expect(q(element, '.pref-pill')).not.toBeNull();
    });

    /**
     * 🔴 STRUCTURE, NOT JUST PRESENCE. Every one of these rules is spacing that
     * lives on a PARENT: `.pref-panel`'s `gap` separates the shield from the
     * text block, and `.pref-detail`'s `gap` separates the three text lines.
     * Wrap either group in an extra element, or move the pill out of
     * `.pref-detail`, and the gap applies to the wrapper instead — the children
     * inside go flush again while every assertion above still passes.
     */
    it('🔴 the shield and the text block are the DIRECT children of .pref-panel', () => {
        const element = createComponent();

        const panel = q(element, '.pref-panel');
        expect([...panel.children].map((c) => c.tagName.toLowerCase())).toEqual([
            'lightning-icon',
            'div'
        ]);
        expect(panel.children[1].classList.contains('pref-detail')).toBe(true);

        const detail = q(element, '.pref-detail');
        // Document order: label, then name, then pill — the design's stacking.
        expect([...detail.children].map((c) => c.className)).toEqual([
            'pref-eyebrow',
            'pref-firm',
            'pref-pill'
        ]);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE BLANK FIRM NAME — `Broker_Firm__c` IS NULLABLE AND WAS NULL LIVE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ THREE SHAPES OF "BLANK", AND ALL THREE REACH THIS COMPONENT.
     *   - `''`        — what `c/bovBrokerPanel.preferredBrokerFirm` returns when
     *                   the flagged row has no firm name. This is the live path.
     *   - undefined   — the prop never set at all (a future caller, or a mount
     *                   with no props). `undefined` is what renders the literal
     *                   string "undefined" if it reaches the DOM.
     *   - '   '       — whitespace. FALSY NOWHERE IN JAVASCRIPT, so a bare
     *                   `this.firmName || UNNAMED` renders a blank bold line for
     *                   it, visually identical to the null case.
     */
    it.each([
        ['an EMPTY STRING (what the panel passes for a null firm)', { firmName: '' }],
        ['NO firmName AT ALL', {}],
        ['a WHITESPACE-ONLY firm name', { firmName: '   ' }]
    ])('🔴 BLANK FIRM NAME — %s renders "Unnamed broker", never an empty panel', (_label, props) => {
        const element = createComponent(props);

        // The panel still renders: a preferred broker EXISTS, it just has no
        // firm name. The parent's `lwc:if` is what decides whether it exists.
        expect(q(element, '.pref-panel')).not.toBeNull();

        const rendered = firmText(element);
        expect(rendered).toBe('Unnamed broker');
        // 🔴 THE TWO FAILURE MODES, NAMED. Both have shipped in this repo.
        expect(rendered).not.toBe('');
        expect(rendered).not.toContain('undefined');
        // And nowhere else in the panel either — a stringified `undefined` bound
        // to a different node would satisfy the assertion above.
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    it('a long firm name reaches the DOM whole — wrapping is CSS, not truncation', () => {
        // 🔴 THE COMPONENT MUST NOT CHOP THE STRING. Overflow is solved in the
        // stylesheet (`min-width: 0` + `overflow-wrap: anywhere`, pinned below);
        // a JS `.slice()` would silently lose the end of a real firm's name and
        // would look identical on screen at narrow widths.
        const element = createComponent({ firmName: LONG_FIRM });

        expect(firmText(element)).toBe(LONG_FIRM);
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
    });

    /**
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 "YES" MUST NOT BE THE ONLY CARRIER OF MEANING.
     * ══════════════════════════════════════════════════════════════════════════
     * Read out of context a screen reader announces the word "YES" with no
     * subject. The pill therefore carries its own subject in a visually-hidden
     * span, so its accessible name reads "Preferred broker: YES".
     *
     * ⚠ ASSERTED ON THE PILL'S OWN RENDERED TEXT, not on the component's
     * `shadowRoot.textContent` — and not with an `aria-label`, which a bare
     * <span> (`role="generic"`) is not permitted to carry.
     */
    it('🔴 the YES pill carries its own subject for a screen reader', () => {
        const element = createComponent();

        const pill = q(element, '.pref-pill');
        const hidden = pill.querySelector('.pref-sr-only');

        expect(hidden).not.toBeNull();
        expect(flat(hidden)).toBe('Preferred broker:');
        // The whole accessible name, in reading order: subject then value.
        expect(flat(pill)).toBe('Preferred broker: YES');
        // 🔴 AND THE VISIBLE HALF IS STILL "YES". A pill that reads
        // "Preferred broker: YES" on screen would satisfy the line above.
        expect(pill.textContent).toContain('YES');
        expect(hidden.textContent).not.toContain('YES');
    });

    it('is accessible', async () => {
        const element = createComponent();

        await expect(element).toBeAccessible();
    });

    it('is accessible with no firm name', async () => {
        const element = createComponent({ firmName: '' });

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
            const firm = ruleBody(/\.pref-firm\s*\{([^}]*)\}/);
            const pill = ruleBody(/\.pref-pill\s*\{([^}]*)\}/);
            expect(panel).not.toBeNull();
            expect(firm).not.toBeNull();
            expect(pill).not.toBeNull();

            expect(panel).toMatch(
                /background:\s*var\(\s*--slds-g-color-success-base-95\b/
            );
            expect(firm).toMatch(
                /color:\s*var\(\s*--slds-g-color-success-base-30\b/
            );
            expect(pill).toMatch(
                /background:\s*var\(\s*--slds-g-color-success-base-80\b/
            );
            expect(pill).toMatch(
                /color:\s*var\(\s*--slds-g-color-success-base-30\b/
            );

            for (const body of [panel, firm, pill]) {
                expect(body).not.toMatch(/container-1/);
            }
        });

        /**
         * 🔴 THE EYEBROW IS **NOT** `on-surface-1`, AND THAT IS A MEASUREMENT.
         * `--slds-g-color-on-surface-1` is this repo's usual "secondary text"
         * hook and reads ~4.6:1 on white — but on this panel's #ebf7e6 tint it
         * is 4.16:1, under AA for text this small, and nothing else in the
         * pipeline would ever report it (axe's contrast rule is inert in jsdom).
         * `--slds-g-color-neutral-base-30` is #444 light / #aeaeae dark: muted,
         * inverting, and 8.8:1 on the tint.
         */
        it('🔴 the muted label uses neutral-base-30, not the sub-AA on-surface-1', () => {
            const eyebrow = ruleBody(/\.pref-eyebrow\s*\{([^}]*)\}/);
            expect(eyebrow).not.toBeNull();

            expect(eyebrow).toMatch(
                /color:\s*var\(\s*--slds-g-color-neutral-base-30\b/
            );
            expect(eyebrow).not.toMatch(/on-surface-1/);
        });

        /**
         * 🔴 THE GAPS ARE MARKUP. The LWC template compiler discards
         * whitespace-only text nodes between sibling elements, so deleting a
         * `gap` does not "tighten" this panel — it removes ALL spacing, and no
         * rendered text changes to show it. `margin: 0` on the paragraphs is
         * what stops the default block margins fighting the gap, so it is part
         * of the same claim.
         */
        it('🔴 keeps the load-bearing gaps that replace the compiler-stripped whitespace', () => {
            const panel = ruleBody(/\.pref-panel\s*\{([^}]*)\}/);
            const detail = ruleBody(/\.pref-detail\s*\{([^}]*)\}/);
            expect(panel).not.toBeNull();
            expect(detail).not.toBeNull();

            expect(panel).toMatch(/display:\s*flex\b/);
            expect(panel).toMatch(/gap:\s*var\(\s*--slds-g-spacing-/);
            expect(detail).toMatch(/display:\s*flex\b/);
            expect(detail).toMatch(/flex-direction:\s*column\b/);
            expect(detail).toMatch(/gap:\s*var\(\s*--slds-g-spacing-/);

            expect(ruleBody(/\.pref-eyebrow\s*\{([^}]*)\}/)).toMatch(
                /margin:\s*0\b/
            );
            expect(ruleBody(/\.pref-firm\s*\{([^}]*)\}/)).toMatch(/margin:\s*0\b/);
        });

        /**
         * 🔴 THE OVERFLOW PAIR, AND IT IS A PAIR. A flex item defaults to
         * `min-width: auto` and refuses to shrink below its longest unbreakable
         * token, so one long firm name forces the panel wider than the card.
         * `overflow-wrap: anywhere` — `anywhere`, NOT `break-word`, because only
         * `anywhere` affects min-content sizing — is what lets `min-width: 0`
         * take effect. Either one alone does nothing.
         */
        it('🔴 a long firm name WRAPS: min-width 0 on the column, overflow-wrap anywhere on the name', () => {
            const detail = ruleBody(/\.pref-detail\s*\{([^}]*)\}/);
            const firm = ruleBody(/\.pref-firm\s*\{([^}]*)\}/);
            expect(detail).not.toBeNull();
            expect(firm).not.toBeNull();

            expect(detail).toMatch(/min-width:\s*0\b/);
            expect(firm).toMatch(/overflow-wrap:\s*anywhere\b/);
            // `break-word` does not affect min-content sizing, so it would leave
            // the panel overflowing while looking like the fix.
            expect(firm).not.toMatch(/overflow-wrap:\s*break-word\b/);
        });

        /**
         * 🔴 `flex: none` ON THE SHIELD. Flex items shrink; without it a long
         * firm name squashes the icon to a sliver rather than wrapping, and
         * nothing in a jsdom suite can see the difference.
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
