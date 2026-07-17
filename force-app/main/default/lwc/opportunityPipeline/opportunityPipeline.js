import { LightningElement, wire } from 'lwc';
import { formatMoney } from 'c/utils';
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
            { key: 'value', label: 'Pipeline Value',    value: formatMoney(s.pipelineValue),                                iconName: 'utility:money',       iconColor: '#2BAFAC' },
            { key: 'land',  label: 'Land Deals',        value: s.landDeals != null ? String(s.landDeals) : '0',             iconName: 'utility:location',    iconColor: '#43A047' },
            { key: 'comm',  label: 'Commercial Deals',  value: s.commercialDeals != null ? String(s.commercialDeals) : '0', iconName: 'utility:company',     iconColor: '#1565c0' }
        ];
    }
}