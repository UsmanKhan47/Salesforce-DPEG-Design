import { LightningElement, wire } from 'lwc';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

// The four header KPI cards, each with its icon + accent color.
const CARD_META = [
    { key: 'totalFirms',     label: 'Total Broker Firms', iconName: 'utility:company', color: '#1565c0' },
    { key: 'totalBrokers',   label: 'Total Brokers',      iconName: 'utility:people',  color: '#2BAFAC' },
    { key: 'activeListings', label: 'Active Listings',    iconName: 'utility:home',     color: '#B968C9' },
    { key: 'offersReceived', label: 'Offers Received',    iconName: 'utility:summary',  color: '#5DA8EC' }
];

export default class BrokerStats extends LightningElement {
    data;

    @wire(getBrokerHub)
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    get metrics() {
        const s = (this.data && this.data.stats) || {};
        return CARD_META.map((m) => {
            const raw = s[m.key];
            return {
                key: m.key,
                displayValue: raw != null ? String(raw) : '0',
                label: m.label,
                iconName: m.iconName,
                iconColor: m.color
            };
        });
    }
}