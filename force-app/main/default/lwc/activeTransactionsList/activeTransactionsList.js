import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getActiveTransactions from '@salesforce/apex/TransactionController.getActiveTransactions';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Rendered wherever a value is genuinely absent — a missing property, an un-fanned-out checklist. */
const EMPTY = '—';

/*
 * 🔴 THERE IS DELIBERATELY NO `TASKS_TOTAL` CONSTANT HERE (removed 2026-08-12).
 *
 * This file used to carry `const TASKS_TOTAL = 75;` and a column literally labelled 'Tasks (75)',
 * while the Transaction record page's `Tasks_Display__c` formula showed `0 / 82`. BOTH numbers were
 * wrong, and no third number would have been right: `TaskFanoutService` writes
 * `Tasks_Total__c = createdForTxn` — the count actually created for THAT Transaction, gated by that
 * Transaction's own condition fields (`Loan_Required__c` and friends, from
 * `Task_Group_Def__mdt.Condition_Field__c`) — so a deal with no loan legitimately gets fewer tasks
 * than one with a loan. The denominator is a PER-ROW fact and is now read per row as
 * `t.tasksTotal`.
 *
 * ⚠ Do not reintroduce a constant "so the bar always has a scale". A row whose checklist has not
 * been fanned out yet has NO denominator, and inventing one would make an unbuilt checklist render
 * as "0 / 75 complete" — a progress bar reporting on work that does not exist.
 */

// [background, dot] per picklist value for the soft status pills.
// ⚠ 'Closed Lost' is a DEAD ENTRY: Transaction__c.Stage__c is a restricted picklist with five
// values and no such value (verified 2026-08-12). Harmless (unmatched stages fall through to
// FALLBACK) and left in place because removing it is unrelated to any reported issue.
// ⚠ RENAMED 2026-08-28 in Setup: the terminal Stage__c value was 'Closed Won' and is now
// 'Closed' (label AND API name). The stale key matched nothing, so the badge fell through to
// FALLBACK grey. Note the RISK map below ALSO has a 'Closed' key — that one is Risk__c, a
// DIFFERENT field; the two maps are never keyed off each other.
const STAGE = {
    'Open Contract': ['#e9f1fb', '#4b7fd6'],
    'Due Diligence': ['#f2ecfb', '#7e3fc0'],
    'Closing Prep':  ['#fdf0e1', '#c98a33'],
    'Post-Closing':  ['#eef0f7', '#5b6bb0'],
    'Closed':        ['#e9f5ec', '#3fae5e'],
    'Closed Lost':   ['#fdeaea', '#e0556b']
};
const RISK = {
    Low:    ['#e9f5ec', '#3fae5e'],
    Watch:  ['#fdf0e1', '#c98a33'],
    High:   ['#fdeaea', '#e0556b'],
    Closed: ['#edf0f4', '#3b5a8c']
};
const FALLBACK = ['#eef1f4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Txn #', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'Property', fieldName: 'propertyName', type: 'text' },
    { label: 'Stage', fieldName: 'stage', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: { fieldName: 'stageDot' } } },
    { label: 'Price', fieldName: 'priceLabel', type: 'text' },
    { label: 'Target Close', fieldName: 'targetCloseLabel', type: 'text' },
    {
        // ⚠ 'Tasks', NOT 'Tasks (N)'. The denominator differs per row (see the note above the
        // STAGE map), so a number in the column HEADER can only ever be right for some rows.
        label: 'Tasks', fieldName: 'tasksText', type: 'progress',
        typeAttributes: {
            wrapStyle: 'display:flex;align-items:center;gap:10px;min-width:160px',
            trackStyle: 'width:110px;height:6px;background:#eef1f4;border-radius:4px;overflow:hidden',
            barStyle: { fieldName: 'tasksBar' },
            numStyle: 'color:#8a96a3;background:#f3f5f7;border-radius:10px;padding:2px 9px;white-space:nowrap;font-size:12px;font-variant-numeric:tabular-nums',
            text: { fieldName: 'tasksText' }
        }
    },
    { label: 'Risk', fieldName: 'risk', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'riskWrap' }, dotStyle: { fieldName: 'riskDot' } } }
];

export default class ActiveTransactionsList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data;
    _error;
    listUrl = '#';

    @wire(getActiveTransactions)
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this._error = undefined;
        } else if (error) {
            this._error = error;
            this._data = undefined;
        }
    }

    get hasError() {
        return !!this._error;
    }
    get errorMessage() {
        return (this._error && this._error.body && this._error.body.message) || 'Unknown error';
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Transaction__c', actionName: 'list' }
        };
    }

    get count() {
        return this._data ? this._data.length : 0;
    }

    get rows() {
        if (!this._data) return [];
        return this._data.map((t) => {
            const done = t.tasksComplete || 0;
            // 🔴 NULL-GUARDED, and `> 0` is doing two jobs at once: it rejects `null`/`undefined`
            // (no fan-out has run, so there is no checklist to measure) AND it rejects 0, which
            // would otherwise divide by zero and yield Infinity/NaN in the width string. A row
            // with no denominator renders '—' and an empty bar rather than a fake 0%.
            const total = t.tasksTotal;
            const hasTotal = typeof total === 'number' && total > 0;
            const pct = hasTotal
                ? Math.min(100, Math.round((done / total) * 100))
                : 0;
            const complete = hasTotal && done >= total;
            const [sBg, sDot] = STAGE[t.stage] || FALLBACK;
            const [rBg, rDot] = RISK[t.risk] || FALLBACK;
            return {
                id: t.id,
                name: t.name,
                recordUrl: `/lightning/r/Transaction__c/${t.id}/view`,
                // Apex now sends the parent Property's name (falling back to the legacy text
                // field); null still means the Transaction genuinely has no Property lookup.
                propertyName: t.propertyName || EMPTY,
                stage: t.stage || EMPTY,
                stageWrap: pillWrap(sBg),
                stageDot: pillDot(sDot),
                priceLabel: this.money(t.price),
                targetCloseLabel: this.dateLabel(t.targetClose),
                tasksText: hasTotal ? `${done} / ${total}` : EMPTY,
                tasksBar: `width:${pct}%;height:100%;background:${complete ? '#2e7d32' : '#2BAFAC'};border-radius:4px`,
                risk: t.risk || EMPTY,
                riskWrap: pillWrap(rBg),
                riskDot: pillDot(rDot)
            };
        });
    }

    // 'YYYY-MM-DD' → 'Jul 17' (manual parse to avoid timezone shifts).
    dateLabel(d) {
        if (!d) return EMPTY;
        const p = String(d).split('-');
        if (p.length !== 3) return d;
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + p[2];
    }

    // Currency in $M, one decimal dropped when whole. Decimal serializes as string over the wire.
    money(v) {
        const n = parseFloat(v);
        if (isNaN(n)) return EMPTY;
        const m = n / 1e6;
        return '$' + (m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)) + 'M';
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}