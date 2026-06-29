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
    'LOI Submitted':      ['#e9f2fd', '#42A5F5'],
    'LOI Signed':         ['#e4f6f8', '#26C6DA'],
    'Under Contract':     ['#fff1e0', '#FB8C00'],
    'Closed Won':         ['#e8f5e9', '#43A047'],
    'Dead/Pass':          ['#fdeaea', '#E53935'],
    'Portfolio Deal':     ['#efe9e6', '#8D6E63']
};
const DEAL_TYPE = {
    Land:       ['#eaf6ec', '#43A047'],
    Commercial: ['#e8f1fc', '#1565c0']
};
const FALLBACK = ['#eef1f4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Deal Name', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'Stage', fieldName: 'stage', type: 'pill', initialWidth: 150, typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: { fieldName: 'stageDot' } } },
    { label: 'Deal Type', fieldName: 'dealType', type: 'pill', initialWidth: 115, typeAttributes: { wrapStyle: { fieldName: 'dtWrap' }, dotStyle: { fieldName: 'dtDot' } } },
    { label: 'Asking Price', fieldName: 'priceLabel', type: 'text', initialWidth: 120 },
    { label: 'Age', fieldName: 'age', type: 'text', initialWidth: 80 }
];

export default class RecentOpportunities extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    listUrl = '#';

    @wire(getRecentOpportunities)
    wired({ data }) {
        if (data) {
            this.data = data;
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
                priceLabel: r.price != null ? '$' + (r.price / 1000000).toFixed(1) + 'M' : '—',
                age: r.days + 'd'
            };
        });
    }

    get count() {
        return this.rows.length;
    }
}