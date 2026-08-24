/**
 * WIRE-MOCK TEMPLATE — @wire to APEX (parameterised) + TWO MODALS
 * --------------------------------------------------------------------------------
 * c-bov-broker-panel is the BOV Outreach broker workspace: ONE header carrying the
 * three broker buttons, above TWO instances of c/bovComparisonMatrix (the
 * "Preferred Broker" card and the "BOV Comparison Matrix" card).
 *
 * Data source: @wire(getSubmissions, { dispositionId: '$recordId' }).
 *   - getSubmissions.emit(rows)  -> data branch
 *   - getSubmissions.error()     -> error branch
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 MOST OF THIS FILE MOVED HERE FROM lwc/bovComparisonMatrix/__tests__ ON
 * 2026-08-24, WITH THE BUTTONS IT PINS.
 * ═════════════════════════════════════════════════════════════════════════════
 * Twenty-five ADD RESPONSE / ADD PREFERRED / REPLACE tests, and the fixtures only
 * they used, came across so that no behaviour lost its pin during the move. The
 * matrix bundle kept an ABSENCE pin over both of its modes instead — the two
 * files are complementary and neither is complete alone.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. BUTTON ASSERTIONS SCAN THE RENDERED `label` PROPERTY, NOT `textContent`.
 *    `lightning-button`'s sfdx-lwc-jest stub renders an EMPTY template, so
 *    `shadowRoot.textContent` contains none of these labels and a
 *    `toContain('Replace Broker')` assertion on it is vacuously green in BOTH
 *    directions.
 * 2. A CHILD'S SHADOW TEXT DOES NOT REACH THIS COMPONENT'S `shadowRoot`. Measured
 *    in this repo: a parent's `shadowRoot.textContent` is `""` with children
 *    rendering their own cards. Every assertion about the children here is a TAG
 *    scan or a PROPERTY read, never a text search.
 * 3. `preferred-only` IS A BARE ATTRIBUTE in the template. LWC resolves a
 *    valueless attribute on a custom element to boolean `true`; the near-miss
 *    `preferred-only=""` is the FALSY empty string and would silently turn the
 *    top card into a second copy of the matrix. Every assertion on it is
 *    `toBe(true)` / `toBe(false)` — a truthiness check passes on `"true"` and on
 *    `""` respectively and proves nothing.
 * 4. `LightningModal.open()` IS A STATIC ON A CLASS and cannot be driven like a
 *    wire adapter, so both modals are mocked wholesale. Their own behaviour is
 *    proved in lwc/bovReplaceBrokerModal/__tests__ and
 *    lwc/bovAddResponseModal/__tests__.
 * 5. `refreshApex` IS NOT AUTO-MOCKED — `@salesforce/apex` resolves to a real
 *    module whose `refreshApex` is a plain function, so an assertion on it fails
 *    with "received value must be a mock or spy function", which reads like a
 *    broken assertion rather than a missing mock.
 *    ⚠ AND IT IS CALLED MORE THAN ONCE PER ACTION HERE, BY DESIGN: this component
 *    refreshes its OWN wire and then calls `refreshData()` on every rendered
 *    child. Call-COUNT assertions would therefore be brittle and would encode the
 *    number of cards; the tests below assert "was called" / "was NOT called", and
 *    one dedicated test proves the fan-out precisely.
 * 6. 🔴 THE PREFERRED-BROKER REPLACEMENT CALLS NO APEX FROM THE CLIENT. The
 *    retirement of the outgoing row and its `BOV_Broker_Change__c` history entry
 *    are written by `BovPreferredBrokerService.retireReplacedPreferred`, called
 *    from `BovSubmissionTriggerHandler.afterInsert` and keyed on the INSERT of a
 *    row carrying `Is_Preferred_Broker__c = true`. The client's whole half is to
 *    make that insert happen with the flag set — which is why the replacement
 *    test asserts `isPreferred === true` on the dialog config, and why the
 *    "no Apex" claim is pinned by COUNTING this bundle's `@salesforce/apex`
 *    imports rather than by a mock that would never be touched either way.
 *    ⚠ IT IS ALSO WHY THERE IS NO PARTIAL-OUTCOME TEST. The retirement runs in
 *    the same transaction as the insert, so a refusal rolls the insert back and
 *    the dialog stays open showing the error; the client never sees a state where
 *    the new row exists and the old one survives.
 */
import { createElement } from 'lwc';
import BovBrokerPanel from 'c/bovBrokerPanel';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';
import { refreshApex } from '@salesforce/apex';
import BovAddResponseModal from 'c/bovAddResponseModal';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not
// cosmetic: this stylesheet's comments NAME the values and properties they
// discuss, so an un-stripped read would satisfy the assertions for the wrong
// reason.
//
// 🔴 SOURCE TEXT, NOT getComputedStyle. jsdom performs no layout, so the only
// observable fact about a `gap` is that the rule exists. A DOM-only suite is
// completely blind to this file.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'bovBrokerPanel.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

/**
 * The body of a single top-level rule. Takes a REGEXP LITERAL carrying one
 * capture group, not a selector string: a string-built RegExp needs doubled
 * backslashes, and getting that wrong returns null for EVERY rule while the test
 * still reads as though it were checking something.
 */
function ruleBody(ruleRegExp) {
    const match = CSS_SOURCE.match(ruleRegExp);
    return match ? match[1] : null;
}

