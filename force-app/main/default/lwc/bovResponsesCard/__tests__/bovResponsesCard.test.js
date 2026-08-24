/**
 * c-bov-responses-card
 * ---------------------------------------------------------------------------
 * "BOV (n)" — card #3 of the three stacked broker cards on the Disposition
 * record page (2026-08-25). One `@wire(getSubmissions, { dispositionId:
 * '$recordId' })`, a two-column table, and THREE mutually exclusive states.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 THE LOAD-BEARING FACTS
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE CARD HIDES ITSELF WHEN THERE ARE NO SUBMISSIONS. A FlexiPage
 *    visibility rule cannot test a child object, so the gate is the component.
 *    Every absence assertion below is therefore paired with a PRESENCE control
 *    on the SAME instance — `toBeNull()` passes identically for "correctly
 *    hidden" and "the feature was deleted", and this component IS a gate.
 * 2. EMPTY AND UNAVAILABLE ARE DIFFERENT STATES AND MUST NEVER SHARE A
 *    RENDERING. Nothing on screen is a claim about the SALE; the honest line is
 *    a fact about the READER. The failure test asserts the card IS there and
 *    the empty test asserts it is NOT — that pairing is what fails if somebody
 *    "simplifies" the two branches into one.
 * 3. EXACTLY TWO COLUMNS. The fixtures carry all five comparison figures on
 *    purpose: the server hands this card the SAME row the BOV Comparison Matrix
 *    renders, so a re-added column would display real, plausible data and look
 *    entirely correct. The banned-value assertions could not exist at all if the
 *    fixtures had been nulled out "because the card does not use those fields".
 * 4. THE COMPONENT DOES NOT RE-SORT. The Apex is already ordered by score; the
 *    fixture below is deliberately BACKUP-FIRST so "preserved the server order"
 *    can be told apart from "sorted Selected to the top".
 * 5. DTO MEMBER NAMES ARE PINNED HERE. A renamed `@AuraEnabled` member on
 *    `BovController.BovRow` fails no deploy and throws nothing in the browser —
 *    the card just renders blanks or hides itself.
 *
 * ⚠ A HAND-ROLLED `<table>`, NOT `lightning-datatable`. Its Jest stub renders an
 * EMPTY template, which would make every text assertion in this file vacuously
 * green and blind `@sa11y/jest` to the headers entirely.
 *
 * ⚠ EVERY ASSERTION READS A RENDERED ELEMENT OR A PROPERTY, NEVER A GETTER.
 * This repo has a measured defect where a getter-only assertion stayed green
 * while the rendered output was wrong.
 */
import { createElement } from 'lwc';
import BovResponsesCard from 'c/bovResponsesCard';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not
// cosmetic: T-TOKENS searches for values this stylesheet's own prose NAMES (it
// quotes `success-container-1` in order to forbid it), so an unstripped read
// would match the comment and the pin would be vacuously red — or, for an
// absence written the other way round, vacuously green.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'bovResponsesCard.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

