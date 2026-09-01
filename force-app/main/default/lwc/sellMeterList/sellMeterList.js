import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import SellMeterOverrideModal from 'c/sellMeterOverrideModal';
import SellMeterInitiateModal from 'c/sellMeterInitiateModal';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';
import hasOverrideAccess from '@salesforce/apex/SellMeterController.hasOverrideAccess';

/*
 * ⚠ `lightning/confirm` IS NO LONGER IMPORTED, AND ITS ABSENCE IS DELIBERATE (2026-08-31, item 5b).
 * `LightningConfirm.open()` resolves `Promise<boolean>` and CANNOT carry an override reason back —
 * that is the whole reason it was replaced by `c/sellMeterOverrideModal`, which resolves
 * `{ confirmed, reason }`. Re-adding the import here is the tell that someone has reverted the
 * capture half of the override audit. See `_promptOverride` below.
 */

/** Last-resort text when a thrown error carries no readable body (e.g. transport failure). */
const GENERIC_CREATE_ERROR = 'Unexpected error creating the disposition.';

/** Shown when a row action throws before it can raise its own, more specific message. */
const GENERIC_ACTION_ERROR = 'Something went wrong handling that action. Please try again.';

// [background, dot, label, textColor, fontWeight] per band.
const METER = {
    GREEN:  ['#e9f5ec', '#3fae5e', 'Sell now',       '#3e3e3e', 600],
    YELLOW: ['#fdf0e1', '#c98a33', 'Getting Close',  '#3e3e3e', 600],
    RED:    ['#fdeaea', '#e0556b', 'Hold - Not yet', '#c23934', 700]
};
const METER_ORDER = { GREEN: 0, YELLOW: 1, RED: 2 };
const PAGE_SIZE = 5;
const pillWrap = (bg, color = '#3e3e3e', weight = 600) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:${weight};color:${color};background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Property', fieldName: 'recordUrl', type: 'url', sortable: true, typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'NOI', fieldName: 'noiLabel', type: 'text', sortable: true },
    { label: 'Mkt Cap', fieldName: 'capRateLabel', type: 'text', sortable: true },
    { label: 'Target Price', fieldName: 'targetLabel', type: 'text', sortable: true },
    { label: 'Peak Sell Date', fieldName: 'peakDateLabel', type: 'text', sortable: true },
    { label: 'Projected Value at Peak', fieldName: 'peakValueLabel', type: 'text', sortable: true },
    { label: 'Meter Score', fieldName: 'meterScoreLabel', type: 'text', sortable: true },
    { label: 'Sell Meter', fieldName: 'sellMeter', type: 'pill', sortable: true, typeAttributes: { wrapStyle: { fieldName: 'meterWrap' }, dotStyle: { fieldName: 'meterDot' } } },
    {
        // 🔴 NOT SORTABLE, AND THAT IS NOT AN OVERSIGHT. The button column has no value to order
        // by — its label is a pure function of the band, which the Sell Meter column already
        // sorts on. A sortable Action column would offer the user a control that reorders the
        // table by something they can already reorder it by, under a worse name.
        label: 'Action', type: 'button', initialWidth: 130,
        typeAttributes: {
            label: { fieldName: 'actionLabel' },
            name: { fieldName: 'actionName' },
            variant: { fieldName: 'actionVariant' },
            disabled: { fieldName: 'actionDisabled' }
        }
    }
];

