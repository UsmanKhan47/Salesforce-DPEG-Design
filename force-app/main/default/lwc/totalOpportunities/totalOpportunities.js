import { LightningElement, wire } from 'lwc';
import getStageCounts from '@salesforce/apex/OpportunityFunnelController.getStageCounts';

// Every Opportunity stage in funnel order, with an icon + accent color per card.
//
// ⚠ `key` is the Opportunity.StageName API VALUE and is the join onto
// OpportunityFunnelController.getStageCounts — `label` is display text only, and the two already
// differ deliberately ('Dead/Pass' renders as 'Dead (Last 90 Days)'). 'Under Contract (PSA)' was
// renamed from 'PSA' (Acquisition Observations phase 2); a stale KEY renders a permanent 0 rather
// than erroring, so it must move with the picklist.
//
// ⚠ The 'Under Contract (PSA)' card's LABEL deliberately drops the '(PSA)' — the card already
// appends '(Last 90 Days)', so carrying the stage value verbatim rendered
// 'Under Contract (PSA) (Last 90 Days)', i.e. two parenthesised groups in a row. This follows the
// same key/label split 'Dead/Pass' -> 'Dead (Last 90 Days)' already uses one row below. The KEY is
// untouched: it is the join and must stay byte-exact.
const STAGE_META = [
    { key: 'New',                 label: 'New',                  iconName: 'utility:add',       color: '#90A4AE' },
    { key: 'Under Review',        label: 'Under Review',         iconName: 'utility:list',      color: '#5C9DED' },
    { key: 'Development Review',   label: 'Development Review',           iconName: 'utility:task',     color: '#7E57C2' },
    { key: 'Construction Review',  label: 'Construction Review',          iconName: 'utility:setup',    color: '#26A69A' },
    { key: 'Underwriting',        label: 'Underwriting',                 iconName: 'utility:money',     color: '#1E88E5' },
    { key: 'LOI',                 label: 'LOI',                          iconName: 'utility:upload',    color: '#42A5F5' },
    { key: 'Under Contract (PSA)', label: 'Under Contract (Last 90 Days)', iconName: 'utility:contract',  color: '#FB8C00' },
    { key: 'Closed Won',          label: 'Closed Won (Last 90 Days)',    iconName: 'utility:favorite',  color: '#43A047' },
    { key: 'Dead/Pass',           label: 'Dead (Last 90 Days)',          iconName: 'utility:close',     color: '#E53935' }
];

export default class TotalOpportunities extends LightningElement {
    data;
    error;

    @wire(getStageCounts)
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
        return (e && e.body && e.body.message) || 'Unable to load opportunities by stage.';
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