import { LightningElement, api, wire } from 'lwc';
import getBrokerFirm from '@salesforce/apex/BrokerFirmController.getBrokerFirm';

// Opportunity sidebar card: the brokerage firm behind the deal, the broker
// contact, and firm-level deal counts (submitted / won / lost).
export default class BrokerFirmCard extends LightningElement {
    @api recordId;
    data;

    @wire(getBrokerFirm, { opportunityId: '$recordId' })
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    get hasFirm() {
        return this.data && this.data.hasFirm;
    }
    get firmName() {
        return (this.data && this.data.firmName) || '—';
    }
    get heading() {
        return this.hasFirm ? `Brokerage Firm - ${this.firmName}` : 'Brokerage Firm';
    }
    get dealsSubmitted() {
        return this.data ? this.data.dealsSubmitted : 0;
    }
    get dealsWon() {
        return this.data ? this.data.dealsWon : 0;
    }
    get dealsLost() {
        return this.data ? this.data.dealsLost : 0;
    }
}