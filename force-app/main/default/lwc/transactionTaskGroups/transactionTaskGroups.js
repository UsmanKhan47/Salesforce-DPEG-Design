import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';
import completeTask from '@salesforce/apex/TransactionTaskController.completeTask';
import completeWireVerification from '@salesforce/apex/TransactionTaskController.completeWireVerification';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
// CRITICAL_RE flags any deal-sinking step; WIRE_RE flags the anti-fraud wire-verification steps
// that must capture a verbal verification before they can close (DPEG brief Section 06).
const CRITICAL_RE = /\(\s*(anti-?fraud|critical[^)]*)\s*\)/i;
const WIRE_RE = /\(\s*anti-?fraud\s*\)/i;

// The four deal phases (Danish's checklist columns), each mapping to the brief's task groups.
const PHASES = [
    { key: 'open',  name: 'Open Contract', letters: ['A', 'B'], icon: 'utility:contract' },
    { key: 'dd',    name: 'Due Diligence', letters: ['C', 'D', 'E', 'F', 'G', 'H', 'H2'], icon: 'utility:search' },
    { key: 'close', name: 'Closing',       letters: ['I'], icon: 'utility:money' },
    { key: 'post',  name: 'Post Closing',  letters: ['J'], icon: 'utility:success' }
];
const PHASE_BY_LETTER = {};
PHASES.forEach((p) => p.letters.forEach((l) => { PHASE_BY_LETTER[l] = p.key; }));

export default class TransactionTaskGroups extends LightningElement {
    @api recordId;
    // When set (one value per flexipage tab), the component is pinned to that phase
    // and the phase-button row is hidden. Blank = show all phases with the buttons.
    @api phase;
    _wire;
    _wireError;
    _data = [];
    _selectedPhase;
    _selectedKey;
    _wireModal = {};
    _wireSaving = false;
    _confirm = {};
    _view = {};

    @wire(getTaskGroups, { transactionId: '$recordId' })
    wired(result) {
        this._wire = result;
        if (result.data) {
            this._data = result.data;
            this._wireError = undefined;
        } else if (result.error) {
            // Capture the load failure so the UI can show a distinct error state
            // instead of the "no tasks yet" empty state (which reads as success).
            this._wireError = result.error;
            this._data = [];
        }
    }

    get isEmpty() {
        return this._data.length === 0;
    }

    get hasWireError() {
        return !!this._wireError;
    }

    // Distinct from the error state: a genuinely empty checklist, not a failed load.
    get showEmpty() {
        return this._data.length === 0 && !this._wireError;
    }

    get wireErrorMessage() {
        const e = this._wireError;
        return (e && e.body && e.body.message) || 'Unable to load the task checklist. Please refresh and try again.';
    }

    // ---- Phase layer ----
    // Hide the in-component phase buttons when this instance is pinned to a phase (tab-per-phase).
    get showPhaseButtons() {
        return !this.phase;
    }

    // No groups fall under the pinned phase (e.g. a conditional group that didn't fan out).
    get phaseEmpty() {
        return !!this.phase && this.phaseGroups.length === 0;
    }

    // Selected phase: the pinned phase if any, else the one holding the first not-complete group.
    get selectedPhaseKey() {
        if (this.phase) {
            return this.phase;
        }
        if (this._selectedPhase && this._data.some((g) => PHASE_BY_LETTER[g.letter] === this._selectedPhase)) {
            return this._selectedPhase;
        }
        const firstOpen = this._data.find((g) => !(g.total > 0 && g.complete >= g.total));
        if (firstOpen) {
            return PHASE_BY_LETTER[firstOpen.letter];
        }
        const firstWithGroups = PHASES.find((p) => this._data.some((g) => PHASE_BY_LETTER[g.letter] === p.key));
        return (firstWithGroups || PHASES[0]).key;
    }

    get phases() {
        const sel = this.selectedPhaseKey;
        return PHASES.map((p) => {
            const groups = this._data.filter((g) => PHASE_BY_LETTER[g.letter] === p.key);
            const total = groups.reduce((s, g) => s + (g.total || 0), 0);
            const complete = groups.reduce((s, g) => s + (g.complete || 0), 0);
            const has = groups.length > 0;
            const pct = total ? Math.round((complete / total) * 100) : 0;
            const done = has && total > 0 && complete >= total;
            let cls = 'tg-phase';
            if (p.key === sel) cls += ' tg-phase--active';
            if (!has) cls += ' tg-phase--empty';
            if (done) cls += ' tg-phase--done';
            return {
                key: p.key,
                name: p.name,
                icon: p.icon,
                countLabel: has ? `${complete} / ${total}` : '—',
                pctLabel: has ? `${pct}%` : '',
                barStyle: `width:${pct}%;background:${done ? '#2e7d32' : '#0176d3'}`,
                done,
                disabled: !has,
                cls
            };
        });
    }

