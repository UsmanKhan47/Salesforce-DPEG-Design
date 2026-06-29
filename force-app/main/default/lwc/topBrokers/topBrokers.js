import { LightningElement, wire } from 'lwc';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

export default class TopBrokers extends LightningElement {
    data;

    @wire(getBrokerHub)
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    get brokers() {
        if (!this.data || !this.data.topBrokers || this.data.topBrokers.length === 0) {
            return [];
        }
        return this.data.topBrokers.map((b, i) => ({
            id: b.id,
            rank: i + 1,
            name: b.name,
            firm: b.firm,
            count: b.activeListings,
            rankClass: 'rank',
            rowClass: i === 0 ? 'row row--lead' : 'row'
        }));
    }

    get hasData() {
        return this.brokers.length > 0;
    }
}