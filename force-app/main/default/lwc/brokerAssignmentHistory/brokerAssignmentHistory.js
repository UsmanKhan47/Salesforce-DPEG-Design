import { LightningElement, api, wire } from 'lwc';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
// Notes longer than this are truncated inline (~half a row) and get a "View" button.
const NOTE_PREVIEW = 60;

export default class BrokerAssignmentHistory extends LightningElement {
    @api recordId;
    d;

    @wire(getDetail, { assignmentId: '$recordId' })
    wired(result) {
        if (result.data) {
            this.d = result.data;
        }
    }

    fmt(v) {
        if (!v) return '—';
        const p = String(v).split('-').map(Number);
        return `${MONTHS[p[1] - 1]} ${p[2]}, ${p[0]}`;
    }

    get hasData() { return !!this.d; }
    get propertyName() { return (this.d && this.d.propertyName) || '—'; }
    get historyIntro() { return `Every broker ever assigned to ${this.propertyName} — nothing is deleted.`; }

    get historyRows() {
        const rows = [...((this.d && this.d.history) || [])];
        // Active rows first, then the rest by startDate descending (most recent next).
        rows.sort((a, b) => {
            const aActive = a.status === 'Active' ? 0 : 1;
            const bActive = b.status === 'Active' ? 0 : 1;
            if (aActive !== bActive) return aActive - bActive;
            return String(b.startDate || '').localeCompare(String(a.startDate || ''));
        });
        return rows.map((h) => {
            const notes = h.notes || '';
            const notesLong = notes.length > NOTE_PREVIEW;
            return {
                id: h.id,
                brokerName: h.brokerName || '—',
                brokerFirm: h.brokerFirm || '—',
                isActive: h.status === 'Active',
                hasNotes: !!notes,
                notesPreview: notesLong ? `${notes.slice(0, NOTE_PREVIEW).trimEnd()}…` : notes,
                notesLong,
                notesClass: notesLong ? 'ba-histnotes ba-histnotes--clip' : 'ba-histnotes',
                hasReason: !!h.reason,
                reasonDisp: h.reason ? `Reason: ${h.reason}` : '',
                rangeDisp: `${this.fmt(h.startDate)} → ${h.endDate ? this.fmt(h.endDate) : 'present'}`,
                rowClass: h.status === 'Active' ? 'ba-histrow ba-histrow--active' : 'ba-histrow'
            };
        });
    }

    // ----- full-note popup (mirrors the transaction checklist "View" dialog) -----
    _note = {};
    get showNoteModal() { return !!this._note.open; }
    get noteText() { return this._note.text || ''; }
    get noteBroker() { return this._note.broker || ''; }
    openNote(event) {
        const id = event.currentTarget.dataset.id;
        const row = ((this.d && this.d.history) || []).find((h) => h.id === id);
        if (row) this._note = { open: true, text: row.notes || '', broker: row.brokerName || '' };
    }
    closeNote() { this._note = {}; }
}
