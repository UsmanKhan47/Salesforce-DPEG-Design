import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import advanceTo from '@salesforce/apex/StageAdvanceController.advanceTo';

/** Headless quick action: send a Land deal from Under Review to Development Review. */
export default class DealSendToDevelopmentReview extends LightningElement {
    @api recordId;

    @api async invoke() {
        try {
            const message = await advanceTo({ recordId: this.recordId, target: 'Development Review' });
            this.dispatchEvent(new ShowToastEvent({ title: 'Success', message, variant: 'success' }));
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            const message =
                (error && error.body && error.body.message) || 'The deal could not be advanced.';
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Cannot advance the deal', message, variant: 'error' })
            );
        }
    }
}