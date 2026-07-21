import { LightningElement, api, wire } from 'lwc';
import getActivity from '@salesforce/apex/WorkOrderController.getActivity';

const KIND_META = {
    Sync:   { fg: '#5A5752', bg: '#EDEBE7' },
    Status: { fg: '#1A3464', bg: '#E8EFF7' },
    Vendor: { fg: '#9A4B00', bg: '#FDF2E7' },
    Note:   { fg: '#132850', bg: '#E8EFF7' },
    Flag:   { fg: '#1A4880', bg: '#EBF3FC' }
};
const badge = (kind) => {
    const x = KIND_META[kind] || KIND_META.Note;
    return `display:inline-flex;align-items:center;font-size:10px;font-weight:700;letter-spacing:0.03em;text-transform:uppercase;padding:2px 7px;border-radius:9999px;background:${x.bg};color:${x.fg}`;
};

// Read-only activity/status history on the Work Order record page. History arrives
// with the nightly Yardi sync — there is no compose box.
export default class WorkOrderTimeline extends LightningElement {
    @api recordId;
    view;
    error;

    @wire(getActivity, { workOrderId: '$recordId' })
    wired({ data, error }) {
        if (data) { this.view = data; this.error = undefined; }
        else if (error) { this.error = error; }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load activity history.';
    }

    get count() { return this.view && this.view.entries ? this.view.entries.length : 0; }
    get untouched() { return !!(this.view && this.view.untouched); }
    get hasEntries() { return this.count > 0; }

    get entries() {
        const rows = (this.view && this.view.entries) || [];
        return rows.map((e, i) => ({
            id: e.id,
            detail: e.detail,
            actor: e.actor || 'Yardi',
            kind: e.kind || 'Note',
            kindStyle: badge(e.kind),
            entryDate: e.entryDate,
            isLatest: i === 0,
            showLine: i < rows.length - 1,
            markerClass: i === 0 ? 'wot-marker wot-marker--latest' : 'wot-marker'
        }));
    }
}