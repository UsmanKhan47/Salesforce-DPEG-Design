import { LightningElement, wire } from 'lwc';
import getStageCounts from '@salesforce/apex/OpportunityFunnelController.getStageCounts';

// Every Opportunity stage in funnel order, with an icon + accent color per card.
const STAGE_META = [
    { key: 'New',                 label: 'New',                  iconName: 'utility:add',       color: '#90A4AE' },
    { key: 'Under Review',        label: 'Under Review',         iconName: 'utility:list',      color: '#5C9DED' },
    { key: 'Development Review',   label: 'Development Review',           iconName: 'utility:task',     color: '#7E57C2' },
    { key: 'Construction Review',  label: 'Construction Review',          iconName: 'utility:setup',    color: '#26A69A' },
    { key: 'Underwriting',        label: 'Underwriting',                 iconName: 'utility:money',     color: '#1E88E5' },
    { key: 'LOI Submitted',       label: 'LOI Submitted',                iconName: 'utility:upload',    color: '#42A5F5' },
    { key: 'LOI Signed',          label: 'LOI Signed',                   iconName: 'utility:check',     color: '#26C6DA' },
    { key: 'Under Contract',      label: 'Under Contract (Last 90 Days)', iconName: 'utility:contract', color: '#FB8C00' },
    { key: 'Closed Won',          label: 'Closed Won (Last 90 Days)',    iconName: 'utility:favorite',  color: '#43A047' },
    { key: 'Dead/Pass',           label: 'Dead (Last 90 Days)',          iconName: 'utility:close',     color: '#E53935' }
];

export default class TotalOpportunities extends LightningElement {
    data;

    @wire(getStageCounts)
    wired({ data }) {
        if (data) {
            this.data = data;
        }
    }

    get metrics() {
        const counts = {};
        if (this.data) {
            this.data.forEach((s) => {
                counts[s.label] = s.count;
            });
        }
        return STAGE_META.map((m) => ({
            key: m.key,
            displayValue: counts[m.key] != null ? String(counts[m.key]) : '0',
            label: m.label,
            iconName: m.iconName,
            iconColor: m.color
        }));
    }
}