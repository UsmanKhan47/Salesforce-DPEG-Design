import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getActiveTransactions from '@salesforce/apex/TransactionController.getActiveTransactions';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const TASKS_TOTAL = 75;

// [background, dot] per picklist value for the soft status pills.
const STAGE = {
    'Open Contract': ['#e9f1fb', '#4b7fd6'],
    'Due Diligence': ['#f2ecfb', '#7e3fc0'],
    'Closing Prep':  ['#fdf0e1', '#c98a33'],
    'Post-Closing':  ['#eef0f7', '#5b6bb0'],
    'Closed Won':    ['#e9f5ec', '#3fae5e'],
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
        label: 'Tasks (75)', fieldName: 'tasksText', type: 'progress',
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
    listUrl = '#';

    @wire(getActiveTransactions)
    wired({ data }) {
        if (data) {
            this._data = data;
        }
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
            const pct = Math.min(100, Math.round((done / TASKS_TOTAL) * 100));
            const complete = done >= TASKS_TOTAL;
            const [sBg, sDot] = STAGE[t.stage] || FALLBACK;
            const [rBg, rDot] = RISK[t.risk] || FALLBACK;
            return {
                id: t.id,
                name: t.name,
                recordUrl: `/lightning/r/Transaction__c/${t.id}/view`,
                propertyName: t.propertyName || '—',
                stage: t.stage || '—',
                stageWrap: pillWrap(sBg),
                stageDot: pillDot(sDot),
                priceLabel: this.money(t.price),
                targetCloseLabel: this.dateLabel(t.targetClose),
                tasksText: `${done} / ${TASKS_TOTAL}`,
                tasksBar: `width:${pct}%;height:100%;background:${complete ? '#2e7d32' : '#2BAFAC'};border-radius:4px`,
                risk: t.risk || '—',
                riskWrap: pillWrap(rBg),
                riskDot: pillDot(rDot)
            };
        });
    }

    // 'YYYY-MM-DD' → 'Jul 17' (manual parse to avoid timezone shifts).
    dateLabel(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length !== 3) return d;
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + p[2];
    }

    // Currency in $M, one decimal dropped when whole. Decimal serializes as string over the wire.
    money(v) {
        const n = parseFloat(v);
        if (isNaN(n)) return '—';
        const m = n / 1e6;
        return '$' + (m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)) + 'M';
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}