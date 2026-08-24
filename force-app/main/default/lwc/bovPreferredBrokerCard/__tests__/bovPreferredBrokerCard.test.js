/**
 * c-bov-preferred-broker-card
 * ---------------------------------------------------------------------------
 * "Preferred Broker" — card #1 of the three stacked broker cards on the
 * Disposition record page (2026-08-25). One `@wire(getSubmissions,
 * { dispositionId: '$recordId' })`, ONE rendered shape, and THREE states that
 * render nothing.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 EVERY ABSENCE PIN BELOW IS PAIRED WITH A PRESENCE CONTROL ON THE SAME
 * COMPONENT INSTANCE, AND THAT IS NOT STYLISTIC.
 * ═══════════════════════════════════════════════════════════════════════════
 * `expect(q('c-bov-preferred-broker')).toBeNull()` passes for two completely
 * different reasons — the gate correctly withheld the panel, or the feature was
 * deleted. This whole component IS a gate, so a suite of bare `toBeNull()`
 * assertions would be green against an empty template. Every test that asserts
 * an absence therefore either renders the panel first and re-emits to remove it,
 * or asserts the absence first and then emits to bring it back. Re-emission on
 * one instance is free: a test wire adapter's `emit()` pushes to every live
 * instance, so a second `getSubmissions.emit(...)` is a data change, not a new
 * fixture.
 *
 * 🔴 TWO MICROTASK TICKS, NOT ONE. This card mounts a CHILD component
 * (`c/bovPreferredBroker`). The repo's usual single `await Promise.resolve()`
 * re-renders the PARENT and leaves the child's own shadow root EMPTY, which
 * makes every assertion about the child's rendered text vacuously "absent".
 * `flush()` below awaits twice. Measured in this repo.
 *
 * ⚠ AND A CHILD'S TEXT NEVER REACHES THIS COMPONENT'S
 * `shadowRoot.textContent` — measured `""` with children rendering. Anything the
 * CHILD owns (its "Unnamed broker" fallback) must be read out of
 * `panel.shadowRoot`; anything this card owns (the title) out of its own.
 *
 * ⚠ EVERY ASSERTION READS A RENDERED ELEMENT OR A PROPERTY, NEVER A GETTER.
 * This repo has a measured defect where a getter-only assertion stayed green
 * while the rendered output was wrong — a getter's return value is not the
 * attribute the template writes.
 */
import { createElement } from 'lwc';
import BovPreferredBrokerCard from 'c/bovPreferredBrokerCard';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not
// cosmetic: the source-text pin below searches for values that this file's own
// prose names, so an unstripped read would satisfy the search from the comment
// and be vacuously green.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'bovPreferredBrokerCard.css'),
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
// `BovController.BovRow` FIXTURES.
//
// ⚠ THE COMPARISON FIGURES ARE POPULATED ON PURPOSE. The server hands this card
// the SAME row the BOV Comparison Matrix renders — valuation, cap rate, score
// and all — so a card that started rendering them would have real, plausible
// data to display. Nulling the fixtures out "because the card does not use those
// fields" would delete the only evidence that it does not.
// ─────────────────────────────────────────────────────────────────────────────

/** The appointed broker: Selected, NOT flagged preferred. */
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
 * `Broker_Firm__c` is legitimately nullable and was null on live data this week:
 * a preferred broker is a firm DPEG would like to use, recorded ahead of any
 * quoted opinion of value, so the thin row carrying the flag frequently carries
 * nothing else.
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

