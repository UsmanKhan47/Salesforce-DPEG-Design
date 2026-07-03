import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import submitForApproval from '@salesforce/apex/LeaseRenewalController.submitForApproval';

// Headless quick action: one click submits the renewal rate into the
// Renewal Rate Approval process, toasts the result, and refreshes the record.
export default class RenewalSubmitForApproval extends LightningElement {
    @api recordId;

    @api async invoke() {
        try {
            const message = await submitForApproval({ recordId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Submitted for approval', message, variant: 'success' })
            );
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (e) {
            const message =
                (e && e.body && e.body.message) || 'Could not submit this renewal for approval.';
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Submit for approval failed', message, variant: 'error', mode: 'sticky' })
            );
        }
    }
}
