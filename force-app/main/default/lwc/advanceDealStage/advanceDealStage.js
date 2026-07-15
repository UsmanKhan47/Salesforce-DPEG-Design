import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import advance from '@salesforce/apex/StageAdvanceController.advance';

/**
 * Headless quick action shared by the per-stage "advance" buttons on the
 * Opportunity (Begin Review, Initiate Underwriting, Initiate LOI, Advance to
 * PSA, Close Deal). The Apex derives the action from the deal's current stage;
 * each button is shown only on its stage via Dynamic Actions visibility on the
 * Highlights Panel.
 */
export default class AdvanceDealStage extends LightningElement {
    @api recordId;

    @api async invoke() {
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