    // Groups belonging to the selected phase (drives the rail).
    get phaseGroups() {
        const pk = this.selectedPhaseKey;
        return this._data.filter((g) => PHASE_BY_LETTER[g.letter] === pk);
    }

    // Within the phase, the selected group defaults to the first not-complete one.
    get selectedKey() {
        const groups = this.phaseGroups;
        if (this._selectedKey && groups.some((g) => g.key === this._selectedKey)) {
            return this._selectedKey;
        }
        const firstOpen = groups.find((g) => !(g.total > 0 && g.complete >= g.total));
        return (firstOpen || groups[0] || {}).key;
    }

    get railItems() {
        const sel = this.selectedKey;
        return this.phaseGroups.map((g) => {
            const complete100 = g.total > 0 && g.complete >= g.total;
            // Ring accent: green when done, amber for the conditional group, else blue.
            const accent = complete100 ? '#2e7d32' : (g.conditional ? '#bf5d0a' : '#1565c0');
            return {
                key: g.key,
                letter: g.letter,
                name: g.name,
                complete100,
                countLabel: `${g.complete} / ${g.total}`,
                ringStyle: `--ring:${accent};--pct:${g.pct}%`,
                itemClass: g.key === sel ? 'tg-gchip tg-gchip--active' : 'tg-gchip'
            };
        });
    }

    get current() {
        const g = this._data.find((x) => x.key === this.selectedKey) || this.phaseGroups[0];
        if (!g) return {};
        const complete100 = g.total > 0 && g.complete >= g.total;
        return {
            letter: g.letter,
            name: g.name,
            ownerLabel: g.ownerLabel,
            conditional: g.conditional,
            countLabel: `${g.complete} / ${g.total}`,
            badgeStyle: `background:${g.conditional ? '#bf5d0a' : '#1565c0'}`,
            barStyle: `width:${g.pct}%;background:${complete100 ? '#2e7d32' : '#2BAFAC'}`,
            rows: g.tasks.map((t) => {
                const critical = CRITICAL_RE.test(t.subject);
                const wire = WIRE_RE.test(t.subject);
                const verified = wire && t.done && t.verifyComplete;
                const notes = (t.notes || '').trim();
                const hasNotes = t.done && notes.length > 0;
                return {
                    id: t.id,
                    subject: t.subject.replace(CRITICAL_RE, '').trim(),
                    critical,
                    wire,
                    showCritical: critical && !verified,
                    verified,
                    verifiedLabel: t.verifiedBy ? `Verified · ${t.verifiedBy}` : 'Verified',
                    // Who completed it + the completion date (with year), only once the task is
                    // done. Must be completedByName, NOT ownerLabel: ownerLabel is the static
                    // ROLE the task is owed by (from Transaction_Task_Def__mdt), so pairing it
                    // with a completion date claimed the role holder closed every task in their
                    // group. Either part may be blank; filter(Boolean) drops the separator then.
                    meta: t.done
                        ? [t.completedByName, this.dateLabelYear(t.completedDate)].filter(Boolean).join(' · ')
                        : '',
                    done: t.done,
                    notes,
                    hasNotes,
                    // The row's View button appears once the task is done and has notes or wire details on file.
                    hasDetails: t.done && (hasNotes || verified),
                    rowClass:
                        (t.done ? 'tg-task tg-task--done' : 'tg-task') + (critical ? ' tg-task--critical' : '')
                };
            })
        };
    }

    dateLabel(d) {
        if (!d) return '';
        const p = String(d).split('-');
        if (p.length !== 3) return '';
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + parseInt(p[2], 10);
    }

    // "May 8, 2026" from a Datetime (used for the completion date on done tasks).
    dateLabelYear(dt) {
        if (!dt) return '';
        const d = new Date(dt);
        if (isNaN(d.getTime())) return '';
        return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
    }

    // Switching phase resets the group selection so it lands on that phase's first open group.
    selectPhase(event) {
        this._selectedPhase = event.currentTarget.dataset.phase;
        this._selectedKey = null;
    }

    select(event) {
        this._selectedKey = event.currentTarget.dataset.key;
    }

