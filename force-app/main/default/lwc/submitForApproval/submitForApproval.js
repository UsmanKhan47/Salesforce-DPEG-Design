import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardDealAction } from 'c/dealActionGuard';
import submitForApproval from '@salesforce/apex/OpportunityApprovalController.submitForApproval';

/**
 * theme 'warning', not 'info', unlike the stage-advance actions. Submitting into the principal
 * approval is not a stage write the user can simply repeat: it creates a pending approval instance,
 * notifies the approver, and a second submit while one is pending is REFUSED. The dialog should look
 * different from a routine forward hop.
 */
const CONFIRM = {
    message: 'Submit this deal for principal approval?',
    label: 'Submit for Approval',
    theme: 'warning'
};

/**
 * Headless quick action on the Opportunity (and the LOI / Underwriting / Contract Review record
 * pages): one click submits the deal into the principal LOI approval process via Apex, then toasts
 * the result and refreshes the record. A custom action rather than the native dynamic
 * Submit-for-Approval, which does not render reliably in Lightning.
 *
 * Every click runs the shared pre-flight in c/dealActionGuard first — permission check, then a
 * LightningConfirm dialog — and does nothing unless both pass. Submission goes through imperative
 * Apex, so getRecordNotifyChange is REQUIRED on success (Apex DML bypasses the LDS cache).
 * OpportunityApprovalController asserts the same permission server-side.
 */
export default class SubmitForApproval extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!(await guardDealAction(this, CONFIRM))) {
            return;
        }
        try {
            const message = await submitForApproval({ recordId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Submitted for approval',
                    message,
                    variant: 'success'
                })
            );
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (e) {
            const message =
                (e && e.body && e.body.message) || 'Could not submit this deal for approval.';
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Submit for approval failed',
                    message,
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        }
    }
}
