import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardDealAction } from 'c/dealActionGuard';
import advanceTo from '@salesforce/apex/StageAdvanceController.advanceTo';

const TARGET = 'Development Review';
const CONFIRM = {
    message: 'Send this deal to Development Review?',
    label: 'Send to Development Review',
    theme: 'info'
};

/**
 * Headless quick action: send a LAND deal from Under Review to Development Review.
 *
 * Development Review and Construction Review are MUTUALLY EXCLUSIVE BRANCHES, not sequential steps —
 * Development Review exists only in the Land business process, Construction Review only in
 * Commercial. That is why this bundle and its Commercial twin hardcode their own target rather than
 * sharing advanceDealStage's derive-from-current-stage route: from Under Review the next stage is
 * ambiguous, and only Deal_Type__c resolves it. The visibility rule on the Highlights Panel gates
 * this button on `Deal_Type__c = Land`.
 *
 * Every click runs the shared pre-flight in c/dealActionGuard first — permission check, then a
 * LightningConfirm dialog — and does nothing unless both pass. The write goes through imperative
 * Apex, so getRecordNotifyChange is REQUIRED on success (Apex DML bypasses the LDS cache, so the
 * Path/highlights would otherwise show a stale stage). `Development Review` is also on
 * StageAdvanceService's explicit-target allow-list, which now rejects any other value.
 */
export default class DealSendToDevelopmentReview extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!(await guardDealAction(this, CONFIRM))) {
            return;
        }
        try {
            const message = await advanceTo({ recordId: this.recordId, target: TARGET });
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
