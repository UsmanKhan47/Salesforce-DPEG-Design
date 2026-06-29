import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import submitForApproval from '@salesforce/apex/OpportunityApprovalController.submitForApproval';

// Headless quick action on the Opportunity: one click submits the deal into the LOI
// approval process via Apex, then toasts the result and refreshes the record.
export default class SubmitForApproval extends LightningElement {
    @api recordId;

    @api async invoke() {
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