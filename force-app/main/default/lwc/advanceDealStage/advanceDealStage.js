import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardDealAction } from 'c/dealActionGuard';
import advance from '@salesforce/apex/StageAdvanceController.advance';

/**
 * The confirmation wording. Deliberately GENERIC — it cannot name the target stage.
 *
 * ── 🔴 WHY THE LABEL IS NOT THE BUTTON'S LABEL (2026-08-27) ──────────────────
 * It used to read 'Advance Deal', which matched no button at all. All FIVE quick actions that invoke
 * this bundle are named for what they DO — "Begin Review", "Initiate Underwriting", "Initiate LOI",
 * "Advance to Under Contract (PSA)", "Close Deal" — so a user who clicked "Initiate LOI" was handed
 * a dialog headed "Advance Deal". The header is now a neutral statement of what the dialog is FOR,
 * chosen to read correctly underneath ANY of those five labels. Same string as the sibling
 * c/advanceRecordStage, which retired 'Advance Stage' for this exact reason on the same day — one
 * confirmation header across both bundles, deliberately.
 *
 * ⚠ IT CANNOT ECHO THE DESTINATION, AND THE REASON IS ORDERING, NOT LAZINESS. The dialog is opened
 * by `guardDealAction` BEFORE `advance()` is called, and `advance(recordId)` is the only thing that
 * resolves the target — it computes `NEXT_STAGE.get(StageName)` server-side and commits the DML in
 * the same call. There is no @AuraEnabled method that returns the target WITHOUT advancing (the only
 * other one, `advanceTo`, takes the target as an ARGUMENT — it is told, it does not tell). So at the
 * moment this label is needed, the destination does not exist anywhere on the client.
 *
 * ⚠ AND THE MESSAGE SAID SOMETHING FALSE. It read 'Advance this deal to the next stage?', but on the
 * Underwriting hop — the one behind "Initiate LOI" — StageAdvanceService.advance does NOT write a
 * stage at all: `StageName == 'Underwriting'` is absent from NEXT_STAGE and routes to
 * OpportunityApprovalService.submitForApproval. The deal reaches LOI only if a principal approves.
 * Promising a stage change there was wrong, not merely vague. 'next step' is the union of both
 * outcomes and is the service's OWN vocabulary for it ("There is no next step available from the
 * <X> stage."). This is the ONE wording difference from c/advanceRecordStage, whose bundle has no
 * approval hop and whose message was correct as written.
 *
 * The two alternatives were considered and rejected:
 *   - @wire getRecord for StageName and compute the label here: this duplicates the NEXT_STAGE map
 *     in JS, where it will silently drift from the Apex the first time a stage is added.
 *   - Split the bundle into five per-action bundles so each can name its own target: more accurate
 *     wording at the cost of five near-identical bundles and five Jest suites.
 * A generic prompt with no duplicated map is the honest trade. If Close Deal ("Close this deal as
 * Won?") later needs specific wording, split THAT ONE action out rather than duplicating the map.
 */
const CONFIRM = {
    message: 'Move this deal to its next step?',
    label: 'Confirm Stage Change',
    theme: 'info'
};

/**
 * Headless quick action shared by the per-stage "advance" buttons on the Opportunity (Begin Review,
 * Initiate Underwriting, Initiate LOI, Advance to PSA, Close Deal). The Apex derives the target from
 * the deal's current stage; each button is shown only on its own stage via a Dynamic Actions
 * visibility rule on the Highlights Panel.
 *
 * Every click runs the shared pre-flight in c/dealActionGuard first — permission check, then a
 * LightningConfirm dialog — and does nothing unless both pass. The stage write then goes through
 * imperative Apex, so getRecordNotifyChange is REQUIRED on success: unlike an LDS `updateRecord`,
 * Apex DML happens behind LDS's back and the Path/highlights would otherwise show a stale stage.
 *
 * NOTE ON "DISABLING" THIS BUTTON: a headless quick action owns no button markup — the platform's
 * action bar renders it — so there is no `disabled` attribute this component can set. Hiding the
 * button for unauthorized users is the Dynamic Actions visibility rule (declarative); this component
 * enforces the same rule at click time, and StageAdvanceController asserts it again server-side.
 */
export default class AdvanceDealStage extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!(await guardDealAction(this, CONFIRM))) {
            return;
        }
        try {
            const message = await advance({ recordId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Success', message, variant: 'success' })
            );
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            const message =
                (error && error.body && error.body.message) ||
                'The deal could not be advanced.';
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Cannot advance the deal', message, variant: 'error' })
            );
        }
    }
}
