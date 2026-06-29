import { LightningElement, wire } from 'lwc';
import getPipelineSnapshot from '@salesforce/apex/OpportunityFunnelController.getPipelineSnapshot';

export default class OpportunityPipeline extends LightningElement {
    data;

    @wire(getPipelineSnapshot)
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    get stats() {
        const s = this.data || {};
        return [
            { key: 'open',  label: 'Open Deals',       value: s.openDeals != null ? String(s.openDeals) : '0',             iconName: 'utility:opportunity', iconColor: '#1565c0' },
            { key: 'value', label: 'Pipeline Value',    value: this._money(s.pipelineValue),                                iconName: 'utility:money',       iconColor: '#2BAFAC' },
            { key: 'land',  label: 'Land Deals',        value: s.landDeals != null ? String(s.landDeals) : '0',             iconName: 'utility:location',    iconColor: '#43A047' },
            { key: 'comm',  label: 'Commercial Deals',  value: s.commercialDeals != null ? String(s.commercialDeals) : '0', iconName: 'utility:company',     iconColor: '#1565c0' }
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