    handleCheck(event) {
        const taskId = event.target.dataset.id;
        const done = event.target.checked;
        const wire = event.target.dataset.wire === 'true';
        // Completed tasks are locked (checkbox disabled), so this only ever fires on check.
        if (!done) {
            return;
        }
        // Wire tasks open the anti-fraud verification dialog (its own confirmation step).
        if (wire) {
            event.target.checked = false; // hold unchecked until the form is submitted
            this._wireModal = { open: true, taskId, subject: event.target.dataset.subject, verifiedBy: '', phone: '', comments: '', error: '' };
            return;
        }
        // Regular tasks ask for a plain confirmation before completing.
        event.target.checked = false; // hold unchecked until confirmed
        this._confirm = { open: true, taskId, subject: event.target.dataset.subject, notes: '' };
    }

    // ---- Confirm-complete dialog ----
    get showConfirmModal() {
        return !!this._confirm.open;
    }
    get confirmSubject() {
        return this._confirm.subject;
    }
    get confirmNotes() {
        return this._confirm.notes;
    }
    handleConfirmNotes(event) {
        this._confirm = { ...this._confirm, notes: event.target.value };
    }
    cancelConfirm() {
        this._confirm = {};
    }
    async confirmComplete() {
        const { taskId, notes } = this._confirm;
        try {
            await completeTask({ taskId, notes });
            // Only dismiss the dialog once the write actually succeeds.
            this._confirm = {};
            await refreshApex(this._wire);
        } catch (e) {
            // The optimistic checkbox was already reverted to unchecked in handleCheck,
            // so the row correctly reads incomplete — surface WHY it did not complete
            // instead of silently swallowing the failure.
            const msg = (e && e.body && e.body.message) || 'Could not complete the task. Please try again.';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Task not completed',
                message: msg,
                variant: 'error',
                mode: 'sticky'
            }));
        }
    }

    // ---- View-details dialog (read-only, for completed tasks) ----
    get showViewModal() {
        return !!this._view.open;
    }
    get viewData() {
        return this._view;
    }
    viewTask(event) {
        const id = event.currentTarget.dataset.id;
        let found;
        this._data.forEach((g) => (g.tasks || []).forEach((t) => {
            if (t.id === id) {
                found = t;
            }
        }));
        if (!found) {
            return;
        }
        const isWire = WIRE_RE.test(found.subject);
        const notes = (found.notes || '').trim();
        const hasWire = isWire && !!found.verifiedBy;
        this._view = {
            open: true,
            subject: found.subject.replace(CRITICAL_RE, '').trim(),
            isWire,
            hasWire,
            verifiedBy: found.verifiedBy,
            phone: found.phone,
            verifiedAt: this.dateTimeLabel(found.verifiedAt),
            notes,
            hasNotes: notes.length > 0,
            hasAny: notes.length > 0 || hasWire
        };
    }
    closeView() {
        this._view = {};
    }

    dateTimeLabel(dt) {
        if (!dt) {
            return '';
        }
        const d = new Date(dt);
        if (isNaN(d.getTime())) {
            return '';
        }
        let h = d.getHours();
        const m = String(d.getMinutes()).padStart(2, '0');
        const ap = h >= 12 ? 'PM' : 'AM';
        h = h % 12 || 12;
        return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} · ${h}:${m} ${ap}`;
    }

    // ---- Wire verification modal ----
    get showWireModal() {
        return !!this._wireModal.open;
    }
    get wireSubject() {
        return this._wireModal.subject;
    }
    get wireVerifiedBy() {
        return this._wireModal.verifiedBy;
    }
    get wirePhone() {
        return this._wireModal.phone;
    }
    get wireComments() {
        return this._wireModal.comments;
    }
    get wireError() {
        return this._wireModal.error;
    }
    get wireSaveDisabled() {
        return this._wireSaving;
    }

    handleVerifiedBy(event) {
        this._wireModal = { ...this._wireModal, verifiedBy: event.target.value };
    }
    handlePhone(event) {
        this._wireModal = { ...this._wireModal, phone: event.target.value };
    }
    handleWireComments(event) {
        this._wireModal = { ...this._wireModal, comments: event.target.value };
    }
    cancelWire() {
        this._wireModal = {};
    }

    async submitWire() {
        const { taskId, verifiedBy, phone, comments } = this._wireModal;
        if (!verifiedBy || !verifiedBy.trim() || !phone || !phone.trim()) {
            this._wireModal = { ...this._wireModal, error: 'Both the confirmer’s name and the phone number used are required.' };
            return;
        }
        this._wireSaving = true;
        try {
            await completeWireVerification({ taskId, verifiedBy: verifiedBy.trim(), phone: phone.trim(), comments: (comments || '').trim() });
            this._wireModal = {};
            await refreshApex(this._wire);
        } catch (e) {
            const msg = (e && e.body && e.body.message) || 'Could not save the verification. Please try again.';
            this._wireModal = { ...this._wireModal, error: msg };
        } finally {
            this._wireSaving = false;
        }
    }
}