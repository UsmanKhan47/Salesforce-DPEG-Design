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
 * Headless quick action: move a deal from `Under Contract (PSA)` to About to Close.
 *
 * ⚠ The stage was renamed `PSA` -> `Under Contract (PSA)` in Acquisition Observations phase 2.
 * This bundle passes only the CONSTANT `About to Close`, so nothing functional here moved — the
 * prose below is repointed so the NEXT_STAGE argument it records stays checkable.
 *
 * ── WHY THIS BUNDLE EXISTS (design doc D3) ────────────────────────────────────
 * `About to Close` is a real stage in BOTH business processes (Land and Retail) and appears on
 * the deal Path, but no button entered or left it: StageAdvanceService.NEXT_STAGE maps
 * `Under Contract (PSA) -> Closed Won`, so the Close Deal button skips straight past it. The stage
 * was reachable only by inline edit, the Path, or the API.
 *
 * ── WHY IT CANNOT USE advanceDealStage ────────────────────────────────────────
 * This is an EXPLICIT-TARGET bundle (the same pattern as the two Send-to-Review branch actions)
 * rather than a caller of the derive-from-current-stage route. It passes the constant `About to
 * Close`, which is on `StageAdvanceService.ALLOWED_EXPLICIT_TARGETS`.
 *
 * ⚠ THE ORIGINAL REASON FOR THAT CHOICE EXPIRED ON 2026-09-02 AND IS RECORDED HERE RATHER THAN
 * DELETED. It used to read: "`NEXT_STAGE` holds ONE primary next stage per current stage, and
 * `Under Contract (PSA)`'s is already `Closed Won`. A deal at that stage now has two legitimate
 * forward moves, which a single-target map cannot express." PSA's primary target IS `About to
 * Close` now, so the map could express this hop and this bundle is no longer strictly necessary.
 * It is kept because it is a live, deployed quick action with its own confirm dialog and its own
 * FlexiPage criterion, and retiring a working button is a separate decision nobody has asked for.
 *
 * ── 🔴 NEXT_STAGE WAS REPOINTED ON 2026-09-02. THIS PARAGRAPH USED TO FORBID IT. ──────────────
 * It read: "`Under Contract (PSA) -> Closed Won` remains the PRIMARY route … Rerouting that
 * stage's primary target to `About to Close` would have silently added a mandatory extra click to
 * every deal that closes, changing the behaviour of a live button (Close Deal) that nobody asked
 * to change. … Revisit only if About to Close becomes a required step."
 *
 * **About to Close became a required step.** `Transaction_Closed_Before_Closed_Won` (2026-09-02)
 * fails CLOSED — a deal with no `Transaction__c` cannot reach `Closed Won` — and entering this
 * stage is the only in-app route that opens one (`ContractExecutionService
 * .openTransactionsOnAboutToClose`). So the condition this paragraph set for revisiting is the
 * condition that was met, and the repoint was made under it rather than in spite of it.
 *
 * 🟢 The feared cost did not materialise. `flexipages/Opportunity_Record_Page` already gates
 * `Opportunity.Close_Deal` on `StageName EQUAL 'About to Close'` and this bundle's action on
 * `EQUAL 'Under Contract (PSA)'` — the two buttons were never both visible at PSA, so the page
 * ALREADY required this click and the repoint added none. The "silently added a mandatory extra
 * click" sentence was describing a page configuration that no longer existed by the time it
 * mattered. Full argument at `StageAdvanceService`'s NEXT_STAGE declaration.
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
