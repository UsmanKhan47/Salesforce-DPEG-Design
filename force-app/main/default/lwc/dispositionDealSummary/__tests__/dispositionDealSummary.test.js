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
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE 2026-08-24 SECOND PASS ADDED A SECOND WIRE, AND IT CHANGES HOW EVERY FIXTURE READS
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * The Property row now renders ONLY at `Disposition_Stage__c = 'Closing'`, and the stage arrives on
 * `getRecord`, NOT in the Apex payload. So:
 *   8. 🔴 EMITTING `FULL_SUMMARY` ALONE NO LONGER RENDERS THE PROPERTY ROW. Every test that wants
 *      it must also `getRecord.emit(recordForStage(STAGE_CLOSING))`. That is not test friction to
 *      be worked around — it IS the requirement ("do not render while the stage is unknown"), and
 *      the ~20 tests that emit only the Apex payload are now, for free, twenty proofs that the
 *      row stays hidden until the stage answers.
 *   9. 🔴 EVERY PROPERTY-ROW ABSENCE PIN CARRIES A PRESENCE CONTROL IN THE SAME TEST. Measured on
 *      2026-08-24: deleting the whole row block from the template reds ALL TEN property-row tests.
 *      The previous generation of this suite left one absence pin GREEN AND VACUOUS under exactly
 *      that mutation. If you add an eleventh, give it a control too.
 */
import { createElement } from 'lwc';
import DispositionDealSummary from 'c/dispositionDealSummary';
import { getRecord } from 'lightning/uiRecordApi';
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
const ASSET_RECORD_ID = 'a0P5g00000AssetOneEAG';
const ASSET_NAME = 'Riverbend Plaza';
const DISPOSITION_ID = 'a0D5g000000DispEAG';

/**
 * 🔴 THE STAGE GATE (2026-08-24). The Property row renders at `Closing` and nowhere else, and the
 * stage arrives on a SECOND wire — `getRecord` on `Disposition__c.Disposition_Stage__c` — so a
 * test that emits only the Apex payload now renders NO Property row. That is not an accident of
 * the fixtures: it is the requirement's "do not render while the stage is unknown".
 *
 * ⚠ THE OTHER TEN VALUES ARE LISTED IN FULL, IN MASTER ORDER, AND NOT SAMPLED. They are the entire
 * value set of `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` minus 'Closing'
 * (11 values; On_Market walks all 11, Off_Market 9 of them). A two-stage sample would still pass if
 * someone widened the gate to, say, "PSA or later" — enumerating the set is what makes that fail.
 */
const STAGE_CLOSING = 'Closing';
const OTHER_STAGES = [
    'Disposition Readiness',
    'BOV Outreach',
    'Broker Selection',
    'NDA',
    'Release Materials',
    'Active Listing',
    'Offer Selection',
    'LOI',
    'PSA',
    'Sale Closes'
];

/** The single-field `getRecord` shape `getFieldValue(data, STAGE_FIELD)` reads. */
function recordForStage(stage) {
    return {
        apiName: 'Disposition__c',
        id: DISPOSITION_ID,
        fields: { Disposition_Stage__c: { value: stage } }
    };
}

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
    psaId: null,
    // ⚠ ADDED 2026-08-24 WITH THE PROPERTY ASSET LINK. This constant is documented above as
    // mirroring `DispositionDealSummaryService.DealSummary` FIELD FOR FIELD, and a payload
    // the Apex cannot produce proves nothing — so DTO members and these keys move together.
    propertyAssetId: null,
    propertyAssetName: null
};

/**
 * A mid-flight sale: NDAs signed, an LOI countered, a PSA in its second version.
 * ⚠ IT CARRIES A PROPERTY ASSET SINCE 2026-08-24, so every test using this fixture renders
 * the asset context line. That is deliberate: the overwhelmingly common real state is a sale
 * WITH an asset (the lookup is populated at creation from the Property Asset page), and a
 * default fixture that omitted it would leave the new markup unexercised in 20 tests.
 */
