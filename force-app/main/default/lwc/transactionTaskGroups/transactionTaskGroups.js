import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import CHECKLIST_FANNED_OUT_FIELD from '@salesforce/schema/Transaction__c.Checklist_Fanned_Out__c';
// New model (Checklist__c / Checklist_Item__c).
import getChecklist from '@salesforce/apex/ChecklistController.getChecklist';
import completeItem from '@salesforce/apex/ChecklistController.completeItem';
import recordWireVerification from '@salesforce/apex/ChecklistController.recordWireVerification';
// Phase 5 capture. `getCaptureContext` PERFORMS DML (it provisions the Loan__c /
// Insurance_Binder__c), so it is imperative and deliberately not a cacheable wire.
import getCaptureContext from '@salesforce/apex/ChecklistController.getCaptureContext';
import linkCaptureDocuments from '@salesforce/apex/ChecklistController.linkCaptureDocuments';
import { MONTHS } from 'c/utils';
import {
    PHASES,
    normalizeChecklistGroups,
    stripMarkerForDisplay
} from 'c/utilsTransactionChecklist';

/**
 * The Transaction closing checklist — phase cards, group rail, and the task list with its
 * confirm / anti-fraud-verification / view-details dialogs.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 AMENDED 2026-09-03 (M5) — THE SECOND DATA MODEL AND ITS DISCRIMINATOR ARE GONE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * This component used to serve TWO models at once, choosing on
 * `Transaction__c.Checklist_Fanned_Out__c`:
 *   true  -> `ChecklistController`         (Checklist__c / Checklist_Item__c)
 *   false -> `TransactionTaskController`   (legacy standard Task)
 * Three imports (`getTaskGroups`, `completeTask`, `completeWireVerification`), the legacy wire,
 * the legacy branch in `groups` / `dataError` / `dataLoaded`, and both write-path `else` branches
 * were deleted with that controller.
 *
 * 🔴 REMOVING THE DISCRIMINATOR IS SAFE ONLY BECAUSE NO DEAL CAN BE ON THE LEGACY MODEL ANY MORE,
 * AND THAT IS A MEASURED FACT ABOUT THE ORG, NOT AN INFERENCE FROM THIS FILE. The legacy fan-out
 * (`TaskFanoutService`), its queueable, its rollup, its Phase 0 prerequisite gate, its controller
 * and service, and `scripts/fanout-seeded-transactions.apex` — the last thing that could put a
 * deal BACK on the Task model — were deleted in the same change, after a probe confirmed ZERO
 * `Task` rows carry `Transaction_Deal__c` or `Task_Group__c` org-wide, and the eight
 * Transaction-only `Activity` fields went with them. Nothing can produce a legacy-model deal, so
 * the removed branch has no reachable state in which it would have been correct.
 *
 * ⚠ THERE IS ONE USER-VISIBLE CONSEQUENCE, AND NO AUTOMATED TEST IN THIS REPO CAN SEE IT.
 * `Checklist_Fanned_Out__c` is false on EVERY Transaction with no executed contract, not only on
 * migrated deals — so those deals used to take the LEGACY branch and render
 * "No tasks yet. Set the Contract Executed Date to generate the checklist." They now take the
 * checklist branch with zero rows. The empty-state copy below was rewritten to keep that
 * guidance, because losing it would be a real regression (design §7 UI-4). Verify it in a
 * browser on a deal with no `Contract_Executed_Date__c`.
 *
 * ⚠ THE `Checklist_Fanned_Out__c` LDS READ IS RETAINED, DEMOTED FROM DISCRIMINATOR TO ADVISORY.
 * It no longer selects a data source; it only distinguishes "the fan-out ran and produced
 * nothing" (worth escalating) from "this deal has not been fanned out yet" (normal). Because it
 * is advisory, A FAILED FLAG READ IS NO LONGER FATAL — it used to blank the whole component,
 * correctly, since without it neither model could be chosen. Now it degrades one sentence.
 *
 * 🔴 RISK 1 (the subject-text coupling) IS FULLY RETIRED. The `CRITICAL_RE` / `WIRE_RE` regexes
 * that used to live at the top of this file went in Phase 3; their `LEGACY_*_RE` successors in
 * `c/utilsTransactionChecklist` went at M5. Criticality and wire-verification come from
 * `Is_Critical__c` / `Is_Wire_Verification__c` — the same two fields `ChecklistRollupService`
 * uses for `Transaction__c.Wire_Open_Risks__c`, so the red flag on this screen and the number on
 * the Wire Sentinel dashboard tile cannot drift apart. NO SUBJECT IS PARSED FOR MEANING ANYWHERE
 * ON THIS PATH. `stripMarkerForDisplay` is cosmetic and stays.
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
 * `ChecklistRollupService` just wrote to the parent Transaction.
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

    _flagResolved = false;
    _fannedOut;

    _checklistWire;
    _checklistData = [];
    _checklistError;
    _checklistLoaded = false;

    _selectedPhase;
    _selectedKey;
    _wireModal = {};
    _wireSaving = false;
    _confirm = {};
    _confirmSaving = false;
    _view = {};
    // PHASE 5 capture dialog. `context` is the server-supplied CaptureRow; `loading` covers the
    // round trip that PROVISIONS the Loan__c / Insurance_Binder__c, which is why the dialog opens
    // in a loading state rather than opening empty and filling in.
    _capture = {};
    _captureSaving = false;

    // ---- Fan-out flag (ADVISORY — empty-state wording only, see the class header) ----------

    @wire(getRecord, { recordId: '$recordId', fields: [CHECKLIST_FANNED_OUT_FIELD] })
    wiredTransaction({ data, error }) {
        if (data) {
            this._fannedOut = getFieldValue(data, CHECKLIST_FANNED_OUT_FIELD);
            this._flagResolved = true;
        } else if (error) {
            // NOT fatal since M5 — this read no longer chooses a data model, so a failure here
            // must not blank a checklist the Apex wire may have loaded perfectly well.
            this._flagResolved = false;
            this._fannedOut = undefined;
        }
    }

    // ---- Data -----------------------------------------------------------------------------

    @wire(getChecklist, { transactionId: '$recordId' })
    wiredChecklist(result) {
        this._checklistWire = result;
        if (result.data) {
            this._checklistData = result.data;
            this._checklistError = undefined;
            this._checklistLoaded = true;
        } else if (result.error) {
            this._checklistError = result.error;
            this._checklistData = [];
            // Set on the ERROR branch too: the round trip is over either way, and leaving it
            // false would hold the component in its loading state behind an error it already has.
            this._checklistLoaded = true;
        }
    }

    get groups() {
        return normalizeChecklistGroups(this._checklistData);
    }

    get dataError() {
        return this._checklistError;
    }

    // ---- Render states --------------------------------------------------------------------
    // Three mutually exclusive states, so an empty checklist is VISIBLY empty and never renders as
    // blank space that reads like a successful load of nothing.

    /**
     * Whether the Apex round trip has come back — with data or with an error.
     *
     * 🔴 OMITTING THIS INVERTED THE WHOLE POINT OF THE EMPTY STATE, AND IT STILL WOULD. Between
     * mount and the wire resolving, `groups` is legitimately `[]` — and with `showEmpty` ungated,
     * every single page load rendered "no checklist items have been generated… the fan-out may not
     * have completed" for a moment, on healthy deals. An alarming, false, load-bearing message
     * shown to everyone, every time.
     *
     * ⚠ THE JEST SUITE COULD NOT SEE IT, and that is the reusable lesson: the render helpers
     * emitted every wire before asserting, so the intermediate state was never observed. There is
     * a test that asserts BEFORE the Apex wire emits.
     * ⚠ This used to be the SECOND half of a two-part loading gate; the first half (waiting on the
     * model discriminator) went at M5. Do not read its removal as making this one redundant.
     */
    get dataLoaded() {
        return this._checklistLoaded;
    }

    /** The round trip is outstanding. Neither an error nor an empty state may render while true. */
    get isLoading() {
        return !this.dataLoaded;
    }

    get hasDataError() {
        return !!this.dataError;
    }

    get dataErrorMessage() {
        const e = this.dataError;
        return (
            (e && e.body && e.body.message) ||
            'Unable to load the checklist. Please refresh and try again.'
        );
    }

    /** A genuinely empty checklist — distinct from an error and from loading. */
    get showEmpty() {
        return !this.isLoading && !this.hasDataError && this.groups.length === 0;
    }

    /**
     * 🔴 THE EMPTY-STATE COPY IS WHERE THE RETIRED DISCRIMINATOR STILL MATTERS (M5, design §7
     * UI-4). Before M5, a deal with `Checklist_Fanned_Out__c = false` took the LEGACY branch and
     * was told what to DO about it — "Set the Contract Executed Date to generate the checklist."
     * That is the single most useful sentence this component renders, it applies to every deal
     * before contract execution, and collapsing both cases into the new model's "contact your
     * administrator" message would have replaced actionable guidance with an escalation for a
     * perfectly normal state. So the fan-out flag is still read, purely to keep this distinction.
     *
     * The third branch is REACHABLE and is not padding: it means the advisory LDS read failed, so
     * neither diagnosis can be asserted honestly and the copy says only what is certainly true.
     */
    get emptyMessage() {
        if (!this._flagResolved) {
            return 'No checklist items to show for this deal.';
        }
        if (this._fannedOut === true) {
            return 'This deal has a checklist, but no items have been generated for it yet. If that looks wrong, contact your administrator — the fan-out may not have completed.';
        }
        return 'No checklist yet. Set the Contract Executed Date to generate the checklist.';
    }

    get showContent() {
        return !this.isLoading && !this.hasDataError && this.groups.length > 0;
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
                    // PHASE 5. Routes the click to the capture dialog instead of the plain confirm
                    // dialog. Server-derived from the item COORDINATE; never re-derived here, and
                    // always false on the legacy model.
                    capture: item.hasCapture === true,
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
        // PHASE 5. An item that records an output elsewhere goes to the capture dialog. The wire
        // branch above wins when both are true, which cannot happen today (no wire-verification
        // item carries a capture def) but is ordered deliberately: the anti-fraud control is the
        // more specific one and must never be displaced by a generic dialog.
        // ⚠ The `&& this.isChecklistModel` conjunct was dropped at M5 — capture is a
        // Checklist_Item__c-only feature and there is no other model left to exclude. `hasCapture`
        // is resolved SERVER-SIDE from the item's coordinate, so a row that carries it is by
        // construction a checklist item.
        if (event.target.dataset.capture === 'true') {
            event.target.checked = false; // hold unchecked until the capture is saved
            this.openCapture(itemId, subject);
            return;
        }
        event.target.checked = false; // hold unchecked until confirmed
        this._confirm = { open: true, itemId, subject, notes: '' };
    }

    /**
     * Refreshes both the checklist itself and the parent Transaction after a successful write.
     *
     * ⚠ THE `notifyRecordUpdateAvailable` CALL IS NOT OPTIONAL. The completion was an imperative
     * Apex DML, and `ChecklistRollupService` then wrote `Tasks_Complete__c` / `Wire_Open_Risks__c`
     * on the parent — all of it behind LDS's back. Without this, the Path and the highlights panel
     * keep showing the counters from before the click until the user reloads the page.
     * ⚠ It ALSO refreshes the advisory `Checklist_Fanned_Out__c` read, which is harmless and
     * slightly useful: completing the last item on a freshly fanned-out deal leaves both LDS
     * caches consistent.
     */
    async refreshAfterWrite() {
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        if (this._checklistWire) {
            await refreshApex(this._checklistWire);
        }
    }

    /**
     * Surfaces a server refusal.
     *
     * ⚠ THE MESSAGE IS MARKER-STRIPPED, and only for that. The wire-fraud gate interpolates the
     * blocking item's raw `Subject__c` into its text, so an unstripped toast names the step
     * `"… (anti-fraud)"` while the row above it shows the same step without the marker. The
     * WORDING is untouched — the server still owns the explanation.
     */
    toastFailure(title, e, fallback) {
        const raw = (e && e.body && e.body.message) || fallback;
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message: stripMarkerForDisplay(raw) || fallback,
                variant: 'error',
                mode: 'sticky'
            })
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
            await completeItem({ itemId, comment: notes });
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

    // ---- Capture dialog (Phase 5) ----------------------------------------------------------
    //
    // 🔴 THE CAPTURED VALUES ARE WRITTEN BY LIGHTNING DATA SERVICE, NOT BY APEX.
    // ARCHITECTURE.md §5 ranks LDS first and reserves imperative Apex for what LDS cannot express.
    // Writing `Lender_Name__c` or `Bank_Account_Type__c` on one record is the textbook
    // `lightning-record-edit-form` case, and routing it through LDS buys three things an Apex
    // writer would have to reimplement: field-level security enforced by the platform, restricted
    // picklists rendered as comboboxes that can only offer real values, and the object's own
    // validation rules. The server side of Phase 5 therefore never names a captured field in a
    // write payload — `ChecklistCaptureService` only CREATES the row and returns its Id.
    //
    // 🔴 THE DOCUMENT UPLOAD IS `lightning-file-upload`, AND THAT IS A QUOTA DECISION.
    // Every `ContentVersion` insert consumes one of the org's 2,500-per-rolling-24-hours
    // `ContentPublication` allowance, test rollback does not refund it, and an overrun throws a
    // `System.UnexpectedException` that escapes `catch (Exception)` and aborts the whole
    // transaction — it caused a production outage here on 2026-08-06. `lightning-file-upload`
    // publishes in the PLATFORM's transaction, so no Apex of ours is ever inside the one that
    // could abort. Apex afterwards only inserts a `ContentDocumentLink`, which costs no quota.
    // ⚠ Do not replace this with a base64 payload sent to Apex. That is the shape of the incident.

    get showCaptureModal() {
        return !!this._capture.open;
    }
    get captureSubject() {
        return this._capture.subject || '';
    }
    get captureLoading() {
        return this._capture.loading === true;
    }
    get captureContext() {
        return this._capture.context || {};
    }
    get isFieldCapture() {
        return this.captureContext.captureMode === 'TARGET_FIELDS';
    }
    get isDocumentCapture() {
        return this.captureContext.captureMode === 'DOCUMENT';
    }
    /**
     * `for:each` needs a keyed object per row; a bare array of strings cannot supply `key`.
     * The `name` is the field API name handed straight to `lightning-input-field`.
     */
    get captureFieldRows() {
        return (this.captureContext.captureFields || []).map((apiName) => ({
            key: apiName,
            name: apiName
        }));
    }
    get captureObjectApiName() {
        return this.captureContext.objectApiName;
    }
    get captureTargetRecordId() {
        return this.captureContext.targetRecordId;
    }
    /** Deal documents are contracts, reports and binders — not an open-ended file drop. */
    get captureAcceptedFormats() {
        return ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.png', '.jpg', '.jpeg'];
    }
    /**
     * The server-supplied explanation of what must be recorded, replaced by the server's REFUSAL
     * text once one has been received. Both come from `ChecklistCaptureDefProvider`, so the
     * pre-emptive hint and the eventual refusal are the same sentence and cannot drift.
     */
    get captureRequirementMessage() {
        return this._capture.requirementError || this.captureContext.requirementMessage || '';
    }
    get hasCaptureRequirement() {
        return !!this.captureRequirementMessage;
    }
    get captureDocumentOnFile() {
        return this._capture.documentOnFile === true;
    }
    /**
     * ⚠ THIS IS A CONVENIENCE, NOT A CONTROL. The document requirement is enforced by
     * `ChecklistCaptureService.assertCaptureSatisfied` on the server; disabling the button only
     * saves the user a round trip. The FIELD requirement is deliberately NOT mirrored here at all —
     * the value lives inside `lightning-record-edit-form`, and reading it out to second-guess the
     * server would be a client-side gate on data the server is about to re-check anyway.
     */
    get captureSaveDisabled() {
        return (
            this._captureSaving ||
            this.captureLoading ||
            (this.isDocumentCapture && !this.captureDocumentOnFile)
        );
    }

    /**
     * Opens the capture dialog and asks the server what this item records.
     *
     * ⚠ THE ROUND TRIP PROVISIONS THE TARGET RECORD, so the dialog opens in a loading state rather
     * than opening empty and filling in — a `lightning-record-edit-form` rendered with an undefined
     * `record-id` silently becomes a CREATE form, which would make a second Loan__c on every open.
     */
    async openCapture(itemId, subject) {
        this._capture = { open: true, itemId, subject, loading: true };
        try {
            const context = await getCaptureContext({ itemId });
            if (!context) {
                // The server says this item records nothing after all — a definition changed under
                // a page that was already open. Fall back to the ordinary confirm dialog rather
                // than showing an empty capture form.
                this._capture = {};
                this._confirm = { open: true, itemId, subject, notes: '' };
                return;
            }
            this._capture = {
                open: true,
                itemId,
                subject,
                loading: false,
                context,
                documentOnFile: context.satisfied === true
            };
        } catch (e) {
            this._capture = {};
            this.toastFailure(
                'Item not completed',
                e,
                'Could not open this item. Please try again.'
            );
        }
    }

    cancelCapture() {
        this._capture = {};
    }

    /**
     * Files the just-uploaded documents against the checklist item.
     *
     * The `ContentVersion` already exists — `lightning-file-upload` created it against the deal in
     * the platform's own transaction. This adds the per-item `ContentDocumentLink` that makes the
     * server-side "has this item got its document?" guard mean something; without it the guard
     * could only ask whether the DEAL has any file at all, which every deal does, so it would pass
     * vacuously forever.
     */
    async handleUploadFinished(event) {
        const documentIds = (event.detail.files || []).map((f) => f.documentId).filter(Boolean);
        if (!documentIds.length) {
            return;
        }
        try {
            await linkCaptureDocuments({ itemId: this._capture.itemId, contentDocumentIds: documentIds });
            this._capture = { ...this._capture, documentOnFile: true, requirementError: '' };
        } catch (e) {
            // ⚠ SET THE MESSAGE, DO NOT CLEAR IT. An earlier version assigned `requirementError:
            // ''` here, which wiped the dialog's only visible explanation at the exact moment one
            // was needed: the file IS uploaded (the platform already published it against the deal)
            // but it is NOT filed against this item, so the server guard will keep refusing the
            // completion and the dialog would say nothing about why. `documentOnFile` is
            // deliberately left false, so Confirm stays disabled rather than offering an action
            // that cannot succeed.
            const raw = (e && e.body && e.body.message) || '';
            this._capture = {
                ...this._capture,
                requirementError:
                    raw ||
                    'The file uploaded to the deal but could not be filed against this item. Upload it again.'
            };
            this.toastFailure(
                'Document not filed',
                e,
                'The file uploaded but could not be filed against this item. Please try again.'
            );
        }
    }

    /**
     * Submits the capture.
     *
     * For a FIELD capture this only asks the `lightning-record-edit-form` to save; the completion
     * happens in `handleCaptureSuccess` once LDS confirms the write. Completing first and saving
     * second would tick an item whose output then failed to save.
     */
    submitCapture() {
        this._capture = { ...this._capture, requirementError: '' };
        if (this.isFieldCapture) {
            this._captureSaving = true;
            // ⚠ CLASS SELECTOR, NOT AN ID. LWC rewrites static `id` attributes at render time, so
            // `querySelector('#something')` never matches in Jest and is fragile in the browser.
            const form = this.template.querySelector('.tg-capture-form');
            // ⚠ THE `typeof` GUARD IS FOR JEST, NOT FOR THE BROWSER, AND IT IS NOT DEFENSIVE
            // PADDING. The sfdx-lwc-jest stub for `lightning-record-edit-form` is a bare custom
            // element with no `submit()`, so an unguarded call throws inside every test that opens
            // a field capture and the suite would be testing the stub rather than this component.
            // In the browser the method always exists. The consequence for the SUITE is stated in
            // its Phase 5 block: Jest can prove that Confirm does NOT complete the item directly,
            // and that `onsuccess` DOES — it cannot prove the form was actually asked to save.
            if (form && typeof form.submit === 'function') {
                form.submit();
                return;
            }
            this._captureSaving = false;
            return;
        }
        this.completeCapturedItem();
    }

    /** LDS saved the target record. Now complete the item. */
    handleCaptureSuccess() {
        this.completeCapturedItem();
    }

    /** LDS refused the target record write. The item is NOT completed. */
    handleCaptureError(event) {
        this._captureSaving = false;
        const detail = (event && event.detail && event.detail.message) || '';
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Details not saved',
                message: detail || 'The details could not be saved. Please check the fields and try again.',
                variant: 'error',
                mode: 'sticky'
            })
        );
    }

    /**
     * Completes the item once its output is recorded.
     *
     * ⚠ A `CaptureRequiredException` CAN STILL ARRIVE HERE, and it is not a bug when it does. The
     * server re-checks; if the user cleared a required field in the form and saved it blank, the
     * form save succeeds and the completion is refused. The refusal text is kept IN THE DIALOG
     * rather than only toasted, because the dialog is where the fix is.
     */
    async completeCapturedItem() {
        const { itemId } = this._capture;
        this._captureSaving = true;
        try {
            await completeItem({ itemId, comment: null });
            this._capture = {};
            await this.refreshAfterWrite();
        } catch (e) {
            const raw = (e && e.body && e.body.message) || '';
            this._capture = { ...this._capture, requirementError: raw };
            this.toastFailure(
                'Item not completed',
                e,
                'Could not complete the item. Please try again.'
            );
        } finally {
            this._captureSaving = false;
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
            await recordWireVerification({
                itemId,
                verifiedByName: verifiedBy.trim(),
                phone: phone.trim(),
                comment: (comments || '').trim()
            });
            this._wireModal = {};
            await this.refreshAfterWrite();
        } catch (e) {
            // Marker-stripped for the same reason as toastFailure above.
            const raw =
                (e && e.body && e.body.message) ||
                'Could not save the verification. Please try again.';
            this._wireModal = { ...this._wireModal, error: stripMarkerForDisplay(raw) || raw };
        } finally {
            this._wireSaving = false;
        }
    }
}
