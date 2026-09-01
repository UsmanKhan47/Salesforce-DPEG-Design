import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import CHECKLIST_FANNED_OUT_FIELD from '@salesforce/schema/Transaction__c.Checklist_Fanned_Out__c';
// New model (Checklist__c / Checklist_Item__c).
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import completeItem from '@salesforce/apex/ChecklistController.completeItem';
import recordWireVerification from '@salesforce/apex/ChecklistController.recordWireVerification';
// Legacy model (standard Task). Still live for every deal Phase 4 has not cut over.
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';
import completeTask from '@salesforce/apex/TransactionTaskController.completeTask';
import completeWireVerification from '@salesforce/apex/TransactionTaskController.completeWireVerification';
import { MONTHS } from 'c/utils';
import {
    MODEL_CHECKLIST,
    MODEL_LEGACY,
    PHASES,
    modelFor,
    normalizeChecklistGroups,
    normalizeLegacyGroups
} from 'c/utilsTransactionChecklist';

/**
 * The Transaction closing checklist — phase cards, group rail, and the task list with its
 * confirm / anti-fraud-verification / view-details dialogs.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS COMPONENT SERVES **TWO DATA MODELS AT ONCE**, AND WHICH ONE IS NOT A GUESS.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `Transaction__c.Checklist_Fanned_Out__c` — read via LDS `getRecord`, ARCHITECTURE.md §5's
 * first-choice data access — decides:
 *   true  -> `ChecklistController`         (Checklist__c / Checklist_Item__c)
 *   false -> `TransactionTaskController`   (legacy standard Task)
 * Phase 4 cuts deals over one at a time, so both are live in the same org for weeks. Only the
 * SELECTED model's Apex wire is provisioned: the other's `transactionId` parameter resolves to
 * `undefined`, and an LWC wire with an undefined reactive parameter does not call its adapter.
 *
 * 🔴 IF THE DISCRIMINATOR CANNOT BE READ, NEITHER MODEL RENDERS. An explicit error is shown.
 * Falling back to legacy would be the worst option available: a migrated deal STILL HAS its old
 * `Task` rows — design §7 leaves them in place deliberately so the migration stays reversible —
 * so a wrong guess renders a complete, plausible, silently stale checklist.
 *
 * 🔴 RISK 1 (the subject-text coupling) IS RETIRED HERE. The `CRITICAL_RE` / `WIRE_RE` regexes
 * that used to live at the top of this file are gone. Criticality and wire-verification now come
 * from `Is_Critical__c` / `Is_Wire_Verification__c` — the same two fields
 * `ChecklistRollupService` uses for `Transaction__c.Wire_Open_Risks__c`, so the red flag on this
 * screen and the number on the Wire Sentinel dashboard tile can no longer drift apart. The legacy
 * path still parses subjects because `Task` carries no such fields, and that parse is confined to
 * `normalizeLegacyGroups` in `c/utilsTransactionChecklist`. Full argument in that module's header.
 *
 * ⚠ NO CLIENT-SIDE PERMISSION GATE, DELIBERATELY. `Checklist_Item__c` is `ControlledByParent`
 * under a Private-OWD `Transaction__c`, and `getObjectInfo.updateable` has NO RECORD CONTEXT — it
 * cannot see sharing, so a gate built on it renders buttons enabled on records the user cannot
 * write (measured on `Property__c`: enabled on 47 of 48 records, every write refused). Rows stay
 * actionable and the SERVER refuses with a specific, user-safe message. The one thing disabled
 * client-side is a row the DATA says is blocked (`blocked`), which is a fact about the record,
 * not a guess about the user.
 *
 * ⚠ APEX DML HAPPENS BEHIND LDS's BACK. Every successful write calls
 * `notifyRecordUpdateAvailable` so the Path and the highlights panel pick up the counters
 * `ChecklistRollupService` / `TaskRollupService` just wrote to the parent Transaction.
 * (`getRecordNotifyChange` is the deprecated form of the same call; it is also exported by the
 * Jest stub as a WIRE ADAPTER rather than a callable, so calling it throws inside tests.)
 *
 * @see force-app/main/default/lwc/utilsTransactionChecklist/utilsTransactionChecklist.js
 */
