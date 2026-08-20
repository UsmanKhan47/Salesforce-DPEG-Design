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
 */
import { createElement } from 'lwc';
import DispositionDealSummary from 'c/dispositionDealSummary';
import getDealSummary from '@salesforce/apex/DispositionDealSummaryController.getDealSummary';

jest.mock(
    '@salesforce/apex/DispositionDealSummaryController.getDealSummary',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

/** Every member the Apex DTO declares, in its "nothing exists yet" state. */
const EMPTY_SUMMARY = {
    ndaCount: null,
    ndaSignedCount: null,
    ndaCountsUnavailable: false,
    ndaStatus: null,
    ndaSignedDate: null,
    hasNda: false,
    ndaUnavailable: false,
    loiStage: null,
    loiOfferPrice: null,
    loiBallInCourt: null,
    hasLoi: false,
    loiUnavailable: false,
    psaStatus: null,
    psaExecutionDate: null,
    psaLatestVersion: null,
    hasPsa: false,
    psaUnavailable: false
};

/** A mid-flight sale: NDAs signed, an LOI countered, a PSA in its second version. */
const FULL_SUMMARY = {
    ...EMPTY_SUMMARY,
    ndaCount: 4,
    ndaSignedCount: 3,
    ndaStatus: 'Signed',
    ndaSignedDate: '2026-03-14',
    hasNda: true,
    loiStage: 'Countered by DPEG',
    loiOfferPrice: 9800000,
    loiBallInCourt: 'Buyer',
    hasLoi: true,
    psaStatus: 'Ready for Execution',
    psaExecutionDate: null,
    psaLatestVersion: 2,
    hasPsa: true
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

        expect(textOf(element, '[data-pill="loi"]')).toBe('Countered by DPEG');
        expect(textOf(element, '[data-meta="loi-price"]')).toBe('$9.8M');
        expect(textOf(element, '[data-meta="loi-court"]')).toBe('Ball in court: Buyer');
    });

    it('DATA BRANCH: the PSA row shows the negotiation status and the maintained version', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        expect(textOf(element, '[data-pill="psa"]')).toBe('Ready for Execution');
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
        expect(textOf(element, '[data-pill="psa"]')).toBe('Ready for Execution');
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

    it('is accessible with data', async () => {
        const element = createComponent();

        getDealSummary.emit(FULL_SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible when empty', async () => {
        const element = createComponent();

        getDealSummary.emit(EMPTY_SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
