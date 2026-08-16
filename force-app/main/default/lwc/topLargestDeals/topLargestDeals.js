import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTopDeals from '@salesforce/apex/TopDealsController.getTopDeals';

/**
 * topLargestDeals — the "Top 5 Largest Deals" home-page card (FSD §24.2: *the five biggest
 * active deals, any stage except Closed*).
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS IS NOT `c/recentOpportunities`, AND MERGING THEM WOULD BE A REGRESSION
 * ═════════════════════════════════════════════════════════════════════════════
 * `c/recentOpportunities` sits on the SAME home page and also shows five deals. They are
 * deliberately separate because they rank on different facts:
 *
 *   c/recentOpportunities   ranks by `Asking_Price__c`  — what the SELLER wants.
 *   c/topLargestDeals (this) ranks by `Amount`          — what the DEAL is worth to DPEG.
 *
 * The tranche-2 design proposed closing §24.2 by adding a stage filter to
 * `recentOpportunities` and relabelling it. **THAT WAS OVERRULED BY THE USER (2026-08-16)**
 * — `recentOpportunities`, its controller method and its selector method are UNTOUCHED.
 *
 * ⇒ Do NOT re-point this component's wire at `OpportunityFunnelController`, and do NOT
 *   "de-duplicate" the two cards. Either change makes this a second copy of a card the page
 *   already carries. `TopDealsControllerTest.ranksOnAmountAndNotOnAskingPrice` is the
 *   server-side falsifier; the `ORDER` test below is the client-side one.
 *
 * ⚠ A SEPARATE CARD IS NOT THE SAME MISTAKE AS `c/transactionAdvanceStage`. ARCHITECTURE.md
 * §5 records that bundle being created and deleted the same day for being byte-identical to
 * an existing one below the comments. This one DIFFERS in the fact it ranks on, in its Apex
 * wire, in its columns (Amount and Close Date, where the other has Asking Price and NOI)
 * and in the question it answers. That is a genuine split, not a copy with a new header.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * ERROR HANDLING — an inline banner, not a toast
 * ═════════════════════════════════════════════════════════════════════════════
 * `TopDealsController` throws `AuraHandledException` with a fixed, user-safe message
 * (ARCHITECTURE.md §5), so `error.body.message` is the actionable text and the Apex-path
 * reader is the correct one here. It is rendered INLINE with `role="alert"` rather than as
 * a toast: this card is passive page furniture the user did not click, so a toast would
 * appear unprompted and then vanish, leaving a permanently empty card with no explanation.
 *
 * 🔴 THE MOST LIKELY REAL-WORLD ERROR IS AN FLS GAP ON `Opportunity.Amount`, which is
 * granted by NO permission set in this repo as at 2026-08-16. The selector is
 * `WITH USER_MODE` on purpose (this backs a read a human asked for), and USER_MODE throws on
 * the WHOLE ROW for ONE inaccessible field — so the whole card fails rather than showing a
 * blank column. That is the intended, LOUD posture; the fix is a permission-set grant.
 *
 * ⚠ THE ERROR BRANCH KEEPS THE COUNT AT ZERO AND HIDES THE TABLE. An error state that still
 * rendered the last-known rows would assert a ranking the server just refused to confirm.
 */

// [background, dot] per stage / deal type for the soft pills.
// Keys are Opportunity.StageName VALUES, not labels — a miss falls through to FALLBACK, so a
// stale key here degrades to a grey pill rather than an error.
// ⚠ 'Closed Won' and 'Dead/Pass' are deliberately ABSENT: the server excludes them, so a key
// for either would be unreachable styling that quietly implies this card can show them.
const STAGE = {
    New: ['#eceff1', '#90A4AE'],
    'Under Review': ['#e8f1fc', '#5C9DED'],
    'Development Review': ['#efe9f7', '#7E57C2'],
    'Construction Review': ['#e3f4f2', '#26A69A'],
    Underwriting: ['#e8f1fc', '#1E88E5'],
    LOI: ['#e9f2fd', '#42A5F5'],
    'Under Contract (PSA)': ['#fff1e0', '#FB8C00'],
    'About to Close': ['#e8f5e9', '#66BB6A'],
    'Portfolio Deal': ['#efe9e6', '#8D6E63']
};