export default class TransactionTaskGroups extends LightningElement {
    @api recordId;
    /**
     * When set (one value per FlexiPage tab), the component is pinned to that phase and the
     * phase-button row is hidden. Blank = show all phases with the buttons.
     *
     * ⚠ VALUES ARE A DEPLOY CONTRACT: `open` | `dd` | `close` | `post`, pinned by four
     * `transactionTaskGroups` instances in `Transaction_Record_Page.flexipage`.
     */
    @api phase;

    _modelResolved = false;
    _modelError;
    _fannedOut;

    _checklistWire;
    _checklistData = [];
    _checklistError;

    _legacyWire;
    _legacyData = [];
    _legacyError;

    _selectedPhase;
    _selectedKey;
    _wireModal = {};
    _wireSaving = false;
    _confirm = {};
    _confirmSaving = false;
    _view = {};

    // ---- Model discrimination -------------------------------------------------------------

    @wire(getRecord, { recordId: '$recordId', fields: [CHECKLIST_FANNED_OUT_FIELD] })
    wiredTransaction({ data, error }) {
        if (data) {
            this._fannedOut = getFieldValue(data, CHECKLIST_FANNED_OUT_FIELD);
            this._modelResolved = true;
            this._modelError = undefined;
        } else if (error) {
            // Do NOT fall back to a model here — see the class header.
            this._modelError = error;
            this._modelResolved = false;
            this._fannedOut = undefined;
        }
    }

    get model() {
        return this._modelResolved ? modelFor(this._fannedOut) : undefined;
    }

    get isChecklistModel() {
        return this.model === MODEL_CHECKLIST;
    }

    get isLegacyModel() {
        return this.model === MODEL_LEGACY;
    }

    /**
     * The wire parameter for the NEW model. `undefined` when the deal is not on it, which stops
     * the adapter being provisioned at all — this is what keeps exactly one model's Apex running.
     */
    get checklistTransactionId() {
        return this.isChecklistModel ? this.recordId : undefined;
    }

    /** The wire parameter for the LEGACY model. See `checklistTransactionId`. */
    get legacyTransactionId() {
        return this.isLegacyModel ? this.recordId : undefined;
    }

    // ---- Data -----------------------------------------------------------------------------

    @wire(getChecklist, { transactionId: '$checklistTransactionId' })
    wiredChecklist(result) {
        this._checklistWire = result;
        if (result.data) {
            this._checklistData = result.data;
            this._checklistError = undefined;
        } else if (result.error) {
            this._checklistError = result.error;
            this._checklistData = [];
        }
    }

    @wire(getTaskGroups, { transactionId: '$legacyTransactionId' })
    wiredLegacy(result) {
        this._legacyWire = result;
        if (result.data) {
            this._legacyData = result.data;
            this._legacyError = undefined;
        } else if (result.error) {
            this._legacyError = result.error;
            this._legacyData = [];
        }
    }

    /** The normalised groups for whichever model is active. One shape, one template. */
    get groups() {
        if (this.isChecklistModel) {
            return normalizeChecklistGroups(this._checklistData);
        }
        if (this.isLegacyModel) {
            return normalizeLegacyGroups(this._legacyData);
        }
        return [];
    }

    get dataError() {
        if (this.isChecklistModel) {
            return this._checklistError;
        }
        if (this.isLegacyModel) {
            return this._legacyError;
        }
        return undefined;
    }

    // ---- Render states --------------------------------------------------------------------
    // Four mutually exclusive states, so an empty checklist is VISIBLY empty and never renders as
    // blank space that reads like a successful load of nothing.

    /** The discriminator has not resolved and has not failed — still loading. */
    get isResolving() {
        return !this._modelResolved && !this._modelError;
    }

    get hasModelError() {
        return !!this._modelError;
    }

    get modelErrorMessage() {
        const e = this._modelError;
        return (
            (e && e.body && e.body.message) ||
            'This deal could not be read, so the checklist cannot be shown. Refresh the page, or contact your administrator if it persists.'
        );
    }

    get hasDataError() {
        return !this.hasModelError && !!this.dataError;
    }

    get dataErrorMessage() {
        const e = this.dataError;
        return (
            (e && e.body && e.body.message) ||
            'Unable to load the checklist. Please refresh and try again.'
        );
    }

