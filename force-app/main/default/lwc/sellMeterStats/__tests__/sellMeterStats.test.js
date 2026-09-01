/**
 * c-sell-meter-stats — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1) + statCard child assertions.
 *
 * Data source: @wire(getMeterSummary) from SellMeterController.getMeterSummary ->
 * a scalar wrapper { green, yellow, red, upside, sellReadyUpside }. The JS ALWAYS
 * renders every tile, defaulting the three band counts to '0' and both money
 * figures to '$0' — so the card renders before the wire emits.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 FIVE TILES SINCE 2026-08-31, AND THE COUNT IS AN ASSERTION, NOT A DETAIL
 * ─────────────────────────────────────────────────────────────────────────────
 * Story 9's acceptance criteria describe FOUR cards. The user decided at Gate 1
 * (2026-08-31) to keep `Portfolio Upside` as the portfolio-wide number under its
 * existing label and ADD a green-only "Sell-Ready Upside" beside it, rather than
 * narrowing and renaming the existing one. So the divergence from the AC is
 * deliberate and this suite pins it in both directions:
 *   - `Portfolio Upside` is still present, still labelled that, and still carries
 *     the PORTFOLIO-WIDE figure (the rename/narrow that was declined would break
 *     both halves);
 *   - `Sell-Ready Upside` is present and carries a DIFFERENT figure.
 *
 * ⚠ THE FIXTURE'S TWO MONEY VALUES ARE DELIBERATELY UNEQUAL, AND NEITHER IS A
 * ROUND MULTIPLE OF THE OTHER. If they were equal — which is exactly the shape
 * the Apex fixture had before 2026-08-31 — every assertion below would pass
 * against an implementation that wired ONE number into BOTH tiles, which is the
 * single most likely defect in this change.
 */
import { createElement } from 'lwc';
import SellMeterStats from 'c/sellMeterStats';
import getMeterSummary from '@salesforce/apex/SellMeterController.getMeterSummary';

