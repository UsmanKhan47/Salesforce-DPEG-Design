import { LightningElement, wire } from 'lwc';
import getKpis from '@salesforce/apex/BrokerAssignmentController.getKpis';

export default class BrokerAssignmentKpis extends LightningElement {
    k;
    @wire(getKpis) wired({ data }) { if (data) this.k = data; }
    get cards() {
        const k = this.k || {};
        return [
            { key: 'total',  value: k.total ?? 0, label: 'Total Assignments / Active', iconName: 'utility:list', iconColor: '#132850' },
            { key: 'stale',  value: k.stale ?? 0,  label: 'Stale',        iconName: 'utility:warning', iconColor: '#A06200' },
            { key: 'leased', value: k.leased ?? 0, label: 'Fully Leased', iconName: 'utility:success', iconColor: '#6B6760' }
        ];
    }
}