    /** A genuinely empty checklist for a resolved model — distinct from an error and from loading. */
    get showEmpty() {
        return (
            !this.isResolving &&
            !this.hasModelError &&
            !this.hasDataError &&
            this.groups.length === 0
        );
    }

    get emptyMessage() {
        if (this.isChecklistModel) {
            return 'This deal is on the new checklist, but no checklist items have been generated for it yet. If that looks wrong, contact your administrator — the fan-out may not have completed.';
        }
        return 'No tasks yet. Set the Contract Executed Date to generate the checklist.';
    }

    get showContent() {
        return (
            !this.isResolving &&
            !this.hasModelError &&
            !this.hasDataError &&
            this.groups.length > 0
        );
    }

    // ---- Phase layer ----------------------------------------------------------------------

    /** Hide the in-component phase buttons when this instance is pinned to a phase. */
    get showPhaseButtons() {
        return !this.phase;
    }

    /** No groups fall under the pinned phase (e.g. a conditional group that did not fan out). */
    get phaseEmpty() {
        return !!this.phase && this.showContent && this.phaseGroups.length === 0;
    }

    /** The pinned phase if any, else the one holding the first not-complete group. */
    get selectedPhaseKey() {
        if (this.phase) {
            return this.phase;
        }
        const groups = this.groups;
        if (this._selectedPhase && groups.some((g) => g.phaseKey === this._selectedPhase)) {
            return this._selectedPhase;
        }
        const firstOpen = groups.find((g) => !(g.total > 0 && g.complete >= g.total));
        if (firstOpen && firstOpen.phaseKey) {
            return firstOpen.phaseKey;
        }
        const firstWithGroups = PHASES.find((p) => groups.some((g) => g.phaseKey === p.key));
        return (firstWithGroups || PHASES[0]).key;
    }

    get phases() {
        const sel = this.selectedPhaseKey;
        const all = this.groups;
        return PHASES.map((p) => {
            const groups = all.filter((g) => g.phaseKey === p.key);
            const total = groups.reduce((s, g) => s + (g.total || 0), 0);
            const complete = groups.reduce((s, g) => s + (g.complete || 0), 0);
            const has = groups.length > 0;
            const pct = total ? Math.round((complete / total) * 100) : 0;
            const done = has && total > 0 && complete >= total;
            let cls = 'tg-phase';
            if (p.key === sel) {
                cls += ' tg-phase--active';
            }
            if (!has) {
                cls += ' tg-phase--empty';
            }
            if (done) {
                cls += ' tg-phase--done';
            }
            return {
                key: p.key,
                name: p.name,
                icon: p.icon,
                countLabel: has ? `${complete} / ${total}` : '—',
                pctLabel: has ? `${pct}%` : '',
                barStyle: `width:${pct}%`,
                barClass: done ? 'tg-phase-fill tg-phase-fill--done' : 'tg-phase-fill',
                done,
                disabled: !has,
                selected: p.key === sel,
                cls
            };
        });
    }

    get phaseGroups() {
        const pk = this.selectedPhaseKey;
        return this.groups.filter((g) => g.phaseKey === pk);
    }

