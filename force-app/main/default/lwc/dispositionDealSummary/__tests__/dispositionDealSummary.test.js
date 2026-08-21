/**
 * WIRE-MOCK TEMPLATE — @wire to APEX (parameterised), matching the c-bov-outreach suite.
 * Single data source: @wire(getDealSummary, { dispositionId: '$recordId' }).
 *
 * ⚠ THE PAYLOAD SHAPES BELOW MIRROR `DispositionDealSummaryService.DealSummary` FIELD FOR FIELD.
 * They are not hand-invented conveniences — a test that emits a shape Apex cannot produce proves
 * nothing about the component. If the DTO gains or loses a member, these constants move with it.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * THE THREE CASES THAT CARRY THE DESIGN
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * 1. 🔴 EMPTY — a sale with no NDA, no LOI and no PSA. This is the state of most dispositions for
 *    most of their life, and the card is UNGATED across all 11 stages, so the empty rendering is
 *    the one users will see most often. It must be three calm rows, never an error.
 * 2. 🔴 PARTIAL FAILURE — one row's read failed while the other two succeeded. This is the entire
 *    point of the service's per-read try/catch: a permission gap on one object must degrade ONE
 *    line, not blank the card. The assertion deliberately checks that the OTHER two rows still
 *    render their real values.
 * 3. 🔴 A DEGRADED ROW IS NOT AN EMPTY ROW. `c/bovOutreach` collapses the two on purpose; design
 *    §0 C-1 found that collapse had been hiding a live provisioning gap on the BOV NDA pill for
 *    months ("No NDA" forever, nothing on screen suggesting a permissions problem). This card
 *    keeps them distinct, so a test asserts the two render differently. If someone "simplifies"
 *    the unavailable flags away, this goes red.
 *
 * NULL COUNTERS: `NDA_Count__c` / `Signed_NDA_Count__c` are null — not 0 — on any Disposition that
 * predates the NDA_Signed_Rollup flow, and Apex passes that null through untouched. The client is
 * the only place the coalescing happens, so "null of null signed" is a real regression this suite
 * fences.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE 2026-08-21 RESTYLE ADDED FOUR MORE FENCES, AND NOT ONE OF THEM CHANGED AN ASSERTION
 * ABOVE. The card was restyled to match `c/dealDocStatus` (lightning-card, icon chips,
 * click-through labels, soft-tint pills). Every behavioural test in this file predates that work
 * and still passes untouched — the markup gained elements, it did not move the ones these
 * assertions are anchored to (`.row`, `[data-row]`, `[data-pill]`, `[data-meta]`, `[data-hint]`,
 * `.error-line`). The new fences are:
 *   4. 🔴 ONLY A ROW WITH A RECORD LINKS. An empty row and a DEGRADED row both render a muted,
 *      unlinked span — and the degraded case is asserted with an Id DELIBERATELY PLANTED IN THE
 *      PAYLOAD, because the Apex contract that it is always null is a second line of defence, not
 *      the client's excuse to skip the check.
 *   5. 🔴 THE THIRD STATE HAS THREE VISUAL AXES, NOT ONE. `dealDocStatus` has two row states;
 *      this card has three, and a single differing pill word is too easy to lose in a later
 *      restyle. The chip class and the hint class are asserted alongside the pill text.
 *   6. 🔴 NO INLINE `style`, NO AUTHORED HEX. `dealDocStatus` colours its icons with inline
 *      `style="--slds-c-icon-color-foreground-default:#2E86DE"` and hard-codes every pill colour.
 *      A SOURCE-TEXT assertion fences that, because the SLDS linter is a separate command a
 *      reviewer can forget to run and Jest is not.
 *   7. 🔴 THE ~340px SIDEBAR LAYOUT. `flex-wrap: wrap` on `.row-head` is what stops a
 *      27-character pill bursting the column. Source-text again — jsdom does no layout, so
 *      `scrollWidth`/`clientWidth` are both 0 and the obvious measurement assertion is vacuous.
 */
import { createElement } from 'lwc';
import DispositionDealSummary from 'c/dispositionDealSummary';
import getDealSummary from '@salesforce/apex/DispositionDealSummaryController.getDealSummary';

