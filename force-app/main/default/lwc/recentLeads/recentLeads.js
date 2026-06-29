import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';

// [background, dot] per stage / confidence level for the soft pills.
const STAGE = {
    New:            ['#eceff1', '#90A4AE'],
    'Under Review': ['#e8f1fc', '#1E88E5'],
    Qualified:      ['#e6f5f4', '#2BAFAC'],
    Converted:      ['#e8f5e9', '#43A047'],
    Disqualified:   ['#fdeaea', '#E53935']
};
const CONF = {
    high:   ['#e6f4ea', '#2e7d32', 'High'],
    medium: ['#fff4e0', '#b8731b', 'Medium'],
    low:    ['#fde8e8', '#c62828', 'Low'],
    na:     ['#eceff1', '#90a4ae', 'N/A']
};
const CHANNEL_ICON = {
    'Email-to-Lead': 'utility:file',
    'Broker Portal': 'utility:user',
    'Manual Entry':  'utility:edit'
};
const FALLBACK = ['#eef1f4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Deal Name', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'Stage', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: { fieldName: 'stageDot' } } },
    { label: 'Channel', fieldName: 'channel', type: 'text', cellAttributes: { iconName: { fieldName: 'channelIcon' }, iconPosition: 'left' } },
    { label: 'Data Completeness', fieldName: 'confidence', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'confWrap' }, dotStyle: { fieldName: 'confDot' } } },
    { label: 'Broker', fieldName: 'broker', type: 'text' },
    { label: 'Age', fieldName: 'days', type: 'text' }
];

export default class RecentLeads extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    listUrl = '#';

    @wire(getFunnel)
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
            const confKey = r.confidence ? r.confidence.toLowerCase() : 'na';
            const [cBg, cDot, cLabel] = CONF[confKey] || CONF.na;
            const known = r.broker && r.broker !== 'Unknown';
            return {
                id: r.id,
                recordUrl: `/lightning/r/Lead/${r.id}/view`,
                name: r.name,
                status: r.status,
                stageWrap: pillWrap(sBg),
                stageDot: pillDot(sDot),
                channel: r.channel,
                channelIcon: CHANNEL_ICON[r.channel] || 'utility:record',
                confidence: cLabel,
                confWrap: pillWrap(cBg),
                confDot: pillDot(cDot),
                broker: known ? r.broker : 'Unknown',
                days: r.days + 'd'
            };
        });
    }

    get count() {
        return this.rows.length;
    }
}