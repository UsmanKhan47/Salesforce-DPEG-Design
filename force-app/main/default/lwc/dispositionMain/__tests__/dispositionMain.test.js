/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRecord)
 * ---------------------------------------------
 * Follows the c-transaction-critical-dates LDS template. c-disposition-main is a
 * single-field router: it reads Disposition__c.Disposition_Stage__c via
 * getRecord + getFieldValue and swaps which feature child renders. So there is
 * NO jest.mock() for LDS — just getRecord.emit(record) with a UI-API record whose
 * fields use the REAL Disposition__c field API name.
 *
 * ⚠ THE TERMINAL STAGE IS 'Sale Closes', NOT 'Completed'. The disposition flow
 * redesign RETIRED 'Completed' (along with 'Call for Offers' and 'Disposition
 * Offer'), so this suite no longer emits it. A fixture that kept emitting a
 * retired value would keep PASSING while proving nothing — the branch simply
 * never fires for a value the org can no longer produce.
 *
 * The child feature components (bov matrix, broker listing, wire verification,
 * ...) render idle: their un-mocked Apex resolves to the transformer's default
 * Promise.resolve() stub, so they mount in an empty state rather than throwing.
 * Assertions check WHICH child slot appears per stage.
 *
 * ⚠ "closing tasks" WAS IN THAT LIST UNTIL 2026-08-24. `c-disposition-closing-tasks`
 * (the "Closing Checklist" card) is no longer rendered by this component at any
 * stage — see the Closing-stage tests below, which now pin its ABSENCE.
 *
 * 🔴 A CHILD'S SHADOW TEXT DOES NOT REACH THIS COMPONENT'S `shadowRoot.textContent`.
 * Probed here on 2026-08-24: at Closing, with `c-wire-verification` mounted and
 * rendering its own card, the parent's `shadowRoot.textContent` is `""`. Every
 * absence assertion in this file must therefore be a TAG scan; a `.not.toContain
 * ('some word')` text assertion is green whatever renders.
 * The accessibility assertion runs against the empty (no-stage) state, which is a
 * guaranteed axe-clean target (matches the headless c-submit-for-approval
 * precedent) and does not depend on grandchild markup.
 */
import { createElement } from 'lwc';
import DispositionMain from 'c/dispositionMain';
import { getRecord } from 'lightning/uiRecordApi';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not cosmetic:
// this stylesheet's comments NAME the values they ban ("margin-top: 16px", "32px"), so an
// un-stripped read would satisfy — or fail — the assertions below for the wrong reason.
//
// 🔴 SOURCE TEXT, NOT getComputedStyle AND NOT A GETTER. jsdom performs no layout, so the
// only observable fact about a `gap` here is that the rule exists. A DOM-only suite is
// completely blind to this file: every stage assertion below stayed green the entire time
// the cards were rendering flush against each other on the record page.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'dispositionMain.css'),
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

const RECORD_ID = 'a0D5g000000DispEAG';

function recordForStage(stage) {
    return {
        apiName: 'Disposition__c',
        id: RECORD_ID,
        fields: { Disposition_Stage__c: { value: stage } }
    };
}

describe('c-disposition-main', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-main', {
            is: DispositionMain
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders no feature child before the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-broker-panel')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-broker-listing')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 BOV OUTREACH IS NOW ONE TAG, NOT TWO (2026-08-24, later the same day)
    //
    // This branch mounted `c-bov-comparison-matrix` TWICE — once with
    // `preferred-only hide-actions`, once bare — and three tests here pinned that
    // pair, its document order and its bare-attribute booleans.
    // `c-bov-broker-panel` now wraps both sections under ONE header carrying the
    // three broker buttons, so ALL of that moved to
    // `lwc/bovBrokerPanel/__tests__/bovBrokerPanel.test.js`, which pins the pair,
    // the order and the `lwc:if` that stops the preferred section orphaning a
    // stack gap when the disposition has no preferred broker — the defect
    // `dispositionMain.css` used to document as "KNOWN, ACCEPTED".
    // 🔴 RETRACTED IN PLACE: that list used to end "`preferredOnly === true` on the
    // top card and `=== false` on the bare one". THERE IS NO SUCH FLAG ANY MORE.
    // Later on 2026-08-24 the preferred view became a hero panel rather than a
    // filtered table, so it became its own bundle (`c/bovPreferredBroker`) and the
    // boolean pin was replaced by a `firmName` contract.
    //
    // ⚠ WHAT MUST STAY PINNED **HERE** is the only thing this file controls:
    // WHICH tag this stage renders, and that the matrix bundle is no longer
    // mounted beside it.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 BOV Outreach renders the broker PANEL, with the record id', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('BOV Outreach'));
        await Promise.resolve();

        const panel = element.shadowRoot.querySelector('c-bov-broker-panel');
        expect(panel).not.toBeNull();
        // ⚠ THE PANEL HAS NO OTHER ROUTE TO THE DISPOSITION. Without record-id it
        // wires `undefined`, its Apex returns an empty list rather than throwing,
        // and the card renders a permanent, confident empty state with nothing on
        // the page to contradict it.
        expect(panel.recordId).toBe(RECORD_ID);

        expect(element.shadowRoot.querySelector('c-broker-listing')).toBeNull();
    });

    it('🔴 the matrix bundle is NOT mounted by this router any more', async () => {
        // ABSENCE PIN, AND A TAG SCAN — never a textContent search. A child's
        // shadow text does not reach this component's shadowRoot (measured here
        // on 2026-08-24: it is the EMPTY STRING even with children rendering), so
        // a word-based assertion would be green whatever renders.
        //
        // 🔴 WHY IT MATTERS: re-adding `<c-bov-comparison-matrix>` here is a
        // one-line mistake that puts a THIRD copy of the same table, with its own
        // wire and no buttons, beside the panel's two. Nothing would error.
        const element = createComponent();

        getRecord.emit(recordForStage('BOV Outreach'));
        await Promise.resolve();

        const renderedTags = Array.from(
            element.shadowRoot.querySelectorAll('*')
        ).map((el) => el.tagName.toLowerCase());

        // Guard the guard: the branch really fired.
        expect(renderedTags).toContain('c-bov-broker-panel');
        // 🔴 THE STRONGEST FORM: this stage renders EXACTLY ONE child, so the pin
        // also catches the matrix being re-added under a different bundle name.
        expect(renderedTags).toEqual(['c-bov-broker-panel']);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 RELEASE MATERIALS (2026-08-24) — the response logger
    //
    // This tag is the ONLY route to creating a `Release_Materials_Response__c`:
    // the object ships with no tab and no list view. Removing the line does not
    // hide a feature, it deletes the only way in.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 Release Materials stage renders the response logger, and only it', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Release Materials'));
        await Promise.resolve();

        const logger = element.shadowRoot.querySelector(
            'c-release-materials-response-log'
        );
        expect(logger).not.toBeNull();
        // ⚠ THE CHILD HAS NO OTHER ROUTE TO THE DISPOSITION. Without record-id
        // it wires `undefined`, its Apex returns a fully-populated EMPTY context
        // rather than throwing, and the card renders a permanent, confident
        // empty log — headers with no rows — that nothing on the page
        // contradicts. (It said "No responses yet" until that hardcoded empty
        // state was removed on 2026-08-25; the wrong answer is the same one.)
        expect(logger.recordId).toBe(RECORD_ID);

        // No other stage's children leak into this branch.
        expect(
            element.shadowRoot.querySelector('c-bov-broker-panel')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-broker-listing')).toBeNull();
        expect(element.shadowRoot.querySelector('c-wire-verification')).toBeNull();
    });

    it('🔴 the response logger appears at NO other stage', async () => {
        // ⚠ EXHAUSTIVE OVER EVERY OTHER VALUE OF Disposition_Stage__c, not a
        // sample. A near-miss in the getter's string comparison ('Release
        // materials', an underscore, a trailing space) fails SILENTLY — the
        // branch simply never fires — so the falsifier that matters is the
        // POSITIVE test above. This one catches the opposite mistake: a getter
        // widened to a `includes`/truthiness test that fires everywhere.
        const otherStages = [
            'Disposition Readiness',
            'BOV Outreach',
            'Broker Selection',
            'NDA',
            'Active Listing',
            'Offer Selection',
            'LOI',
            'PSA',
            'Closing',
            'Sale Closes'
        ];

        for (const stage of otherStages) {
            const element = createComponent();
            getRecord.emit(recordForStage(stage));
            // eslint-disable-next-line no-await-in-loop
            await Promise.resolve();

            expect(
                element.shadowRoot.querySelector('c-release-materials-response-log')
            ).toBeNull();
            document.body.removeChild(element);
        }
    });

    it('Active Listing stage renders the broker-listing cluster', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Active Listing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-backup-brokers')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-bov-broker-panel')
        ).toBeNull();
    });

    it('🔴 renders NO call-for-offers card at Active Listing — the UAT removal must not come back', async () => {
        // DELIBERATE ABSENCE PIN (UAT 2026-08-21: "also remove call for offers lwc, we
        // don't need to show"). The positive assertion that used to prove
        // c-disposition-call-for-offers rendered here was DELETED, not weakened — this
        // replaces it, and it is the only thing standing between a one-line re-add of the
        // tag in dispositionMain.html and it silently shipping. The bundle still exists in
        // lwc/, so the re-add is genuinely one line.
        //
        // ⚠ THE FIXTURE IS THE POPULATED ONE ON PURPOSE. 'Active Listing' is the exact
        // stage the card used to render at; an absence assertion against the pre-wire
        // empty state would pass for the wrong reason. The two not-toBeNull() checks below
        // exist to PROVE the block actually rendered, so the absence below means "the card
        // is gone" and not "nothing rendered at all".
        //
        // ⚠ SUBSTRING MATCH ON TAG NAMES, NOT A SINGLE querySelector, AND NOT textContent.
        // textContent would be VACUOUS here: c-disposition-main is a router whose children
        // are custom elements with their own shadow roots, so the host's textContent never
        // contains their copy whether they render or not. Tag names are what this component
        // actually controls. The substring also catches the OPPORTUNITY-scoped
        // c-call-for-offers-list / c-call-for-offers-panel, which are out of scope for the
        // disposition module and are the likeliest wrong thing for someone to reach for.
        const element = createComponent();

        getRecord.emit(recordForStage('Active Listing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-backup-brokers')
        ).not.toBeNull();

        const renderedTags = Array.from(
            element.shadowRoot.querySelectorAll('*')
        ).map((el) => el.tagName.toLowerCase());

        expect(renderedTags.length).toBeGreaterThan(0);
        expect(
            renderedTags.filter((tag) => tag.includes('call-for-offers'))
        ).toEqual([]);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 CLOSING = THE WIRE CARD, AND NOTHING ELSE (2026-08-24)
    //
    // `<c-disposition-closing-tasks>` (the "Closing Checklist" card) was removed
    // from the Closing branch at the user's request. Both tests below USED TO
    // assert it was present; they are retargeted rather than deleted, so the pair
    // now proves the exact opposite fact on the same fixtures.
    //
    // ⚠ THE ABSENCE PIN IS A **TAG SCAN**, NOT A textContent SEARCH, AND THAT IS
    // A MEASURED DECISION. Probed 2026-08-24 in this suite: at Closing,
    // `element.shadowRoot.textContent` is the EMPTY STRING even with
    // `c-wire-verification` mounted and rendering — a child's shadow text does not
    // cross into the parent's shadow root under this repo's Jest setup. An
    // `expect(text).not.toContain('checklist')` assertion here would therefore be
    // green forever, whether the card renders or not. The tag scan is the only
    // observable that moves. (Same shape as the call-for-offers pin above.)
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 Closing stage renders the wire card ONLY — no closing checklist', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Closing'));
        await Promise.resolve();

        const renderedTags = Array.from(
            element.shadowRoot.querySelectorAll('*')
        ).map((el) => el.tagName.toLowerCase());

        // GUARD THE GUARD: the Closing branch really fired. Without this, every
        // assertion below would also pass on a stage that renders nothing at all.
        expect(renderedTags).toContain('c-wire-verification');

        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).toBeNull();
        expect(
            renderedTags.filter((tag) => tag.includes('closing-tasks'))
        ).toEqual([]);

        // 🔴 THE STRONGEST FORM: the branch renders EXACTLY ONE child. This is what
        // catches a checklist re-added under a DIFFERENT bundle name, which both
        // assertions above would miss.
        expect(renderedTags).toEqual(['c-wire-verification']);
    });

    it('🔴 Sale Closes shows the same single card (finished-deal view, still no checklist)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Sale Closes'));
        await Promise.resolve();

        const renderedTags = Array.from(
            element.shadowRoot.querySelectorAll('*')
        ).map((el) => el.tagName.toLowerCase());

        expect(renderedTags).toEqual(['c-wire-verification']);
    });

    it('RETIRED VALUE: the old terminal stage routes NOWHERE', async () => {
        // 'Completed' was removed from Disposition_Stage__c and existing rows
        // migrated off it. This is the falsifier for the isClosing rewrite: if
        // someone re-adds it to the getter "to be safe", this test reds. A test
        // that merely stopped mentioning it would not.
        //
        // ⚠ THE `c-disposition-closing-tasks` ASSERTION THAT USED TO SIT HERE WAS
        // DELETED, NOT KEPT (2026-08-24). That card no longer renders at ANY stage,
        // so asserting its absence at this one became VACUOUSLY GREEN — it would
        // have passed with `isClosing` returning true for 'Completed', which is the
        // single thing this test exists to catch. `c-wire-verification` is now the
        // only observable that distinguishes the two branches.
        const element = createComponent();

        getRecord.emit(recordForStage('Completed'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
        expect(element.shadowRoot.querySelectorAll('*')).toHaveLength(0);
    });

    it('ERROR BRANCH: renders an inline error state and no feature child when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-broker-panel')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('.wire-error')
        ).not.toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 STACK SPACING (2026-08-24) — pinned against the STYLESHEET SOURCE
    //
    // The cards on this page rendered EDGE TO EDGE. The LWC compiler discards
    // whitespace-only text nodes between sibling elements, so nothing separates
    // them by default and nothing in the DOM shows the difference. The fix is a
    // `gap` on :host — the one container every stage's cards are direct children
    // of — and these three tests are its falsifiers.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 :host is a column flex container with a TOKENISED gap — the whole page stack depends on it', () => {
        const host = ruleBody(/:host\s*\{([^}]*)\}/);
        expect(host).not.toBeNull();

        // `gap` only does anything on a flex/grid container. `display: block`
        // (what this rule used to say) silently ignores it, which looks exactly
        // like the bug this change fixes.
        expect(host).toMatch(/display:\s*flex\b/);
        expect(host).toMatch(/flex-direction:\s*column\b/);

        // ⚠ THE TOKEN IS PART OF THE ASSERTION. A raw `gap: 16px` looks identical
        // on the light theme and is unthemeable; SLDS 2 requires the hook.
        // --slds-g-spacing-4 is 1rem, the step this page already uses.
        expect(host).toMatch(/gap:\s*var\(\s*--slds-g-spacing-4\b/);

        // Nothing in the stacking rule may be a raw pixel value outside a token
        // fallback (`var(--hook, 1rem)` is fine — the hook wins when themed).
        expect(host.replace(/var\([^()]*\)/g, 'TOKEN')).not.toMatch(/\d+px/);
    });

    it('🔴 NOTHING doubles up on the gap — .listing-row must not carry a margin', () => {
        // `.listing-row { margin-top: 16px }` predates the :host gap and did the
        // same job back when Active Listing was the only multi-card stage. Left in
        // place it reads 32px between the broker-listing card and the two-up row
        // while every other stage reads 16px. This pin stops it being "restored",
        // and catches the same mistake being made on a newly added card.
        const listingRow = ruleBody(/\.listing-row\s*\{([^}]*)\}/);
        expect(listingRow).not.toBeNull();
        expect(listingRow).not.toMatch(/margin/);
        expect(listingRow).toMatch(/gap:\s*var\(\s*--slds-g-spacing-/);

        // Guard the guard: a stylesheet stripped of tokens would pass the
        // not.toMatch() above vacuously.
        expect((CSS_SOURCE.match(/var\(\s*--slds-/g) || []).length).toBeGreaterThan(3);
    });

    it('🔴 the stage cards really are DIRECT children of :host — which is why ONE gap covers every stage', async () => {
        // :host is only the stacking container because `<template if:true=…>` is
        // not an element. Wrap either card in a plain <div> and the gap applies to
        // the wrapper instead — the cards inside go flush again while every other
        // assertion in this file still passes. This is the DOM half of the fix;
        // the stylesheet half is pinned in the two tests above.
        //
        // 🔴 RETARGETED 2026-08-24 FROM BOV OUTREACH TO ACTIVE LISTING, AND THE
        // REASON IS THE WHOLE POINT OF THE TEST. BOV Outreach used to render TWO
        // sibling cards here and was the natural fixture; it now renders ONE
        // (`c-bov-broker-panel`, which owns the gap between its own two cards in
        // its own stylesheet). A one-child stage cannot falsify a gap rule —
        // there is nothing for the gap to sit between — so the fixture moved to
        // the stage that still has two direct children. Active Listing is now the
        // ONLY multi-card stage in this router.
        const element = createComponent();

        getRecord.emit(recordForStage('Active Listing'));
        await Promise.resolve();

        const topLevel = Array.from(element.shadowRoot.children).map((el) =>
            el.tagName.toLowerCase()
        );

        // Two DIRECT children, in order: the broker-listing card and the two-up
        // row. Wrapping the pair in a <div> collapses this to one entry.
        expect(topLevel).toEqual(['c-broker-listing', 'div']);
    });

    it('🔴 BOV Outreach: the panel is a DIRECT child too — it must not acquire a wrapper', async () => {
        // The single-child stage still needs its own pin: a wrapper <div> added
        // here would move the :host gap off the panel and space it from nothing,
        // and every other assertion in this file would stay green.
        const element = createComponent();

        getRecord.emit(recordForStage('BOV Outreach'));
        await Promise.resolve();

        expect(
            Array.from(element.shadowRoot.children).map((el) =>
                el.tagName.toLowerCase()
            )
        ).toEqual(['c-bov-broker-panel']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
