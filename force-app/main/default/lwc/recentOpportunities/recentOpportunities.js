import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRecentOpportunities from '@salesforce/apex/OpportunityFunnelController.getRecentOpportunities';

// [background, dot] per stage / deal type for the soft pills.
const STAGE = {
    New:                  ['#eceff1', '#90A4AE'],
    'Under Review':       ['#e8f1fc', '#5C9DED'],
    'Development Review':  ['#efe9f7', '#7E57C2'],
    'Construction Review': ['#e3f4f2', '#26A69A'],
    Underwriting:         ['#e8f1fc', '#1E88E5'],
    LOI:                  ['#e9f2fd', '#42A5F5'],
    PSA:                  ['#fff1e0', '#FB8C00'],
    'Closed Won':         ['#e8f5e9', '#43A047'],
    'Dead/Pass':          ['#fdeaea', '#E53935'],
    'Portfolio Deal':     ['#efe9e6', '#8D6E63']
};
// Keys are Deal_Type__c VALUES, not labels — a miss falls through to FALLBACK, so a stale key
// here degrades to a grey pill rather than an error. 'Retail' (was 'Commercial') moved with the
// Deal Type migration, phase 1 D3.
const DEAL_TYPE = {
    Land:   ['#eaf6ec', '#43A047'],
    Retail: ['#e8f1fc', '#1565c0']
};
const FALLBACK = ['#eef1f4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Deal Name', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'Stage', fieldName: 'stage', type: 'pill', initialWidth: 150, typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: { fieldName: 'stageDot' } } },
    { label: 'Deal Type', fieldName: 'dealType', type: 'pill', initialWidth: 115, typeAttributes: { wrapStyle: { fieldName: 'dtWrap' }, dotStyle: { fieldName: 'dtDot' } } },
    { label: 'Asking Price', fieldName: 'priceLabel', type: 'text', initialWidth: 120 },
    { label: 'NOI', fieldName: 'noiLabel', type: 'text', initialWidth: 110 },
    { label: 'Age', fieldName: 'age', type: 'text', initialWidth: 80 }
];

// $1.2M / $850K / $0 — compact currency for the Asking Price and NOI columns.
const money = (n) => {
    if (n == null) {
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

export default class RecentOpportunities extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    error;
    listUrl = '#';

    @wire(getRecentOpportunities)
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
        return (e && e.body && e.body.message) || 'Unable to load recent opportunities.';
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
        return this.data.slice(0, 5).map((r) => {
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
                priceLabel: money(r.price),
                noiLabel: money(r.noi),
                age: r.days + 'd'
            };
        });
    }

    get count() {
        return this.rows.length;
    }
}