describe('c-bov-preferred-broker-card', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    const createComponent = () => {
        const element = createElement('c-bov-preferred-broker-card', {
            is: BovPreferredBrokerCard
        });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        return element;
    };

    /**
     * Two microtask ticks. ⚠ ONE IS NOT ENOUGH — see the file header.
     */
    const flush = async () => {
        await Promise.resolve();
        await Promise.resolve();
    };

    const card = (element) => element.shadowRoot.querySelector('lightning-card');
    const panel = (element) =>
        element.shadowRoot.querySelector('c-bov-preferred-broker');
    const titleSpan = (element) =>
        element.shadowRoot.querySelector('span[slot="title"]');

    // ─────────────────────────────────────────────────────────────────────────
    // THE GATE — the whole point of the bundle.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 THE CARD RENDERS WHEN A ROW IS FLAGGED PREFERRED, AND NOT WHEN NONE IS', async () => {
        const element = createComponent();

        // PRESENT.
        getSubmissions.emit([SUB_BACKUP, SUB_PREFERRED_NAMED]);
        await flush();

        expect(card(element)).not.toBeNull();
        expect(panel(element)).not.toBeNull();
        // 🔴 THE FIRM NAME REACHES THE CHILD. Without this the panel renders
        // "Unnamed broker" for a broker that HAS a name, and every structural
        // assertion in this file still passes.
        expect(panel(element).firmName).toBe('Cushman & Wakefield');

        // ABSENT — same instance, same fixture shape, one row swapped. The card
        // must withhold itself ENTIRELY: not an empty card, not a "none yet"
        // line. A FlexiPage visibility rule cannot express this condition, so
        // this gate is the only thing standing between the user and a green
        // panel asserting a broker that does not exist.
        getSubmissions.emit([SUB_BACKUP, SUB_SELECTED]);
        await flush();

        expect(panel(element)).toBeNull();
        expect(card(element)).toBeNull();
        // 🔴 NOT ONE ELEMENT, not even the card chrome. A titled empty card is
        // the failure mode this assertion exists to catch.
        expect(element.shadowRoot.querySelectorAll('*')).toHaveLength(0);
    });

    it('🔴 NOTHING IS CLAIMED BEFORE THE WIRE ANSWERS', async () => {
        const element = createComponent();
        await flush();

        // ABSENT FIRST — nobody has looked for a broker yet, so an empty green
        // "Preferred Broker" card here would assert one. Inverted order (absence
        // then presence) because a pre-wire state cannot be reached by emitting.
        expect(card(element)).toBeNull();
        expect(element.shadowRoot.querySelectorAll('*')).toHaveLength(0);

        // THEN PRESENT — which is what proves the assertions above are about the
        // pre-wire state and not about a component that renders nothing ever.
        getSubmissions.emit([SUB_PREFERRED_NAMED]);
        await flush();
        expect(panel(element)).not.toBeNull();
    });

    it('🔴 A NAMELESS PREFERRED BROKER STILL GETS THE CARD, AND THE CHILD SUPPLIES THE FALLBACK', async () => {
        const element = createComponent();
        getSubmissions.emit([SUB_PREFERRED_NAMELESS]);
        await flush();

        // The flag is what makes a preferred broker, not the name. A row that
        // carries the flag and nothing else is the LIVE shape.
        expect(card(element)).not.toBeNull();
        expect(panel(element)).not.toBeNull();

        // 🔴 `''`, NOT `null` AND NOT `undefined`. This value is bound to an
        // ATTRIBUTE on a custom element, and a getter bound to an attribute is
        // written UNCONDITIONALLY — `undefined` reaches the DOM as the literal
        // string "undefined", measured in this repo.
        expect(panel(element).firmName).toBe('');

        // ⚠ READ FROM THE CHILD'S OWN SHADOW ROOT. A child's text NEVER reaches
        // the parent's `shadowRoot.textContent` (measured: `""` with children
        // rendering), so the obvious parent-side assertion would be vacuously
        // green whatever the child did. The prop assertion above and this one
        // are TWO DIFFERENT CLAIMS: only the prop catches the parent sending
        // `undefined`, only this catches the child losing its fallback.
        expect(panel(element).shadowRoot.textContent).toContain('Unnamed broker');
        expect(panel(element).shadowRoot.textContent).not.toContain('undefined');
    });

    it('🔴 A FAILED READ CLEARS WHAT WAS ON SCREEN — it does not leave a stale broker', async () => {
        const element = createComponent();

        // A good read first: the card is up, naming a broker.
        getSubmissions.emit([SUB_PREFERRED_NAMED]);
        await flush();
        expect(panel(element)).not.toBeNull();
        expect(panel(element).firmName).toBe('Cushman & Wakefield');

        // ...then the refresh fails.
        getSubmissions.error();
        await flush();

        // 🔴 THIS IS WHAT PINS `this._rows = []` IN THE ERROR BRANCH. A handler
        // that only recorded the failure would leave a green panel on screen
        // still naming Cushman & Wakefield, with nothing anywhere on the page
        // saying the data is stale.
        // ⚠ AN ERROR-ONLY TEST CANNOT CATCH THAT: it never emits data, so the
        // array is already empty when the error arrives and the mutant passes.
        // This test has to emit first. Mutation-verified.
        expect(panel(element)).toBeNull();
        expect(card(element)).toBeNull();
    });

    it('🔴 A FAILED READ IS SILENT — no error banner, no empty card, nothing', async () => {
        const element = createComponent();
        getSubmissions.error();
        await flush();

        // ⚠ THIS IS A DECISION ABOUT THE PAGE, NOT AN OMISSION.
        // `c/bovResponsesCard` — same wire, same config, same LDS cache entry, a
        // few inches below on the same page — renders the honest `role="status"`
        // line for this failure. Two cards announcing one failed read is noise,
        // and a hero panel's honest form of "we could not read the brokers" is
        // not to claim a broker.
        expect(element.shadowRoot.querySelectorAll('*')).toHaveLength(0);
        expect(element.shadowRoot.textContent).toBe('');

        // Presence control: the same instance renders on a good read, so the
        // absences above are the failure state and not a dead component.
        getSubmissions.emit([SUB_PREFERRED_NAMED]);
        await flush();
        expect(panel(element)).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // THE CARD CHROME.
    // ─────────────────────────────────────────────────────────────────────────

    it('the card is titled "Preferred Broker" and carries no count', async () => {
        const element = createComponent();
        getSubmissions.emit([SUB_PREFERRED_NAMED, SUB_SELECTED, SUB_BACKUP]);
        await flush();

        expect(titleSpan(element).textContent.trim()).toBe('Preferred Broker');
        // 🔴 NO NUMBER, EVER. There is exactly one preferred broker by
        // definition, so "(1)" would be noise — and a count of the three
        // SUBMISSIONS in the fixture would be a number for a list this card does
        // not render. That number belongs to `c/bovResponsesCard`.
        expect(titleSpan(element).textContent).not.toMatch(/\d/);
        expect(card(element).iconName).toBe('standard:contact');
    });

    /**
     * 🔴 T-TRIPLE-LABEL — a KNOWN, MEASURED duplication, pinned so that removing
     * any copy is a decision rather than an accident.
     *
     * ⚠ IT IS THREE, NOT TWO. This test was written expecting two and MEASURED
     * three; that is the reason it is worth having. Announced in order, a screen
     * reader on this card hears:
     *   1. "Preferred Broker"        — this card's title  (THIS bundle)
     *   2. "Preferred Broker"        — the panel's eyebrow (`c/bovPreferredBroker`)
     *   3. "Preferred broker:" YES   — the pill's visually-hidden subject, which
     *                                  exists because "YES" alone names nothing
     * Copies 2 and 3 are both load-bearing for the child's OTHER consumer:
     * `c/bovBrokerPanel` titles its card "Brokers", so without the eyebrow that
     * panel would be an unlabelled green box, and without the hidden subject its
     * pill would announce the bare word "YES".
     *
     * COPY 1 IS THE ONE THIS BUNDLE ADDS, and it is the user's design ("a card
     * titled Preferred Broker"). Suppressing copy 2 from here would mean an
     * `@api` mode flag on the child — exactly the shape this repo spent
     * 2026-08-24 retiring from `c/bovComparisonMatrix` — so it was not done.
     *
     * ⚠ IF THE REPETITION IS EVER JUDGED UNACCEPTABLE the fix is to drop the
     * EYEBROW from the child and give `c/bovBrokerPanel`'s instance a heading of
     * its own; copy 3 must stay whatever happens. At that point this test is
     * updated on purpose, which is the whole reason it counts rather than merely
     * asserting "contains".
     */
    it('🔴 T-TRIPLE-LABEL: the phrase renders THREE times — title, eyebrow, and the pill subject', async () => {
        const element = createComponent();
        getSubmissions.emit([SUB_PREFERRED_NAMED]);
        await flush();

        // COPY 1 — this card's own shadow root, and it is the ONLY one here. A
        // child's text never reaches a parent's `shadowRoot.textContent`
        // (measured `""` in this repo), so this count cannot see the other two.
        expect(
            (element.shadowRoot.textContent.match(/Preferred Broker/g) || []).length
        ).toBe(1);

        // COPIES 2 AND 3 — inside the child, a separate shadow tree. The two are
        // distinguishable by case and by the colon: the eyebrow is title-case
        // with no colon, the pill's hidden subject is sentence-case WITH one
        // (without the colon the accessible name reads "Preferred brokerYES" —
        // the template compiler discards the whitespace-only text node between
        // the span and the word).
        const childText = panel(element).shadowRoot.textContent;
        expect((childText.match(/Preferred Broker/g) || []).length).toBe(1);
        expect((childText.match(/Preferred broker: /g) || []).length).toBe(1);
        expect((childText.match(/Preferred Broker/gi) || []).length).toBe(2);

        // Guard the guard: the child really did render its panel, so these are
        // duplicates and not an empty stub.
        expect(childText).toContain('Cushman & Wakefield');
        expect(childText).toContain('YES');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-CSS — jsdom performs NO LAYOUT, so this stylesheet is invisible to
    // every DOM assertion above. A source-text pin is the only automated
    // falsifier that exists for it.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-CSS: the card body is inset from a spacing token, and no colour is hardcoded', () => {
        // Without this the green panel renders flush against the card's edges —
        // `lightning-card`'s default slot has no padding of its own.
        const body = CSS_SOURCE.match(/\.pbc-body\s*\{([^}]*)\}/);
        expect(body).not.toBeNull();
        expect(body[1]).toMatch(/padding\s*:\s*var\(--slds-g-spacing-/);

        // 🔴 THIS BUNDLE OWNS NO COLOUR AT ALL — every colour in the card belongs
        // to `c/bovPreferredBroker`, whose stylesheet documents at length why the
        // green is `success-base-95` + `success-base-30` and not the SOLID
        // `success-container-1`. A colour appearing here is a second copy to
        // drift. Blanking `var(--hook, #fallback)` INCLUDING its fallback is the
        // trick: a hex surviving that is one nothing can re-theme.
        const withoutTokens = CSS_SOURCE.replace(/var\(\s*--[^()]*\)/g, 'TOKEN');
        expect(withoutTokens).not.toMatch(/#[0-9a-fA-F]{3}/);
        expect(withoutTokens).not.toMatch(/rgba?\(/);
        expect(withoutTokens).not.toMatch(/hsla?\(/);
        expect(withoutTokens).not.toMatch(/\b(background|color)\s*:/);
    });

    it('is accessible', async () => {
        const element = createComponent();
        getSubmissions.emit([SUB_PREFERRED_NAMED, SUB_SELECTED]);
        await flush();

        // ⚠ `@sa11y/jest` DOES traverse into child shadow roots, so this audits
        // `c/bovPreferredBroker` in its nested position — which is where a
        // doubled landmark or heading would show up and where the child's own
        // suite cannot see it.
        await expect(element).toBeAccessible();
    });
});
