import { LightningElement, wire } from 'lwc';
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
            { key: 'up',     label: 'Portfolio Upside', value: this._money(s.upside),                     iconName: 'utility:money',   iconColor: '#2BAFAC' }
        ];
    }

    _money(n) {
        const v = Number(n);
        if (!isFinite(v) || v === 0) {
            return '$0';
        }
        if (Math.abs(v) >= 1000000) {
            return '$' + (v / 1000000).toFixed(1) + 'M';
        }
        if (Math.abs(v) >= 1000) {
            return '$' + Math.round(v / 1000) + 'K';
        }
        return '$' + v;
    }
}