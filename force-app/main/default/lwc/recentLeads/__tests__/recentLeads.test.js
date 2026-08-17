/**
 * c-recent-leads — @wire-to-Apex suite WITH NavigationMixin.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1) + the lwc-recipes
 * navigation mock (matches c-broker-scorecard).
 *
 * Data source: @wire(getFunnel) from LeadFunnelController.getFunnel. The JS reads
 * `data.recent` and feeds the first 5 rows to a c-list-datatable, with the count in
 * the card title. connectedCallback resolves a "View All" URL via
 * NavigationMixin.GenerateUrl, and the footer link navigates to the Lead list view.
 *
 * lightning/navigation is mocked so [Navigate] dispatches a catchable 'navigate'
 * event carrying the PageReference (the sfdx-lwc-jest stub's Navigate is a no-op, and
 * the host element and component instance differ, so an instance override cannot
 * capture the call). Rows are asserted via the datatable's `data` @api — c-list-datatable
 * extends the stubbed lightning/datatable, so cell DOM is not rendered here.
 */
import { createElement } from 'lwc';
import RecentLeads from 'c/recentLeads';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', { detail: { pageReference } })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('https://example.com/lead-list');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/LeadFunnelController.getFunnel',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// 6 recent leads -> the JS slices to the first 5.
//
// ⚠ SUPERSEDED 2026-08-17 — the fixture used to carry a package on row 1 and none on the others, to
// exercise the 'Package' column's null guard. That column was removed from this card (the dedicated
// `c/recentPackages` widget on the same homepage now owns the fact), so `packageId`/`packageName`
// are gone from the rows here as well as from `LeadFunnelController.LeadRow`. A row shape carrying
// members no getter reads would suggest the column still exists.
//
// ⚠ EXTENDED 2026-08-17 — every row now carries `extractionScore`, because the renamed 'Score' column
// renders it in one cell. The FIRST FIVE values (the only ones this card displays — it slices to 5)
// deliberately cover every band and the upper boundary: 85 green, 55 amber, 20 red, 70 the `>= 70`
// EDGE (green, not amber) and null "not scored". A fixture where every row scored the same could not
// falsify the banding at all.
//
// 🔴 `confidence` IS STILL ON EVERY ROW AND IS NOW A PURE FALSIFIER INPUT — DO NOT DELETE IT AS
// "UNUSED FIXTURE DATA" (third pass, 2026-08-17). The client no longer reads it: as of this pass BOTH
// the word and the colour in the Score cell derive from `extractionScore`. But the server still sends
// it (`LeadFunnelController` needs `Parse_Confidence__c` for the 'Review Queue' tile, so
// `LeadRow.confidence` stays in the payload), and keeping it here is the ONLY way these tests can
// prove the label ignores it. A fixture without it could not tell "labelled from the score" apart from
// "labelled from the confidence" — which is exactly how the reported bug survived pass two.
//
// 🔴 ROWS 4 AND 6 ARE THE DISAGREEMENT CASES AND THEIR VALUES ARE LOAD-BEARING — DO NOT "TIDY" THEM
// INTO AGREEMENT. As originally written the two bands AGREED on every visible row (High/85, Medium/55,
// Low/20, High/70, null/null), so every assertion passed under either implementation. Row 4 is LOW
// confidence with a 70 score (⇒ must read `High · 70%` on GREEN — both taken from the score, in direct
// contradiction of its confidence) and row 6 is HIGH confidence with a 0 score (⇒ `Low · 0%` on RED).
// They falsify in opposite directions, so a regression to a confidence-sourced word or colour cannot
// pass both.
//
// ⚠ Row 6 is NOT reachable through this fixture (the slice drops it), so it is exercised by targeted
// emits below — as is the 29% case the user actually reported.
//
// ⚠ Row 6's `0` is NOT reachable through this fixture — the slice drops it — so the zero case (a REAL
// score of zero, which a `!pct` guard would silently mis-render as "Not scored") has its own test with
// a targeted emit. It is left on row 6 so the fixture states the intended value rather than implying
// the field is optional.
const FUNNEL = {
    recent: [
        { id: '00Q000000000001', name: 'Gateway Plaza', status: 'New', channel: 'Email-to-Lead', confidence: 'High', extractionScore: 85, broker: 'Dana Reyes', priority: 'High', days: 2 },
        { id: '00Q000000000002', name: 'Harbor Point', status: 'Under Review', channel: 'Broker Portal', confidence: 'Medium', extractionScore: 55, broker: 'Sam Okafor', priority: 'Normal', days: 5 },
        { id: '00Q000000000003', name: 'Cedar Commons', status: 'Qualified', channel: 'Manual Entry', confidence: 'Low', extractionScore: 20, broker: 'Unknown', priority: 'Normal', days: 9 },
        { id: '00Q000000000004', name: 'Oak Ridge', status: 'Converted', channel: 'Email-to-Lead', confidence: 'Low', extractionScore: 70, broker: 'Jo Lin', priority: 'Normal', days: 12 },
        { id: '00Q000000000005', name: 'Pine Tower', status: 'Disqualified', channel: 'Broker Portal', confidence: null, extractionScore: null, broker: 'Unknown', priority: 'Normal', days: 30 },
        { id: '00Q000000000006', name: 'Maple Court', status: 'New', channel: 'Manual Entry', confidence: 'High', extractionScore: 0, broker: 'Alex Kim', priority: 'High', days: 1 }
    ]
};

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

