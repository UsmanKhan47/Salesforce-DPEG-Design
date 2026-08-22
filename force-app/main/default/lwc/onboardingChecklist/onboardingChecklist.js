import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable, getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';
import completeTask from '@salesforce/apex/OnboardingController.completeTask';
import PROPERTY_ASSET_FIELD from '@salesforce/schema/Onboarding__c.Property_Asset__c';
import PROPERTY_NAME_FIELD from '@salesforce/schema/Onboarding__c.Property_Name__c';
import UtilityMeterCapture from 'c/utilityMeterCapture';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const FILTERS = ['All','Not Started','Overdue','Completed'];

/* ══════════════════════════════════════════════════════════════════════════════
   FSD UAT UT-001 — "Onboarding utility-transfer task completed → meter capture
   screen opens; meters saved against property and spaces."

   🔴 THIS IS A BEHAVIOUR CHANGE TO A SHIPPED FEATURE AND IT CROSSES A MODULE
   BOUNDARY (Onboarding → Utilities). Completing ONE specific checklist row now
   opens a modal where it previously closed silently. Every other row is
   byte-for-byte unaffected — `_isUtilityTransferTask` is the only gate.

   ── WHY DETECTION IS CLIENT-SIDE, WITH ZERO APEX CHANGE ────────────────────
   `OnboardingController.getChecklist` ALREADY returns both signals this needs:
   `ChecklistGroup.category` and `ChecklistItem.name` (the Task Subject). They are
   in memory here before the user clicks anything.

   The server-side alternative would be to widen
   `TaskSelector.selectForOnboardingCompletion` to carry `Onboarding_Category__c`.
   That must NOT be done: the selector is `WITH USER_MODE` over five fields, and
   exactly ONE permission set in this repo grants `Task.Onboarding_Category__c`
   (`DPEG_Task_Edit`). USER_MODE throws rather than degrades, so any persona
   without that set would get `System.QueryException: No such column` and
   ONBOARDING TASK COMPLETION WOULD BREAK ORG-WIDE — on a change that looks like
   it only touches a new module.

   ── THE SUBJECT STRING IS BRITTLE, SO IT LIVES IN ONE PLACE ────────────────
   Matching on a Subject means re-wording the checklist item silently kills UT-001
   — no error, the modal just stops appearing. The constant below is the single
   point of truth and names its source. A durable marker field on the Task would
   be better and is the recommended follow-up; it needs a new field, which is out
   of scope for this build.
   ══════════════════════════════════════════════════════════════════════════════ */

/** Task Subject, verbatim from scripts/load-onboarding-task-defs.apex:99 (row 28), which
 *  seeds the `Onboarding_Task_Def__mdt` record every new onboarding fans out from. */
const UTILITY_TRANSFER_SUBJECT = 'Set up utility accounts & transfers';
/** That row's `Onboarding_Category__c`, from the same source. */
const UTILITY_TRANSFER_CATEGORY = 'Vendor & Expense Management';

const ownerShort = (n) => !n ? '' : (n === 'Accounting Queue' ? 'Accounting' : n.split(' ')[0]);

export default class OnboardingChecklist extends LightningElement {
    @api recordId;
    groups = [];
    error;
    selectedIndex = 0;
    filter = 'All';
    _wire;
    _confirm = {};
    _saving = false;

