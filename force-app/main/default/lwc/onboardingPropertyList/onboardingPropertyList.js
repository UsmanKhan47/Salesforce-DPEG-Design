import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getOnboardings from '@salesforce/apex/OnboardingController.getOnboardings';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const STATUS = {
    'On Track':    ['#E2F0EC', '#1A7A6B'],
    'In Progress': ['#FBF1DA', '#D4940A'],
    'At Risk':     ['#FAE6E2', '#C0392B'],
    'Blocked':     ['#FAE6E2', '#C0392B'],
    'Complete':    ['#E2F0EC', '#1A7A6B']
};
const FALLBACK = ['#EEF1F4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:9999px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;
const pctColor = (p) => (p >= 80 ? '#1A7A6B' : p >= 50 ? '#D4940A' : '#C0392B');

const COLUMNS = [
    { label: 'Property', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'propertyName' }, target: '_self' } },
    { label: 'Target', fieldName: 'targetLabel', type: 'text' },
    { label: 'Stage', fieldName: 'stage', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: { fieldName: 'stageDot' } } },
    {
        label: '% Complete', fieldName: 'pctText', type: 'progress',
        typeAttributes: {
            wrapStyle: 'display:flex;align-items:center;gap:10px;min-width:150px',
            trackStyle: 'width:96px;height:8px;background:#ECEBEA;border-radius:9999px;overflow:hidden',
            barStyle: { fieldName: 'pctBar' },
            numStyle: 'color:#3B3B3B;font-weight:700;white-space:nowrap;font-size:12px;font-variant-numeric:tabular-nums',
            text: { fieldName: 'pctText' }
        }
    },
    { label: 'Open', fieldName: 'openTasks', type: 'number', cellAttributes: { alignment: 'center' } },
    { label: 'Status', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } } }
];

export default class OnboardingPropertyList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data;
    listUrl = '#';

    @wire(getOnboardings) wired({ data }) { if (data) this._data = data; }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => { this.listUrl = url; });
    }
    get listPageRef() {
        return { type: 'standard__objectPage', attributes: { objectApiName: 'Onboarding__c', actionName: 'list' } };
    }
    get count() { return this._data ? this._data.length : 0; }
    get rows() {
        if (!this._data) return [];
        return this._data.map((o) => {
            const pct = o.completionPct || 0;
            const [sBg, sDot] = STATUS[o.status] || FALLBACK;
            return {
                id: o.id,
                propertyName: o.propertyName || o.name,
                recordUrl: `/lightning/r/Onboarding__c/${o.id}/view`,
                targetLabel: this.dateLabel(o.targetDate),
                stage: o.stage || '—',
                stageWrap: pillWrap('#EEF1F5'),
                stageDot: pillDot('#1B3A6B'),
                pctText: `${pct}%`,
                pctBar: `width:${pct}%;height:100%;background:${pctColor(pct)};border-radius:9999px`,
                openTasks: o.openTasks,
                status: o.status || '—',
                statusWrap: pillWrap(sBg),
                statusDot: pillDot(sDot)
            };
        });
    }
    dateLabel(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length !== 3) return d;
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + p[2];
    }
    viewAll(event) { event.preventDefault(); this[NavigationMixin.Navigate](this.listPageRef); }
}