jest.mock(
    '@salesforce/apex/SellMeterController.getMeterSummary',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

/**
 * 🔴 THE MEMBER NAMES ARE THE SERVER'S — `SellMeterController.MeterSummary`
 * declares `green`, `yellow`, `red`, `upside`, `sellReadyUpside`. A Jest fixture
 * DEFINES this payload locally, so it proves the component reads its OWN fixture
 * and never that the fixture matches Apex. Renaming `sellReadyUpside` on the Apex
 * side leaves this file green while the fifth tile renders '$0' forever.
 * Re-check against the Apex, not against a green suite.
 */
const SUMMARY = {
    green: 3,
    yellow: 5,
    red: 2,
    upside: 12500000,
    sellReadyUpside: 4200000
};

describe('c-sell-meter-stats', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-sell-meter-stats', {
            is: SellMeterStats
        });
        document.body.appendChild(element);
        return element;
    }

    function cards(element) {
        return element.shadowRoot.querySelectorAll('c-stat-card');
    }

    it('EMPTY: renders five tiles at their 0 / $0 defaults before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        expect(values).toEqual(['0', '0', '0', '$0', '$0']);
    });

    it('DATA BRANCH: maps band counts and formats BOTH upside figures', async () => {
        const element = createComponent();

        getMeterSummary.emit(SUMMARY);
        await Promise.resolve();

        const summaryCards = cards(element);
        expect(summaryCards.length).toBe(5);

        const values = [...summaryCards].map((c) => c.value);
        expect(values).toEqual(['3', '5', '2', '$12.5M', '$4.2M']);

        const labels = [...summaryCards].map((c) => c.label);
        expect(labels).toEqual([
            'Sell now',
            'Getting Close',
            'Hold - Not yet',
            'Portfolio Upside',
            'Sell-Ready Upside'
        ]);
    });

    /**
     * 🔴 THE FIELD-WIRING FALSIFIER. The two tiles must read DIFFERENT server
     * fields. Without this, the whole suite passes against a component that wires
     * `s.upside` into both — the mistake a copy-pasted array entry makes — because
     * every other assertion checks the pair as a whole array in one shot.
     */
    it('🔴 the two money tiles read DIFFERENT server fields', async () => {
        const element = createComponent();

        // Deliberately lopsided: the green-only subset is a small fraction of the
        // portfolio-wide total, which is the real-world shape (the design estimates
        // the green subset at roughly 20-25% of the whole).
        getMeterSummary.emit({
            green: 1,
            yellow: 4,
            red: 9,
            upside: 40000000,
            sellReadyUpside: 1500000
        });
        await Promise.resolve();

        const byLabel = {};
        [...cards(element)].forEach((c) => {
            byLabel[c.label] = c.value;
        });

        expect(byLabel['Portfolio Upside']).toBe('$40.0M');
        expect(byLabel['Sell-Ready Upside']).toBe('$1.5M');
        expect(byLabel['Portfolio Upside']).not.toBe(byLabel['Sell-Ready Upside']);
    });

    /**
     * 🔴 THE DECLINED-CHANGE PIN. The design recommended RENAMING `Portfolio
     * Upside` to `Sell-Ready Upside` and narrowing its figure to green-only; the
     * user declined that at Gate 1 on 2026-08-31 in favour of adding a fifth tile.
     * This asserts the label still exists AND still carries the portfolio-wide
     * number, so someone "finishing" the recommendation later fails here rather
     * than shipping a headline figure that silently drops ~75-80%.
     */
    it('🔴 Portfolio Upside was NOT renamed and was NOT narrowed to green-only', async () => {
        const element = createComponent();

        getMeterSummary.emit(SUMMARY);
        await Promise.resolve();

        const labels = [...cards(element)].map((c) => c.label);
        expect(labels).toContain('Portfolio Upside');

        const portfolio = [...cards(element)].find(
            (c) => c.label === 'Portfolio Upside'
        );
        // 12.5M is the PORTFOLIO-WIDE figure in the fixture; 4.2M is the green-only
        // one. If the narrowing were applied, this tile would read '$4.2M'.
        expect(portfolio.value).toBe('$12.5M');
        expect(portfolio.value).not.toBe('$4.2M');
    });

    it('DATA BRANCH: formats a sub-million upside in K', async () => {
        const element = createComponent();

        getMeterSummary.emit({
            green: 0,
            yellow: 0,
            red: 0,
            upside: 750000,
            sellReadyUpside: 250000
        });
        await Promise.resolve();

        expect(cards(element)[3].value).toBe('$750K');
        expect(cards(element)[4].value).toBe('$250K');
    });

    /**
     * The fifth tile must default like the fourth when the server field is absent —
     * which is exactly what an older org, a stale LWDS cache, or a not-yet-deployed
     * Apex change delivers. It must read '$0', never 'undefined' or an empty tile.
     */
    it('MISSING FIELD: an absent sellReadyUpside renders $0, not undefined', async () => {
        const element = createComponent();

        getMeterSummary.emit({ green: 1, yellow: 1, red: 1, upside: 9000000 });
        await Promise.resolve();

        const sellReady = [...cards(element)].find(
            (c) => c.label === 'Sell-Ready Upside'
        );
        expect(sellReady).toBeDefined();
        expect(sellReady.value).toBe('$0');
        expect(element.shadowRoot.innerHTML).not.toContain('undefined');
    });

    it('ERROR BRANCH: keeps the default tiles and shows an inline error when the wire errors', async () => {
        const element = createComponent();

        getMeterSummary.error();
        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        expect(values).toEqual(['0', '0', '0', '$0', '$0']);
        // Wire failure surfaces an inline error banner instead of a silent default state.
        expect(element.shadowRoot.querySelector('.sms-error')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getMeterSummary.emit(SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
