import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';
import completeTask from '@salesforce/apex/OnboardingController.completeTask';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const FILTERS = ['All','In Progress','Not Applicable','Overdue'];

const ownerShort = (n) => !n ? '' : (n === 'Accounting Queue' ? 'Accounting' : n.split(' ')[0]);

export default class OnboardingChecklist extends LightningElement {
    @api recordId;
    groups = [];
    selectedIndex = 0;
    filter = 'All';
    _wire;
    _confirm = {};
    _saving = false;

    @wire(getChecklist, { onboardingId: '$recordId' })
    wired(result) { this._wire = result; if (result.data) this.groups = result.data; }

    get tiles() {
        return this.groups.map((g, i) => {
            const sel = i === this.selectedIndex;
            const pct = g.total ? Math.round((100 * g.complete) / g.total) : 0;
            const complete100 = g.total > 0 && g.complete >= g.total;
            return {
                key: g.category, letter: String.fromCharCode(65 + i), name: g.category,
                count: `${g.complete} / ${g.total}`, index: String(i), complete100,
                ringStyle: `--ring:${complete100 ? '#2e7d32' : '#1565c0'};--pct:${pct}%`,
                chipClass: sel ? 'oc-gchip oc-gchip--active' : 'oc-gchip'
            };
        });
    }
    get chips() {
        return FILTERS.map((f) => ({ key: f, label: f, name: f,
            chipClass: this.filter === f ? 'oc-chip oc-chip--active' : 'oc-chip' }));
    }
    get selected() {
        const g = this.groups[this.selectedIndex];
        if (!g) return { letter: 'A', name: '', count: '0 / 0', barStyle: 'width:0%' };
        const pct = g.total ? Math.round((100 * g.complete) / g.total) : 0;
        const complete100 = g.total > 0 && g.complete >= g.total;
        return { letter: String.fromCharCode(65 + this.selectedIndex), name: g.category, count: `${g.complete} / ${g.total}`,
            barStyle: `width:${pct}%;background:${complete100 ? '#2e7d32' : '#2BAFAC'}` };
    }
    get items() {
        const g = this.groups[this.selectedIndex];
        if (!g) return [];
        return g.items.filter((it) => this.matches(it)).map((it) => this.enrich(it));
    }
    get isEmpty() { return this.items.length === 0; }

    matches(it) {
        const f = this.filter;
        if (f === 'All') return true;
        if (f === 'Overdue') return it.overdue;
        return it.status === f;
    }
    enrich(it) {
        const done = it.status === 'Complete';
        const isNA = it.status === 'Not Applicable';
        const dateTxt = isNA ? '—' : this.dateLabel(it.due);
        return {
            id: it.id, name: it.name, done, locked: done || isNA, isNA,
            meta: `${ownerShort(it.owner)} · ${dateTxt}`,
            metaClass: it.overdue ? 'oc-meta oc-meta--overdue' : 'oc-meta',
            rowClass: 'oc-task'
                + (done ? ' oc-task--done' : '')
                + (isNA ? ' oc-task--na' : '')
        };
    }
    dateLabel(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length !== 3) return d;
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + parseInt(p[2], 10);
    }
    selectGroup(e) { this.selectedIndex = parseInt(e.currentTarget.dataset.index, 10); this.filter = 'All'; }
    selectFilter(e) { this.filter = e.currentTarget.dataset.name; }

    // ---- Interactive completion ----
    handleCheck(event) {
        // Completed / N/A rows are disabled, so this only fires when checking an open task.
        const taskId = event.target.dataset.id;
        const subject = event.target.dataset.subject;
        event.target.checked = false; // hold unchecked until confirmed
        this._confirm = { open: true, taskId, subject, notes: '' };
    }
    get showConfirmModal() { return !!this._confirm.open; }
    get confirmSubject() { return this._confirm.subject; }
    get confirmNotes() { return this._confirm.notes; }
    get saving() { return this._saving; }
    handleConfirmNotes(event) { this._confirm = { ...this._confirm, notes: event.target.value }; }
    cancelConfirm() { this._confirm = {}; }
    async confirmComplete() {
        const { taskId, notes } = this._confirm;
        this._saving = true;
        try {
            await completeTask({ taskId, notes: (notes || '').trim() });
            this._confirm = {};
            await refreshApex(this._wire);
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } finally {
            this._saving = false;
        }
    }
}