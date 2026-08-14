import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardDealAction } from 'c/dealActionGuard';
import advanceTo from '@salesforce/apex/StageAdvanceController.advanceTo';

const TARGET = 'Construction Review';
const CONFIRM = {
    message: 'Send this deal to Construction Review?',
    label: 'Send to Construction Review',
    theme: 'info'
};

/**
 * Headless quick action: send a COMMERCIAL deal from Under Review to Construction Review.
 *
 * Construction Review and Development Review are MUTUALLY EXCLUSIVE BRANCHES, not sequential steps —
 * Construction Review exists only in the Retail business process, Development Review only in
 * Land. That is why this bundle and its Land twin hardcode their own target rather than sharing
 * advanceDealStage's derive-from-current-stage route: from Under Review the next stage is ambiguous,
 * and only Deal_Type__c resolves it. The visibility rule on the Highlights Panel gates this button on
 * `Deal_Type__c = Retail`.
 *
 * Every click runs the shared pre-flight in c/dealActionGuard first — permission check, then a
 * LightningConfirm dialog — and does nothing unless both pass. The write goes through imperative
 * Apex, so getRecordNotifyChange is REQUIRED on success (Apex DML bypasses the LDS cache, so the
 * Path/highlights would otherwise show a stale stage). `Construction Review` is also on
 * StageAdvanceService's explicit-target allow-list, which now rejects any other value.
 */
export default class DealSendToConstructionReview extends LightningElement {
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
