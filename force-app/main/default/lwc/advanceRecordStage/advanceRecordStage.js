import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import advance from '@salesforce/apex/RecordStageAdvanceController.advance';

/**
 * The confirmation wording. Deliberately GENERIC — it cannot name the target stage.
 *
 * This ONE bundle backs the advance action on all SEVEN stage-controlled objects, across THREE
 * modules: acquisitions (LOI__c, Underwriting__c, Construction_Feasibility_Review__c,
 * Development_Feasibility_Review__c), acquisitions/disposition shared (NDA__c,
 * Contract_Review__c — one object per module via record type) and transactions (Transaction__c,
 * added 2026-08-12). The target is derived SERVER-SIDE from the record's current stage inside
 * RecordStageAdvanceService. The client genuinely does not know where the record is going, and it
 * must not find out by guessing.
 *
 * The alternative — `@wire getRecord` for the stage field and compute the label here — is REFUSED
 * for the same reason ARCHITECTURE.md §5 already refuses it for `advanceDealStage`: it duplicates
 * the Apex stage sequences in JS, where they will silently drift the first time a stage is added.
 * Here it would be NINE sequences (CONFIG_BY_TYPE is keyed per RECORD TYPE, not per object, so
 * NDA__c and Contract_Review__c contribute two each), and the stage FIELD differs per object
 * (NDA__c uses `Status__c`, Contract_Review__c uses `Negotiation_Status__c`), so the wire itself
 * would need a per-object branch before the sequences even started drifting.
 *
 * 🔴 IF ONE OBJECT LATER NEEDS SPECIFIC WORDING, SPLIT THAT ONE ACTION INTO ITS OWN BUNDLE RATHER
 * THAN DUPLICATING THE MAP — and note that "its own bundle" means a bundle that DIFFERS. A
 * byte-identical copy carrying only a different header is not a split; it is a second file that
 * must now receive every fix this one gets. That is precisely what `c/transactionAdvanceStage` was,
 * and it was DELETED on 2026-08-12 (code review W3, user decision) in favour of this component,
 * which needed no change at all to serve `Transaction__c` — the server dispatches on
 * `Id.getSObjectType()`, so this file never learned an object's name.
 */
const CONFIRM = {
    message: 'Advance this record to the next stage?',
    label: 'Advance Stage',
    theme: 'info'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The stage could not be advanced.';

/**
 * Headless quick action shared by the "advance stage" buttons on all SEVEN stage-controlled
 * objects. The Apex derives the target from the record's current stage, so the action cannot skip a
 * hop and the client never holds a stage map.
 *
 * ⚠ It is OBJECT-AGNOSTIC BY CONSTRUCTION, not by coincidence: it names no object, imports no
 * object's schema and holds no stage value. Adding an eighth object is a `CONFIG_BY_TYPE` entry and
 * a quick action pointing here — zero changes to this file. `Transaction__c` (2026-08-12) is the
 * proof: it was added with no edit to this component at all.
 *
 * Every click runs the shared pre-flight in c/recordStageGuard first — per-record permission check,
 * then a LightningConfirm dialog — and does nothing unless both pass.
 *
 * ── 🔴 getRecordNotifyChange IS MANDATORY HERE ───────────────────────────────
 * The stage write goes through IMPERATIVE APEX, so the DML happens behind LDS's back. Without
 * getRecordNotifyChange on success the Path and the highlights panel keep showing the OLD stage
 * until the user reloads — the exact symptom this feature exists to fix. Conversely it must NOT be
 * added to any LDS-`updateRecord` bundle (c/leadStatusChange's consumers): those write THROUGH the
 * cache and re-render on their own. ARCHITECTURE.md §5 documents that the two requirements are
 * opposite and must not be harmonised.
 *
 * NOTE ON "DISABLING" THIS BUTTON: a headless quick action owns no button markup — the platform's
 * action bar renders it — so there is no `disabled` attribute this component can set. Hiding the
 * button for unauthorized users is the Dynamic Actions visibility rule (declarative); this
 * component enforces the same rule at click time, and RecordStageAdvanceController asserts it again
 * server-side.
 */
export default class AdvanceRecordStage extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!(await guardStageAction(this, this.recordId, CONFIRM))) {
            return;
        }
        try {
            const message = await advance({ recordId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Success', message, variant: 'success' })
            );
            // Apex DML bypasses the LDS cache — without this the Path shows a stale stage.
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            // A denial, a "no next step", or a validation rule's own text: all are user-safe by
            // construction (the controller masks anything unexpected), so surface them verbatim.
            const message =
                (error && error.body && error.body.message) || GENERIC_ERROR;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Cannot advance the stage',
                    message,
                    variant: 'error'
                })
            );
        }
    }
}
