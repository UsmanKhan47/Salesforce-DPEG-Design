import { LightningElement, wire } from 'lwc';
import getAlerts from '@salesforce/apex/BrokerAssignmentController.getAlerts';

const TILES = [
    { key:'overdue', label:'Overdue check-ins', bg:'#FDF0F0', fg:'#8B1A1A', bd:'#F9CECE' },
    { key:'dueSoon', label:'Due for follow-up',  bg:'#FDF5E6', fg:'#7A4A00', bd:'#FAEAC8' },
    { key:'onTrack', label:'On track',           bg:'#EBF9F1', fg:'#146830', bd:'#CCEEDD' },
    { key:'active',  label:'Active listings',    bg:'#E8EFF7', fg:'#1A3464', bd:'#B8CDE8' }
];

export default class BrokerCheckInAlerts extends LightningElement {
    a;
    @wire(getAlerts) wired({ data }) { if (data) this.a = data; }
    get tiles() {
        const a = this.a || {};
        return TILES.map(t => ({
            key: t.key, label: t.label, value: a[t.key] ?? 0,
            tileStyle: `background:${t.bg};border:1px solid ${t.bd};border-radius:6px;padding:12px 14px;color:${t.fg}`
        }));
    }
}