/**
 * The component's own source, for the ONE assertion the DOM cannot make: how many
 * Apex methods this bundle imports.
 *
 * 🔴 WHY SOURCE TEXT AND NOT A MOCK. "This component calls no Apex for the
 * replacement" cannot be pinned with `expect(someMock).not.toHaveBeenCalled()` —
 * a mock for a module the component does not import is never touched, so that
 * assertion is green whether the claim holds or not, and stays green after
 * someone adds the import and the call. Counting the imports is the only
 * observable that moves.
 */
const JS_SOURCE = require('fs').readFileSync(
    require('path').join(__dirname, '..', 'bovBrokerPanel.js'),
    'utf8'
);

/** Every `import … from '@salesforce/apex/…'` line, comments excluded by anchoring. */
const apexImports = () =>
    JS_SOURCE.match(/^import\s+.*from\s+'@salesforce\/apex\/[^']+';$/gm) || [];

/**
 * 🔴 KEPT EVEN THOUGH THIS COMPONENT DOES NOT IMPORT `NavigationMixin`.
 * ══════════════════════════════════════════════════════════════════════════════
 * The "never navigates" tests below are the anti-regression pins for the
 * 2026-08-21 UAT bug ("once we save broker response it redirects to that record
 * page instead of staying on the same page"). Without this mock they are VACUOUS:
 * sfdx-lwc-jest's own `lightning/navigation` stub does not dispatch anything a
 * test can listen for, so a re-added `NavigationMixin.Navigate` call would fire
 * silently and both tests would stay green forever.
 *
 * This replacement makes `Navigate` DISPATCH a `navigate` CustomEvent, which is
 * the repo convention and the only observable those absence assertions have.
 * ⚠ IT ALSO SERVES THE CHILD. `c/bovComparisonMatrix` really does mix in
 * `NavigationMixin` (for its "View All" footer link) and really is mounted by
 * these tests, so `GenerateUrl` has to resolve or the child's
 * `connectedCallback` rejects. A child's own `navigate` event does not bubble,
 * so it cannot reach this component's listener and cannot forge a pass.
 */
