import { LightningElement, wire } from 'lwc';
import { formatMoney } from 'c/utils';
import getMeterSummary from '@salesforce/apex/SellMeterController.getMeterSummary';

export default class SellMeterStats extends LightningElement {
    data;

    @wire(getMeterSummary)
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    get metrics() {
        const s = this.data || {};
        return [
            { key: 'green',  label: 'Sell now',         value: s.green != null ? String(s.green) : '0',   iconName: 'utility:check', iconColor: '#3fae5e' },
            { key: 'yellow', label: 'Getting Close',    value: s.yellow != null ? String(s.yellow) : '0', iconName: 'utility:list',  iconColor: '#c98a33' },
            { key: 'red',    label: 'Hold - Not yet',   value: s.red != null ? String(s.red) : '0',       iconName: 'utility:pause',   iconColor: '#e0556b' },
            { key: 'up',     label: 'Portfolio Upside', value: formatMoney(s.upside),                     iconName: 'utility:money',   iconColor: '#2BAFAC' }
        ];
    }
}