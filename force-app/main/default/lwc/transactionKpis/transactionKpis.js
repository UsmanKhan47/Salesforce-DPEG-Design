import { LightningElement, wire } from 'lwc';
import getKpis from '@salesforce/apex/TransactionController.getKpis';

// Card order, with the icon + accent color for each KPI.
const CARD_META = [
    { key: 'active',     label: 'Active Transactions', iconName: 'utility:contract', color: '#1565c0' },
    { key: 'inContract', label: 'In Contract',         iconName: 'utility:money',    color: '#2BAFAC' },
    { key: 'earnest',    label: 'Earnest at Risk',     iconName: 'utility:warning',  color: '#bf5d0a' },
    { key: 'ttc',        label: 'Avg Time-to-Close',   iconName: 'utility:event',    color: '#5a6b7b' }
];

export default class TransactionKpis extends LightningElement {
    kpis;

    @wire(getKpis)
    wired({ data }) {
        if (data) {
            this.kpis = data;
        }
    }

    get metrics() {
        const k = this.kpis || {};
        const values = {
            active: this.num(k.activeCount),
            inContract: this.moneyWhole(k.inContractValue),
            earnest: this.money(k.earnestAtRisk),
            ttc: this.num(k.avgTimeToCloseDays) + 'd'
        };
        return CARD_META.map((m) => ({
            key: m.key,
            label: m.label,
            iconName: m.iconName,
            iconColor: m.color,
            displayValue: values[m.key]
        }));
    }

    // Plain integer. Falls back to 0 before the wire resolves.
    num(v) {
        return v != null ? String(v) : '0';
    }

    // Large aggregate in whole $M (e.g. In Contract). parseFloat first (Decimal-over-wire is a string).
    moneyWhole(v) {
        const n = parseFloat(v);
        if (isNaN(n) || n === 0) return '$0';
        if (Math.abs(n) >= 1e6) {
            return '$' + Math.round(n / 1e6) + 'M';
        }
        return this.money(v);
    }

    // Currency in $M / $k. Decimals serialize as strings over the wire, so parseFloat first.
    money(v) {
        const n = parseFloat(v);
        if (isNaN(n) || n === 0) return '$0';
        const abs = Math.abs(n);
        if (abs >= 1e6) {
            const m = n / 1e6;
            return '$' + (m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)) + 'M';
        }
        if (abs >= 1e3) {
            const t = n / 1e3;
            return '$' + (t % 1 === 0 ? t.toFixed(0) : t.toFixed(1)) + 'k';
        }
        return '$' + n.toFixed(0);
    }
}