jest.mock(
    '@salesforce/apex/BovController.getSubmissions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a0Y0000000000001AAA';

// ─────────────────────────────────────────────────────────────────────────────
// `BovController.BovRow` FIXTURES — see fact 3 in the header for why the
// comparison figures are populated.
// ─────────────────────────────────────────────────────────────────────────────

/** The appointed broker: Selected, not flagged preferred, top of the ranking. */
const SUB_SELECTED = {
    id: 'a0X0000000000001AAA',
    name: 'BOV-0001',
    brokerFirm: 'Jones Lang LaSalle',
    contactName: 'Dana Reid',
    bovAmount: 4200000,
    commissionRate: 2.5,
    daysToMarket: 45,
    histSuccessRate: 88,
    capRate: 6.1,
    bovScore: 92.5,
    status: 'Selected',
    isSelected: true,
    isPreferred: false
};

/** A runner-up. Backup is the picklist's default value. */
const SUB_BACKUP = {
    id: 'a0X0000000000002AAA',
    name: 'BOV-0002',
    brokerFirm: 'Marcus & Millichap',
    contactName: 'Priya Nair',
    bovAmount: 3950000,
    commissionRate: 3,
    daysToMarket: 60,
    histSuccessRate: 71,
    capRate: 6.4,
    bovScore: 74,
    status: 'Backup',
    isSelected: false,
    isPreferred: false
};

/**
 * 🔴 A PREFERRED BROKER WITH **NO FIRM NAME AND NO SCORE** — THE LIVE SHAPE.
 * `Broker_Firm__c` is legitimately nullable and was null on live data this week.
 * The null score is part of the same shape and is why such a row sorts LAST
 * under `BOV_Score__c DESC NULLS LAST`.
 */
const SUB_PREFERRED_NAMELESS = {
    id: 'a0X0000000000003AAA',
    name: 'BOV-0003',
    brokerFirm: null,
    contactName: null,
    bovAmount: null,
    commissionRate: null,
    daysToMarket: null,
    histSuccessRate: null,
    capRate: null,
    bovScore: null,
    status: 'Backup',
    isSelected: false,
    isPreferred: true
};

/** The ordinary preferred case: flagged AND named. */
const SUB_PREFERRED_NAMED = {
    ...SUB_PREFERRED_NAMELESS,
    id: 'a0X0000000000004AAA',
    name: 'BOV-0004',
    brokerFirm: 'Cushman & Wakefield'
};

/** A hand-typed, spaces-only firm name — falsy nowhere in JavaScript. */
const SUB_WHITESPACE_FIRM = {
    ...SUB_BACKUP,
    id: 'a0X0000000000005AAA',
    name: 'BOV-0005',
    brokerFirm: '   '
};

/** A row whose status the record leaves blank. */
const SUB_BLANK_STATUS = {
    ...SUB_BACKUP,
    id: 'a0X0000000000006AAA',
    name: 'BOV-0006',
    brokerFirm: 'Newmark',
    status: null
};

/**
 * 🔴 A THIRD PICKLIST VALUE — THE ONLY FIXTURE THAT CAN FALSIFY "PASSED
 * THROUGH, NOT DERIVED".
 *
 * `Submission_Status__c` is Backup/Selected today, and with only those two
 * values a derived `isSelected ? 'Selected' : 'Backup'` ternary produces exactly
 * the same output as passing the record's own value through — so every
 * two-valued fixture in this file is blind to the difference. A third value is
 * the whole risk the pass-through exists to cover: under a ternary it would be
 * silently RELABELLED "Backup", and nothing would throw or fail to deploy.
 */
const SUB_THIRD_STATUS = {
    ...SUB_BACKUP,
    id: 'a0X0000000000007AAA',
    name: 'BOV-0007',
    brokerFirm: 'Colliers',
    status: 'Withdrawn',
    isSelected: false
};

/**
 * ⚠ BACKUP FIRST, SELECTED SECOND — DELIBERATELY NOT THE ORDER A HUMAN WOULD
 * CHOOSE. The component renders SERVER order and does not sort, so a fixture
 * that already happened to be Selected-first could not tell "preserved the
 * server's order" apart from "sorted Selected to the top". Inverting it is what
 * makes the ordering assertion falsifiable.
 */
const SUBMISSIONS = [SUB_BACKUP, SUB_SELECTED];

describe('c-bov-responses-card', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    const createComponent = () => {
        const element = createElement('c-bov-responses-card', {
            is: BovResponsesCard
        });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        return element;
    };

    const card = (element) => element.shadowRoot.querySelector('lightning-card');
    const table = (element) => element.shadowRoot.querySelector('.brc-table');
    const titleSpan = (element) =>
        element.shadowRoot.querySelector('span[slot="title"]');
    const titleText = (element) => {
        const span = titleSpan(element);
        return span ? span.textContent.trim() : null;
    };

    /** The rendered [name, status] pairs, in DOCUMENT order. */
    const rows = (element) =>
        [...element.shadowRoot.querySelectorAll('.brc-table tbody tr')].map((tr) =>
            [...tr.querySelectorAll('td')].map((td) => td.textContent.trim())
        );

    // ─────────────────────────────────────────────────────────────────────────
    // THE THREE STATES.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 ROWS: a two-column table with the count in the title — and NOTHING when there are none', async () => {
        const element = createComponent();

        // PRESENT.
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        expect(card(element)).not.toBeNull();
        expect(table(element)).not.toBeNull();
        expect(titleText(element)).toBe('BOV (2)');

        // 🔴 EXACTLY TWO HEADERS AND THEIR EXACT WORDS. This is the requirement:
        // Broker Name and Status, nothing else.
        expect(
            [...element.shadowRoot.querySelectorAll('th')].map((th) =>
                th.textContent.trim()
            )
        ).toEqual(['Broker Name', 'Status']);
        // Real column headers, not styled divs — an empty or scope-less <th>
        // fails axe's own table rules and leaves the values unassociated.
        expect(
            [...element.shadowRoot.querySelectorAll('th')].map((th) =>
                th.getAttribute('scope')
            )
        ).toEqual(['col', 'col']);

        // 🔴 SERVER ORDER, NOT SORTED. The fixture is Backup-FIRST on purpose.
        expect(rows(element)).toEqual([
            ['Marcus & Millichap', 'Backup'],
            ['Jones Lang LaSalle', 'Selected']
        ]);

        // ABSENT — a sale with no BOV submissions at all (a manually appointed
        // broker is a real path). Not a headerless table, not an empty card,
        // not a "none yet" line: NOTHING.
        getSubmissions.emit([]);
        await Promise.resolve();

        expect(table(element)).toBeNull();
        expect(card(element)).toBeNull();
        // 🔴 NOT ONE ELEMENT. A titled "BOV (0)" card is the failure mode this
        // assertion exists to catch.
        expect(element.shadowRoot.querySelectorAll('*')).toHaveLength(0);
        expect(element.shadowRoot.textContent).toBe('');
    });

    it('🔴 NOTHING IS CLAIMED BEFORE THE WIRE ANSWERS', async () => {
        const element = createComponent();
        await Promise.resolve();

        // ABSENT FIRST — nobody has counted anything yet, so a "BOV (0)" here
        // would state, in the same words it would use for a sale that genuinely
        // has none, that no broker ever responded. Inverted order because a
        // pre-wire state cannot be reached by emitting.
        expect(element.shadowRoot.querySelectorAll('*')).toHaveLength(0);

        // THEN PRESENT — which proves the absence above is the pre-wire state
        // and not a component that renders nothing ever.
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();
        expect(table(element)).not.toBeNull();
    });

    it('🔴 FAILED READ: the card IS there, with one honest line and NO count', async () => {
        const element = createComponent();
        getSubmissions.error();
        await Promise.resolve();

        // 🔴 A FAILED READ IS NOT AN EMPTY SALE. Silence here would be a
        // confident wrong answer — the reader would conclude that no broker ever
        // responded.
        expect(card(element)).not.toBeNull();
        const line = element.shadowRoot.querySelector('.brc-unavailable');
        expect(line).not.toBeNull();
        expect(line.textContent.trim()).toBe(
            'Broker responses could not be loaded.'
        );
        // `status`, not `alert`: nothing the user did caused this, and a
        // secondary card on a busy record page does not get to interrupt.
        expect(line.getAttribute('role')).toBe('status');

        // 🔴 NO NUMBER — the card knows none. "BOV (0)" would be the same words
        // it would use for a sale with genuinely no submissions.
        expect(titleText(element)).toBe('BOV');
        expect(titleText(element)).not.toMatch(/\d/);
        // ...and no table, headerless or otherwise.
        expect(table(element)).toBeNull();
        expect(element.shadowRoot.querySelector('th')).toBeNull();
    });

    it('🔴 A FAILED READ CLEARS WHAT WAS ON SCREEN — it does not leave stale rows', async () => {
        const element = createComponent();

        // A good read first: two rows and a count.
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();
        expect(rows(element)).toHaveLength(2);
        expect(titleText(element)).toBe('BOV (2)');

        // ...then the refresh fails.
        getSubmissions.error();
        await Promise.resolve();

        // 🔴 THIS IS WHAT PINS `this._rows = []` IN THE ERROR BRANCH. A handler
        // that only set the failed flag would leave a full table on screen
        // directly above a line saying the responses could not be loaded — two
        // contradictory claims at once — and would keep a stale count in the
        // title.
        // ⚠ THE ERROR-ONLY TEST ABOVE CANNOT CATCH THAT: it never emits data, so
        // the array is already empty when the error arrives and the mutant
        // passes. This one has to emit first. Mutation-verified.
        expect(table(element)).toBeNull();
        expect(titleText(element)).toBe('BOV');
        expect(element.shadowRoot.querySelector('.brc-unavailable')).not.toBeNull();
    });

    it('🔴 EMPTY AND UNAVAILABLE NEVER SHARE A RENDERING', async () => {
        const element = createComponent();

        // The failure renders the card and the line...
        getSubmissions.error();
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('.brc-unavailable')).not.toBeNull();

        // ...and the empty sale renders neither. Same instance, one emit apart.
        // This is the assertion that fails if somebody collapses the two
        // branches into one "nothing to show" state.
        getSubmissions.emit([]);
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('.brc-unavailable')).toBeNull();
        expect(element.shadowRoot.textContent).not.toContain('could not be loaded');
        expect(element.shadowRoot.querySelectorAll('*')).toHaveLength(0);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // WHAT THE TWO COLUMNS CONTAIN.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 TWO COLUMNS MEANS TWO — no valuation, cap rate, score, days or contact', async () => {
        const element = createComponent();
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        // Guard the guard: two real rows rendered, so every absence is real.
        expect(rows(element)).toHaveLength(2);

        // 🔴 THE FIXTURES CARRY ALL FIVE COMPARISON FIGURES, so a re-added column
        // would render real, plausible data — which is exactly why the header
        // and cell counts are not sufficient on their own.
        const text = table(element).textContent;
        [
            '4,200,000',
            '4200000',
            '3,950,000',
            '6.1',
            '6.4',
            '92.5',
            '74',
            '45',
            '60',
            'Dana Reid',
            'Priya Nair'
        ].forEach((banned) => {
            expect(text).not.toContain(banned);
        });
        ['Valuation', 'Cap Rate', 'Score', 'Days', 'Contact', 'Commission'].forEach(
            (banned) => {
                expect(text).not.toContain(banned);
            }
        );

        // Two cells per row, structurally — a column added with no header text
        // would slip past the word list above.
        [...element.shadowRoot.querySelectorAll('tbody tr')].forEach((tr) => {
            expect(tr.querySelectorAll('td')).toHaveLength(2);
        });
    });

    it('🔴 THE STATUS IS READABLE TEXT; ONLY THE PILL COLOUR IS DERIVED', async () => {
        const element = createComponent();
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        const pills = [
            ...element.shadowRoot.querySelectorAll('.brc-table tbody .brc-badge')
        ];
        expect(pills).toHaveLength(2);
        // The WORD is the state. This repo has a measured incident of a
        // text->badge swap deleting accessible content a test had pinned, and
        // axe's colour-contrast rule is INERT in jsdom — so colour alone would be
        // checked by nothing in this pipeline.
        expect(pills.map((s) => s.textContent.trim())).toEqual([
            'Backup',
            'Selected'
        ]);
        // The colour is reinforcement, derived from `isSelected` — never the
        // other way round.
        expect(pills[0].className).toBe('brc-badge brc-badge--backup');
        expect(pills[1].className).toBe('brc-badge brc-badge--selected');
    });

    it('🔴 THE STATUS WORD IS PASSED THROUGH, NOT DERIVED FROM isSelected', async () => {
        const element = createComponent();
        // Row 1: the record leaves the status blank, so it falls back to the
        // picklist's own default ("Backup" carries <default>true</default> in the
        // field metadata — it is the field's answer, not a guess).
        // Row 2: A THIRD VALUE. See the fixture's own comment — this row is the
        // only thing in the file that can tell a pass-through apart from a
        // two-way ternary on `isSelected`, because with only Backup/Selected in
        // play the two implementations are indistinguishable.
        getSubmissions.emit([SUB_BLANK_STATUS, SUB_THIRD_STATUS]);
        await Promise.resolve();

        expect(rows(element)).toEqual([
            ['Newmark', 'Backup'],
            ['Colliers', 'Withdrawn']
        ]);

        // 🔴 AND THE THIRD VALUE STILL GETS THE NEUTRAL PILL, NOT THE GREEN ONE.
        // The COLOUR is the only thing derived from `isSelected`, and the safe
        // side of an unknown status is "not chosen".
        expect(
            [...element.shadowRoot.querySelectorAll('.brc-badge')].map(
                (s) => s.className
            )
        ).toEqual(['brc-badge brc-badge--backup', 'brc-badge brc-badge--backup']);
    });

    it('🔴 A NAMELESS FIRM RENDERS THE PLACEHOLDER, NEVER A BLANK CELL', async () => {
        const element = createComponent();
        getSubmissions.emit([SUB_PREFERRED_NAMELESS, SUB_WHITESPACE_FIRM]);
        await Promise.resolve();

        // ⚠ TWO DIFFERENT BLANK SHAPES AND BOTH REACH THE SAME PLACEHOLDER. A
        // null is falsy; `'   '` is falsy NOWHERE in JavaScript, so a bare `||`
        // renders a blank cell for it — visually identical to the null case and
        // reachable from a hand-typed record. Only the `.trim()` catches it.
        expect(rows(element)).toEqual([
            ['Unnamed broker', 'Backup'],
            ['Unnamed broker', 'Backup']
        ]);
        // ⚠ THE SAME WORDS `c/bovPreferredBroker` USES FOR THE SAME MISSING
        // VALUE. The Preferred Broker card two places above can be showing this
        // very row at the same moment, and two placeholders for one missing
        // value read as two different states.
        expect(element.shadowRoot.textContent).not.toContain('undefined');
        expect(element.shadowRoot.textContent).not.toContain('null');
    });

    it('🔴 PREFERRED ROWS ARE INCLUDED IN THE LIST, NOT FILTERED OUT', async () => {
        const element = createComponent();
        getSubmissions.emit([SUB_SELECTED, SUB_BACKUP, SUB_PREFERRED_NAMED]);
        await Promise.resolve();

        // The user's design shows three named firms with three statuses. The
        // preferred broker is one of the sale's BOV submissions like any other.
        // 🔴 `c/bovComparisonMatrix` EXCLUDES the preferred row — that is a fact
        // about the matrix (it is a chooser, and the preferred row is not a
        // candidate), NOT a house rule. Copying its filter here would silently
        // drop a row and leave the count disagreeing with the list.
        expect(rows(element)).toEqual([
            ['Jones Lang LaSalle', 'Selected'],
            ['Marcus & Millichap', 'Backup'],
            ['Cushman & Wakefield', 'Backup']
        ]);
        // The count matches the list beneath it — which is the only property a
        // count on a card needs.
        expect(titleText(element)).toBe('BOV (3)');
    });

    it('the table is NAMED by the card title, so it is not an anonymous grid', async () => {
        const element = createComponent();
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        // ⚠ THE IDREF RESOLVES BECAUSE THE TITLE SPAN, THOUGH SLOTTED INTO
        // `lightning-card`'s SHADOW ROOT, IS STILL A NODE OF THIS COMPONENT'S
        // SHADOW TREE — which is the tree an IDREF is resolved in. A <caption>
        // was the alternative and was rejected: it would render the same words a
        // second time, directly under the title that already says them.
        //
        // 🔴 MEASURED: THE RENDERED `id` IS **NOT** THE ONE IN THE TEMPLATE. The
        // LWC compiler mangles every static `id` to keep it unique across
        // instances — `id="brc-title"` renders as `brc-title-20` — and rewrites
        // every IDREF in the SAME template to match. So the assertion has to be
        // that the two AGREE, never that either equals the literal in the
        // source. A test written against the literal fails on a component that
        // is completely correct, and (worse) a test asserting only
        // `getAttribute('aria-labelledby') === 'brc-title'` would keep passing if
        // the span's `id` were deleted, because the mangling is what ties them.
        const id = titleSpan(element).id;
        expect(id).toBeTruthy();
        expect(id).toMatch(/^brc-title-\d+$/);
        expect(table(element).getAttribute('aria-labelledby')).toBe(id);

        // ...and it actually resolves, inside this shadow root, to the title.
        // ⚠ `[id="…"]`, NOT `#…`. MEASURED: under LWC's SYNTHETIC shadow DOM an
        // ID SELECTOR returns `null` for an element the attribute selector finds
        // on the very next line. Written as `#${id}` this assertion fails on a
        // component that is entirely correct, which reads as a broken IDREF.
        const named = element.shadowRoot.querySelector(`[id="${id}"]`);
        expect(named).toBe(titleSpan(element));
        expect(named.textContent.trim()).toBe('BOV (2)');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE STYLESHEET — jsdom performs NO LAYOUT, so nothing in a DOM
    // assertion above can see a burst container, a lost inset or a dark-on-dark
    // pill. Source-text pins are the only automated falsifiers that exist.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-CSS: the table cannot burst a 340px sidebar, and the card body is inset', () => {
        // `table-layout: fixed` hands the two columns their width up front
        // instead of letting the longest firm name set it; `width: 100%` is what
        // gives it a width to divide. Drop either and a long firm name pushes the
        // card sideways at 340px.
        const tableRule = CSS_SOURCE.match(/\.brc-table\s*\{([^}]*)\}/);
        expect(tableRule).not.toBeNull();
        expect(tableRule[1]).toMatch(/table-layout\s*:\s*fixed/);
        expect(tableRule[1]).toMatch(/width\s*:\s*100%/);

        // `anywhere`, not `break-word`: only `anywhere` affects min-content
        // sizing, which is what actually lets a long unbreakable firm name wrap.
        const host = CSS_SOURCE.match(/:host\s*\{([^}]*)\}/);
        expect(host).not.toBeNull();
        expect(host[1]).toMatch(/overflow-wrap\s*:\s*anywhere/);

        // `lightning-card`'s default slot has no padding of its own.
        const body = CSS_SOURCE.match(/\.brc-body\s*\{([^}]*)\}/);
        expect(body).not.toBeNull();
        expect(body[1]).toMatch(/padding\s*:\s*var\(--slds-g-spacing-/);

        // 🔴 NO MEDIA QUERIES: they measure the VIEWPORT, and the constraint here
        // is CONTAINER width — the same viewport yields a ~276px sidebar or a
        // ~900px main region.
        // 🔴 AND NO `@container` EITHER: measured in this repo, it compiles fine
        // but makes jsdom DISCARD THE WHOLE STYLESHEET, which would silently
        // disable every pin in this block.
        expect(CSS_SOURCE).not.toMatch(/@media/);
        expect(CSS_SOURCE).not.toMatch(/@container/);
    });

    it('🔴 T-TOKENS: no colour is hardcoded, and the green is NOT container-1', () => {
        // Blanking `var(--hook, #fallback)` INCLUDING its fallback is the trick —
        // a hex surviving that is one nothing can re-theme. Every SLDS 2 colour
        // hook resolves to a `light-dark(...)` pair in the cosmos theme, so a
        // literal written straight into a declaration is correct in exactly one
        // theme.
        const withoutTokens = CSS_SOURCE.replace(/var\(\s*--[^()]*\)/g, 'TOKEN');
        expect(withoutTokens).not.toMatch(/#[0-9a-fA-F]{3}/);
        expect(withoutTokens).not.toMatch(/rgba?\(/);
        expect(withoutTokens).not.toMatch(/hsla?\(/);
        // Guard the guard: the stylesheet really is token-driven, so the
        // absences above mean something.
        expect((CSS_SOURCE.match(/var\(\s*--slds-/g) || []).length).toBeGreaterThan(
            20
        );

        // 🔴 `--slds-g-color-success-container-1` IS #2e844a — A SOLID MID-GREEN,
        // not a tint — so the natural-reading "pale container + dark text"
        // pairing is dark-on-dark wherever the SLDS 2 base theme is active. The
        // pale literal beside it in a `var()` fallback describes only the
        // hook-UNDEFINED case, so a file shipping it reads as correct. NOTHING
        // ELSE IN THIS PIPELINE CATCHES IT: the SLDS linter only checks that a
        // hook was used, and axe's colour-contrast rule is inert in jsdom.
        const selected = CSS_SOURCE.match(/\.brc-badge--selected\s*\{([^}]*)\}/);
        expect(selected).not.toBeNull();
        expect(selected[1]).not.toMatch(/container-1/);
        expect(selected[1]).toMatch(/success-base-95/);
        expect(selected[1]).toMatch(/success-base-30/);

        // ⚠ AND THE NEUTRAL PILL IS NOT THE `disabled-*` PAIR: measured, that is
        // WHITE on PALE GREY and near-invisible on a white card.
        const backup = CSS_SOURCE.match(/\.brc-badge--backup\s*\{([^}]*)\}/);
        expect(backup).not.toBeNull();
        expect(backup[1]).not.toMatch(/disabled/);
    });

    it('is accessible with rows', async () => {
        const element = createComponent();
        getSubmissions.emit([SUB_SELECTED, SUB_BACKUP, SUB_PREFERRED_NAMED]);
        await Promise.resolve();

        expect(rows(element)).toHaveLength(3);
        await expect(element).toBeAccessible();
    });

    it('is accessible on the failed read', async () => {
        const element = createComponent();
        getSubmissions.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.brc-unavailable')).not.toBeNull();
        await expect(element).toBeAccessible();
    });
});
