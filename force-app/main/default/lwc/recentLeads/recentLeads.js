import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';

// [background, dot] per stage for the soft pills. The Stage column is UNCHANGED and keeps its dot.
const STAGE = {
    New:            ['#eceff1', '#90A4AE'],
    'Under Review': ['#e8f1fc', '#1E88E5'],
    Qualified:      ['#e6f5f4', '#2BAFAC'],
    Converted:      ['#e8f5e9', '#43A047'],
    Disqualified:   ['#fdeaea', '#E53935']
};

/**
 * ⚠ `CONF_LABEL` LIVED HERE AND WAS DELETED 2026-08-17 (third pass). DO NOT RE-ADD IT.
 *
 * It mapped `Parse_Confidence__c` (HIGH / MEDIUM / LOW) to the WORD at the front of the Score cell,
 * while the percentage AND the colour came from `Extraction_Score_Pct__c`. The user hit the resulting
 * contradiction live and reported it in exactly these terms: **"29% is High? That's wrong."** Once the
 * cell had been collapsed to a single score-banded background (pass two, below), a confidence-sourced
 * word sat next to a score-sourced colour with nothing tying them together — so on any row where the
 * two fields disagreed the cell contradicted itself in plain sight.
 *
 * 🔴 THE FIX IS STRUCTURAL, NOT A NEW LOOKUP TABLE: the word and the colour are now returned by the
 * SAME function from the SAME input (`scoreBand`), so they are incapable of drifting apart again. A
 * second, parallel threshold map for the label would have re-opened the identical defect one edit
 * later. The four words survive — `High` / `Medium` / `Low` / `N/A` — but they are now score bands.
 *
 * 🔴 THIS DID NOT RETIRE `Parse_Confidence__c`, WHICH IS STILL LIVE SERVER-SIDE — do not "tidy" it out
 * of anything. `LeadFunnelController.getFunnel()` counts `Parse_Confidence__c == 'LOW'` into
 * `reviewQueue`, which feeds the 'Review Queue' tile elsewhere on this same homepage, and
 * `LeadRow.confidence` still ships in the payload (the tests below deliberately keep it in the fixture
 * as a falsifier input). What changed is only that NOTHING IN THIS FILE READS IT — the field is not
 * displayed here any more. Removing it from `LeadSelector.selectRecent`'s SELECT or from the DTO would
 * silently zero that tile.
 */

/**
 * The 'Score' cell — ONE pill, ONE flat background, ONE source field, no indicator inside it.
 *
 * ═══ 🔴 EVERY PART OF THIS CELL COMES FROM `Extraction_Score_Pct__c`. READ BEFORE ADDING A SECOND ═══
 * ═══     SOURCE, A SECOND COLOUR, OR A SECOND THRESHOLD TABLE.                                  ═══
 * Text is `{ScoreLabel} · {Score}%` (`Low · 29%`); the background is banded on the same number by the
 * same function. The label is a WORD FOR THE NUMBER BESIDE IT, so the two can never disagree.
 *
 * ⚠ A THIRD SUPERSEDED DESIGN, AND IT IS THE ONE THE USER ACTUALLY REPORTED (2026-08-17, pass three):
 * the label used to come from `Parse_Confidence__c` while the number and the colour came from the
 * score, which rendered rows like `High · 29%` on a RED pill. See the deleted-`CONF_LABEL` note above
 * for why that is not a wording problem but a two-sources problem, and why the fix had to be to derive
 * the label from the score rather than to re-map the confidence words.
 *
 * ⚠ TWO FURTHER EARLIER DESIGNS ARE SUPERSEDED AND MUST NOT BE RESTORED (both 2026-08-17), making
 * three in total with the one above:
 *   1. A per-confidence pill background + dot, PLUS a Unicode disc glyph (🟢/🟠/🔴/⚪) carrying the
 *      score's own colour inside the composed string — e.g. `🟢 High · 🔴 29%`. Shipped, seen, and
 *      rejected by the user on sight: "We don't need to show two colors in one record, only show
 *      background color that's it." Two colours in one cell read as two competing verdicts on one row,
 *      and when the bands disagreed (green confidence, red score) the cell actively looked broken. The
 *      glyphs are gone with it — the pill's own background now does that work, so there is nothing
 *      left for a disc to add. ⚠ Note this pass removed the second COLOUR but left the mismatched
 *      WORD, which is what the user then reported; collapsing to one colour is what made the
 *      contradiction legible.
 *   2. Extending the SHARED `c/listDatatable` with a second text/style slot. Still rejected, and the
 *      reasons are unchanged and worth keeping because they will be re-proposed: that subclass has
 *      SEVENTEEN consumers, has not been functionally modified since the initial commit, and —
 *      decisively — a datatable subclass's cell templates CANNOT BE RENDERED IN JEST AT ALL
 *      (`lightning/datatable` is a stub; `listDatatable.test.js` says so in its own header and can
 *      only assert the static `customTypes` config). This change needs none of it.
 *
 * ⚠ THE DOT SPAN IS STRUCTURAL IN THE SHARED TEMPLATE, SO IT IS DEFUSED, NOT DELETED. `pill.html`
 * renders `<span style={typeAttributes.dotStyle}></span>` UNCONDITIONALLY — there is no `if:true`
 * around it, so no column can omit the element without editing the shared bundle. This column
 * therefore simply does not BIND `dotStyle` (see `COLUMNS`), leaving an unstyled, zero-size,
 * background-less span, and `flatPillWrap` sets `gap:0` so that empty flex child cannot push the
 * label right the way the 7px gap on the other pills would. Note a datatable subclass cannot reach
 * its cell templates from a `.css` file (stated in `listDatatable.js`'s own header), so `dotStyle` is
 * the ONLY route by which that span could ever acquire a style — an unbound one is genuinely inert.
 *
 * ⚠ NULL IS NOT ZERO AND MUST NOT RENDER AS 0% OR AS RED. Per the field's own metadata comment,
 * scoring is fail-soft (the inbound email pipeline must never be made to throw), so a null means the
 * score COULD NOT BE COMPUTED — a neutral state. Rendering it red would accuse a broker email of
 * being empty when nothing was ever measured. The user's "Every lead should be scored" was addressed
 * by the data fix, not by pretending a missing score is a zero here; this branch is the defensive
 * floor under that fix, so it must stay reachable and stay grey.
 */