/**
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 EVERY SORTABLE COLUMN'S `fieldName` POINTS AT A PRE-FORMATTED STRING. SORTING ON IT IS
 *    NONSENSE. THIS MAP IS THE FIX AND IT IS NOT OPTIONAL.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `lightning-datatable` does NOT sort data itself — it raises `onsort` carrying the clicked
 * column's `fieldName`, and the PARENT performs the sort. Sorting naively on the emitted
 * fieldName gives, column by column:
 *
 *   recordUrl      '/lightning/r/Property_Asset__c/<Id>/view'  -> orders by RECORD ID
 *   noiLabel       '$2.0M'                                     -> '$10.0M' < '$2.0M' (lexicographic)
 *   capRateLabel   '6.5%'                                      -> breaks the moment a rate hits 10%
 *   targetLabel    '$30.0M'                                    -> same as NOI
 *   peakDateLabel  'Jan 1, 2020'                               -> orders ALPHABETICALLY BY MONTH NAME
 *   peakValueLabel '$34.0M'                                    -> same as NOI
 *   meterScoreLabel'1.07×'                                     -> '1.9×' > '11.2×'
 *   sellMeter      'Sell now | 12d'                            -> alphabetical, ignores band rank
 *
 * Every one of those is WRONG, and every one of them LOOKS right on a small demo portfolio,
 * which is why this is written down rather than left to be noticed.
 *
 * 🔴 THE LABELS MUST STAY LABELS — CONVERTING THE COLUMNS TO NATIVE `currency` / `percent` /
 * `date-local` TYPES IS NOT THE ALTERNATIVE. It would (a) render `$2,000,000.00` and `1/1/2020`
 * on the user's home screen, a visible formatting regression, and (b) break the contract with
 * `c/sellMeterInitiateModal`, which is handed `noiLabel` / `capRateLabel` / `targetLabel` /
 * `peakDateLabel` off the row PRECISELY so the popup and the row it opened from cannot show
 * different numbers for the same property. Four Jest assertions pin that hand-off.
 *
 * So: keep the labels for DISPLAY, carry the raw values on the row for ORDERING, and map one to
 * the other here. `recordUrl -> name` follows the in-repo precedent in `lwc/loiCounterOffer`.
 *
 * ⚠ `peakSellDate` IS THE RAW `'YYYY-MM-DD'` STRING AND NEEDS NO DATE PARSING. ISO-8601 date
 * strings sort chronologically under a plain string compare — that is the format's defining
 * property. Do not "improve" this into `new Date(...)`; the component's own `_fmtFullDate` exists
 * because JS date parsing introduces timezone shifts this component was bitten by.
 *
 * ⚠ THE SELL METER PILL SORTS BY BAND RANK (`meterOrder`), NOT BY ITS OWN TEXT. 'Sell now' /
 * 'Getting Close' / 'Hold - Not yet' have no useful alphabetical order, and the countdown suffix
 * makes it worse. Band rank is the only ordering the column means.
 *
 * ⚠ A `fieldName` MISSING FROM THIS MAP FALLS BACK TO ITSELF, so a newly-added sortable column
 * silently sorts on its display string. If you add a column, add its key here in the same edit.
 */
const SORT_KEY = {
    recordUrl: 'name',
    noiLabel: 'noi',
    capRateLabel: 'mktCapRate',
    targetLabel: 'targetPrice',
    peakDateLabel: 'peakSellDate',
    peakValueLabel: 'projectedValueAtPeak',
    meterScoreLabel: 'meterScore',
    sellMeter: 'meterOrder'
};

