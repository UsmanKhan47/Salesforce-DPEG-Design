import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import submitForApproval from '@salesforce/apex/DispositionApprovalController.submitForApproval';

/**
 * The confirmation wording. Deliberately GENERIC — it cannot name the approval process.
 *
 * ONE bundle backs ALL FOUR Submit quick actions on Disposition__c
 * (`Submit_Sale_Decision`, `Submit_Selected_Broker`, `Submit_Broker_Selection`,
 * `Submit_Closing_Approval`), and each of them submits a DIFFERENT thing:
 *
 *   Disposition Readiness   the Disposition        -> Sale_Decision_Approval
 *   BOV Outreach (On)       the SELECTED BOV_Submission__c -> Broker_Finalize_Approval
 *   Broker Selection (Off)  the Disposition        -> Broker_Selection_Approval
 *   Closing                 the Disposition        -> Closing_Approval
 *
 * `DispositionApprovalService.submitForApproval` derives which one from the record's stage AND
 * record type, SERVER-SIDE. The client genuinely does not know what it is submitting, and it must
 * not find out by guessing. Wiring `getRecord` for the stage and branching the wording here would
 * copy that derivation table into JS, where there is no compile link to the Apex and it drifts
 * silently the first time a stage is inserted — the same argument `c/advanceRecordStage` records at
 * length for its own generic wording.
 *
 * theme 'warning', not 'info', matching `c/submitForApproval` (the Opportunity twin) and for the
 * same reason: submitting into a principal approval is not a write the user can simply repeat. It
 * creates a pending approval instance, notifies the approver, LOCKS the record
 * (`recordEditability = AdminOnly`), and a second submit while one is pending is REFUSED. The
 * dialog should not look like a routine forward hop.
 */
const CONFIRM = {
    message: 'Submit this disposition for approval?',
    label: 'Submit for Approval',
    theme: 'warning'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'This disposition could not be submitted for approval.';

/**
 * c-disposition-submit-for-approval — headless quick action behind all four Disposition__c
 * "Submit ... for Approval" buttons.
 *
 * ── 🔴 WHY THIS IS NOT `c/submitForApproval` ─────────────────────────────────
 * `c/submitForApproval` is bound to the ACQUISITIONS gate by two hard imports: it calls
 * `c/dealActionGuard`, whose `hasDealActionAccess()` takes NO argument and resolves the
 * OPPORTUNITY permission controller at module scope, and it posts to
 * `OpportunityApprovalController`. Neither can express "which object's gate?", so reusing it here
 * would ask the acquisitions question about a disposition record and answer it for the wrong
 * persona. ARCHITECTURE.md §5 already records that the guard utils must not be merged.
 *
 * This bundle uses `c/recordStageGuard` instead, whose permission question is PER-RECORD — it
 * passes the recordId to `RecordStageAdvanceController.hasStageActionAccess`, which dispatches on
 * `Id.getSObjectType()` and resolves `Disposition__c` to the `DISPOSITION_DRIVER` gate
 * (`Disposition_Deal_Actions` custom permission). No new Apex and no new guard module was needed:
 * the recordId-taking signature that looked speculative when it was written is what makes this a
 * zero-Apex reuse.
 *
 * ⚠ THE GUARD IS SHARED WITH THE *ADVANCE* ACTION, WHICH IS CORRECT AND NOT A CONFLATION. Both
 * questions are "may this user drive this disposition's stage?", answered by the same custom
 * permission. `DispositionApprovalController` asserts it again server-side, so this check is a
 * courtesy that produces a better message — removing it would degrade UX, not open a hole.
 *
 * ── 🔴 getRecordNotifyChange IS MANDATORY HERE ───────────────────────────────
 * The submission goes through IMPERATIVE APEX, so the DML happens behind LDS's back. Without it the
 * Path, the highlights panel and every Dynamic Actions visibility rule on the page keep evaluating
 * the OLD field values until the user reloads — which, since those rules are what show and hide
 * these very buttons, means the button the user just pressed stays on screen. Conversely it must
 * NOT be added to any LDS-`updateRecord` bundle: those write THROUGH the cache and re-render on
 * their own (ARCHITECTURE.md §5).
 *
 * A headless quick action owns no button markup — the platform's action bar renders it — so there
 * is no `disabled` attribute this component could set. Hiding the button for unauthorized users is
 * the Dynamic Actions visibility rule (declarative); this component enforces the same rule at click
 * time. The two are COMPLEMENTARY, not alternatives.
 */
export default class DispositionSubmitForApproval extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!(await guardStageAction(this, this.recordId, CONFIRM))) {
            return;
        }
        try {
            // ⚠ THE APEX PARAMETER IS `dispositionId`, NOT `recordId`:
            // DispositionApprovalController.submitForApproval(Id dispositionId). An imperative
            // Apex call binds by NAME — a mismatch is not a compile error on either side, it
            // simply arrives null and throws a far less obvious error at the server.
            const message = await submitForApproval({ dispositionId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Submitted for approval',
                    message,
                    variant: 'success'
                })
            );
            // Apex DML bypasses the LDS cache — without this the Path and the action bar keep
            // showing the pre-submission state.
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            // The service's refusals are AUTHORED to be shown — "no BOV submission is Selected",
            // "wire verification is not complete", "an approval is already pending" — and the
            // controller masks anything unexpected. Surface them verbatim; replacing them with
            // generic wording is what leaves a user staring at the platform's useless "no
            // applicable approval process was found".
            const message = (error && error.body && error.body.message) || GENERIC_ERROR;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Cannot submit for approval',
                    message,
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        }
    }
}
