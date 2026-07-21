import { LightningElement, wire } from 'lwc';
import getBrokerHub from '@salesforce/apex/BrokerController.getBrokerHub';

export default class TopBrokers extends LightningElement {
    data;
    error;

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

    get hasError() {
        return !!this.error && !this.hasData;
    }

    // Empty only when the wire genuinely returned no brokers — not when it errored.
    get isEmpty() {
        return !this.hasData && !this.hasError;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }
}