const SCORE_GOOD = 70; // >= 70 — green, 'High'
const SCORE_FAIR = 40; // 40-69 — amber, 'Medium'; below 40 — red, 'Low'
/**
 * 🔴 LABEL AND COLOUR ARE CO-LOCATED PER BAND ON PURPOSE — DO NOT SPLIT THEM INTO TWO MAPS. Keeping
 * the word next to the hex is what makes "29% cannot say High" true by construction rather than by
 * review: one band, one entry, one threshold test in `scoreBand`. Two maps read by two branches is
 * precisely the shape that produced the reported defect, with the label coming from one place and the
 * colour from another.
 *
 * ⚠ THE FOUR HEX VALUES ARE UNCHANGED SINCE THE CONFIDENCE PILL — NOT NEW COLOURS. Green `#e6f4ea`
 * was `CONF.high`'s background, amber `#fff4e0` was `medium`'s, red `#fde8e8` was `low`'s and grey
 * `#eceff1` was `na`'s. The palette on this homepage has never changed; what changed is only what
 * SELECTS from it — the score band, and now the word too.
 *
 * ⚠ The four WORDS are also unchanged, which is why the fix is invisible on any row whose score and
 * confidence happened to agree (i.e. most of them). That is exactly why the tests pin rows where they
 * DISAGREE — see `recentLeads.test.js`.
 */
const SCORE_BAND = {
    good:     { bg: '#e6f4ea', label: 'High' },
    fair:     { bg: '#fff4e0', label: 'Medium' },
    poor:     { bg: '#fde8e8', label: 'Low' },
    unscored: { bg: '#eceff1', label: 'N/A' }
};
/**
 * The VALUE fragment for an unscored row — not a label. (Renamed from `SCORE_UNSCORED_LABEL` when the
 * bands gained real labels, so the two halves of `N/A · Not scored` are named for the slots they fill.)
 */
const SCORE_UNSCORED_VALUE = 'Not scored';

/**
 * Bands one score into ALL THREE of the cell's outputs: its qualitative word, its numeric fragment and
 * its single background colour.
 *
 * 🔴 ONE FUNCTION, ONE ARGUMENT, THREE OUTPUTS — THIS IS THE FIX FOR THE REPORTED BUG, so do not
 * refactor the label out of it. Because the word and the hex leave here together, off the one
 * comparison chain below, there is no code path that can produce `High` beside a red 29%. A caller that
 * computed the label itself (from confidence, or from a second copy of these thresholds) would re-open
 * the defect, and it would look correct in review.
 *
 * @param {number|null|undefined} pct `Extraction_Score_Pct__c`, 0-100, or null when not scored.
 * @returns {{label: string, value: string, bg: string}} Neither text fragment is ever empty, so the
 *          pill never renders blank or as a bare separator.
 */