describe('c-recent-leads', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-recent-leads', { is: RecentLeads });
        document.body.appendChild(element);
        return element;
    }

    it('EMPTY: shows a zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Leads (0)');
        expect(datatable(element).data).toEqual([]);
    });

    it('DATA BRANCH: caps the datatable at the 5 most recent and counts them', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(5); // 6 emitted, sliced to 5
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Leads (5)');
    });

    it('DATA BRANCH: transforms a row (record URL, priority star, age suffix)', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        const first = datatable(element).data[0];
        expect(first.recordUrl).toBe('/lightning/r/Lead/00Q000000000001/view');
        expect(first.name).toBe('Gateway Plaza');
        expect(first.broker).toBe('⭐ Dana Reyes'); // priority High -> starred
        expect(first.days).toBe('2d');
        expect(first.channelIcon).toBe('utility:file');

        // Non-high priority + Unknown broker -> plain 'Unknown', no star.
        expect(datatable(element).data[2].broker).toBe('Unknown');
    });

    it('SCORE COLUMN: is labelled "Score" and the old "Data Completeness" heading is gone', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        const labels = datatable(element).columns.map((c) => c.label);
        expect(labels).toContain('Score');
        expect(labels).not.toContain('Data Completeness');

        // The column still renders through c/listDatatable's SHARED `pill` type, unmodified — the one
        // colour is carried by `wrapStyle`, not by a new custom cell type. If anyone extends that
        // subclass for this cell, `typeAttributes` grows and this reds.
        const score = datatable(element).columns.find((c) => c.label === 'Score');
        expect(score.type).toBe('pill');
        // `fieldName` moved with the label: the value is no longer just the confidence band.
        expect(score.fieldName).toBe('score');

        // 🔴 EXACTLY ONE STYLE BINDING, AND `dotStyle` IS DELIBERATELY ABSENT. This is the assertion
        // that pins "one colour per row": the shared `pill.html` renders its dot span unconditionally,
        // so the element cannot be removed — but nothing is BOUND to it here, leaving it unstyled and
        // invisible (and `scoreWrap` uses `gap:0` so the empty flex child cannot offset the label).
        // Binding anything to `dotStyle` re-creates the two-colour cell the user rejected, and reds
        // this. Note the Stage column DOES still bind a dot — this is scoped to Score.
        expect(Object.keys(score.typeAttributes).sort()).toEqual(['wrapStyle']);
        expect(score.typeAttributes.dotStyle).toBeUndefined();
        expect(score.typeAttributes.wrapStyle).toEqual({ fieldName: 'scoreWrap' });

        const stage = datatable(element).columns.find((c) => c.label === 'Stage');
        expect(stage.typeAttributes.dotStyle).toEqual({ fieldName: 'stageDot' });
    });

    it('SCORE COLUMN: one cell, ONE flat background, and BOTH the word and the % taken from the SCORE', async () => {
        // 🔴 THE CENTRAL ASSERTION OF THIS CELL. Every visible part of it — the qualitative word, the
        // percentage and the single background — derives from `Extraction_Score_Pct__c` and from
        // nothing else. `Parse_Confidence__c` is a DIFFERENT fact (certainty about
        // `is_acquisition_related`, not extraction completeness) and is no longer rendered here at all.
        //
        // ⚠ SUPERSEDES TWO EARLIER VERSIONS OF THIS TEST, BOTH 2026-08-17:
        //   1. a per-confidence `confWrap` + `confDot` PLUS a disc glyph inside the value (`High · 🟢
        //      85%`), rejected by the user: "We don't need to show two colors in one record, only show
        //      background color that's it";
        //   2. one colour but a confidence-sourced WORD, which the user then reported live — "29% is
        //      High? That's wrong" — because the word and the colour answered to different fields.
        // Both absences are now asserted rather than merely untested.
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        const rows = datatable(element).data;

        // TEXT: `{ScoreLabel} · {Score}%` — a word for the number, then the number. No glyph.
        expect(rows[0].score).toBe('High · 85%');
        expect(rows[1].score).toBe('Medium · 55%');
        expect(rows[2].score).toBe('Low · 20%');
        // 🔴 THE WORD DISCRIMINATOR: row 4 is LOW confidence with a 70 score, so a confidence-sourced
        // label reads 'Low · 70%' and the score-sourced one reads 'High · 70%'. This is the assertion
        // that reds if anyone re-points the label at `r.confidence`.
        expect(rows[3].score).toBe('High · 70%');
        expect(rows[3].score).not.toBe('Low · 70%');

        // COLOUR: one background per row, from the SCORE band — green >= 70, amber 40-69, red < 40.
        expect(rows[0].scoreWrap).toContain('background:#e6f4ea'); // 85 -> green
        expect(rows[1].scoreWrap).toContain('background:#fff4e0'); // 55 -> amber
        expect(rows[2].scoreWrap).toContain('background:#fde8e8'); // 20 -> red
        // 🔴 THE COLOUR DISCRIMINATOR, on the same row: green proves the band comes from the score AND
        // that `>= 70` is the green boundary, not the amber one.
        expect(rows[3].scoreWrap).toContain('background:#e6f4ea');

        // 🔴 WORD AND COLOUR AGREE ON EVERY ROW — the invariant the user's report was about. Asserted
        // as a rule over all rows, not just the four spelled out above, so a future band added to one
        // half and not the other cannot slip through.
        const BAND_BY_WORD = {
            High:   '#e6f4ea',
            Medium: '#fff4e0',
            Low:    '#fde8e8',
            'N/A':  '#eceff1'
        };
        rows.forEach((row) => {
            const word = row.score.split(' · ')[0];
            expect(BAND_BY_WORD[word]).toBeDefined(); // no unexpected vocabulary
            expect(row.scoreWrap).toContain(`background:${BAND_BY_WORD[word]}`);
        });

        // The `gap:0` that neutralises the shared template's unconditional (and here unstyled) dot
        // span. With `pillWrap`'s 7px gap the invisible child would push the label right.
        expect(rows[0].scoreWrap).toContain('gap:0');

        // ONE COLOUR PER ROW, ENFORCED: the row emits no second style for this cell at all.
        rows.forEach((row) => {
            expect(row.confWrap).toBeUndefined();
            expect(row.confDot).toBeUndefined();
            expect(row.scoreDot).toBeUndefined();
            // No emoji-circle glyphs anywhere in the value — the pill's background does that work.
            expect(row.score).not.toMatch(/[🟢🟠🔴⚪]/u);
        });
    });

    it('SCORE COLUMN: a null score reads "Not scored" on grey — never 0%, never red, never blank', async () => {
        // Per the field's own metadata comment, scoring is FAIL-SOFT (the inbound email pipeline must
        // never be made to throw), so null means the score could not be COMPUTED. Rendering it as 0%
        // or red would accuse a broker email of being empty when nothing was ever measured. The user's
        // "Every lead should be scored" was addressed by the DATA fix; this branch is the defensive
        // floor under it, so it must stay reachable and stay neutral.
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        const nullScored = datatable(element).data[4];
        // The word is still prefixed — 'N/A', now the UNSCORED SCORE BAND's own label rather than a
        // confidence band — so the separator means the same thing on every row. Mildly redundant beside
        // 'Not scored', kept deliberately for that uniformity (see the getter's comment).
        expect(nullScored.score).toBe('N/A · Not scored');
        expect(nullScored.score).not.toContain('0%');
        expect(nullScored.scoreWrap).toContain('background:#eceff1'); // neutral grey, not red
        expect(nullScored.scoreWrap).not.toContain('#fde8e8');
    });

    it('SCORE COLUMN: a REAL score of zero renders as 0% on RED, not as "Not scored"', async () => {
        // 🔴 THE FALSIFIER FOR A `!pct` / `pct || …` GUARD. Zero is a meaningful measurement — every one
        // of the nine deal-process keys missing — and is the exact value a falsy check would silently
        // convert into "not scored", i.e. into "we never measured this". The two states must stay
        // distinguishable, so this and the null test above discriminate in opposite directions: 0 is
        // RED, null is GREY.
        //
        // 🔴 It is also the strongest source discriminator in the suite: this row is HIGH confidence
        // with a ZERO score, the maximum possible disagreement between the two fields. Both the word
        // and the colour must follow the score — `Low` on RED — so a confidence-sourced implementation
        // reads `High · 0%` on green and fails both assertions.
        //
        // Emitted directly because the card slices to 5 rows and the fixture's zero sits on row 6.
        const element = createComponent();

        getFunnel.emit({ recent: [{ ...FUNNEL.recent[0], extractionScore: 0 }] });
        await Promise.resolve();

        const zeroScored = datatable(element).data[0];
        expect(zeroScored.score).toBe('Low · 0%');
        expect(zeroScored.score).not.toBe('High · 0%'); // the pass-two rendering
        expect(zeroScored.scoreWrap).toContain('background:#fde8e8'); // red, NOT the grey of null
    });

    it('SCORE COLUMN REGRESSION: a HIGH-confidence Lead scoring 29% reads "Low · 29%", never "High · 29%"', async () => {
        // 🔴 THE EXACT BUG THE USER REPORTED FROM THE LIVE HOMEPAGE, PINNED VERBATIM: "29% is High?
        // That's wrong." Under pass two the word came from `Parse_Confidence__c` while the number and
        // the colour came from `Extraction_Score_Pct__c`, so a Lead the model was confident about but
        // had extracted almost nothing from rendered as `High · 29%` on a RED pill — a cell that
        // contradicted itself in two places at once.
        //
        // 29 is used rather than a round number because it is the value that was on screen, and it sits
        // clear of the 40 boundary so this test is about the SOURCE of the word, not about a threshold.
        const element = createComponent();

        getFunnel.emit({
            recent: [{ ...FUNNEL.recent[0], confidence: 'High', extractionScore: 29 }]
        });
        await Promise.resolve();

        const row = datatable(element).data[0];
        expect(row.score).toBe('Low · 29%');
        expect(row.score).not.toBe('High · 29%'); // the reported rendering
        expect(row.score).not.toContain('High');  // and no other arrangement of it
        expect(row.scoreWrap).toContain('background:#fde8e8'); // word and colour finally agree
    });

    it('SCORE COLUMN REGRESSION: the confidence field cannot influence the cell at all', async () => {
        // 🔴 THE STRONGEST FORM OF THE FIX — INDEPENDENCE, not just "correct on the reported row". Three
        // Leads share one score and differ ONLY in `Parse_Confidence__c`; all three must render the
        // byte-identical cell. Any implementation that reads the confidence field for the word, the
        // colour, or anything else in this cell fails here regardless of which mapping it uses, which is
        // what makes this test survive a rewrite of the label vocabulary.
        //
        // ⚠ `confidence` is deliberately still POPULATED (and still shipped by `LeadRow`) — the point is
        // that it is present and ignored, not that it is absent.
        const element = createComponent();

        getFunnel.emit({
            recent: [
                { ...FUNNEL.recent[0], confidence: 'High',   extractionScore: 29 },
                { ...FUNNEL.recent[0], id: '00Q0000000000AA', confidence: 'Medium', extractionScore: 29 },
                { ...FUNNEL.recent[0], id: '00Q0000000000BB', confidence: null,     extractionScore: 29 }
            ]
        });
        await Promise.resolve();

        const rows = datatable(element).data;
        expect(rows.map((r) => r.score)).toEqual(['Low · 29%', 'Low · 29%', 'Low · 29%']);
        expect(new Set(rows.map((r) => r.scoreWrap)).size).toBe(1); // one style, three confidences
    });

    it('SCORE COLUMN: a fractional score is rounded, and a missing member degrades to "N/A · Not scored"', async () => {
        const element = createComponent();

        getFunnel.emit({
            recent: [
                { ...FUNNEL.recent[0], extractionScore: 84.6 },
                // No `extractionScore` member at all — what an older server response looks like. It
                // must degrade to the neutral state rather than rendering `NaN%`.
                { ...FUNNEL.recent[1], extractionScore: undefined },
                // 🔴 THE BOUNDARY THE ROUNDING ORDER DECIDES: 69.6 is shown as `70%`, so the word must be
                // the word for 70 — `High`. Banding the RAW value instead would render `Medium · 70%`,
                // reintroducing the reported defect at a boundary where it is much harder to notice.
                { ...FUNNEL.recent[0], id: '00Q0000000000CC', extractionScore: 69.6 }
            ]
        });
        await Promise.resolve();

        const rows = datatable(element).data;
        expect(rows[0].score).toBe('High · 85%');
        expect(rows[0].scoreWrap).toContain('background:#e6f4ea'); // 84.6 rounds to 85, still green
        // ⚠ Row 2's confidence is 'Medium' and is ignored: an unscored row reads the UNSCORED band's
        // own 'N/A', not the confidence word it used to carry here ('Medium · Not scored').
        expect(rows[1].score).toBe('N/A · Not scored');
        expect(rows[1].score).not.toContain('Medium');
        expect(rows[1].scoreWrap).toContain('background:#eceff1'); // degrades to grey, never NaN%
        expect(rows[2].score).toBe('High · 70%');
        expect(rows[2].scoreWrap).toContain('background:#e6f4ea');
    });

    it('NO PACKAGE COLUMN: the retired column is absent and no row carries package members', async () => {
        // 🔴 AN ABSENCE ASSERTION, REPLACING THREE PRESENCE ASSERTIONS (2026-08-17). The three
        // 'PACKAGE COLUMN' tests that stood here (link rendering, the empty-cell null guard, and
        // the `type: 'url'` column shape) were removed with the column itself — `c/recentPackages`
        // on this same homepage now owns "which multi-property email did this arrive on?".
        //
        // Deleting them outright would have left NOTHING red if the column were pasted back, so the
        // one test kept in their place asserts the removal in both places it has to hold: the column
        // is gone from `COLUMNS`, and no row getter emits `packageUrl`/`packageName`. The second half
        // matters independently — a re-added row member with no column is a live FLS cost on
        // `LeadSelector.selectRecent` in exchange for nothing on screen.
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        expect(
            datatable(element).columns.find((c) => c.label === 'Package')
        ).toBeUndefined();
        expect(
            datatable(element).columns.some((c) => c.fieldName === 'packageUrl')
        ).toBe(false);

        const first = datatable(element).data[0];
        expect(first.packageUrl).toBeUndefined();
        expect(first.packageName).toBeUndefined();
    });

    it('VIEW ALL: clicking the footer link navigates to the Lead list view', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('Lead');
        expect(pageRef.attributes.actionName).toBe('list');
    });

    it('ERROR BRANCH: renders an inline error state and hides the datatable when the wire errors', async () => {
        const element = createComponent();

        getFunnel.error({ message: 'Lead feed unavailable.' });
        await Promise.resolve();

        // The datatable is replaced by a visible error message (not a silent blank).
        expect(datatable(element)).toBeNull();
        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Lead feed unavailable.');
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Recent Leads (0)');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