export default class SellMeterList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data;
    _page = 1;
    listUrl = '#';
    error;

    /**
     * Undefined until the user clicks a column header. `undefined` IS the "default view" state
     * that band ordering belongs to — see `allRows`. Do not initialise these to a column; doing so
     * would put the table into user-sorted mode before the user has sorted anything, and would
     * silently retire the band ordering that gives the opening screen its meaning.
     */
    sortedBy;
    sortedDirection = 'asc';

    /**
     * 🔴 DEFAULTS TO `false`, AND THE DEFAULT IS THE DESIGN. The wire resolves asynchronously, so
     * a `true` default would render every YELLOW row's Override button ENABLED for the length of
     * the round trip and then disable it — a control that appears and then withdraws, which reads
     * as a bug and is clickable in the gap. Starting closed and opening is invisible; starting
     * open and closing is not.
     *
     * ⚠ THIS IS A UX AFFORDANCE, NOT THE GATE. `DispositionService` asserts the same permission on
     * BOTH create paths, on the YELLOW branch only. Setting this to `true` by hand in a console
     * buys an enabled button and a server refusal.
     */
    _canOverride = false;

    @wire(getPortfolio)
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    /**
     * Whether the running user may override the sell meter on a YELLOW row (stories 12 / 14).
     *
     * ⚠ FAILS CLOSED ON ERROR, AND DELIBERATELY DOES **NOT** RAISE THE ERROR BANNER. A failure
     * here is not a failure to load the list — the table is fine and the user can still Initiate
     * GREEN rows and read every number. Surfacing it as `this.error` would replace a working page
     * with "Sell meter list could not be loaded" because a permission check faulted. The correct
     * degradation is the one a non-principal already gets: a disabled Override button.
     *
     * ⚠ `data === true` RATHER THAN A TRUTHINESS TEST. The Apex returns a Boolean, but a wire that
     * has not answered yet delivers `undefined`, and `undefined` must not be allowed anywhere near
     * an enablement decision.
     */
    @wire(hasOverrideAccess)
    wiredOverrideAccess({ data, error }) {
        if (error) {
            this._canOverride = false;
            // eslint-disable-next-line no-console
            console.error('Sell Meter override permission check failed', error);
            return;
        }
        this._canOverride = data === true;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Property_Asset__c', actionName: 'list' }
        };
    }

    get count() {
        return this._data ? this._data.length : 0;
    }

    /**
     * Full ordered + formatted list; the visible page is sliced from this in `rows`.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE RED-SPLICE WAS REMOVED ON 2026-08-31. THIS IS THE RECORD OF THAT DECISION.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * ⚠ THIS BLOCK USED TO CARRY THE FOLLOWING COMMENT AND THE CODE IT DESCRIBED. IT IS QUOTED
     * RATHER THAN DELETED SO THE REMOVAL READS AS A DECISION AND NOT AS SOMEONE NOT NOTICING IT:
     *
     *     *"Holds (RED) sort last, so they'd never appear on page 1. Pull the first Hold up into
     *     the last visible slot of page 1 so the opening screen showcases all three states."*
     *
     *     if (!sorted.slice(0, PAGE_SIZE).some((r) => r.sellMeter === 'RED')) {
     *         const idx = sorted.findIndex((r) => r.sellMeter === 'RED');
     *         if (idx >= PAGE_SIZE) {
     *             const [hold] = sorted.splice(idx, 1);
     *             sorted.splice(PAGE_SIZE - 1, 0, hold);
     *         }
     *     }
     *
     * IT IS GONE, DELIBERATELY, AT THE USER'S DIRECTION (Gate 1, 2026-08-31, design decision D-8).
     * The design recommended keeping it for the default view only and disabling it once the user
     * sorted; the user declined that reconciliation and asked for the splice to be removed
     * outright. The rule is now the simple one it always looked like: **band order governs the
     * unsorted view, and user sort governs everything after it.**
     *
     * The stated consequence, so nobody reports it as a regression: page 1 no longer guarantees a
     * RED row. A portfolio with six or more non-RED assets now opens showing only GREEN and
     * YELLOW, and the user reaches the Holds through the pager or by sorting. The showcase
     * property the splice provided is genuinely lost — that is the trade, not an accident.
     *
     * ⚠ IT HAD NO TEST WHEN IT WAS REMOVED. Neither pre-2026-08-31 fixture reached the branch
     * (one had 3 rows, so page 1 already contained the RED; the other was six GREEN rows and its
     * own comment said "no RED -> no page-1 reorder"). A regression net for the branch was built
     * as part of this change and then INVERTED to pin its absence — see
     * `sellMeterList.test.js`'s SPLICE REMOVAL block, which drives ≥6 mixed-band rows with the
     * only RED beyond index 4 and asserts it stays on page 2. Do not delete that fixture as
     * redundant: it is the only thing in the repo that can tell a re-added splice from band order.
     *
     * ── THE TWO ORDERINGS ──────────────────────────────────────────────────────────────────
     * `sortedBy` undefined -> BAND ORDER (GREEN, YELLOW, RED). The opening screen leads with
     *                         what is actionable, which is the ordering the page is for.
     * `sortedBy` set       -> the user's column, on RAW values via SORT_KEY, in
     *                         `sortedDirection`. Band order is not applied as a tiebreak: a user
     *                         who sorted by NOI asked for NOI order, and a hidden secondary key
     *                         produces an order they cannot predict from the header they clicked.
     */
    get allRows() {
        if (!this._data) return [];
        const rows = this._data.map((r) => this._toRow(r));
        return this.sortedBy ? this._userSorted(rows) : this._bandOrdered(rows);
    }

    /** Band order (GREEN, YELLOW, RED) — the default view. Unknown bands sort last. */
    _bandOrdered(rows) {
        return [...rows].sort((a, b) => a.meterOrder - b.meterOrder);
    }

    /**
     * The user's sort, on RAW values.
     *
     * ⚠ NULLS ALWAYS SORT LAST, IN BOTH DIRECTIONS, AND THAT IS A CHOICE RATHER THAN A FALLOUT.
     * Every money and date column on this table is genuinely nullable (an asset with no NOI, no
     * target price, no projected value), and those rows carry '—'. Letting them float to the top
     * on a descending sort would bury the largest values — the answer the user clicked the header
     * to see — under rows that have no value at all. `Array.prototype.sort` is stable, so rows
     * that tie keep their band order from the incoming map.
     */
    _userSorted(rows) {
        const field = SORT_KEY[this.sortedBy] || this.sortedBy;
        const dir = this.sortedDirection === 'asc' ? 1 : -1;
        return [...rows].sort((a, b) => {
            const av = a[field];
            const bv = b[field];
            const aMissing = av === null || av === undefined;
            const bMissing = bv === null || bv === undefined;
            if (aMissing && bMissing) return 0;
            if (aMissing) return 1;
            if (bMissing) return -1;
            if (av > bv) return dir;
            if (av < bv) return -dir;
            return 0;
        });
    }

    /**
     * One wire row -> one datatable row.
     *
     * 🔴 EACH ROW CARRIES BOTH SHAPES ON PURPOSE: the `*Label` strings the columns DISPLAY, and
     * the raw values `SORT_KEY` ORDERS by. Dropping the raw keys to "tidy" the row silently
     * reverts sorting to lexicographic nonsense — see SORT_KEY's header for what each column then
     * does. The raw keys bind to no column and render nowhere.
     */
    _toRow(r) {
        const meter = r.sellMeter || 'RED';
        const [bg, dot, label, textColor, weight] = METER[meter] || METER.RED;
        const countdown = this._countdown(r.peakSellDate);
        // YELLOW is now a PRINCIPAL-ONLY action (2026-08-31, stories 12/14). A non-principal sees
        // the button, still labelled 'Override', DISABLED — mirroring the RED 'Hold' idiom already
        // in this column, so the action is visibly present and visibly not theirs. Hiding it would
        // leave a blank cell, which reads as a rendering fault rather than as a permission.
        const isYellow = meter === 'YELLOW';
        return {
            id: r.id,
            name: r.name,
            recordUrl: `/lightning/r/Property_Asset__c/${r.id}/view`,
            noiLabel: this._fmtM(r.noi),
            capRateLabel: r.mktCapRate != null ? parseFloat(r.mktCapRate).toFixed(1) + '%' : '—',
            targetLabel: this._fmtM(r.targetPrice),
            peakDateLabel: this._fmtFullDate(r.peakSellDate),
            peakValueLabel: this._fmtM(r.projectedValueAtPeak),
            meterScoreLabel: this._fmtMultiple(r.meterScore),
            sellMeter: countdown ? `${label} | ${countdown}` : label,
            meterWrap: pillWrap(bg, textColor, weight),
            meterDot: pillDot(dot),
            actionLabel: meter === 'GREEN' ? 'Initiate' : (isYellow ? 'Override' : 'Hold'),
            actionName: meter === 'GREEN' ? 'initiate' : (isYellow ? 'override' : 'hold'),
            actionVariant: meter === 'GREEN' ? 'brand' : (isYellow ? 'neutral' : 'base'),
            actionDisabled: meter === 'RED' || (isYellow && !this._canOverride),
            // ── Raw values for SORT_KEY. Bound to no column; rendered nowhere. ──
            noi: r.noi,
            mktCapRate: r.mktCapRate,
            targetPrice: r.targetPrice,
            peakSellDate: r.peakSellDate,
            projectedValueAtPeak: r.projectedValueAtPeak,
            meterScore: r.meterScore,
            meterOrder: METER_ORDER[meter] ?? 3
        };
    }

    /**
     * Column-header sort. Follows `lwc/loiCounterOffer`'s handler, plus the page reset.
     *
     * ⚠ THE PAGE RESET IS NOT COSMETIC. Without it, a user sorting from page 3 lands on rows 11-15
     * of a completely different ordering — an arbitrary window of a list they have just
     * reordered, with no relationship to what they asked for. Sorting is a request to see the top
     * of something.
     */
    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
        this._page = 1;
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.count / PAGE_SIZE));
    }

    // Clamped current page (guards against data shrinking under the active page).
    get page() {
        return Math.min(Math.max(1, this._page), this.totalPages);
    }

    get rows() {
        const start = (this.page - 1) * PAGE_SIZE;
        return this.allRows.slice(start, start + PAGE_SIZE);
    }

    get showPager() {
        return this.count > PAGE_SIZE;
    }

    get rangeLabel() {
        if (!this.count) return '0 of 0';
        const start = (this.page - 1) * PAGE_SIZE + 1;
        const end = Math.min(this.page * PAGE_SIZE, this.count);
        return `${start}–${end} of ${this.count}`;
    }

    get pageLabel() {
        return `Page ${this.page} of ${this.totalPages}`;
    }

    get isFirstPage() {
        return this.page <= 1;
    }

    get isLastPage() {
        return this.page >= this.totalPages;
    }

    prevPage() {
        if (!this.isFirstPage) this._page = this.page - 1;
    }

    nextPage() {
        if (!this.isLastPage) this._page = this.page + 1;
    }

    /**
     * Row-button dispatcher for the three sell-meter actions.
     *
     * - `initiate` (GREEN)   opens the initiate modal immediately.
     * - `override` (YELLOW)  confirms FIRST, then opens the identical modal.
     * - `hold`     (RED)     returns early. The button is already `disabled`, and the server
     *                        refuses a RED asset too — the client early-return is the
     *                        outermost of three defences, not the only one.
     *
     * ⚠ `override` was previously unhandled, so the yellow row's ENABLED button was a
     * silent no-op — a live defect this restores. Do not narrow the guard back to
     * `!== 'initiate'`.
     *
     * ── 🔴 THE BAND GATE DID NOT MOVE WHEN THE MODAL ARRIVED ────────────────
     * The modal is inserted AFTER this dispatcher and AFTER the yellow-band confirmation,
     * not in place of either. RED still never reaches it; YELLOW still answers the override
     * question before it appears. Opening the modal first and asking the override question
     * inside it would let a user fill in a record type before being told the property is not
     * at peak — the confirmation exists to be the FIRST thing they see.
     *
     * ✅ AND IT DID NOT MOVE WHEN THE CONFIRMATION BECAME A MODAL EITHER (2026-08-31, item 5b).
     * `c/sellMeterOverrideModal` replaced `LightningConfirm` because a confirm returns only a
     * boolean and could not carry the override REASON back. The ORDER is unchanged and is still
     * the point: the override question — now with its reason field — is still the first thing the
     * user sees, and `c/sellMeterInitiateModal` still opens only after it is answered.
     *
     * ── 🔴 `override` IS PRINCIPAL-ONLY SINCE 2026-08-31 (stories 12 / 14) ───
     * The guard below refuses `override` when `_canOverride` is false, and it is NOT redundant
     * with the disabled button. The disabled attribute is a rendering instruction; this dispatcher
     * is reachable from a `rowaction` event, and the component's own history is a lesson in
     * exactly how far a row-action payload can diverge from what the column definition says.
     * ⚠ It is still only the OUTERMOST of three defences — the server asserts the same permission
     * on both `DispositionService` create paths. Removing this makes the button clickable and the
     * refusal server-side; removing the server assert opens the feature.
     */
    handleRowAction(event) {
        // An exception thrown inside a datatable row-action handler is swallowed by the
        // datatable with NO UI signal at all, which is indistinguishable from "the click did
        // nothing" — exactly the symptom that hid the defect below for as long as it existed.
        // This catch is permanent for that reason: a broken action must always say so.
        try {
            const detail = (event && event.detail) || {};
            const row = detail.row || {};
            const name = this._resolveActionName(detail.action, row);
            if (name !== 'initiate' && name !== 'override') {
                // Includes 'hold' (RED) — inert by design, see the band note above.
                return;
            }
            const assetId = row.id;
            if (!assetId) {
                this._toast('Could not initiate', 'No property asset is linked to this row.', 'error');
                return;
            }
            if (name === 'override') {
                if (!this._canOverride) {
                    // Inert for a non-principal, exactly as 'hold' is inert for RED — the button
                    // is already rendered disabled, and the server refuses independently. Silent
                    // for the same reason 'hold' is silent: the user was never offered the action.
                    return;
                }
                this._promptOverride(row).then((answer) => {
                    // A cancel does nothing and says nothing — the user already knows they cancelled.
                    if (answer && answer.confirmed === true) {
                        this._openInitiateModal(row, true, answer.reason);
                    }
                });
                return;
            }
            this._openInitiateModal(row, false, null);
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('Sell Meter row action failed', error);
            this._toast('Could not complete that action', this._errorText(error, GENERIC_ACTION_ERROR), 'error');
        }
    }

    /**
     * Resolves the button's action name for the clicked row.
     *
     * 🔴 READ THIS BEFORE "SIMPLIFYING" IT BACK TO `event.detail.action.name`.
     *
     * `lightning-datatable` does NOT resolve `fieldName` references inside a column's
     * `typeAttributes` when it builds the `rowaction` event payload — it passes the RAW COLUMN
     * DEFINITION through as `detail.action`. Because the Action column declares
     * `name: { fieldName: 'actionName' }`, `detail.action.name` is the OBJECT
     * `{ fieldName: 'actionName' }`, never the string `'initiate'`. Stringified into the
     * handler's guard it becomes `'[object Object]'`, which matches neither accepted name, so
     * EVERY click returned early and silently.
     *
     * Measured in the live org on 2026-08-20 (Copperfield Town Center, a GREEN row):
     *   detail.action = {"label":{"fieldName":"actionLabel"},"name":{"fieldName":"actionName"},
     *                    "variant":{...},"disabled":{...}}
     *   resolved name = '[object Object]'  →  "Ignored action" → returned
     *
     * ⚠ THIS IS NOT A REDESIGN REGRESSION. The pre-redesign code used the same
     * `!== 'initiate'` guard against the same unresolved payload, so the button had never
     * worked; every disposition in the org was created by a seed script, which is why nobody
     * hit it sooner.
     *
     * `detail.row` IS fully resolved and already carries the per-row `actionName` built in
     * `allRows`, so the row is the reliable source. The `action.name` string branch is kept
     * because a static (non-`fieldName`) column definition — or a future platform version that
     * does resolve typeAttributes — legitimately sends a real string, and that must still win.
     *
     * @param {object} action `event.detail.action`; may be an unresolved column definition
     * @param {object} row    `event.detail.row`; always the resolved row from `allRows`
     * @returns {string|undefined} the action name, or undefined when neither source has one
     */
    _resolveActionName(action, row) {
        const fromAction = action && action.name;
        if (typeof fromAction === 'string' && fromAction) {
            return fromAction;
        }
        return row && row.actionName;
    }

    /**
     * Yellow-band override prompt (Gate 1 Q2 = confirm-then-create), and the capture point for the
     * override REASON since 2026-08-31.
     *
     * Does NOT import c/dealActionGuard: that util imports an Opportunity permission controller at
     * module scope, which would give the Disposition dashboard a hard dependency on an Opportunity
     * gate for ten lines of code. ARCHITECTURE.md §5 already records that the guard utils must not
     * be merged. That reasoning is unchanged by this component gaining a permission wire of its
     * own — `SellMeterController.hasOverrideAccess` is a Disposition-side read.
     *
     * A toast cannot be used here — it is fire-and-forget and returns nothing, so it cannot carry
     * an answer of any kind.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * ⚠ THIS METHOD WAS `_confirmOverride` AND USED `lightning/confirm` UNTIL 2026-08-31.
     * ITS HEADER ENDED WITH A SCOPE DECISION THAT HAS NOW BEEN OVERTURNED. QUOTED, NOT DELETED:
     * ═══════════════════════════════════════════════════════════════════════════════════════
     *     *"What survives is the OTHER half: there is still no override REASON field. The
     *     override is recorded only by this dialog having been answered and by the distinct
     *     success-toast title below, which is a deliberate scope decision, not an oversight."*
     *
     * 🔴 THAT IS NOW FALSE, BY DECISION AND WITH A DATE: Tranche 2 item 5b (stories 12 / 14,
     * confirmed at Gate 1 on 2026-08-31) adds `Disposition__c.Sell_Meter_Override_Reason__c` and
     * makes a reason MANDATORY on this path. `LightningConfirm.open()` resolves
     * `Promise<boolean>` and structurally cannot carry one back, which is why the confirm was
     * replaced by `c/sellMeterOverrideModal` rather than extended.
     *
     * ✅ WHAT SURVIVES THE REPLACEMENT, AND WAS THE REASON FOR CHOOSING A NEW MODAL OVER A
     * TEXTAREA INSIDE `c/sellMeterInitiateModal`:
     *   1. The override question is STILL THE FIRST THING THE USER SEES. Asking it inside the
     *      initiate modal would let them fill in a record type before being told the property is
     *      not at peak.
     *   2. `c/sellMeterInitiateModal` STAYS BYTE-IDENTICAL IN ITS UI on both paths. Its header
     *      records that an override must never look different from an initiate; an override-only
     *      textarea in it would reverse that decision as a side effect of this one. It gains a
     *      pass-through `@api overrideReason` that it renders nowhere.
     *
     * ── THE RESOLVE CONTRACT ────────────────────────────────────────────────
     *   undefined / { confirmed: false }  cancelled or dismissed — do nothing, say nothing
     *   { confirmed: true, reason }       proceed, carrying the principal's typed reason
     * The `.catch` maps a modal-layer failure to a refusal: a prompt that could not be shown has
     * not been answered, and proceeding on a question nobody saw is the one outcome this dialog
     * exists to prevent.
     */
    _promptOverride(row) {
        return SellMeterOverrideModal.open({
            size: 'small',
            label: 'Override the sell meter?',
            description:
                'Confirm that this property should go to market before its peak sell date, and '
                + 'record why.',
            propertyName: row.name
        }).catch((error) => {
            // eslint-disable-next-line no-console
            console.error('Sell Meter override dialog failed to open', error);
            return { confirmed: false };
        });
    }

    /**
     * The single entry point shared by Initiate and Override — deliberately identical apart
     * from the toast title, so an override can never diverge from an initiate.
     *
     * ⚠ THIS REPLACED A DIRECT `DispositionController.findOrCreate` CALL. That method still
     * exists and is deliberately untouched (design §1.4), but it creates WITHOUT a record type
     * choice and WITHOUT submitting an approval, which is no longer what this button means.
     * `initiateAndSubmit` — invoked inside the modal — does both. Do not "simplify" this back
     * into a direct `findOrCreate` call: it would silently create Off-Market-defaulted
     * dispositions that no approval ever sees.
     *
     * All messaging lives HERE rather than in the modal, because a toast raised from inside a
     * modal that is closing in the same tick is a race; this component outlives the modal.
     *
     * ⚠ `overrideReason` IS PASSED THROUGH THE MODAL, NOT RENDERED BY IT (2026-08-31, item 5b).
     * The modal accepts it as an `@api` and forwards it to Apex as the third argument of
     * `initiateAndSubmit`; it appears nowhere in the dialog. That is what keeps the two paths
     * visually identical, which this method's header requires. It is `null` on the Initiate path.
     *
     * @param {object} row the sell-meter row the button was pressed on
     * @param {boolean} isOverride true when the yellow-band override path opened the modal
     * @param {?string} overrideReason the principal's typed reason; null on the Initiate path
     */
    async _openInitiateModal(row, isOverride, overrideReason) {
        let result;
        try {
            result = await SellMeterInitiateModal.open({
                size: 'small',
                label: 'Initiate Disposition',
                description:
                    'Review the property summary, choose On Market or Off Market, and send the disposition for approval.',
                assetId: row.id,
                propertyName: row.name,
                // Pre-formatted by `_toRow` — the modal does no formatting of its own, so the
                // popup and the row it opened from cannot show different numbers.
                noiLabel: row.noiLabel,
                capRateLabel: row.capRateLabel,
                targetLabel: row.targetLabel,
                peakDateLabel: row.peakDateLabel,
                // Carried, not shown. See the note above.
                overrideReason: overrideReason
            });
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('Sell Meter initiate modal failed to open', error);
            // The modal failed to OPEN. Nothing was created and nothing was attempted, so this
            // is not the server-refusal path — say so plainly rather than reusing that wording.
            this._toast('Could not open the initiate dialog', this._errorText(error), 'error');
            return;
        }

        // Cancelled or dismissed: nothing was created, so say nothing.
        if (!result) {
            return;
        }
        if (result.error) {
            // A designed server refusal (the sell-meter gate) arrives as an AuraHandledException
            // whose message is AUTHORED TO BE SHOWN — surface it verbatim rather than replacing
            // it with generic wording. Sticky, because it is the whole answer to the click.
            this._toast('Could not create disposition', this._errorText(result.error), 'error');
            // eslint-disable-next-line no-console
            console.error('Sell Meter initiate failed', result.error);
            return;
        }
        this._handleOutcome(result.outcome, row, isOverride);
    }

    /**
     * Acts on `DispositionService.InitiateOutcome`.
     *
     * 🔴 THE MEMBER NAMES BELOW ARE THE SERVER'S, COPIED VERBATIM FROM
     * `DispositionService.InitiateOutcome`: `dispositionId`, `submitted`, `message`. A Jest
     * fixture DEFINES this payload locally, so a rename on the Apex side leaves this file
     * reading `undefined` with a GREEN suite and a clean deploy. If the Apex DTO changes, this
     * block is the only place to change — keep the mapping in one place for that reason.
     *
     * 🔴 `submitted === false` IS A SUCCESS PATH. `dispositionId` is always populated on a
     * non-throwing return, so the record EXISTS; only the approval submission did not take.
     * Navigate regardless, and let the toast VARIANT carry the difference. Treating false as a
     * failure would tell the user nothing was created about a record that is sitting there.
     */
    _handleOutcome(outcome, row, isOverride) {
        const dispositionId = outcome && outcome.dispositionId;
        if (!dispositionId) {
            // Contractually unreachable — a non-throwing return always carries an Id. Handled
            // anyway so a future contract change surfaces as a message rather than as a
            // navigation to `undefined`.
            this._toast('Could not create disposition', GENERIC_CREATE_ERROR, 'error');
            return;
        }
        const submitted = outcome.submitted === true;
        const property = row.name || 'this property';
        const title = submitted
            ? isOverride
                ? 'Disposition initiated (override)'
                : 'Disposition sent for approval'
            : 'Disposition created — not submitted';
        const fallback = submitted
            ? `Opened the disposition for ${property}.`
            : `The disposition for ${property} was created but could not be submitted for approval.`;
        this._toast(title, outcome.message || fallback, submitted ? 'success' : 'warning');
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: dispositionId, actionName: 'view' }
        });
    }

    /**
     * Extracts user-safe text from a thrown error; never lets `undefined` reach a toast.
     * `fallback` defaults to the create-path wording because that is the overwhelming majority
     * of callers; the row-action catch passes its own, since nothing was created there.
     */
    _errorText(error, fallback = GENERIC_CREATE_ERROR) {
        return (
            (error && error.body && error.body.message) ||
            (error && error.message) ||
            fallback
        );
    }

    /**
     * ⚠ `warning` IS STICKY ALONGSIDE `error`. The created-but-not-submitted toast is the only
     * notice the user gets that an approval still has to be raised by hand; a 3-second
     * auto-dismiss would routinely lose it behind the page navigation that follows it in the
     * same tick.
     */
    _toast(title, message, variant) {
        const sticky = variant === 'error' || variant === 'warning';
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant, mode: sticky ? 'sticky' : 'dismissable' })
        );
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    _fmtM(val) {
        if (val == null) return '—';
        return '$' + (parseFloat(val) / 1000000).toFixed(1) + 'M';
    }

    /**
     * The Sell Meter Score as a multiple: `1.07×` (story 10, 2026-08-31).
     *
     * The value is `impliedValue / targetPrice`, computed SERVER-SIDE in
     * `SellMeterController.PropertyRow.meterScore` and already on the wire — it has been computed
     * and returned and never rendered since the component was built. This adds no query, no field
     * and no FLS grant.
     *
     * ⚠ `×` IS U+00D7 MULTIPLICATION SIGN, NOT THE LETTER `x`. A screen reader announces `×` as
     * "times" and `x` as the letter "ex", so the two are not interchangeable for a value whose
     * whole meaning is "N times the target price". Do not "normalise" it to ASCII.
     *
     * ⚠ ONE DASH COVERS THREE DISTINCT CAUSES, DELIBERATELY. The server returns null when NOI is
     * null, when the market cap rate is null or zero, or when the target price is null or zero.
     * A table cell has no room to distinguish them and the distinction is not actionable from
     * here — the fix in all three cases is to populate the asset. `_fmtM` and the cap-rate
     * formatter already use '—'; a second placeholder would imply a difference that does not
     * exist.
     *
     * ⚠ 2 DECIMALS, NOT 1. This is a ratio around 1.0, so one decimal collapses 1.04 and 1.09
     * into the same displayed number on a screen whose entire purpose is ranking assets against
     * each other.
     */
    _fmtMultiple(val) {
        if (val == null) return '—';
        return parseFloat(val).toFixed(2) + '×';
    }

    // 'YYYY-MM-DD' → 'Aug 12, 2027' (manual parse to avoid timezone shifts).
    _fmtFullDate(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length < 3) return '—';
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return months[parseInt(p[1], 10) - 1] + ' ' + parseInt(p[2], 10) + ', ' + p[0];
    }

    // Time remaining until the peak sell date, as 'Xm Yd' (e.g. '5m 6d'); 'Now' if already at/past peak.
    _countdown(d) {
        if (!d) return '';
        const p = String(d).split('-').map((n) => parseInt(n, 10));
        if (p.length < 3 || p.some(isNaN)) return '';
        const peak = new Date(p[0], p[1] - 1, p[2]);
        const now = new Date();
        now.setHours(0, 0, 0, 0);
        if (peak <= now) return 'Now';
        let months = (peak.getFullYear() - now.getFullYear()) * 12 + (peak.getMonth() - now.getMonth());
        let days = peak.getDate() - now.getDate();
        if (days < 0) {
            months -= 1;
            days += new Date(peak.getFullYear(), peak.getMonth(), 0).getDate(); // days in the month before peak
        }
        return months > 0 ? `${months}m ${days}d` : `${days}d`;
    }
}