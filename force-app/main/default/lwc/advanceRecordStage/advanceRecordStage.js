import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import advance from '@salesforce/apex/RecordStageAdvanceController.advance';

/**
 * The confirmation wording. Deliberately GENERIC — it cannot name the target stage.
 *
 * This ONE bundle backs FIVE quick actions across FIVE different objects (NDA, LOI, Underwriting,
 * Construction Feasibility Review, Development Feasibility Review) and the target is derived
 * SERVER-SIDE from the record's current stage inside RecordStageAdvanceService. The client
 * genuinely does not know where the record is going, and it must not find out by guessing.
 *
 * The alternative — `@wire getRecord` for the stage field and compute the label here — is REFUSED
 * for the same reason ARCHITECTURE.md §5 already refuses it for `advanceDealStage`: it duplicates
 * the Apex stage maps in JS, where they will silently drift the first time a stage is added. Here
 * it would be five maps, not one, and the stage FIELD differs per object (NDA uses `Status__c`),
 * so the wire itself would need a per-object branch before the map even started drifting.
 *
 * If one object later needs specific wording, split THAT ONE action into its own bundle rather than
 * duplicating the map.
 */
const CONFIRM = {
    message: 'Advance this record to the next stage?',
    label: 'Advance Stage',
    theme: 'info'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The stage could not be advanced.';

/**
 * Headless quick action shared by the "advance stage" buttons on the five stage-controlled
 * acquisitions child objects. The Apex derives the target from the record's current stage, so the
 * action cannot skip a hop and the client never holds a stage map.
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