    /** Within the phase, the selected group defaults to the first not-complete one. */
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
            let ringClass = 'tg-ring';
            if (complete100) {
                ringClass += ' tg-ring--done';
            } else if (g.conditional) {
                ringClass += ' tg-ring--conditional';
            }
            return {
                key: g.key,
                letter: g.letter,
                name: g.name,
                complete100,
                countLabel: `${g.complete} / ${g.total}`,
                ringClass,
                ringStyle: `--pct:${g.pct}%`,
                itemClass: g.key === sel ? 'tg-gchip tg-gchip--active' : 'tg-gchip'
            };
        });
    }

    get current() {
        const g = this.groups.find((x) => x.key === this.selectedKey) || this.phaseGroups[0];
        if (!g) {
            // Every member returned as a safe empty value: these feed element ATTRIBUTES, and a
            // getter bound to an attribute is written UNCONDITIONALLY — returning undefined
            // renders the literal string "undefined" into the DOM.
            return {
                letter: '',
                name: '',
                ownerLabel: '',
                conditional: false,
                countLabel: '',
                badgeClass: 'tg-badge tg-badge--lg',
                barStyle: 'width:0%',
                barClass: 'tg-bar',
                rows: []
            };
        }
        const complete100 = g.total > 0 && g.complete >= g.total;
        return {
            letter: g.letter,
            name: g.name,
            ownerLabel: g.ownerLabel,
            conditional: g.conditional,
            countLabel: `${g.complete} / ${g.total}`,
            badgeClass: g.conditional ? 'tg-badge tg-badge--lg tg-badge--conditional' : 'tg-badge tg-badge--lg',
            barStyle: `width:${g.pct}%`,
            barClass: complete100 ? 'tg-bar tg-bar--done' : 'tg-bar',
            rows: g.items.map((item) => {
                const hasNotes = item.done && item.comment.length > 0;
                const blocked = item.blocked && !item.done;
                let rowClass = item.done ? 'tg-task tg-task--done' : 'tg-task';
                if (item.critical) {
                    rowClass += ' tg-task--critical';
                }
                if (blocked) {
                    rowClass += ' tg-task--blocked';
                }
                return {
                    id: item.id,
                    subject: item.subject,
                    critical: item.critical,
                    wire: item.wire,
                    showCritical: item.critical && !item.verified,
                    verified: item.verified,
                    verifiedLabel: item.verifiedByName
                        ? `Verified · ${item.verifiedByName}`
                        : 'Verified',
                    blocked,
                    // Who completed it + the completion date (with year), only once done. Must be
                    // completedByName, NOT ownerLabel: ownerLabel is the static ROLE the item is
                    // owed by, so pairing it with a completion date claims the role holder closed
                    // every item in their group. Either part may be blank; filter(Boolean) drops
                    // the separator then.
                    meta: item.done
                        ? [item.completedByName, this.dateLabelYear(item.completedDateTime)]
                              .filter(Boolean)
                              .join(' · ')
                        : '',
                    done: item.done,
                    // A completed row is locked; a blocked row is locked because the DATA says its
                    // prerequisite is unmet. Neither is a permission guess.
                    disabled: item.done || blocked,
                    notes: item.comment,
                    hasNotes,
                    hasDetails: item.done && (hasNotes || item.verified),
                    rowClass
                };
            })
        };
    }

    // ---- Formatting -----------------------------------------------------------------------

    /** "May 8, 2026" from a Datetime. */
    dateLabelYear(dt) {
        if (!dt) {
            return '';
        }
        const d = new Date(dt);
        if (isNaN(d.getTime())) {
            return '';
        }
        return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
    }

    /** "May 8, 2026 · 3:04 PM" from a Datetime. */
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

    // ---- Selection ------------------------------------------------------------------------

    /** Switching phase resets the group selection so it lands on that phase's first open group. */
    selectPhase(event) {
        this._selectedPhase = event.currentTarget.dataset.phase;
        this._selectedKey = null;
    }

    select(event) {
        this._selectedKey = event.currentTarget.dataset.key;
    }

    // ---- Completion -----------------------------------------------------------------------

    handleCheck(event) {
        const itemId = event.target.dataset.id;
        const checked = event.target.checked;
        const wire = event.target.dataset.wire === 'true';
        // Completed and blocked rows are disabled, so this only ever fires on check.
        if (!checked) {
            return;
        }
        const subject = event.target.dataset.subject || '';
        if (wire) {
            event.target.checked = false; // hold unchecked until the form is submitted
            this._wireModal = {
                open: true,
                itemId,
                subject,
                verifiedBy: '',
                phone: '',
                comments: '',
                error: ''
            };
            return;
        }
        event.target.checked = false; // hold unchecked until confirmed
        this._confirm = { open: true, itemId, subject, notes: '' };
    }

    /**
     * Refreshes both the checklist itself and the parent Transaction after a successful write.
     *
     * ⚠ THE `notifyRecordUpdateAvailable` CALL IS NOT OPTIONAL. The completion was an imperative
     * Apex DML, and the rollup then wrote `Tasks_Complete__c` / `Wire_Open_Risks__c` on the parent
     * — all of it behind LDS's back. Without this, the Path and the highlights panel keep showing
     * the counters from before the click until the user reloads the page.
     */
    async refreshAfterWrite() {
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        const active = this.isChecklistModel ? this._checklistWire : this._legacyWire;
        if (active) {
            await refreshApex(active);
        }
    }

    toastFailure(title, e, fallback) {
        const msg = (e && e.body && e.body.message) || fallback;
        this.dispatchEvent(
            new ShowToastEvent({ title, message: msg, variant: 'error', mode: 'sticky' })
        );
    }

    // ---- Confirm-complete dialog ----------------------------------------------------------

    get showConfirmModal() {
        return !!this._confirm.open;
    }
    get confirmSubject() {
        return this._confirm.subject || '';
    }
    get confirmNotes() {
        return this._confirm.notes || '';
    }
    get confirmSaveDisabled() {
        return this._confirmSaving;
    }
    handleConfirmNotes(event) {
        this._confirm = { ...this._confirm, notes: event.target.value };
    }
    cancelConfirm() {
        this._confirm = {};
    }

    async confirmComplete() {
        const { itemId, notes } = this._confirm;
        this._confirmSaving = true;
        try {
            if (this.isChecklistModel) {
                await completeItem({ itemId, comment: notes });
            } else {
                await completeTask({ taskId: itemId, notes });
            }
            // Only dismiss the dialog once the write actually succeeds.
            this._confirm = {};
            await this.refreshAfterWrite();
        } catch (e) {
            // The optimistic checkbox was already reverted in handleCheck, so the row correctly
            // reads incomplete — surface WHY. A wire-fraud prerequisite refusal arrives here with
            // its own message naming the blocking step; the generic fallback would tell the user
            // to "try again", which can never work for that case.
            this.toastFailure(
                'Item not completed',
                e,
                'Could not complete the item. Please try again.'
            );
        } finally {
            this._confirmSaving = false;
        }
    }

    // ---- View-details dialog (read-only, for completed items) ------------------------------

    get showViewModal() {
        return !!this._view.open;
    }
    get viewData() {
        return this._view;
    }

    viewTask(event) {
        const id = event.currentTarget.dataset.id;
        let found;
        this.groups.forEach((g) =>
            (g.items || []).forEach((item) => {
                if (item.id === id) {
                    found = item;
                }
            })
        );
        if (!found) {
            return;
        }
        const hasWire = found.wire && !!found.verifiedByName;
        this._view = {
            open: true,
            subject: found.subject,
            isWire: found.wire,
            hasWire,
            verifiedBy: found.verifiedByName,
            phone: found.phone,
            verifiedAt: this.dateTimeLabel(found.verifiedAt),
            notes: found.comment,
            hasNotes: found.comment.length > 0,
            hasAny: found.comment.length > 0 || hasWire
        };
    }

    closeView() {
        this._view = {};
    }

    // ---- Wire verification modal ----------------------------------------------------------

    get showWireModal() {
        return !!this._wireModal.open;
    }
    get wireSubject() {
        return this._wireModal.subject || '';
    }
    get wireVerifiedBy() {
        return this._wireModal.verifiedBy || '';
    }
    get wirePhone() {
        return this._wireModal.phone || '';
    }
    get wireComments() {
        return this._wireModal.comments || '';
    }
    get wireError() {
        return this._wireModal.error || '';
    }
    get hasWireError() {
        return !!this._wireModal.error;
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
        const { itemId, verifiedBy, phone, comments } = this._wireModal;
        if (!verifiedBy || !verifiedBy.trim() || !phone || !phone.trim()) {
            this._wireModal = {
                ...this._wireModal,
                error: 'Both the confirmer’s name and the phone number used are required.'
            };
            return;
        }
        this._wireSaving = true;
        try {
            if (this.isChecklistModel) {
                await recordWireVerification({
                    itemId,
                    verifiedByName: verifiedBy.trim(),
                    phone: phone.trim(),
                    comment: (comments || '').trim()
                });
            } else {
                await completeWireVerification({
                    taskId: itemId,
                    verifiedBy: verifiedBy.trim(),
                    phone: phone.trim(),
                    comments: (comments || '').trim()
                });
            }
            this._wireModal = {};
            await this.refreshAfterWrite();
        } catch (e) {
            const msg =
                (e && e.body && e.body.message) ||
                'Could not save the verification. Please try again.';
            this._wireModal = { ...this._wireModal, error: msg };
        } finally {
            this._wireSaving = false;
        }
    }
}