const scoreBand = (pct) => {
    // `== null` catches BOTH null and undefined and nothing else — 0 is a real, meaningful score
    // (every deal-process key missing) and must survive this guard.
    if (pct == null || pct === '') {
        return { ...SCORE_BAND.unscored, value: SCORE_UNSCORED_VALUE };
    }
    const value = Number(pct);
    if (Number.isNaN(value)) {
        return { ...SCORE_BAND.unscored, value: SCORE_UNSCORED_VALUE };
    }
    // 🔴 ROUND FIRST, THEN BAND — AND IN THAT ORDER, NOT THE REVERSE. Apex sends a Decimal, so
    // rounding is needed anyway to keep a stray `84.6` from rendering as `84.6%` in a narrow column.
    // But the band MUST be taken from the rounded number the user actually sees: banding on the raw
    // value would render a 69.6 as `Medium · 70%`, i.e. a word disagreeing with the number beside it —
    // the exact defect class this pass exists to remove, just moved to the boundary where it is harder
    // to spot. The only visible effect either way is on a fractional score within 0.5 of a threshold.
    const shown = Math.round(value);
    let band = SCORE_BAND.poor;
    if (shown >= SCORE_GOOD) {
        band = SCORE_BAND.good;
    } else if (shown >= SCORE_FAIR) {
        band = SCORE_BAND.fair;
    }
    return { ...band, value: `${shown}%` };
};
const CHANNEL_ICON = {
    'Email-to-Lead': 'utility:file',
    'Broker Portal': 'utility:user',
    'Manual Entry':  'utility:edit'
};
const FALLBACK = ['#eef1f4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;
/**
 * A pill with NO dot — identical to `pillWrap` but `gap:0`.
 *
 * 🔴 THE `gap:0` IS THE WHOLE POINT OF THIS SECOND HELPER, NOT A COSMETIC TWEAK. `pill.html` always
 * renders its dot span, so a dot-less column still has an empty flex child ahead of the label; with
 * `pillWrap`'s `gap:7px` that invisible child would push the text 7px right, leaving the pill
 * visibly lopsided (18px of space on the left, 11px on the right). Do NOT collapse this back into
 * `pillWrap` — the Stage column needs the 7px because it HAS a dot.
 */
const flatPillWrap = (bg) => `display:inline-flex;align-items:center;gap:0;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;

const COLUMNS = [
    { label: 'Deal Name', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'Stage', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: { fieldName: 'stageDot' } } },
    { label: 'Channel', fieldName: 'channel', type: 'text', cellAttributes: { iconName: { fieldName: 'channelIcon' }, iconPosition: 'left' } },
    // ⚠ 'Data Completeness' -> 'Score' (2026-08-17). The cell carries ONE FACT in TWO FORMS under ONE
    // COLOUR: the value is the composed string `Low · 29%` — a word for the number, then the number —
    // and the single background is banded on that same score.
    //
    // 🔴 `dotStyle` IS DELIBERATELY NOT BOUND HERE, AND ITS ABSENCE IS LOAD-BEARING — DO NOT "FIX" IT
    // BACK IN. It was `{ fieldName: 'confDot' }` until the user asked for one colour per row. The dot
    // is the second colour, so binding anything to it re-creates precisely what was removed. The span
    // itself survives (it is unconditional in the shared `pill.html`) but is left unstyled and is
    // neutralised by `flatPillWrap`'s `gap:0`. See `scoreBand` above for the full note.
    //
    // ⚠ `fieldName` is `score`, and as of pass three that name is finally literal — the member holds
    // nothing but `Extraction_Score_Pct__c` in two renderings. It was `confidence` two passes ago while
    // the value was a confidence band, which is precisely the trap that let a confidence word and a
    // score colour end up in one cell without anyone noticing.
    //
    // 🔴 THE TWO FIELDS ARE STILL DIFFERENT FACTS AND MUST NEVER BE CONFLATED — that warning survives
    // this change, it just no longer applies to THIS CELL, which now shows only one of them.
    // `Parse_Confidence__c` is the model's certainty about `is_acquisition_related`;
    // `Extraction_Score_Pct__c` is the percent of the nine signed-off deal-process keys actually
    // captured. The field metadata is explicit that a high confidence does NOT imply a high score —
    // which is exactly why pairing one field's word with the other's number produced a cell that
    // contradicted itself. Do not average them, rank on their combination, or re-introduce the
    // confidence word here. If the confidence band ever needs to be on screen again it needs its OWN
    // column, with its own colour, not a share of this one.
    { label: 'Score', fieldName: 'score', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'scoreWrap' } } },
    { label: 'Broker', fieldName: 'broker', type: 'text' },
    // ⚠ SUPERSEDED 2026-08-17 — THE 'Package' COLUMN WAS REMOVED FROM THIS ARRAY THE SAME DAY IT
    // WAS ADDED, AND IT MUST NOT BE RESTORED HERE. It was a `type: 'url'` column linking to the
    // multi-property `Property_Package__c` a Lead arrived on, with a null guard in `get rows()` so
    // the single-property majority rendered an empty cell instead of a dead link.
    //
    // WHY THE PREMISE DIED: the column was only ever a partial answer, because it is downstream of
    // `LeadFunnelController.getFunnel()`, which priority-partitions `LeadSelector.selectRecent(50)`
    // and then shows the first 5 rows — so a package's own Leads can fall silently past the cutoff
    // (observed with a direct server call). `c/recentPackages` reads `Property_Package__c` directly,
    // with its own sort and its own server-side cutoff, and now sits as its own card on this same
    // homepage. With that card present the column is redundant, so it was retired rather than kept
    // as a second, weaker view of the same fact.
    //
    // ⚠ Restoring it is not a client-only change: it would also mean re-adding `packageId` /
    // `packageName` to `LeadFunnelController.LeadRow` and `Property_Package__c` +
    // `Property_Package__r.Name` to `LeadSelector.selectRecent`, whose `WITH USER_MODE` SELECT is
    // the whole Lead Funnel homepage's single point of FLS failure. See that method's header.
    { label: 'Age', fieldName: 'days', type: 'text' }
];

export default class RecentLeads extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    error;
    listUrl = '#';

    @wire(getFunnel)
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.data = undefined;
        }
    }

    get hasError() {
        return !!this.error;
    }
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load recent leads.';
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lead', actionName: 'list' },
            state: { filterName: '__Recent' }
        };
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    get rows() {
        if (!this.data) {
            return [];
        }
        return this.data.recent.slice(0, 5).map((r) => {
            const [sBg, sDot] = STAGE[r.status] || FALLBACK;
            // ⚠ `r.confidence` IS DELIBERATELY NOT READ HERE. It still arrives on every row (the server
            // needs `Parse_Confidence__c` for the 'Review Queue' tile), but this cell no longer displays
            // it — see the deleted-`CONF_LABEL` note at the top of the file. Reading it back into this
            // getter is the reported bug.
            const band = scoreBand(r.extractionScore);
            const known = r.broker && r.broker !== 'Unknown';
            const brokerName = known ? r.broker : 'Unknown';
            return {
                id: r.id,
                recordUrl: `/lightning/r/Lead/${r.id}/view`,
                name: r.name,
                status: r.status,
                stageWrap: pillWrap(sBg),
                stageDot: pillDot(sDot),
                channel: r.channel,
                channelIcon: CHANNEL_ICON[r.channel] || 'utility:record',
                // The 'Score' cell: the score's own word, then the score — one string, one colour, one
                // source. `·` is this repo's cell separator idiom (c/recentPackages joins its broker
                // name and address the same way).
                //
                // 🔴 BOTH FRAGMENTS COME OFF THE SAME `band`, so `Low · 29%` cannot become `High · 29%`
                // without changing `scoreBand` itself. Composing the label from anything else — most
                // obviously `r.confidence` — is the defect the user reported.
                //
                // ⚠ THE WORD IS ALWAYS PREFIXED, INCLUDING ON THE UNSCORED ROW, which reads
                // `N/A · Not scored`. That is mildly redundant now that both halves derive from one
                // field, and it is kept anyway: the separator then means the same thing on every row,
                // and this is the rare defensive branch (all Leads are seeded with a score), so it is
                // not worth a second cell shape for a reader to learn.
                //
                // ⚠ `confWrap` / `confDot` ARE GONE and the row emits exactly ONE style for this cell.
                // Re-adding either is the two-colour design the user rejected in pass two.
                score: `${band.label} · ${band.value}`,
                scoreWrap: flatPillWrap(band.bg),
                broker: r.priority === 'High' ? `⭐ ${brokerName}` : brokerName,
                days: r.days + 'd'
            };
        });
    }

    get count() {
        return this.rows.length;
    }
}