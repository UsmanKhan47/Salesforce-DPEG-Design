import { LightningElement, wire } from 'lwc';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';
import getStageCounts from '@salesforce/apex/OpportunityFunnelController.getStageCounts';

// Combined "Leads by Stage" + "Opportunities by Stage" board. Replaces the
// separate c-total-leads and c-total-opportunities widgets. Data is unchanged:
// LeadFunnelController.getFunnel (lead stage counts) and
// OpportunityFunnelController.getStageCounts (opportunity stage counts).

const LEAD_META = [
    { key: 'New',          label: 'New',          suffix: '',               icon: 'utility:add',     color: '#16A39B' },
    { key: 'Under Review', label: 'Under Review', suffix: '',               icon: 'utility:list',    color: '#2E86DE' },
    { key: 'Qualified',    label: 'Qualified',    suffix: '',               icon: 'utility:check',   color: '#27AE60' },
    { key: 'Converted',    label: 'Converted',    suffix: '(Last 90 Days)', icon: 'utility:forward', color: '#1E8E4E' },
    { key: 'Disqualified', label: 'Disqualified', suffix: '(Last 90 Days)', icon: 'utility:close',   color: '#E0463F' }
];

// Opportunity stages in funnel order. This list now mirrors
// OpportunityFunnelController.STAGE_ORDER one-for-one — the legacy 'Portfolio Deal' stage that this
// list used to exclude by hand was retired at the source (Portfolio Deal rename, Phase A1), so there
// is no longer anything to exclude here.
//
// ⚠ EXACTLY 10 ENTRIES. `oppRowsLeft` is slice(0, 5) and `oppRowsRight` is slice(5, 10), so an
// 11th entry renders NOWHERE — it is silently dropped, not wrapped. Adding a stage means changing
// the column split too. First five render in the left column, last five in the right column.
//
// ⚠ `key` is the Opportunity.StageName API VALUE and is the join onto
// OpportunityFunnelController.getStageCounts — `label` is display text only, and the two are
// already allowed to differ ('Dead/Pass' renders as 'Dead'). 'Under Contract (PSA)' was renamed
// from 'PSA' (Acquisition Observations phase 2); a stale KEY renders a permanent 0 rather than
// erroring, so it must move with the picklist.
//
// ⚠ The 'Under Contract (PSA)' row's LABEL deliberately drops the '(PSA)'. This component renders
// `label` followed by `suffix`, so carrying the stage value verbatim produced
// 'Under Contract (PSA) (Last 90 Days)' — two parenthesised groups in a row. Same key/label split
// as 'Dead/Pass' -> 'Dead' three rows below. The KEY is untouched: it is the join and must stay
// byte-exact. c/totalOpportunities renders the identical string from its own STAGE_META; the two
// were changed together.
const OPP_META = [
    { key: 'New',                 label: 'New',                 suffix: '',               icon: 'utility:add',      color: '#16A39B' },
    { key: 'Under Review',        label: 'Under Review',        suffix: '',               icon: 'utility:list',     color: '#2E86DE' },
    { key: 'Development Review',  label: 'Development Review',   suffix: '',               icon: 'utility:task',     color: '#7E57C2' },
    { key: 'Construction Review', label: 'Construction Review', suffix: '',               icon: 'utility:setup',    color: '#1FA7A0' },
    { key: 'Underwriting',        label: 'Underwriting',        suffix: '',               icon: 'utility:money',    color: '#2E86DE' },
    { key: 'LOI',                 label: 'LOI',                 suffix: '',               icon: 'utility:upload',   color: '#3E8FE0' },
    { key: 'Under Contract (PSA)', label: 'Under Contract',       suffix: '(Last 90 Days)', icon: 'utility:contract', color: '#F08C00' },
    { key: 'About to Close',      label: 'About to Close',      suffix: '',               icon: 'utility:clock',    color: '#E8A33D' },
    { key: 'Closed Won',          label: 'Closed Won',          suffix: '(Last 90 Days)', icon: 'utility:favorite', color: '#27AE60' },
    { key: 'Dead/Pass',           label: 'Dead',                suffix: '(Last 90 Days)', icon: 'utility:close',     color: '#E0463F' }
];

export default class PipelineStageBoard extends LightningElement {
    leadCounts = {};
    oppCounts = {};
    leadError;
    oppError;

    @wire(getFunnel)
    wiredLeads({ data, error }) {
        if (data && data.stages) {
            const c = {};
            data.stages.forEach((s) => { c[s.label] = s.count; });
            this.leadCounts = c;
            this.leadError = undefined;
        } else if (error) {
            this.leadError = error;
        }
    }

    @wire(getStageCounts)
    wiredOpps({ data, error }) {
        if (data) {
            const c = {};
            data.forEach((s) => { c[s.label] = s.count; });
            this.oppCounts = c;
            this.oppError = undefined;
        } else if (error) {
            this.oppError = error;
        }
    }

    get error() {
        return this.leadError || this.oppError;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load the pipeline stage board.';
    }

    buildRows(meta, counts) {
        return meta.map((m) => {
            const count = counts[m.key] || 0;
            return {
                key: m.key,
                label: m.label,
                suffix: m.suffix,
                hasSuffix: !!m.suffix,
                icon: m.icon,
                value: String(count),
                iconStyle: `--slds-c-icon-color-foreground-default:${m.color};--sds-c-icon-color-foreground-default:${m.color}`,
                iconWrapStyle: `background:${m.color}22`,
                valueStyle: `color:${m.color}`
            };
        });
    }

    get leadRows() {
        return this.buildRows(LEAD_META, this.leadCounts);
    }

    get oppRows() {
        return this.buildRows(OPP_META, this.oppCounts);
    }

    get oppRowsLeft() {
        return this.oppRows.slice(0, 5);
    }

    get oppRowsRight() {
        return this.oppRows.slice(5, 10);
    }

    get leadTotal() {
        return LEAD_META.reduce((sum, m) => sum + (this.leadCounts[m.key] || 0), 0);
    }

    get oppTotal() {
        return OPP_META.reduce((sum, m) => sum + (this.oppCounts[m.key] || 0), 0);
    }
}