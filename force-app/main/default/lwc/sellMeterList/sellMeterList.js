import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';
import findOrCreate from '@salesforce/apex/DispositionController.findOrCreate';

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
    { label: 'Property', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'NOI', fieldName: 'noiLabel', type: 'text' },
    { label: 'Mkt Cap', fieldName: 'capRateLabel', type: 'text' },
    { label: 'Target Price', fieldName: 'targetLabel', type: 'text' },
    { label: 'Peak Sell Date', fieldName: 'peakDateLabel', type: 'text' },
    { label: 'Projected Value at Peak', fieldName: 'peakValueLabel', type: 'text' },
    { label: 'Sell Meter', fieldName: 'sellMeter', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'meterWrap' }, dotStyle: { fieldName: 'meterDot' } } },
    {
        label: 'Action', type: 'button', initialWidth: 130,
        typeAttributes: {
            label: { fieldName: 'actionLabel' },
            name: { fieldName: 'actionName' },
            variant: { fieldName: 'actionVariant' },
            disabled: { fieldName: 'actionDisabled' }
        }
    }
];

export default class SellMeterList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data;
    _page = 1;
    listUrl = '#';
    error;

    @wire(getPortfolio)
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
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

    // Full sorted + formatted list; the visible page is sliced from this in `rows`.
    get allRows() {
        if (!this._data) return [];
        const sorted = [...this._data].sort(
            (a, b) => (METER_ORDER[a.sellMeter] ?? 3) - (METER_ORDER[b.sellMeter] ?? 3)
        );
        // Holds (RED) sort last, so they'd never appear on page 1. Pull the first Hold up into
        // the last visible slot of page 1 so the opening screen showcases all three states.
        if (!sorted.slice(0, PAGE_SIZE).some((r) => r.sellMeter === 'RED')) {
            const idx = sorted.findIndex((r) => r.sellMeter === 'RED');
            if (idx >= PAGE_SIZE) {
                const [hold] = sorted.splice(idx, 1);
                sorted.splice(PAGE_SIZE - 1, 0, hold);
            }
        }
        return sorted.map((r) => {
            const meter = r.sellMeter || 'RED';
            const [bg, dot, label, textColor, weight] = METER[meter] || METER.RED;
            const countdown = this._countdown(r.peakSellDate);
            return {
                id: r.id,
                name: r.name,
                recordUrl: `/lightning/r/Property_Asset__c/${r.id}/view`,
                noiLabel: this._fmtM(r.noi),
                capRateLabel: r.mktCapRate != null ? parseFloat(r.mktCapRate).toFixed(1) + '%' : '—',
                targetLabel: this._fmtM(r.targetPrice),
                peakDateLabel: this._fmtFullDate(r.peakSellDate),
                peakValueLabel: this._fmtM(r.projectedValueAtPeak),
                sellMeter: countdown ? `${label} | ${countdown}` : label,
                meterWrap: pillWrap(bg, textColor, weight),
                meterDot: pillDot(dot),
                actionLabel: meter === 'GREEN' ? 'Initiate' : (meter === 'YELLOW' ? 'Override' : 'Hold'),
                actionName: meter === 'GREEN' ? 'initiate' : (meter === 'YELLOW' ? 'override' : 'hold'),
                actionVariant: meter === 'GREEN' ? 'brand' : (meter === 'YELLOW' ? 'neutral' : 'base'),
                actionDisabled: meter === 'RED'
            };
        });
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

    handleRowAction(event) {
        const action = event.detail && event.detail.action;
        if (!action || action.name !== 'initiate') {
            return;
        }
        const row = event.detail.row || {};
        const assetId = row.id;
        if (!assetId) {
            this._toast('Could not initiate', 'No property asset is linked to this row.', 'error');
            return;
        }
        findOrCreate({ assetId })
            .then((dispId) => {
                this._toast('Disposition ready', `Opened the disposition for ${row.name || 'this property'}.`, 'success');
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: { recordId: dispId, actionName: 'view' }
                });
            })
            .catch((error) => {
                const msg =
                    (error && error.body && error.body.message) ||
                    (error && error.message) ||
                    'Unexpected error creating the disposition.';
                this._toast('Could not create disposition', msg, 'error');
                // eslint-disable-next-line no-console
                console.error('Sell Meter initiate failed', error);
            });
    }

    _toast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant, mode: variant === 'error' ? 'sticky' : 'dismissable' })
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