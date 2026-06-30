import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getScorecard from '@salesforce/apex/BrokerAssignmentController.getScorecard';

const BARS = [
    ['active',     '#22A652'],
    ['leased',     '#C8A045'],
    ['replaced',   '#D93636'],
    ['terminated', '#8B1A1A']
];

export default class BrokerScorecard extends NavigationMixin(LightningElement) {
    _data = [];
    error;

    @wire(getScorecard)
    wired({ data, error }) {
        if (data) {
            this._data = data;
        } else if (error) {
            this.error = error;
        }
    }

    initials(name) {
        return (name || '').split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase();
    }

    get cards() {
        return this._data.map(b => {
            const total = b.total || 1;
            const bars = BARS
                .map(([k, c]) => ({
                    key: k,
                    n: b[k] || 0,
                    style: `width:${((b[k] || 0) / total) * 100}%;background:${c};height:100%`
                }))
                .filter(s => s.n > 0);
            return {
                brokerId:   b.brokerId,
                name:       b.name,
                firm:       b.firm,
                initials:   this.initials(b.name),
                active:     b.active     || 0,
                leased:     b.leased     || 0,
                replaced:   b.replaced   || 0,
                terminated: b.terminated || 0,
                total:      b.total      || 0,
                bars
            };
        });
    }

    get hasCards() {
        return this.cards.length > 0;
    }

    viewListings() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Broker_Assignments' }
        });
    }
}