// Keys are Deal_Type__c VALUES, not labels — a miss falls through to FALLBACK.
const DEAL_TYPE = {
    Land: ['#eaf6ec', '#43A047'],
    Retail: ['#e8f1fc', '#1565c0']
};

const FALLBACK = ['#eef1f4', '#94a3b8'];

const pillWrap = (bg) =>
    `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) =>
    `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    {
        label: 'Deal Name',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    {
        label: 'Stage',
        fieldName: 'stage',
        type: 'pill',
        initialWidth: 160,
        typeAttributes: {
            wrapStyle: { fieldName: 'stageWrap' },
            dotStyle: { fieldName: 'stageDot' }
        }
    },
    {
        label: 'Deal Type',
        fieldName: 'dealType',
        type: 'pill',
        initialWidth: 115,
        typeAttributes: {
            wrapStyle: { fieldName: 'dtWrap' },
            dotStyle: { fieldName: 'dtDot' }
        }
    },
    { label: 'Amount', fieldName: 'amountLabel', type: 'text', initialWidth: 120 },
    { label: 'Close Date', fieldName: 'closeDateLabel', type: 'text', initialWidth: 120 },
    { label: 'Age', fieldName: 'age', type: 'text', initialWidth: 80 }
];

/**
 * $1.2M / $850K / $0 — compact currency, matching the sibling deal cards on this page.
 *
 * ⚠ A null renders as an em dash, NOT as `$0`. An amount-less deal is one nobody has costed
 * yet; `$0` would assert it is worth nothing, which is a different and wrong claim. The
 * server sorts nulls last for the same reason.
 */
const money = (n) => {
    if (n === null || n === undefined) {
        return '—';
    }
    if (Math.abs(n) >= 1000000) {
        return '$' + (n / 1000000).toFixed(1) + 'M';
    }
    if (Math.abs(n) >= 1000) {
        return '$' + Math.round(n / 1000) + 'K';
    }
    return '$' + n;
};

/**
 * The Apex `Date` arrives as an ISO `yyyy-MM-dd` string.
 *
 * ⚠ It is rendered VERBATIM rather than through `new Date(...).toLocaleDateString()`.
 * Parsing a bare ISO date in JS treats it as UTC midnight and then renders it in the
 * browser's local zone, which shifts the displayed day backwards for every user west of
 * GMT — a close date that silently reads as the day before. Passing the string through has
 * no timezone surface at all.
 */
const isoDate = (value) => (value ? String(value) : '—');

export default class TopLargestDeals extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    error;
    listUrl = '#';

    @wire(getTopDeals)
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
        return (
            (e && e.body && e.body.message) ||
            'Unable to load the largest deals.'
        );
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Opportunity', actionName: 'list' },
            state: { filterName: 'All_Deals' }
        };
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    /**
     * ⚠ NO CLIENT-SIDE `slice` AND NO CLIENT-SIDE SORT. The server already applies
     * `ORDER BY Amount DESC NULLS LAST` and `LIMIT 5`, so re-imposing either here would put
     * a second, drifting copy of the ranking rule in JS — and a client sort would silently
     * reorder rows the server deliberately ordered by a tiebreak (`CreatedDate DESC`) this
     * component cannot see.
     */
    get rows() {
        if (!this.data) {
            return [];
        }
        return this.data.map((r) => {
            const [sBg, sDot] = STAGE[r.stage] || FALLBACK;
            const [dBg, dDot] = DEAL_TYPE[r.dealType] || FALLBACK;
            return {
                id: r.id,
                recordUrl: `/lightning/r/Opportunity/${r.id}/view`,
                name: r.name,
                stage: r.stage,
                stageWrap: pillWrap(sBg),
                stageDot: pillDot(sDot),
                dealType: r.dealType || '—',
                dtWrap: pillWrap(dBg),
                dtDot: pillDot(dDot),
                amountLabel: money(r.amount),
                closeDateLabel: isoDate(r.closeDate),
                age: r.days + 'd'
            };
        });
    }

    get count() {
        return this.rows.length;
    }
}
