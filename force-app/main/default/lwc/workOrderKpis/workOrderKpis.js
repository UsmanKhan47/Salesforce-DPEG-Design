import { LightningElement, wire } from 'lwc';
import getHomeKpis from '@salesforce/apex/WorkOrderController.getHomeKpis';

// Top KPI strip on the Work Orders home page.
export default class WorkOrderKpis extends LightningElement {
    k;
    error;
    @wire(getHomeKpis) wired({ data, error }) {
        if (data) { this.k = data; this.error = undefined; }
        else if (error) { this.error = error; }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load work order KPIs.';
    }

    get cards() {
        const k = this.k || {};
        return [
            { key: 'open',      value: k.open ?? 0,      label: 'Open Work Orders', iconName: 'utility:wrench',   iconColor: '#7A9ED4' },
            { key: 'breached',  value: k.breached ?? 0,  label: 'Breached SLA',     iconName: 'utility:warning',  iconColor: '#E58A8A' },
            { key: 'dueSoon',   value: k.dueSoon ?? 0,   label: 'Due Soon',         iconName: 'utility:clock',    iconColor: '#D8BE72' },
            { key: 'untouched', value: k.untouched ?? 0, label: 'Untouched',        iconName: 'utility:preview',  iconColor: '#B39DDB' }
        ];
    }
}