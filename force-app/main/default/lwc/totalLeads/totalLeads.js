import { LightningElement, wire } from 'lwc';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';

// Stage definitions in funnel order, with the icon + accent color for each count.
// Pipeline stages use line glyphs; the two outcome stages share a matched
// circle-style pair (success / clear) so the set reads as one consistent system.
const STAGE_META = [
    { key: 'New',          label: 'New',                          iconName: 'utility:add',     color: '#90A4AE' },
    { key: 'Under Review', label: 'Under Review',                 iconName: 'utility:list',    color: '#1E88E5' },
    { key: 'Qualified',    label: 'Qualified',                    iconName: 'utility:check',   color: '#2BAFAC' },
    { key: 'Converted',    label: 'Converted (Last 90 Days)',     iconName: 'utility:forward', color: '#43A047' },
    { key: 'Disqualified', label: 'Disqualified (Last 90 Days)',  iconName: 'utility:close',   color: '#E53935' }
];

export default class TotalLeads extends LightningElement {
    data;
    error;

    @wire(getFunnel)
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load leads by stage.';
    }

    get metrics() {
        const counts = {};
        if (this.data) {
            this.data.stages.forEach((s) => {
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