const FULL_SUMMARY = {
    ...EMPTY_SUMMARY,
    propertyAssetId: ASSET_RECORD_ID,
    propertyAssetName: ASSET_NAME,
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

    function createComponent(props = { recordId: DISPOSITION_ID }) {
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

    /**
     * The Property row, or null.
     *
     * ⚠ ONE SELECTOR, USED BY EVERY PROPERTY-ROW TEST — PRESENCE AND ABSENCE ALIKE. If the hook is
     * renamed, every one of them moves together; if the row is DELETED, the presence half of each
     * pin below goes red. That pairing is deliberate: an absence assertion whose feature has been
     * removed passes for the wrong reason, which is exactly what happened when the old asset block
     * was test-deleted on 2026-08-24 (three tests died loudly, the absence pin stayed green).
     */
    function propertyRow(element) {
        return element.shadowRoot.querySelector('[data-asset-line]');
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

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE PROPERTY ROW (2026-08-24) — THE ROW TREATMENT, AT CLOSING ONLY
    // ═════════════════════════════════════════════════════════════════════════
    //
    // TWO REQUIREMENTS LANDED TOGETHER AND THEY FAIL DIFFERENTLY, SO THEY ARE PINNED SEPARATELY:
    //   1. THE TREATMENT. The line used to render as a bare `Property  <name>` sentence above the
    //      rows and read as bolted on. It now reuses the document rows' own composition — icon
    //      chip, bold label, right-aligned pill. A regression here is VISUAL, so the pins are on
    //      rendered class names and rendered structure, never on a getter: a getter-only assertion
    //      has passed in this repo while the rendered attribute was wrong.
    //   2. THE STAGE GATE. The row renders at `Disposition_Stage__c = 'Closing'` and nowhere else.
    //      A regression here is INVISIBLE — a row showing at every stage looks exactly like the
    //      pre-gate build, and a row showing at no stage looks exactly like a sale with no asset.
    //      Nothing on screen would say either was wrong, which is why the gate is enumerated
    //      against the full picklist below rather than sampled.
    //
    // 🔴 EVERY ABSENCE PIN BELOW CARRIES ITS OWN PRESENCE CONTROL, IN THE SAME TEST, ON THE SAME
    // COMPONENT INSTANCE. That is not belt-and-braces — it is the direct fix for the hazard this
    // file recorded on 2026-08-24: deleting the whole asset block left the old absence pin GREEN
    // (`toBeNull()` passes when the feature is gone) while three sibling tests died loudly. Each
    // test here asserts the row IS rendered under one condition and IS NOT under another, so
    // deleting the feature reds all of them and widening the gate reds all of them.

    /**
     * 🔴 THE href COMES FROM `NavigationMixin.GenerateUrl`, NOT FROM A HAND-BUILT STRING, and
     * that is what this asserts: sfdx-lwc-jest's navigation stub resolves GenerateUrl to
     * `https://www.example.com`, a URL no hand-rolled `/lightning/r/...` builder could produce.
     * An implementation that composed its own path would render something else and fail here.
     *
     * ⚠ THE ANCHOR TEXT IS "Property" AND THE NAME IS IN THE PILL — the slot assignment, asserted.
     * On a document row the label is what the row is ABOUT ("NDA") and the pill is its current
     * VALUE; a property's only value is which property it is. Swapping the two would still render
     * both strings and still pass a `textContent`-only check, so both slots are pinned by hook.
     */
    it('ASSET: at Closing, the name is in the pill and the label links via GenerateUrl', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();

        const link = element.shadowRoot.querySelector('a[data-asset-link]');
        expect(link).not.toBeNull();
        expect(link.textContent).toBe('Property');
        expect(link.getAttribute('href')).toBe('https://www.example.com');
        expect(link.getAttribute('title')).toBe(`Open ${ASSET_NAME}`);
        expect(link.dataset.recordId).toBe(ASSET_RECORD_ID);
        expect(textOf(element, '[data-asset-pill]')).toBe(ASSET_NAME);

        // 🔴 CALIBRATES THE ABSENCE PINS BELOW. Two of them assert the WORD "Property" is not in
        // `shadowRoot.textContent`; this proves that instrument can see the word when it is there.
        // (A child component's shadow text does NOT reach a parent's `shadowRoot.textContent` —
        // this row is in this component's own template, so it does.)
        expect(element.shadowRoot.textContent).toContain('Property');
    });

    /**
     * 🔴 THE TREATMENT REQUIREMENT, AS RENDERED CLASS NAMES. The row must not merely LOOK similar
     * — it must be built from the document rows' OWN hooks, so a later change to `.row-head` /
     * `.row-left` / `.row-icon` / `.row-label` / `.pill` moves both together. Asserting the exact
     * `className` (not `toContain`) is what makes a lookalike class fail.
     */
    it('ASSET: wears the document rows composition — chip, bold label, right-aligned pill', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();

        const row = propertyRow(element);
        expect(row).not.toBeNull();
        // 🔴 `.asset-row`, NOT `.row` — it shares the box via a shared declaration block, but it
        //    must not answer to the selector this suite counts document rows with.
        expect(row.className).toBe('asset-row');

        const head = row.querySelector('.row-head');
        expect(head).not.toBeNull();
        const left = head.querySelector('.row-left');
        expect(left).not.toBeNull();

        const chip = left.querySelector('[data-asset-icon]');
        expect(chip.className).toBe('row-icon row-icon_property');
        const icon = chip.querySelector('lightning-icon');
        expect(icon.iconName).toBe('utility:company');
        // Decorative: the visible label carries the meaning (announcing both says it twice).
        expect(icon.alternativeText).toBe('');

        const label = element.shadowRoot.querySelector('[data-asset-label]');
        expect(label.className).toBe('row-label row-label_link');
        expect(left.contains(label)).toBe(true);

        const pill = element.shadowRoot.querySelector('[data-asset-pill]');
        expect(pill.className).toBe('pill pill_neutral pill_asset');
        // The pill is the row head's LAST element — the right-aligned slot, as on a document row.
        expect(head.lastElementChild).toBe(pill);

        // And the document rows still use that same skeleton, which is the whole point of reusing
        // the hooks rather than copying the look.
        const ndaHead = element.shadowRoot.querySelector('[data-row="nda"] .row-head');
        expect(ndaHead.querySelector('.row-left .row-icon')).not.toBeNull();
        expect(ndaHead.lastElementChild.className).toContain('pill');
    });

    /**
     * 🔴 THE PLACEMENT REQUIREMENT, AS AN ASSERTION. The row must come BEFORE the document list in
     * document order, and must not be one of the list's items — the `<ul>` is named "Deal
     * documents" and a property is not one. A comma selector queried once returns nodes in
     * DOCUMENT order, so this reds if the row is moved below the list.
     *
     * ⚠ THE COUNTS ARE THE OTHER HALF. `.row` / `[data-row]` / `[data-pill]` / `[data-icon]` are
     * what ~10 tests in this file use to mean "the three document rows". The property row carries
     * its own hooks precisely so those counts stay 3 and keep meaning what they say — if it ever
     * borrows them, this test says so.
     */
    it('ASSET: sits ABOVE the document list and is not one of its items', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();

        const ordered = Array.from(
            element.shadowRoot.querySelectorAll('.card-sub, [data-asset-line], ul.rows')
        );
        expect(ordered.map((n) => n.tagName)).toEqual(['P', 'DIV', 'UL']);
        expect(ordered[1].dataset.assetLine).toBe('');

        expect(element.shadowRoot.querySelector('ul.rows [data-asset-line]')).toBeNull();
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
        expect(
            Array.from(element.shadowRoot.querySelectorAll('.row')).map((r) => r.dataset.row)
        ).toEqual(['nda', 'loi', 'psa']);
        expect(element.shadowRoot.querySelectorAll('[data-pill]').length).toBe(3);
        expect(element.shadowRoot.querySelectorAll('[data-icon]').length).toBe(3);
    });

    /**
     * 🔴 THE GATE, ENUMERATED AGAINST THE WHOLE PICKLIST. Closing renders the row; each of the
     * other ten does not; then Closing again, so the gate is proven to swing BOTH ways on one
     * instance rather than merely to have been closed once.
     *
     * ⚠ A TWO-STAGE SAMPLE WOULD NOT BE ENOUGH. The plausible regression is a WIDENED gate — "PSA
     * or later", "any stage past LOI", or the constant deleted altogether — and every one of those
     * still passes a test that only checks 'Disposition Readiness'. Ten values cost nothing here.
     */
    it('STAGE GATE: the Property row renders at Closing and at none of the other ten stages', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();
        expect(propertyRow(element)).not.toBeNull();

        /* eslint-disable no-await-in-loop */
        for (const stage of OTHER_STAGES) {
            getRecord.emit(recordForStage(stage));
            await flushPromises();
            expect(propertyRow(element)).toBeNull();
            expect(element.shadowRoot.querySelector('a[data-asset-link]')).toBeNull();
            expect(element.shadowRoot.querySelector('[data-asset-pill]')).toBeNull();
            // The card itself is untouched at every stage — this gate hides ONE row.
            expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
        }
        /* eslint-enable no-await-in-loop */

        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();
        expect(propertyRow(element)).not.toBeNull();
        expect(textOf(element, '[data-asset-pill]')).toBe(ASSET_NAME);
    });

    /**
     * 🔴 "DO NOT FLASH THE ROW IN AND THEN REMOVE IT." The stage arrives on a SECOND wire, so the
     * card's own data lands first and there is a real window in which the asset is known and the
     * stage is not. Nothing may render in that window.
     *
     * ⚠ BOTH CLOCKS ARE CHECKED. A microtask (`Promise.resolve()`) is the first paint after the
     * Apex wire; a macrotask (`flushPromises`) is after `GenerateUrl` settles and re-renders. A
     * "render, then hide" implementation would be green at exactly one of the two.
     */
    it('STAGE GATE: nothing renders while the stage is unknown, on either clock', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        // The card genuinely rendered its data branch — the stage is what is missing, not the data.
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
        expect(propertyRow(element)).toBeNull();

        await flushPromises();
        expect(propertyRow(element)).toBeNull();
        expect(element.shadowRoot.querySelector('a[data-asset-link]')).toBeNull();
        expect(element.shadowRoot.textContent).not.toContain('Property');

        // CONTROL: the same instance renders it the moment the stage answers.
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();
        expect(propertyRow(element)).not.toBeNull();
    });

    /**
     * 🔴 FAIL CLOSED, AND DO NOT ESCALATE. `Disposition__c` is OWD Private: a reader who cannot see
     * the parent cannot read its stage. The honest rendering is no row — not a row at every stage
     * — and NOT a card-level error banner, because the three document rows are unaffected by a
     * stage read and this card renders ungated on all 11 stages.
     */
    it('STAGE GATE: a failed stage read renders no row and no card error', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.error();
        await flushPromises();

        expect(propertyRow(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.error-line')).toBeNull();
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
        expect(textOf(element, '[data-pill="nda"]')).toBe('Signed');

        // CONTROL: recovery is not blocked — a later successful read renders the row.
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();
        expect(propertyRow(element)).not.toBeNull();
    });

    /**
     * 🔴 ABSENT RENDERS NOTHING — NOT A PLACEHOLDER, NOT AN EM-DASH, NOT A DEAD LINK. This is
     * the OPPOSITE of the three document rows, where an empty state ("No LOI on this sale yet")
     * IS the information. `Disposition__c.Property_Asset__c` is an optional Lookup carrying
     * `deleteConstraint = SetNull`, so deleting an asset nulls it on every Disposition that
     * referenced it — this state is reachable in production, not theoretical.
     *
     * ⚠ IT OPENS WITH THE ROW RENDERED AND THEN TAKES THE ASSET AWAY, on one instance and at one
     * stage. The old version of this test emitted only the empty payload, and was measured GREEN
     * AND VACUOUS when the entire asset block was deleted. This shape cannot be: the first half
     * dies the moment the feature does.
     */
    it('ASSET: at Closing, a sale with no Property Asset renders no row at all', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();
        expect(propertyRow(element)).not.toBeNull();

        getDealSummary.emit(EMPTY_SUMMARY);
        await flushPromises();

        expect(propertyRow(element)).toBeNull();
        expect(element.shadowRoot.querySelector('a[data-asset-link]')).toBeNull();
        expect(element.shadowRoot.querySelector('[data-asset-pill]')).toBeNull();
        expect(element.shadowRoot.querySelector('[data-asset-icon]')).toBeNull();
        // Still a working card, and not a placeholder under a different name — the WORD is gone.
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
        expect(element.shadowRoot.textContent).not.toContain('Property');
    });

    /**
     * The degraded shape the server actually produces: `applyParentFields` assigns both members
     * inside its try, so a refused parent read leaves BOTH null. Half-populated is not a state
     * Apex can emit — but the getter requires both anyway, because an Id with no readable name
     * would render a link with no text and a name with no Id has nothing to open.
     */
    it('ASSET: an Id with no name, or a name with no Id, renders nothing rather than a broken link', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();
        expect(propertyRow(element)).not.toBeNull();

        getDealSummary.emit({
            ...FULL_SUMMARY,
            propertyAssetName: null
        });
        await flushPromises();
        expect(propertyRow(element)).toBeNull();
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);

        getDealSummary.emit({
            ...FULL_SUMMARY,
            propertyAssetId: null
        });
        await flushPromises();
        expect(propertyRow(element)).toBeNull();
        expect(element.shadowRoot.querySelectorAll('.row').length).toBe(3);
    });

    /**
     * 🔴 THE href IS NEVER THE LITERAL STRING "undefined", here as on the rows. `GenerateUrl`
     * returns a Promise, so for one tick there is an asset and no URL. The row still renders —
     * the NAME is real context and suppressing it would make the card flicker — with the label as
     * a muted SPAN, never as a bare `<a>` pointing at a 404 relative path.
     */
    it('ASSET: renders the label as plain text until the generated URL resolves', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await Promise.resolve(); // one microtask: both wires landed, GenerateUrl has not

        expect(element.shadowRoot.querySelector('a[data-asset-link]')).toBeNull();
        const label = element.shadowRoot.querySelector('[data-asset-label]');
        expect(label).not.toBeNull();
        expect(label.tagName).toBe('SPAN');
        expect(label.className).toBe('row-label row-label_muted');
        expect(label.textContent).toBe('Property');
        // The name is context, not a link affordance — it renders on the first paint either way.
        expect(textOf(element, '[data-asset-pill]')).toBe(ASSET_NAME);
        expect(element.shadowRoot.innerHTML).not.toContain('undefined');
    });

    /**
     * 🔴 SOURCE-TEXT FENCE ON THE SHARED BOX. `.asset-row` and `.row` share ONE declaration block
     * so the Property row cannot drift from a document row; splitting them into two blocks is the
     * drift. jsdom does no layout, so this is unmeasurable at runtime — `getComputedStyle().gap`
     * is empty and `scrollWidth` is 0 — which is why it is asserted against the stylesheet, exactly
     * like the `.row-head` wrap fence above.
     *
     * ⚠ THE PILL NEEDS A TRUNCATION DEFENCE THE DOCUMENT PILLS DO NOT. Their contents are bounded
     * picklist values (13 characters at worst); an asset NAME is unbounded free text, and `.pill`
     * is `white-space: nowrap`, so in the ~340px sidebar a long one would burst the column.
     * `display: inline-block` is part of the fix, not a style choice — `text-overflow` does nothing
     * to a flex container's anonymous text item, so dropping it silently disables the ellipsis.
     */
    it('NARROW COLUMN: the property row shares the row box and its pill can truncate', () => {
        const shared = CSS_SOURCE.match(/\.row,\s*\.asset-row\s*\{[^}]*\}/);
        expect(shared).not.toBeNull();
        expect(shared[0]).toMatch(/padding:/);
        expect(shared[0]).toMatch(/border-bottom:/);

        const assetPill = CSS_SOURCE.match(/\.pill_asset\s*\{[^}]*\}/);
        expect(assetPill).not.toBeNull();
        expect(assetPill[0]).toMatch(/display:\s*inline-block/);
        // ⚠ `min-width: 0`, NOT `max-width: 100%` — a flex item will not shrink below its content
        //    until the automatic minimum size is released, AND the SLDS linter rejects a bare `%`
        //    under `slds/no-hardcoded-values-slds2` (measured: it took this bundle off zero).
        expect(assetPill[0]).toMatch(/min-width:\s*0/);
        expect(assetPill[0]).toMatch(/overflow:\s*hidden/);
        expect(assetPill[0]).toMatch(/text-overflow:\s*ellipsis/);

        // 🔴 THE SEPARATION BETWEEN CHIP, LABEL AND PILL IS THE SHARED FLEX `gap`. The LWC compiler
        //    DROPS the whitespace between two sibling inline elements, so without it the row reads
        //    "PropertyRiverbend Plaza". `&nbsp;` works and is worse — invisible in review, and it
        //    survives into `textContent` where it silently breaks string assertions.
        const rowLeft = CSS_SOURCE.match(/\.row-left\s*\{[^}]*\}/);
        expect(rowLeft[0]).toMatch(/gap:/);
        expect(HTML_SOURCE).not.toContain('&nbsp;');
    });

    it('is accessible with the Property row and the asset link resolved', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        getRecord.emit(recordForStage(STAGE_CLOSING));
        await flushPromises();

        expect(propertyRow(element)).not.toBeNull();
        await expect(element).toBeAccessible();
    });

    it('is accessible when empty', async () => {
        const element = createComponent();

        getDealSummary.emit(EMPTY_SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
