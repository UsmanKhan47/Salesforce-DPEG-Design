import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardDealAction } from 'c/dealActionGuard';
import advance from '@salesforce/apex/StageAdvanceController.advance';

/**
 * The confirmation wording. Deliberately GENERIC — it cannot name the target stage.
 *
 * This one bundle backs FIVE quick actions (Begin Review, Initiate Underwriting, Initiate LOI,
 * Advance to PSA, Close Deal) and the target is derived SERVER-SIDE from the deal's current stage
 * inside StageAdvanceService.NEXT_STAGE. The client genuinely does not know where the deal is going.
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
    message: 'Advance this deal to the next stage?',
    label: 'Advance Deal',
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