    @wire(getChecklist, { onboardingId: '$recordId' })
    wired(result) {
        this._wire = result;
        if (result.data) {
            this.groups = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error;
            this.groups = [];
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load the onboarding checklist.';
    }

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
        if (f === 'Completed') return it.status === 'Complete';
        return it.status === f; // 'Not Started'
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
        // The CATEGORY is captured here, at click time, from the group the row belongs to.
        // Reading it later would be wrong: refreshApex re-renders and the user may have moved
        // to a different category tile before the promise resolves.
        const group = this.groups[this.selectedIndex];
        const category = group ? group.category : undefined;
        this._confirm = { open: true, taskId, subject, category, notes: '' };
    }
    get showConfirmModal() { return !!this._confirm.open; }
    get confirmSubject() { return this._confirm.subject; }
    get confirmNotes() { return this._confirm.notes; }
    get saving() { return this._saving; }
    handleConfirmNotes(event) { this._confirm = { ...this._confirm, notes: event.target.value }; }
    cancelConfirm() { this._confirm = {}; }
    async confirmComplete() {
        const { taskId, notes, subject, category } = this._confirm;
        this._saving = true;
        try {
            await completeTask({ taskId, notes: (notes || '').trim() });
            this._confirm = {};
            await refreshApex(this._wire);
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            // UT-001. AFTER the completion has been persisted and the checklist refreshed,
            // so a failed save never opens the capture screen and the user is never asked to
            // record meters for a task that did not complete.
            if (this._isUtilityTransferTask(subject, category)) {
                await this._openMeterCapture();
            }
        } catch (e) {
            // Surface a user-safe message and keep the confirm modal open so the
            // user can retry — the completion was never persisted.
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not complete the task',
                message: (e && e.body && e.body.message) || 'Unexpected error',
                variant: 'error'
            }));
        } finally {
            this._saving = false;
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // FSD UAT UT-001 — utility-transfer hand-off. See the block comment at the top
    // of this file for why detection is client-side and why the Apex selector must
    // NOT be widened to do it server-side.
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * The Onboarding's property, read through LDS.
     *
     * `getRecord` rather than a new Apex method: the two fields needed are already on the
     * record the user is looking at, and adding an @AuraEnabled read for them would be Apex
     * used as a data-access layer, which ARCHITECTURE.md section 5 forbids.
     */
    @wire(getRecord, {
        recordId: '$recordId',
        fields: [PROPERTY_ASSET_FIELD, PROPERTY_NAME_FIELD]
    })
    onboarding;

    get _propertyAssetId() {
        return getFieldValue(this.onboarding.data, PROPERTY_ASSET_FIELD);
    }

    get _propertyName() {
        return getFieldValue(this.onboarding.data, PROPERTY_NAME_FIELD);
    }

    /**
     * Whether the row just completed is the utility-transfer one.
     *
     * BOTH the category and the subject must match. The category alone is far too broad
     * (Vendor & Expense Management carries eight rows), and the subject alone would fire on
     * an identically-worded row added to another category later.
     */
    _isUtilityTransferTask(subject, category) {
        return subject === UTILITY_TRANSFER_SUBJECT && category === UTILITY_TRANSFER_CATEGORY;
    }

    /**
     * Opens the meter capture grid for this onboarding's property.
     *
     * ⚠ IF THE ONBOARDING HAS NO PROPERTY, DO NOTHING AND SAY SO. Opening the grid without a
     * property would let a user type a whole register that the save then refuses - the
     * service requires a property because a meter without one is invisible on every register
     * list in the app.
     */
    async _openMeterCapture() {
        const propertyAssetId = this._propertyAssetId;
        if (!propertyAssetId) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Meter capture not opened',
                message: 'This onboarding has no property linked, so meters cannot be '
                    + 'recorded against it yet.',
                variant: 'warning'
            }));
            return;
        }
        const outcome = await UtilityMeterCapture.open({
            size: 'large',
            label: 'Capture Meters',
            description: 'Record the utility meters installed at this property and its spaces.',
            propertyAssetId,
            propertyName: this._propertyName
        });
        // Falsiness, not `=== undefined`: the Jest stub's close() with no argument arrives as
        // `detail === null` (CustomEvent spec-defaults detail to null) while the real
        // LightningModal resolves undefined. Both mean "cancelled" and must behave alike.
        if (!outcome) {
            return;
        }
        if (outcome.error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not save the meters',
                message: (outcome.error.body && outcome.error.body.message)
                    || 'Unexpected error saving the meters.',
                variant: 'error',
                mode: 'sticky'
            }));
            return;
        }
        const result = outcome.result || {};
        this.dispatchEvent(new ShowToastEvent({
            title: 'Meters saved',
            message: `${result.created || 0} created, ${result.updated || 0} updated.`,
            variant: 'success'
        }));
        // Service-point warnings are STICKY and separate: they name a possible physical meter
        // swap, which is the one thing here a person has to act on later.
        (result.warnings || []).forEach((warning) => {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Check this service point',
                message: warning,
                variant: 'warning',
                mode: 'sticky'
            }));
        });
    }
}