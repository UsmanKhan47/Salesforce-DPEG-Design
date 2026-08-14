import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardDealAction } from 'c/dealActionGuard';
import advanceTo from '@salesforce/apex/StageAdvanceController.advanceTo';

const TARGET = 'About to Close';
const CONFIRM = {
    message: 'Move this deal to About to Close?',
    label: 'Move to About to Close',
    theme: 'info'
};

/**
 * Headless quick action: move a deal from PSA to About to Close.
 *
 * ── WHY THIS BUNDLE EXISTS (design doc D3) ────────────────────────────────────
 * `About to Close` is a real stage in BOTH business processes (Land and Retail) and appears on
 * the deal Path, but no button entered or left it: StageAdvanceService.NEXT_STAGE maps
 * `PSA -> Closed Won`, so the Close Deal button skips straight past it. The stage was reachable only
 * by inline edit, the Path, or the API.
 *
 * ── WHY IT CANNOT USE advanceDealStage ────────────────────────────────────────
 * `NEXT_STAGE` holds ONE primary next stage per current stage, and PSA's is already `Closed Won`. A
 * PSA deal now has two legitimate forward moves, which a single-target map cannot express — so this
 * is an EXPLICIT-TARGET bundle (the same pattern as the two Send-to-Review branch actions) rather
 * than a fifth caller of the derive-from-current-stage route.
 *
 * ── NEXT_STAGE WAS DELIBERATELY LEFT ALONE ────────────────────────────────────
 * `PSA -> Closed Won` remains the PRIMARY route: Close Deal still closes a PSA deal as Won in one
 * click, and About to Close stays an OPTIONAL explicit stop. Rerouting PSA's primary target to
 * `About to Close` would have silently added a mandatory extra click to every deal that closes,
 * changing the behaviour of a live button (Close Deal) that nobody asked to change. Both actions are
 * visible on PSA; the user picks. Revisit only if About to Close becomes a required step.
 *
 * Every click runs the shared pre-flight in c/dealActionGuard first — permission check, then a
 * LightningConfirm dialog — and does nothing unless both pass. The write goes through imperative
 * Apex, so getRecordNotifyChange is REQUIRED on success (Apex DML bypasses the LDS cache, so the
 * Path/highlights would otherwise show a stale stage). `About to Close` is on
 * StageAdvanceService's explicit-target allow-list, which now rejects any other value.
 */
export default class DealMoveToAboutToClose extends LightningElement {
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
