import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getNotes from '@salesforce/apex/BrokerAssignmentController.getNotes';
import addNote from '@salesforce/apex/BrokerAssignmentController.addNote';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class BrokerAssignmentNotes extends LightningElement {
    @api recordId;
    draft = '';
    saving = false;
    loadError;
    _wired;
    _notes = [];

    @wire(getNotes, { recordId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this._notes = result.data;
            this.loadError = undefined;
        } else if (result.error) {
            this.loadError = (result.error?.body?.message) || 'Couldn\'t load notes.';
            this._notes = [];
        }
    }

    get notes() {
        return this._notes.map((n) => ({
            id: n.id,
            author: n.author || 'Unknown',
            text: n.preview || n.title,
            when: this.fmt(n.createdDate)
        }));
    }
    get count() { return this._notes.length; }
    get hasNotes() { return this._notes.length > 0; }
    get showEmpty() { return !this.loadError && this._notes.length === 0; }
    get cannotPost() { return this.saving || !this.draft || !this.draft.trim(); }

    onDraftChange(event) { this.draft = event.target.value; }

    async postNote() {
        if (this.cannotPost) return;
        this.saving = true;
        try {
            await addNote({ recordId: this.recordId, body: this.draft });
            this.draft = '';
            await refreshApex(this._wired);
        } catch (e) {
            const msg = (e && e.body && e.body.message) || 'Something went wrong saving the note.';
            this.dispatchEvent(new ShowToastEvent({ title: 'Could not add note', message: msg, variant: 'error' }));
        } finally {
            this.saving = false;
        }
    }

    fmt(dt) {
        if (!dt) return '';
        const d = new Date(dt);
        if (isNaN(d.getTime())) return '';
        let h = d.getHours();
        const m = String(d.getMinutes()).padStart(2, '0');
        const ap = h >= 12 ? 'PM' : 'AM';
        h = h % 12 || 12;
        return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} · ${h}:${m} ${ap}`;
    }
}