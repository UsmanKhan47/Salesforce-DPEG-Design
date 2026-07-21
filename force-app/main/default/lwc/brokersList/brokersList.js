import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

// [background, dot] per broker status for the soft pills.
const STATUS = {
    Active:   ['#e8f5e9', '#43A047'],
    Inactive: ['#eceff1', '#90A4AE']
};
const FALLBACK = ['#eef1f4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

function fmtMoney(n) {
    if (n == null) {
        return '—';
    }
    if (n >= 1000000) {
        return '$' + (n / 1000000).toFixed(n >= 10000000 ? 0 : 1) + 'M';
    }
    if (n >= 1000) {
        return '$' + Math.round(n / 1000) + 'K';
    }
    return '$' + n;
}

const COLUMNS = [
    { label: 'Broker', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' } },
    { label: 'Firm', fieldName: 'firm', type: 'text' },
    { label: 'Active Listings', fieldName: 'activeListings', type: 'text' },
    { label: 'Offers', fieldName: 'offers', type: 'text' },
    { label: 'Closed Volume', fieldName: 'volumeLabel', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } } }
];

export default class BrokersList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    error;
    listUrl = '#';

    @wire(getBrokerHub)
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
            attributes: { objectApiName: 'Contact', actionName: 'list' },
            state: { filterName: '__Recent' }
        };
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    get rows() {
        if (!this.data || !this.data.brokers) {
            return [];
        }
        // Show only the top 5 (sorted by closed volume); the rest are reachable via View All.
        return this.data.brokers.slice(0, 5).map((b) => {
            const [bg, dot] = STATUS[b.status] || FALLBACK;
            return {
                id: b.id,
                recordUrl: `/lightning/r/Contact/${b.id}/view`,
                name: b.name,
                firm: b.firm || '—',
                activeListings: String(b.activeListings),
                offers: String(b.offers),
                volumeLabel: fmtMoney(b.closedVolume),
                status: b.status,
                statusWrap: pillWrap(bg),
                statusDot: pillDot(dot)
            };
        });
    }

    get count() {
        return this.data && this.data.brokers ? this.data.brokers.length : 0;
    }
}