/*
 * ⚠ `require`, NOT `import { readFileSync } from 'fs'`. The LWC compiler processes every module
 * under `lwc/` and rejects a bare ESM import of a Node builtin with `LWC1702`, which surfaces as
 * an editor error with an empty message and no obvious cause. Every other source-text assertion
 * in this repo (`competingBrokerSubmissions`, `dispositionBuyerTimeline`, `bovBrokerChangeHistory`)
 * uses `require` for exactly this reason.
 *
 * Comments are stripped FIRST so the source files can name banned values in plain prose — the
 * stylesheet's own header discusses `#2E86DE` and inline `style`, and an unstripped read would
 * fail the very assertions those comments explain.
 */
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'dispositionDealSummary.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

const HTML_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'dispositionDealSummary.html'),
        'utf8'
    )
    .replace(/<!--[\s\S]*?-->/g, '');

jest.mock(
    '@salesforce/apex/DispositionDealSummaryController.getDealSummary',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const NDA_RECORD_ID = 'a0N5g00000NdaOneEAG';
const LOI_RECORD_ID = 'a0L5g00000LoiOneEAG';
const PSA_RECORD_ID = 'a0C5g00000PsaOneEAG';

/**
 * Every member the Apex DTO declares, in its "nothing exists yet" state.
 * ⚠ `ndaId` / `loiId` / `psaId` were added to `DealSummary` on 2026-08-21 to back the card's
 * click-through links, so they are here too — this constant is documented above as mirroring the
 * DTO field for field, and a payload the Apex cannot produce proves nothing.
 */
const EMPTY_SUMMARY = {
    ndaCount: null,
    ndaSignedCount: null,
    ndaCountsUnavailable: false,
    ndaStatus: null,
    ndaSignedDate: null,
    hasNda: false,
    ndaUnavailable: false,
    ndaId: null,
    loiStage: null,
    loiOfferPrice: null,
    loiBallInCourt: null,
    hasLoi: false,
    loiUnavailable: false,
    loiId: null,
    psaStatus: null,
    psaExecutionDate: null,
    psaLatestVersion: null,
    hasPsa: false,
    psaUnavailable: false,
    psaId: null
};

/** A mid-flight sale: NDAs signed, an LOI countered, a PSA in its second version. */
const FULL_SUMMARY = {
    ...EMPTY_SUMMARY,
    ndaCount: 4,
    ndaSignedCount: 3,
    ndaStatus: 'Signed',
    ndaSignedDate: '2026-03-14',
    hasNda: true,
    ndaId: NDA_RECORD_ID,
    // ⚠ REPOINTED 2026-08-21 from 'Countered by DPEG'. That value was removed from the
    // Disposition_LOI record type when the user replaced the sell-side sequence with
    // Received -> Under Review -> Negotiation -> Signed, so no disposition LOI can carry it.
    // 🔴 THIS FIXTURE WAS GREEN BEFORE AND WOULD HAVE STAYED GREEN AFTER. It is a JS literal fed
    // to a mocked wire adapter — nothing here is ever validated against the org's picklist, so a
    // dead value survives indefinitely and quietly turns this test into a demonstration that the
    // component renders a state production cannot produce. Repointed for that reason, not because
    // anything failed.
    loiStage: 'Negotiation',
    loiOfferPrice: 9800000,
    loiBallInCourt: 'Buyer',
    hasLoi: true,
    loiId: LOI_RECORD_ID,
    // ⚠ REPOINTED 2026-08-21 from 'Ready for Execution'. The user removed that value (and
    // 'Revised' and 'Executed') from the Disposition_PSA record type; its sequence is now
    // Initial Draft -> Negotiation -> Signed. Same stale-JS-literal trap as loiStage above: this
    // fixture never touches the org's picklist, so the dead value would have stayed green forever.
    // 🔴 'Negotiation' AND NOT 'Signed', DELIBERATELY. 'Signed' is the sell-side TERMINAL now, and
    // this fixture pairs psaStatus with psaExecutionDate: null — a combination that would be
    // self-contradictory at the terminal and would make the "no psa-date line" assertion below read
    // as a bug rather than as the mid-negotiation state it is testing.
    psaStatus: 'Negotiation',
    psaExecutionDate: null,
    psaLatestVersion: 2,
    hasPsa: true,
    psaId: PSA_RECORD_ID
};

describe('c-disposition-deal-summary', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-disposition-deal-summary', {
            is: DispositionDealSummary
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function textOf(element, selector) {
        const node = element.shadowRoot.querySelector(selector);
        return node === null ? null : node.textContent;
    }

    /**
     * ⚠ A SINGLE `await Promise.resolve()` IS NOT ENOUGH FOR THE LINK TESTS, AND THAT IS WHY THIS
     * EXISTS. The row labels only become anchors once `NavigationMixin.GenerateUrl`'s Promise
     * settles and the resulting re-render lands — two hops past the wire emission. A macrotask
     * turn covers both. Every test above deliberately keeps its single-microtask await, which is
     * how they still assert the pre-link rendering unchanged.
     */
    function flushPromises() {
        return new Promise((r) => setTimeout(r, 0));
    }

    it('renders no rows until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.error-line')).toBeNull();
    });

    it('DATA BRANCH: renders exactly three rows, in deal order', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.row');
        expect(rows.length).toBe(3);
        expect(rows[0].dataset.row).toBe('nda');
        expect(rows[1].dataset.row).toBe('loi');
        expect(rows[2].dataset.row).toBe('psa');
    });

    it('DATA BRANCH: the NDA row shows the status, the signed-of-total count and the signed date', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        expect(textOf(element, '[data-pill="nda"]')).toBe('Signed');
        expect(textOf(element, '[data-meta="nda-counts"]')).toBe('3 of 4 signed');
        expect(textOf(element, '[data-meta="nda-date"]')).toBe('Signed Mar 14, 2026');
    });

    it('DATA BRANCH: the LOI row shows the disposition stage, price and ball-in-court', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        // ⚠ REPOINTED 2026-08-21 with FULL_SUMMARY.loiStage — see the fixture's own note.
        expect(textOf(element, '[data-pill="loi"]')).toBe('Negotiation');
        expect(textOf(element, '[data-meta="loi-price"]')).toBe('$9.8M');
        expect(textOf(element, '[data-meta="loi-court"]')).toBe('Ball in court: Buyer');
    });

    it('DATA BRANCH: the PSA row shows the negotiation status and the maintained version', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        expect(textOf(element, '[data-pill="psa"]')).toBe('Negotiation');
        expect(textOf(element, '[data-meta="psa-version"]')).toBe('Version 2');
        // Execution_Date__c is null until the PSA is executed — the line is absent, not an em-dash.
        expect(element.shadowRoot.querySelector('[data-meta="psa-date"]')).toBeNull();
    });

    /**
     * 🔴 THE EXCLUSION FENCE. `LOI_Status__c` (always 'Draft' on a sale) and `LOI_Signed_Date__c`
     * (structurally always blank on a sale) are excluded by design §0 C-10 / C-11. If someone
     * "fixes the omission" by wiring either into the LOI row, this goes red and sends them to the
     * component header.
     */
    it('LOI ROW: never renders LOI_Status__c or a signed date, even when the payload carries them', async () => {
        const element = createComponent();

        getDealSummary.emit({
            ...FULL_SUMMARY,
            loiStatus: 'Draft',
            loiSignedDate: '2026-04-01'
        });
        await Promise.resolve();

        const loiRow = element.shadowRoot.querySelector('[data-row="loi"]');
        expect(loiRow.textContent).not.toContain('Draft');
        expect(loiRow.textContent).not.toContain('Apr 1, 2026');
    });

    /**
     * 🔴 EMPTY STATE. A sale with no NDA, no LOI and no PSA — the commonest state of the commonest
     * card in the module. Three rows, plain-language hints, no error, no spinner.
     */
    it('EMPTY STATE: a sale with no NDA, LOI or PSA renders three empty rows and no error', async () => {
        const element = createComponent();

        getDealSummary.emit(EMPTY_SUMMARY);
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
        expect(element.shadowRoot.querySelector('.error-line')).toBeNull();

        expect(textOf(element, '[data-pill="nda"]')).toBe('No NDA');
        expect(textOf(element, '[data-pill="loi"]')).toBe('No LOI');
        expect(textOf(element, '[data-pill="psa"]')).toBe('No PSA');

        expect(textOf(element, '[data-hint="nda"]')).toBe('No NDA on this sale yet');
        expect(textOf(element, '[data-hint="loi"]')).toBe('No LOI on this sale yet');
        expect(textOf(element, '[data-hint="psa"]')).toBe('No PSA on this sale yet');

        // No meta lines at all on an empty card — including no counter line, which would
        // otherwise assert "0 of 0 signed" about a sale that has never been counted.
        expect(element.shadowRoot.querySelectorAll('.row-meta').length).toBe(0);
    });

    /**
     * 🔴 THE PARTIAL-FAILURE FENCE — the single most important test in this file. One failed read
     * degrades ONE row; the other two keep their real values and the card keeps rendering.
     */
    it('PARTIAL FAILURE: a failed LOI read degrades only the LOI row', async () => {
        const element = createComponent();

        getDealSummary.emit({
            ...FULL_SUMMARY,
            loiUnavailable: true,
            loiStage: null,
            loiOfferPrice: null,
            loiBallInCourt: null,
            hasLoi: false
        });
        await Promise.resolve();

        // The card is intact.
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
        expect(element.shadowRoot.querySelector('.error-line')).toBeNull();

        // The LOI row is degraded, and says so.
        expect(textOf(element, '[data-pill="loi"]')).toBe('Unavailable');
        expect(textOf(element, '[data-hint="loi"]')).toContain('permissions');

        // 🔴 The other two rows are untouched — this is the assertion that fails if someone folds
        // the per-read catches back into one outer catch.
        expect(textOf(element, '[data-pill="nda"]')).toBe('Signed');
        expect(textOf(element, '[data-meta="nda-counts"]')).toBe('3 of 4 signed');
        expect(textOf(element, '[data-pill="psa"]')).toBe('Negotiation');
    });

    /**
     * 🔴 A DEGRADED ROW MUST NOT IMPERSONATE AN EMPTY ONE. Design §0 C-1: the BOV pill's
     * indistinguishable version hid a real provisioning gap for months.
     */
    it('PARTIAL FAILURE: a degraded row is rendered differently from an empty one', async () => {
        const element = createComponent();

        getDealSummary.emit({ ...EMPTY_SUMMARY, ndaUnavailable: true });
        await Promise.resolve();

        // NDA read failed; LOI genuinely has nothing.
        expect(textOf(element, '[data-pill="nda"]')).toBe('Unavailable');
        expect(textOf(element, '[data-pill="nda"]')).not.toBe('No NDA');
        expect(textOf(element, '[data-hint="nda"]')).not.toBe('No NDA on this sale yet');
        expect(
            element.shadowRoot.querySelector('[data-hint="nda"]').className
        ).toContain('row-hint_alert');

        expect(textOf(element, '[data-pill="loi"]')).toBe('No LOI');
        expect(
            element.shadowRoot.querySelector('[data-hint="loi"]').className
        ).not.toContain('row-hint_alert');
    });

    /**
     * The counter read is caught separately from the NDA row's own read, because the two live on
     * different objects with independent FLS. A readable status must survive an unreadable
     * counter.
     */
    it('PARTIAL FAILURE: an unreadable counter suppresses only the count line, not the NDA status', async () => {
        const element = createComponent();

        getDealSummary.emit({
            ...FULL_SUMMARY,
            ndaCountsUnavailable: true,
            ndaCount: null,
            ndaSignedCount: null
        });
        await Promise.resolve();

        expect(textOf(element, '[data-pill="nda"]')).toBe('Signed');
        expect(textOf(element, '[data-meta="nda-counts"]')).toBe('NDA counts unavailable');
        expect(textOf(element, '[data-meta="nda-date"]')).toBe('Signed Mar 14, 2026');
    });

    /**
     * 🔴 NULL COUNTERS ARE NOT ZERO ON THE WIRE. Pre-rollup rows hold null in both fields and Apex
     * passes them through raw; this component is the only place they are coalesced. Without the
     * `?? 0` this renders "null of null signed".
     */
    it('NULL COUNTERS: a signed NDA whose counters were never rolled up renders "0 of 0 signed"', async () => {
        const element = createComponent();

        getDealSummary.emit({
            ...FULL_SUMMARY,
            ndaCount: null,
            ndaSignedCount: null
        });
        await Promise.resolve();

        const counts = textOf(element, '[data-meta="nda-counts"]');
        expect(counts).toBe('0 of 0 signed');
        expect(counts).not.toContain('null');
        expect(counts).not.toContain('undefined');
    });

    it('TONES: an unmapped status still renders its own text, on the neutral style', async () => {
        const element = createComponent();

        getDealSummary.emit({ ...FULL_SUMMARY, ndaStatus: 'Some New Value' });
        await Promise.resolve();

        const pill = element.shadowRoot.querySelector('[data-pill="nda"]');
        expect(pill.textContent).toBe('Some New Value');
        expect(pill.className).toBe('pill pill_neutral');
    });

    it('ERROR BRANCH: a wire error renders one card-level message and no rows', async () => {
        const element = createComponent();

        getDealSummary.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(0);
        expect(textOf(element, '.error-line')).toBe("Couldn't load the deal summary.");
    });

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE 2026-08-21 RESTYLE — matching c/dealDocStatus WITHOUT losing the third row state
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * The borrowed chrome: a `lightning-card` with the `standard:document` icon, which is what
     * makes this card read as the Opportunity page's `c/dealDocStatus` at a glance. The
     * hand-rolled `.card` / `.card-header` wrapper it replaced must be gone, not merely hidden.
     */
    it('CHROME: renders inside a lightning-card with the standard:document icon', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        const card = element.shadowRoot.querySelector('lightning-card');
        expect(card).not.toBeNull();
        expect(card.iconName).toBe('standard:document');
        expect(element.shadowRoot.querySelector('.card-header')).toBeNull();
        expect(textOf(element, '.card-title')).toBe('Deal Summary');
    });

    /**
     * 🔴 THE LINK IS A REAL ANCHOR WITH A REAL `href`. `c/dealDocStatus` uses
     * `<a class="doc-name" onclick={openNda}>` with NO href, which is not keyboard-focusable and
     * is not announced as a link. The in-repo accessible precedent (`c/bovComparisonMatrix`'s
     * "View All") generates the href from `NavigationMixin.GenerateUrl`; the sfdx-lwc-jest stub
     * resolves that to `https://www.example.com`, so the assertion is on the href being POPULATED
     * from the generator rather than on a particular URL string.
     */
    it('LINK: a row with a record renders its label as a focusable anchor with an href', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await flushPromises();

        const link = element.shadowRoot.querySelector('a[data-label="nda"]');
        expect(link).not.toBeNull();
        expect(link.textContent).toBe('NDA');
        expect(link.getAttribute('href')).toBe('https://www.example.com');
        expect(link.getAttribute('title')).toBe('Open NDA');
        expect(link.dataset.recordId).toBe(NDA_RECORD_ID);

        // All three rows link when all three have records.
        expect(element.shadowRoot.querySelectorAll('a[data-label]').length).toBe(3);
    });

    /**
     * 🔴 THE href IS NEVER THE LITERAL STRING "undefined". A getter bound to an element's
     * attribute is written UNCONDITIONALLY, so returning `undefined` from `recordUrl` would
     * render `href="undefined"` — a link that navigates to a 404 relative path. Before the
     * GenerateUrl promise settles there must be NO anchor at all, not an empty one.
     */
    it('LINK: no anchor exists before the generated URL resolves', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('a[data-label]').length).toBe(0);
        expect(element.shadowRoot.querySelector('[data-label="nda"]').className)
            .toContain('row-label_muted');
        expect(element.shadowRoot.innerHTML).not.toContain('undefined');
    });

    /** An empty row has nothing to open, so its label stays a muted span forever. */
    it('LINK: an EMPTY row never becomes a link', async () => {
        const element = createComponent();

        getDealSummary.emit(EMPTY_SUMMARY);
        await flushPromises();

        expect(element.shadowRoot.querySelectorAll('a[data-label]').length).toBe(0);
        ['nda', 'loi', 'psa'].forEach((key) => {
            expect(
                element.shadowRoot.querySelector(`[data-label="${key}"]`).className
            ).toContain('row-label_muted');
        });
    });

    /**
     * 🔴 THE SHARPEST OF THE NEW FENCES. A DEGRADED row must not offer a link to a record the
     * reader was just refused — and the Id is PLANTED IN THE PAYLOAD here on purpose. Apex's
     * contract is that a failed read leaves the Id null (it is assigned inside the try, after the
     * selector returns), but that is a SECOND line of defence, not a reason for the client to
     * skip the check: `buildRow`'s `unavailable > exists > empty` precedence is what actually
     * guarantees this, and this test is what fails if someone reorders it.
     */
    it('LINK: a DEGRADED row never links, even when the payload carries an Id', async () => {
        const element = createComponent();

        getDealSummary.emit({
            ...FULL_SUMMARY,
            loiUnavailable: true,
            hasLoi: false,
            loiId: LOI_RECORD_ID
        });
        await flushPromises();

        expect(element.shadowRoot.querySelector('a[data-label="loi"]')).toBeNull();
        expect(
            element.shadowRoot.querySelector('[data-label="loi"]').className
        ).toContain('row-label_muted');
        expect(textOf(element, '[data-pill="loi"]')).toBe('Unavailable');

        // The other two rows are unaffected — the degrade is still per row.
        expect(element.shadowRoot.querySelector('a[data-label="nda"]')).not.toBeNull();
        expect(element.shadowRoot.querySelector('a[data-label="psa"]')).not.toBeNull();
    });

    /**
     * 🔴 THE THIRD STATE IS DIFFERENTIATED ON THREE AXES, NOT ONE. `c/dealDocStatus` has two row
     * states; this card has three, and "Unavailable" being one more word in a pill is too easy to
     * lose in a future restyle. The pill stays SOLID while every other pill is a soft tint, the
     * icon chip goes error-toned, and the hint goes non-italic/semibold. This asserts all three at
     * once against a genuinely EMPTY row in the same render, so the contrast — not just the
     * presence — is what is pinned.
     */
    it('THREE STATES: a degraded row differs from an empty row on pill, chip AND hint', async () => {
        const element = createComponent();

        getDealSummary.emit({ ...EMPTY_SUMMARY, ndaUnavailable: true });
        await flushPromises();

        // Axis 1 — the pill.
        expect(element.shadowRoot.querySelector('[data-pill="nda"]').className)
            .toContain('pill_blocked');
        expect(element.shadowRoot.querySelector('[data-pill="loi"]').className)
            .toContain('pill_neutral');

        // Axis 2 — the icon chip.
        expect(element.shadowRoot.querySelector('[data-icon="nda"]').className)
            .toContain('row-icon_blocked');
        expect(element.shadowRoot.querySelector('[data-icon="loi"]').className)
            .toContain('row-icon_loi');
        expect(element.shadowRoot.querySelector('[data-icon="loi"]').className)
            .not.toContain('row-icon_blocked');

        // Axis 3 — the hint.
        expect(element.shadowRoot.querySelector('[data-hint="nda"]').className)
            .toContain('row-hint_alert');
        expect(element.shadowRoot.querySelector('[data-hint="loi"]').className)
            .not.toContain('row-hint_alert');
    });

    /** A populated row keeps its document-type chip; the chip identifies the row, not its state. */
    it('THREE STATES: a populated row keeps its per-type icon chip', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await flushPromises();

        expect(element.shadowRoot.querySelector('[data-icon="nda"]').className)
            .toBe('row-icon row-icon_nda');
        expect(element.shadowRoot.querySelector('[data-icon="loi"]').className)
            .toBe('row-icon row-icon_loi');
        expect(element.shadowRoot.querySelector('[data-icon="psa"]').className)
            .toBe('row-icon row-icon_psa');
    });

    /**
     * 🔴 SOURCE-TEXT FENCE ON THE STYLING RULE. `c/dealDocStatus` colours its icons with
     * `style="--slds-c-icon-color-foreground-default:#2E86DE"` on the element and hard-codes every
     * pill colour (`background: #e6f4ea`, `box-shadow: inset 0 0 0 1px #b6e0c6`). Copying any of
     * that is the single most likely way this restyle gets "finished" by a later hand, and it
     * would take the bundle from zero SLDS violations to a dozen. The linter catches it — but the
     * linter is a separate command a reviewer can forget, and Jest is not.
     */
    it('STYLING: no inline style attribute in the template, and no authored colour in the CSS', () => {
        expect(HTML_SOURCE).not.toMatch(/\sstyle\s*=/);

        // Every colour-bearing declaration must resolve through an SLDS 2 global hook. A literal
        // like `#e6f4ea` or `rgba(46,134,222,0.13)` fails; `var(--slds-g-…, #ebf7e6)` passes,
        // because there the literal is the linter-generated fallback, not the authored value.
        const colourDecls = CSS_SOURCE.match(
            /(?:^|[\s;{])(?:background|color|box-shadow)\s*:\s*[^;]+;/g
        );
        expect(colourDecls).not.toBeNull();
        colourDecls.forEach((decl) => {
            const value = decl.slice(decl.indexOf(':') + 1).trim();
            expect(value.startsWith('var(--slds-') || value.startsWith('inset 0 0 0 var(--slds-'))
                .toBe(true);
        });
    });

    /**
     * 🔴 SOURCE-TEXT FENCE ON THE ~340px SIDEBAR LAYOUT. This card sits in the record page's
     * narrow sidebar, not the wide main column `c/dealDocStatus` occupies. `flex-wrap: wrap` on
     * `.row-head` is what lets a long pill drop to its own line instead of bursting the column,
     * and `min-width: 0` on `.row-left` is what lets the label shrink at all.
     * ⚠ 2026-08-21: this used to say "a 27-character pill (`Counter Received from Buyer`)". That
     * value was removed from the Disposition_LOI record type — and in the same day's second wave
     * `Ready for Execution` (19) went off Disposition_PSA too, so the longest string a sell-side
     * row can normally render dropped again, to `Initial Draft` / `Under Review` (13 and 12).
     * THE ASSERTIONS BELOW ARE UNCHANGED and the CSS rules must stay: both retired values are still
     * ACTIVE on their master value sets and still mapped in LOI_TONE / PSA_TONE, so a data load can
     * still render them, and the margin was always thin. See the matching note in
     * dispositionDealSummary.css.
     * ⚠ This is a SOURCE assertion rather than a measurement on purpose: jsdom does no layout, so
     * `scrollWidth` and `clientWidth` are both 0 and `expect(scrollWidth).toBeLessThanOrEqual(
     * clientWidth)` is `0 <= 0` — green whether or not the component overflows.
     */
    it('NARROW COLUMN: the row head wraps and nothing restores a horizontal scrollbar', () => {
        const rowHead = CSS_SOURCE.match(/\.row-head\s*\{[^}]*\}/);
        expect(rowHead).not.toBeNull();
        expect(rowHead[0]).toMatch(/flex-wrap:\s*wrap/);

        const rowLeft = CSS_SOURCE.match(/\.row-left\s*\{[^}]*\}/);
        expect(rowLeft).not.toBeNull();
        expect(rowLeft[0]).toMatch(/min-width:\s*0/);

        // A scroll container would hide the overflow instead of fixing it.
        expect(CSS_SOURCE).not.toMatch(/overflow(-x)?\s*:\s*(auto|scroll)/);
    });

    it('is accessible with data', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    /** The linked rendering is a different DOM from the muted one, so it gets its own a11y pass. */
    it('is accessible once the row labels have become links', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await flushPromises();

        expect(element.shadowRoot.querySelectorAll('a[data-label]').length).toBe(3);
        await expect(element).toBeAccessible();
    });

    it('is accessible when empty', async () => {
        const element = createComponent();

        getDealSummary.emit(EMPTY_SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
