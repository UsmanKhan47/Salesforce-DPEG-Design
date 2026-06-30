import { LightningElement, wire } from 'lwc';
import getKpis from '@salesforce/apex/BrokerAssignmentController.getKpis';

export default class BrokerAssignmentKpis extends LightningElement {
    k;
    @wire(getKpis) wired({ data }) { if (data) this.k = data; }
    get cards() {
        const k = this.k || {};
        return [
            { key: 'total',   value: k.total ?? 0,   label: 'Total Assignments', iconName: 'utility:record', iconColor: '#132850' },
            { key: 'active',  value: k.active ?? 0,  label: 'Active Listings',   iconName: 'utility:trending', iconColor: '#198A40' },
            { key: 'overdue', value: k.overdue ?? 0, label: 'Check-in Overdue',  iconName: 'utility:warning', iconColor: '#A06200' },
            { key: 'leased',  value: k.leased ?? 0,  label: 'Fully Leased',      iconName: 'utility:success', iconColor: '#6B6760' }
        ];
    }
}