jest.mock('lightning/navigation', () => {
    const Navigate = Symbol('Navigate');
    const GenerateUrl = Symbol('GenerateUrl');
    const NavigationMixin = (Base) =>
        class extends Base {
            [Navigate](pageRef) {
                this.dispatchEvent(
                    new CustomEvent('navigate', { detail: pageRef })
                );
            }
            [GenerateUrl]() {
                return Promise.resolve('/lightning/o/BOV_Submission__c/list');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

jest.mock(
    '@salesforce/apex/BovController.getSubmissions',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock('c/bovReplaceBrokerModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock('c/bovAddResponseModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), {
    virtual: true
});

const RECORD_ID = 'a0D5g000000DispEAG';

const SUBMISSIONS = [
    {
        id: 'a0X010000000001',
        name: 'BOV-0001',
        isSelected: true,
        bovScore: 88,
        brokerFirm: 'Colliers International',
        contactName: 'Jane Doe',
        bovAmount: 12500000,
        daysToMarket: 45,
        capRate: 6.25
    },
    {
        id: 'a0X010000000002',
        name: 'BOV-0002',
        isSelected: false,
        bovScore: 71,
        brokerFirm: 'JLL',
        contactName: 'John Roe',
        bovAmount: 11000000,
        daysToMarket: 60,
        capRate: 6.8
    }
];

/**
 * ⚠ NOTE WHAT `SUBMISSIONS` ABOVE DOES *NOT* CARRY: an `isPreferred` KEY AT ALL.
 * Every test driven off it therefore doubles as the pin for "an ABSENT flag
 * behaves as not-preferred": Add Preferred Broker must still be offered, and
 * Replace Broker must take its ORIGINAL path.
 * ⚠ `isPreferred === false` WOULD NOT BE EQUIVALENT: an Apex `Boolean` null
 * arrives as JS `null`, not `false`, so only `=== true` keeps a null out of the
 * preferred branch.
 */

/** Every submission still Backup — the pre-selection state. */
const NONE_SELECTED = SUBMISSIONS.map((s) => ({ ...s, isSelected: false }));

/**
 * One preferred broker, and deliberately the THIN row a preferred broker really
 * is: no valuation, no days-to-market, no cap rate, no score. A preferred broker
 * is a firm DPEG would like to use — not a firm that has quoted — so a fixture
 * carrying a full BOV response would prove the feature works on data it does not
 * produce.
 */
const PREFERRED_ROW = {
    id: 'a0X010000000003',
    name: 'BOV-0003',
    isSelected: false,
    isPreferred: true,
    bovScore: null,
    brokerFirm: 'Cushman & Wakefield',
    contactName: 'Ada Lin',
    bovAmount: null,
    daysToMarket: null,
    capRate: null
};

/** The read-only label this panel must hand the replacement dialog. */
const PREFERRED_LABEL = 'Cushman & Wakefield — Ada Lin';

/**
 * Two ordinary responses (one Selected) PLUS one preferred broker that is NOT
 * selected — the window between the modal's insert and `BovAutoSelectionService`
 * promoting the row, and the permanent state on a LOCKED disposition.
 */
const WITH_PREFERRED = [...SUBMISSIONS, PREFERRED_ROW];

/**
 * 🔴 THE STEADY STATE AFTER THE 2026-08-24 DECISION: the preferred broker HOLDS
 * the single `Selected` slot and every scored response has been demoted to
 * `Backup` by `BovAutoSelectionService`.
 *
 * This fixture is what makes `_selected` falsifiable. Narrowed to the scored rows
 * NOTHING here is Selected, so `canReplaceBroker` goes false and Replace Broker
 * disappears — leaving no route in the entire UI to replace an appointed broker,
 * with no error anywhere.
 */
const PREFERRED_APPOINTED = [
    ...SUBMISSIONS.map((sub) => ({ ...sub, isSelected: false })),
    { ...PREFERRED_ROW, isSelected: true }
];

/**
 * 🔴 THE REAL SHAPE OF THIS ORG'S DATA, NOT A CONVENIENT ONE. Six broker Contacts
 * exist TWICE with an identical name AND an identical firm, and seven Contacts on
 * the Broker record type are not brokers at all. Neither is filtered nor
 * de-duplicated — the user's decision — so the PICKER has to be legible anyway.
 */
const DUPLICATE_BROKERS = [
    {
        id: 'a0X010000000011',
        name: 'BOV-0011',
        isSelected: false,
        bovScore: null,
        brokerFirm: 'Marcus Whitfield Realty',
        contactName: 'Marcus Whitfield',
        bovAmount: 9400000,
        daysToMarket: 70,
        capRate: 6.1
    },
    {
        id: 'a0X010000000012',
        name: 'BOV-0012',
        isSelected: false,
        bovScore: null,
        brokerFirm: 'Marcus Whitfield Realty',
        contactName: 'Marcus Whitfield',
        bovAmount: 9400000,
        daysToMarket: 70,
        capRate: 6.1
    }
];

/**
 * The duplicate-broker pair WITH an incumbent, so the Replace path can reach
 * them: `_backupOptions` is only reachable through Replace Broker, which only
 * renders once something IS Selected.
 */
const DUPLICATE_BROKERS_WITH_INCUMBENT = () => [
    { ...SUBMISSIONS[0] },
    ...DUPLICATE_BROKERS
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-bov-broker-panel', () => {
    beforeEach(() => {
        BovReplaceBrokerModal.open.mockResolvedValue(undefined);
        BovAddResponseModal.open.mockResolvedValue(undefined);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-bov-broker-panel', {
            is: BovBrokerPanel
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const addBtn = (el) => el.shadowRoot.querySelector('.panel-add');
    const replaceBtn = (el) => el.shadowRoot.querySelector('.panel-replace');
    const preferredBtn = (el) =>
        el.shadowRoot.querySelector('.panel-add-preferred');

    /**
     * 🔴 KEPT AFTER THE BUTTON WAS DELETED, ON PURPOSE. `.matrix-select` / a
     * "Select Broker" button no longer exists anywhere — the first appointment is
     * made automatically from `BOV_Score__c` on the server. An absence pin needs
     * a way to name the thing that must stay absent. Never dereferenced.
     */
    const selectBtn = (el) => el.shadowRoot.querySelector('.panel-select');

    /** Every rendered button's LABEL, in template order. See fact 1 in the header. */
    const buttonLabels = (el) =>
        [...el.shadowRoot.querySelectorAll('lightning-button')].map(
            (b) => b.label
        );

    /** The rendered matrix children, in document order. */
    const matrices = (el) => [
        ...el.shadowRoot.querySelectorAll('c-bov-comparison-matrix')
    ];

    // ═════════════════════════════════════════════════════════════════════════
    // THE PANEL ITSELF — one header, three buttons, two cards
    // ═════════════════════════════════════════════════════════════════════════

    it('renders ONE header with the panel title', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        const titles = [
            ...element.shadowRoot.querySelectorAll('span[slot="title"]')
        ];
        // 🔴 EXACTLY ONE, IN THIS SHADOW ROOT. The two children each render their
        // own `span[slot="title"]` ("Preferred Broker", "BOV Comparison Matrix
        // (n)") — inside THEIR shadow roots, which this query cannot reach. A
        // second title here would mean the panel had grown a duplicate header.
        expect(titles).toHaveLength(1);
        expect(titles[0].textContent).toBe('Brokers');
    });

    it('🔴 THE THREE BUTTONS, IN ORDER — and Select Broker is gone by name', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        // ⚠ toEqual ON THE WHOLE ARRAY, not three toContain() calls: this is what
        // pins the ORDER (the user's) and catches a fourth button appearing.
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Replace Broker',
            'Add Preferred Broker'
        ]);
        expect(selectBtn(element)).toBeNull();
    });

    it('🔴 the buttons are in lightning-card\'s ACTION slot, not in the body', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        // The requirement is "at its top right", which on a lightning-card means
        // `slot="actions"`. Rendering the same three buttons above the cards
        // instead would pass every label assertion in this file.
        const actions = element.shadowRoot.querySelector('div[slot="actions"]');
        expect(actions).not.toBeNull();
        expect(
            [...actions.querySelectorAll('lightning-button')].map((b) => b.label)
        ).toEqual([
            'Add Broker Response',
            'Replace Broker',
            'Add Preferred Broker'
        ]);
    });

    it('REPLACE BROKER is HIDDEN until a submission is Selected — and NOTHING takes its place', async () => {
        const element = createComponent();

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        expect(replaceBtn(element)).toBeNull();
        expect(selectBtn(element)).toBeNull();
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Add Preferred Broker'
        ]);
    });

    it('🔴 EMPTY DISPOSITION: no broker button, but BOTH add buttons — an empty sale is exactly when you add one', async () => {
        const element = createComponent();

        getSubmissions.emit([]);
        await Promise.resolve();

        expect(replaceBtn(element)).toBeNull();
        // ⚠ NEITHER ADD BUTTON DEPENDS ON THE ROW COUNT, and that is deliberate:
        // recording a preferred broker before any response has arrived is the
        // normal first act on a new disposition.
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Add Preferred Broker'
        ]);
    });

    it('🔴 WIRE ERROR BRANCH: no broker button, and the add buttons survive as the recovery route', async () => {
        const element = createComponent();

        getSubmissions.error();
        await Promise.resolve();

        // The panel deliberately renders NO error banner of its own — the matrix
        // child renders one, and two banners for one failed read is noise.
        expect(replaceBtn(element)).toBeNull();
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Add Preferred Broker'
        ]);
        // Guard the guard: the matrix child is still mounted to show its banner.
        expect(matrices(element)).toHaveLength(1);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE TWO CARDS, AND THE GAP THE PREFERRED ONE USED TO ORPHAN
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 NO PREFERRED BROKER: exactly ONE card renders — the preferred TAG is not in the DOM at all', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        const cards = matrices(element);
        // 🔴 THIS IS THE GAP FIX, ASSERTED. `dispositionMain.css` documented the
        // old behaviour as "KNOWN, ACCEPTED": the preferred instance rendered an
        // EMPTY card, and a zero-height flex item still takes a `gap`, so the
        // stack began one 1rem step low. A component that merely renders nothing
        // would still be an element here and this would read 2.
        expect(cards).toHaveLength(1);
        expect(cards[0].preferredOnly).toBe(false);
    });

    it('🔴 WITH A PREFERRED BROKER: TWO cards, preferred FIRST, and preferred-only is BOOLEAN true', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        const cards = matrices(element);
        expect(cards).toHaveLength(2);

        // 🔴 `querySelectorAll` RETURNS DOCUMENT ORDER, so index 0 IS the top
        // card. A `querySelector` test would pass with the tags in either order.
        // ⚠ `toBe(true)`, NEVER A TRUTHINESS CHECK. `preferred-only` is written
        // as a BARE attribute; the near-miss `preferred-only=""` passes the FALSY
        // empty string and would render a second copy of the matrix here.
        expect(cards[0].preferredOnly).toBe(true);
        expect(cards[0].recordId).toBe(RECORD_ID);

        // The bare tag is unchanged by construction.
        expect(cards[1].preferredOnly).toBe(false);
        expect(cards[1].recordId).toBe(RECORD_ID);
    });

    it('🔴 both cards are DIRECT children of .panel-stack — which is why ONE gap covers them', async () => {
        // The gap lives on `.panel-stack`. Wrap either card in a plain <div> and
        // the gap applies to the wrapper instead — the cards inside go flush
        // again while every other assertion in this file still passes.
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        const stack = element.shadowRoot.querySelector('.panel-stack');
        expect(stack).not.toBeNull();
        // ⚠ THE DIVIDER IS A SIBLING OF THE TWO CARDS, NOT A CHILD OF EITHER —
        // that is what makes the stack's own 1rem gap fall on both sides of it
        // and centre it. Nesting it inside the preferred card's tag, or wrapping
        // the pair in a <div>, both fail here.
        expect(
            [...stack.children].map((el) => el.tagName.toLowerCase())
        ).toEqual(['c-bov-comparison-matrix', 'div', 'c-bov-comparison-matrix']);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE DIVIDER BETWEEN THE TWO SECTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 PRESENCE **AND** ABSENCE, ON ONE INSTANCE, IN ONE TEST. A bare
     * `expect(q('.panel-rule')).toBeNull()` passes for two entirely different
     * reasons — the condition correctly withheld the rule, or the divider was
     * deleted from the template altogether. The presence half is the control
     * that dies when the feature does; without it the absence half is vacuous.
     *
     * ⚠ RE-EMITTING ON THE SAME COMPONENT IS THE POINT. `getSubmissions.emit`
     * pushes to every live instance, so the second emit is a DATA CHANGE on the
     * component that just rendered the rule — not a second fixture that might be
     * failing to render it for some unrelated reason.
     *
     * The no-preferred state is the one on screen most of the time: every
     * disposition starts without a preferred broker, and a hairline above a lone
     * matrix card would be a rule with nothing on one side of it.
     */
    it('🔴 THE DIVIDER: drawn between the two cards, and GONE when the preferred card is', async () => {
        const element = createComponent();

        // ── WITH a preferred broker: two cards, one rule, and it is BETWEEN them.
        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        const stack = element.shadowRoot.querySelector('.panel-stack');
        expect(element.shadowRoot.querySelectorAll('.panel-rule')).toHaveLength(
            1
        );
        expect(
            [...stack.children].map((el) => el.tagName.toLowerCase())
        ).toEqual(['c-bov-comparison-matrix', 'div', 'c-bov-comparison-matrix']);
        // Position, not just existence: the rule is the MIDDLE child. A divider
        // rendered after both cards would satisfy a `not.toBeNull()` check.
        expect(stack.children[1].classList.contains('panel-rule')).toBe(true);

        // ── WITHOUT one: the matrix is the only child and the rule is gone.
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        expect(matrices(element)).toHaveLength(1);
        expect(element.shadowRoot.querySelector('.panel-rule')).toBeNull();
        expect(
            [...element.shadowRoot.querySelector('.panel-stack').children].map(
                (el) => el.tagName.toLowerCase()
            )
        ).toEqual(['c-bov-comparison-matrix']);
    });

    /**
     * ⚠ DECORATION MUST NOT BE ANNOUNCED. The rule names nothing — each card's
     * own title is what tells a screen-reader user a new section has begun — so
     * it carries `role="presentation"` AND `aria-hidden`, and no text at all.
     */
    it('🔴 THE DIVIDER is decorative: no text, presentation role, aria-hidden', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        const rule = element.shadowRoot.querySelector('.panel-rule');
        expect(rule).not.toBeNull();
        expect(rule.getAttribute('role')).toBe('presentation');
        expect(rule.getAttribute('aria-hidden')).toBe('true');
        expect(rule.textContent).toBe('');
        expect(rule.children).toHaveLength(0);
    });

    /**
     * 🔴 THE STYLESHEET IS THE ONLY PLACE THE DIVIDER IS VISIBLE AT ALL. jsdom
     * performs no layout and resolves no custom properties, so `getComputedStyle`
     * cannot tell a 1px hairline from a rule with no height, no colour, or one
     * that has shrunk to zero. Source text is the only gate available.
     */
    it('🔴 .panel-rule is a TOKENISED hairline that cannot shrink away', () => {
        const rule = ruleBody(/\.panel-rule\s*\{([^}]*)\}/);
        expect(rule).not.toBeNull();

        // Flex items shrink. A 1px-high item that shrinks is simply not there,
        // and nothing else in this suite would notice.
        expect(rule).toMatch(/flex:\s*none\b/);

        // ⚠ THE TOKENS ARE PART OF THE ASSERTION, NOT POLISH.
        // `--slds-g-color-border-1` is `light-dark(#c9c9c9, #444)`: a literal
        // would read correctly in exactly one of light and dark, and axe's
        // contrast rule is inert in jsdom, so nothing else catches that.
        expect(rule).toMatch(/height:\s*var\(\s*--slds-g-sizing-border-1\b/);
        expect(rule).toMatch(/background:\s*var\(\s*--slds-g-color-border-1\b/);

        // No raw colour or pixel value outside a token fallback.
        const withoutTokens = rule.replace(/var\([^()]*\)/g, 'TOKEN');
        expect(withoutTokens).not.toMatch(/#[0-9a-fA-F]{3,8}/);
        expect(withoutTokens).not.toMatch(/\b(rgb|rgba|hsl|hsla)\(/);
        expect(withoutTokens).not.toMatch(/\d+px/);

        // 🔴 A BOX, NOT A `border-top` — the same treatment `c/brokerListing`'s
        // `.cfo-rule` uses on the same page. A border here would sit flush
        // against the lower card's own `lightning-card` edge and read doubled.
        expect(rule).not.toMatch(/border-(top|bottom|left|right)\s*:/);
    });

    it('🔴 .panel-stack is a column flex container with a TOKENISED gap', () => {
        const stack = ruleBody(/\.panel-stack\s*\{([^}]*)\}/);
        expect(stack).not.toBeNull();

        // `gap` only does anything on a flex/grid container. `display: block`
        // silently ignores it, which looks exactly like the bug it fixes — and
        // the LWC compiler discards whitespace between siblings, so without it
        // the two cards render EDGE TO EDGE with nothing between them.
        expect(stack).toMatch(/display:\s*flex\b/);
        expect(stack).toMatch(/flex-direction:\s*column\b/);
        // ⚠ THE TOKEN IS PART OF THE ASSERTION. A raw `gap: 16px` looks identical
        // on the light theme and is unthemeable; SLDS 2 requires the hook.
        expect(stack).toMatch(/gap:\s*var\(\s*--slds-g-spacing-4\b/);
        // No raw pixel value outside a token fallback.
        expect(stack.replace(/var\([^()]*\)/g, 'TOKEN')).not.toMatch(/\d+px/);
    });

    it('🔴 NOTHING doubles up on the gap — no per-card margin anywhere in this stylesheet', () => {
        // A margin on either card reads as gap + margin between them and leaves
        // dead space above the card footer after the last one.
        expect(CSS_SOURCE).not.toMatch(/margin/);
        // Guard the guard: a stylesheet stripped of everything would pass the
        // assertion above vacuously.
        expect((CSS_SOURCE.match(/var\(\s*--slds-/g) || []).length).toBeGreaterThan(0);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ADD BROKER RESPONSE
    // ═════════════════════════════════════════════════════════════════════════

    it('ADD RESPONSE: opens the in-place dialog for THIS disposition', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(BovAddResponseModal.open).toHaveBeenCalledTimes(1);
        const config = BovAddResponseModal.open.mock.calls[0][0];
        expect(config.dispositionId).toBe(RECORD_ID);
        expect(config.label).toBe('Add Broker Response');
    });

    it('🔴 ADD RESPONSE: never navigates — this is the UAT redirect regression pin', async () => {
        // Until 2026-08-21 this called NavigationMixin.Navigate with
        // `actionName: 'new'`, and the platform's post-save behaviour for a
        // record created that way is to navigate TO the new record — throwing the
        // user off the disposition page. The fix was to stop navigating at all,
        // and this component does not even mix in NavigationMixin.
        // ⚠ AN ABSENCE ASSERTION ON PURPOSE: asserting only that the modal opened
        // would stay green if a Navigate call were added back beside it.
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(navHandler).not.toHaveBeenCalled();
    });

    it('🔴 ADD RESPONSE SUCCESS: toasts, then refreshes', async () => {
        BovAddResponseModal.open.mockResolvedValue({
            recordId: 'a0X010000000099',
            name: 'BOV-0099'
        });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.title).toBe('Broker response logged');
        expect(toast.message).toContain('BOV-0099');
        expect(toast.variant).toBe('success');
        expect(refreshApex).toHaveBeenCalled();
    });

    it('ADD RESPONSE CANCELLED: no toast and no refresh', async () => {
        // A dismissed LightningModal resolves `undefined`; this repo's Jest stub
        // resolves `null`. Both are falsy and both must take the silent branch.
        BovAddResponseModal.open.mockResolvedValue(undefined);
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('ADD RESPONSE: a modal that fails to OPEN toasts and does not refresh', async () => {
        BovAddResponseModal.open.mockRejectedValue({
            body: { message: 'boom' }
        });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.title).toBe('Could not open the response dialog');
        expect(toast.message).toBe('boom');
        expect(refreshApex).not.toHaveBeenCalled();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ADD PREFERRED BROKER
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 ADD PREFERRED: opens the SAME add-response bundle with isPreferred TRUE', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        expect(BovAddResponseModal.open).toHaveBeenCalledTimes(1);
        const config = BovAddResponseModal.open.mock.calls[0][0];
        expect(config.isPreferred).toBe(true);
        expect(config.label).toBe('Add Preferred Broker');
        expect(config.dispositionId).toBe(RECORD_ID);
        // ⚠ NOT the replacement dialog — this is a FIRST appointment.
        expect(config.isReplacement).toBeUndefined();
        // 🔴 AND NOT c/bovReplaceBrokerModal. The two bundles are one keystroke
        // apart in the source and the failure would be silent.
        expect(BovReplaceBrokerModal.open).not.toHaveBeenCalled();
    });

    it('🔴 ADD RESPONSE passes isPreferred FALSE — the default path is not the preferred path', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        // ⚠ `toBe(false)`, NOT a falsiness check: `undefined` would also be falsy
        // and would leave the modal's own default deciding the mode.
        expect(BovAddResponseModal.open.mock.calls[0][0].isPreferred).toBe(false);
    });

    it('ADD PREFERRED SUCCESS: toasts in PREFERRED wording, then refreshes', async () => {
        BovAddResponseModal.open.mockResolvedValue({
            recordId: 'a0X010000000098',
            name: 'BOV-0098'
        });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        const toast = toastHandler.mock.calls[0][0].detail;
        // ⚠ A PREFERRED ROW IS NOT A RESPONSE. The two land in DIFFERENT cards on
        // this page; telling a user their "broker response" was logged when it
        // went to the card above is how a support ticket starts.
        expect(toast.title).toBe('Preferred broker added');
        expect(toast.message).toContain('preferred broker');
        expect(refreshApex).toHaveBeenCalled();
    });

    it('ADD PREFERRED CANCELLED: no toast and no refresh', async () => {
        BovAddResponseModal.open.mockResolvedValue(null);
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('ADD PREFERRED: a modal that fails to OPEN toasts its OWN title and does not refresh', async () => {
        BovAddResponseModal.open.mockRejectedValue({});
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        const toast = toastHandler.mock.calls[0][0].detail;
        // Distinct from the add-response failure title: the user pressed a
        // different button and must be told which dialog failed.
        expect(toast.title).toBe('Could not open the preferred broker dialog');
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('🔴 ADD PREFERRED BROKER is HIDDEN once one exists — exactly one per disposition', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        // ⚠ WITHDRAWN, NOT DISABLED. There is no server-side uniqueness guard on
        // `Is_Preferred_Broker__c`, so this getter is the only thing enforcing
        // "exactly one" — a button that is always offered and never refused
        // teaches the user nothing.
        expect(preferredBtn(element)).toBeNull();
        // The other two are untouched by the preferred row.
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Replace Broker'
        ]);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // REPLACE BROKER — THE ORIGINAL PATH (no preferred broker on the sale)
    // ═════════════════════════════════════════════════════════════════════════

    it('REPLACE: opens the modal with ONLY the backups and names the incumbent', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(BovReplaceBrokerModal.open).toHaveBeenCalledTimes(1);
        const config = BovReplaceBrokerModal.open.mock.calls[0][0];
        expect(config.dispositionId).toBe(RECORD_ID);
        expect(config.isFirstAppointment).toBe(false);
        expect(config.currentBroker).toBe('Colliers International');
        // The incumbent is excluded: promoting a broker to itself is not an
        // operation and the server refuses it.
        expect(config.backupOptions.map((o) => o.value)).toEqual([
            'a0X010000000002'
        ]);
        expect(config.backupOptions[0].label).toContain('JLL');
    });

    it('🔴 REPLACE: a null score renders an EM DASH, never 0', async () => {
        const element = createComponent();

        getSubmissions.emit(DUPLICATE_BROKERS_WITH_INCUMBENT());
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const options =
            BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions;
        expect(options[0].label).toContain('Score —');
        expect(options[0].label).not.toContain('Score 0');
    });

    it('🔴 REPLACE: two brokers with an IDENTICAL name and firm are still distinguishable', async () => {
        // Six broker Contacts in this org exist twice with the same name AND the
        // same firm. Firm alone renders two options as the same string, and the
        // user is choosing at random between them.
        const element = createComponent();

        getSubmissions.emit(DUPLICATE_BROKERS_WITH_INCUMBENT());
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const options =
            BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions;
        expect(options).toHaveLength(2);
        expect(options[0].label).not.toBe(options[1].label);
        expect(options[0].label).toContain('BOV-0011');
        expect(options[1].label).toContain('BOV-0012');
    });

    it('REPLACE: never navigates', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(navHandler).not.toHaveBeenCalled();
    });

    it('🔴 REPLACE SUCCESS: toasts the SERVER message sticky, then refreshes', async () => {
        const serverMessage =
            'JLL is now the selected broker. A fresh broker approval is required.';
        BovReplaceBrokerModal.open.mockResolvedValue({ message: serverMessage });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const toast = toastHandler.mock.calls[0][0].detail;
        // 🔴 VERBATIM. The server chooses between "Broker appointed…" and "Broker
        // replaced…" from what it actually did inside the transaction; a second
        // copy authored here would still be claiming the old thing the day the
        // service changes.
        expect(toast.message).toBe(serverMessage);
        // 🔴 STICKY. The warning about a fresh approval is a consequence the user
        // has to act on, and an auto-dismissing toast is how it gets missed.
        expect(toast.mode).toBe('sticky');
        expect(refreshApex).toHaveBeenCalled();
    });

    it('REPLACE CANCELLED: no toast and no refresh', async () => {
        BovReplaceBrokerModal.open.mockResolvedValue(undefined);
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('REPLACE: a modal that fails to OPEN toasts a distinct message and does not refresh', async () => {
        BovReplaceBrokerModal.open.mockRejectedValue({});
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Could not open the replace dialog'
        );
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('🔴 the preferred row is EXCLUDED from the replace picker', async () => {
        // ⚠ THE REASON CHANGED 2026-08-24 AND THE ASSERTION DID NOT. It used to
        // be "replaceSelectedBroker knows nothing about Is_Preferred_Broker__c
        // and would appoint this row, putting a broker with NO BOV amount into
        // Broker_Finalize_Approval". Appointing a preferred broker is now the
        // INTENDED outcome, so that is no longer a hazard. The row is excluded
        // because the picker's job is to offer SCORED alternatives to whoever
        // holds the slot.
        //
        // 🔴 THIS FIXTURE IS THE ONE THAT STILL REACHES THE ORIGINAL PATH WITH A
        // PREFERRED ROW PRESENT... and it does NOT: `WITH_PREFERRED` now routes
        // Replace Broker to the REPLACEMENT dialog. The picker is therefore
        // reached only when no preferred row exists, which is what the two
        // assertions below encode — the exclusion is now structural.
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(BovReplaceBrokerModal.open).not.toHaveBeenCalled();
        expect(BovAddResponseModal.open).toHaveBeenCalledTimes(1);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE PREFERRED BROKER HOLDS THE SELECTED SLOT (user decision, 2026-08-24)
    //
    // The scored field is all Backup; the appointed broker is the preferred one.
    // These tests exist because the FIRST implementation of `_selected` narrowed
    // it to the scored rows and NOT ONE EXISTING TEST WENT RED when that was
    // widened back — the suite was blind to this whole state.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 APPOINTED PREFERRED: REPLACE BROKER still renders — the only route to swap an appointed broker', async () => {
        const element = createComponent();

        getSubmissions.emit(PREFERRED_APPOINTED);
        await Promise.resolve();

        // Narrow `_selected` to the scored rows and this goes null: nothing there
        // is Selected in this state, the button vanishes, and there is NO route
        // anywhere in the UI to replace an appointed broker. Nothing errors.
        expect(replaceBtn(element)).not.toBeNull();
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Replace Broker'
        ]);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 REPLACE BROKER, PREFERRED MODE (new, 2026-08-24)
    //
    // With a preferred broker on the sale, Replace Broker opens the ADD PREFERRED
    // BROKER dialog in replacement mode instead of the backup picker: the
    // successor is usually a broker who has submitted no BOV at all, and so has
    // no row for a picker to offer.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 REPLACE PREFERRED: opens the ADD bundle in replacement mode, NOT the backup picker', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        // 🔴 BOTH HALVES. Asserting only that the add bundle opened would stay
        // green if the picker opened beside it.
        expect(BovReplaceBrokerModal.open).not.toHaveBeenCalled();
        expect(BovAddResponseModal.open).toHaveBeenCalledTimes(1);

        const config = BovAddResponseModal.open.mock.calls[0][0];
        expect(config.label).toBe('Replace Preferred Broker');
        expect(config.isReplacement).toBe(true);
        // ⚠ PASSED WITH `isPreferred: true` TOO. The dialog writes
        // `Is_Preferred_Broker__c` off THAT flag, so a replacement opened without
        // it would create an ordinary unflagged response under a title promising
        // a replacement — and the outgoing row would then be retired against it.
        expect(config.isPreferred).toBe(true);
        expect(config.dispositionId).toBe(RECORD_ID);
    });

    it('🔴 REPLACE PREFERRED: the outgoing broker is handed over as a read-only LABEL', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const config = BovAddResponseModal.open.mock.calls[0][0];
        // ⚠ IDENTITY ONLY — firm and contact. Deliberately NOT
        // `brokerOptionLabel`, which appends the amount, the score and the
        // auto-number: a preferred row is thin, so that helper renders
        // "Firm — Contact · — · Score — · BOV-0003" for the one broker on screen.
        expect(config.outgoingBrokerLabel).toBe(PREFERRED_LABEL);
    });

    it('🔴 REPLACE PREFERRED: the CLIENT calls no Apex — the retirement is trigger-side', async () => {
        // ══════════════════════════════════════════════════════════════════════
        // 🔴 THE AGREED CONTRACT, PINNED AS AN ABSENCE.
        // ══════════════════════════════════════════════════════════════════════
        // The retirement lives in `BovPreferredBrokerService.retireReplacedPreferred`,
        // called from `BovSubmissionTriggerHandler.afterInsert`, and it is keyed
        // on the INSERT of a row carrying `Is_Preferred_Broker__c = true`. The
        // client's entire half is to make that insert happen, which the dialog
        // does. An imperative call added here would be a SECOND writer of an
        // invariant that lives in one place, and would race a trigger that has
        // already done the work.
        //
        // ⚠ THIS IS AN ABSENCE PIN WITH A GUARD, because an absence pin alone
        // would also pass on a button that does nothing at all. The two positive
        // assertions are what make the third one mean something.
        BovAddResponseModal.open.mockResolvedValue({
            recordId: 'a0X010000000077',
            name: 'BOV-0077'
        });
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(BovAddResponseModal.open).toHaveBeenCalledTimes(1);
        // 🔴 THE ONE FACT THE TRIGGER KEYS ON. Without this flag the dialog
        // creates an ordinary unflagged response under a "Replace Preferred
        // Broker" header, nothing is retired, nothing errors, and the outgoing
        // broker stays appointed.
        expect(BovAddResponseModal.open.mock.calls[0][0].isPreferred).toBe(true);

        // 🔴 AND EXACTLY ONE APEX IMPORT IN THE WHOLE BUNDLE — the cacheable read
        // that feeds the buttons. Adding `BovController.replacePreferredBroker`
        // (the draft contract, recorded in the component's import block) reds
        // this line. It is a SOURCE-TEXT assertion for the reason given where
        // `apexImports` is defined: a mock cannot pin the absence of an import.
        const imports = apexImports();
        expect(imports).toHaveLength(1);
        expect(imports[0]).toContain('BovController.getSubmissions');
    });

    it('🔴 REPLACE PREFERRED SUCCESS: a sticky warning naming the OUTGOING broker, then a refresh', async () => {
        BovAddResponseModal.open.mockResolvedValue({
            recordId: 'a0X010000000077'
        });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.title).toBe('Preferred broker replaced');
        // 🔴 THE OUTGOING BROKER IS NAMED. This copy is client-authored — unlike
        // the backup-picker path, where `replaceSelectedBroker` RETURNS a
        // sentence — because the retirement happens in an after-insert trigger,
        // which returns nothing to a client. Naming the broker is what makes the
        // toast worth reading: the outgoing submission is GONE, not archived.
        expect(toast.message).toContain('Cushman & Wakefield');
        expect(toast.message).toContain('broker change history');
        // 🔴 STICKY, and `warning` rather than `success`, matching the other
        // broker-swap path. A destroyed row is not a routine confirmation.
        expect(toast.mode).toBe('sticky');
        expect(toast.variant).toBe('warning');
        expect(refreshApex).toHaveBeenCalled();
    });

    it('🔴 REPLACE PREFERRED: a modal that fails to OPEN toasts and changes nothing', async () => {
        BovAddResponseModal.open.mockRejectedValue({
            body: { message: 'dialog unavailable' }
        });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.title).toBe('Could not open the replace dialog');
        expect(toast.message).toBe('dialog unavailable');
        expect(toast.variant).toBe('error');
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('REPLACE PREFERRED CANCELLED: nothing toasts and nothing refreshes', async () => {
        // 🔴 NOTHING WAS INSERTED, SO THE TRIGGER NEVER RAN AND THE OUTGOING
        // BROKER IS UNTOUCHED. A success toast here would tell the user their
        // preferred broker had been replaced when it had not, and a refresh would
        // suggest the page had changed.
        BovAddResponseModal.open.mockResolvedValue(undefined);
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('🔴 NO PREFERRED BROKER: Replace Broker takes the ORIGINAL path and never opens the add bundle', async () => {
        // The other half of the branch. Without this, routing the whole button to
        // the replacement dialog would pass every replacement test in this file.
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(BovReplaceBrokerModal.open).toHaveBeenCalledTimes(1);
        expect(BovAddResponseModal.open).not.toHaveBeenCalled();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // THE REFRESH FAN-OUT
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 a write refreshes THIS wire AND every rendered child', async () => {
        BovAddResponseModal.open.mockResolvedValue({
            recordId: 'a0X010000000099'
        });
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        const kids = matrices(element);
        expect(kids).toHaveLength(2);
        const spies = kids.map((kid) => jest.spyOn(kid, 'refreshData'));

        addBtn(element).click();
        await flushPromises();

        // ⚠ THE CHILD CALLS ARE NOT DECORATION. All three wires share one LDS
        // cache entry, so invalidating it here SHOULD re-provision the children —
        // but that is an assumption about LDS internals which no Jest stub models
        // and which nothing on this page would report if it stopped holding.
        spies.forEach((spy) => expect(spy).toHaveBeenCalledTimes(1));

        // And this component's OWN wire was refreshed with the UN-DESTRUCTURED
        // wire result. `refreshApex` cannot re-provision a wire from a
        // `{ data, error }` pair — or from the bare array — so a "tidying" edit
        // to `this._wired = result.data` silently stops refreshing the data the
        // three buttons' visibility rules read.
        //
        // 🔴 CALL INDEX 0, NOT `.some(...)` OVER EVERY CALL, AND THIS IS A
        // MEASURED CORRECTION. `_refreshAll` refreshes this component first and
        // then fans out to the children, and the CHILDREN still hold proper
        // un-destructured wire results — so a `some()` assertion was satisfied by
        // a child's call and stayed GREEN with this component's own wire
        // destructured. Mutation M13 proved it. Index 0 is this component's.
        const own = refreshApex.mock.calls[0][0];
        expect(own).toBeDefined();
        expect(own.data).toEqual(WITH_PREFERRED);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
