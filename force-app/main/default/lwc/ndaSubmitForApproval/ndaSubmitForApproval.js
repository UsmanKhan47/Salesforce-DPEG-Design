import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import submitNdaForApproval from '@salesforce/apex/DispositionApprovalController.submitNdaForApproval';

/**
 * The confirmation wording.
 *
 * ⚠ UNLIKE `c/dispositionSubmitForApproval`, THIS ONE CAN NAME WHAT IT IS SUBMITTING, AND IT DOES.
 * That bundle is deliberately generic because ONE bundle backs FOUR quick actions submitting three
 * different records into four different processes, derived server-side — the client genuinely does
 * not know. Here there is exactly one action, one object and one process, so the vagueness would be
 * a copied habit rather than a reasoned constraint.
 * 🔴 AND IT SAYS THE RECORD WILL LOCK, WHICH IS THE PART A USER CANNOT DISCOVER ANY OTHER WAY.
 * `NDA_Issue_Approval` sets `recordEditability = AdminOnly`, so the NDA becomes read-only the
 * instant this succeeds — including for the person who just pressed the button. The way back is
 * Recall, from the Approval History related list that `NDA_Record_Page` and `NDA__c-NDA Layout`
 * gained in the same wave. Telling the user beforehand is cheaper than every support ticket that
 * starts "I can't edit the NDA any more".
 *
 * theme 'warning', not 'info', matching `c/dispositionSubmitForApproval` and `c/submitForApproval`
 * for the same reason: submitting into a principal approval is not a write the user can simply
 * repeat. It creates a pending instance, notifies the approvers, LOCKS the record, and a SECOND
 * submit while one is pending is REFUSED. The dialog must not look like a routine forward hop.
 */
const CONFIRM = {
    message:
        'Submit this NDA for the NDA Issue approval? The NDA will be locked for editing until a principal approves, rejects or recalls it.',
    label: 'Submit for Approval',
    theme: 'warning'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'This NDA could not be submitted for approval.';

/**
 * c-nda-submit-for-approval — the headless quick action behind
 * `quickActions/NDA__c.Submit_NDA_Approval`. Built 2026-08-31 (Tranche 3 item 2d).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY A BUNDLE EXISTS FOR THIS AT ALL, IN ONE PARAGRAPH
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * `flexipages/NDA_Record_Page` carries `enableActionsConfiguration = true`, which DISCARDS the
 * page's inherited `platformActionList` entirely (measured on this project). The platform's own
 * "Submit for Approval" button is therefore not on that page and cannot be inherited onto it —
 * every action there is enumerated explicitly. Even if it were available, design D-9 rejected it:
 * it routes around `NdaApprovalService`'s authored pre-checks and surfaces an unmet entry criterion
 * as the platform's opaque "no applicable approval process was found".
 *
 * ⚠ THIS BUTTON REPLACES `NDA__c.Move_to_Approved`, AT THE SAME SLOT AND UNDER BYTE-IDENTICAL
 * VISIBILITY CRITERIA. That action performed the SAME transition (`Prepare` -> `Approved`) in one
 * click, through `RecordStageAdvanceService`'s map, gated on `Disposition_Deal_Actions` — which
 * `DPEG_Disposition_Edit` (the ANALYST set) grants and `DPEG_Disposition_View` (the PRINCIPAL set)
 * is forbidden to hold. So the analyst could make the decision and the principal could not. Both
 * the map hop and that quick action were retired in this same wave (Gate 1 decision D-7); WHO may
 * press the button is unchanged, and WHAT the press does is now "ask a principal" instead of
 * "write the value".
 *
 * ── 🔴 WHY THIS IS NOT `c/dispositionSubmitForApproval` ───────────────────────────────────────
 * That bundle posts to `DispositionApprovalController.submitForApproval(Id dispositionId)`, whose
 * service derives the target approval from a DISPOSITION's stage and record type. An NDA Id there
 * does not fall through to a nicer error — it fails a `Disposition__c` selector read. The action is
 * a different object with different entry criteria, so it needs its own Apex entry point; it
 * reuses this class's CONTROLLER (see that class's 2026-08-31 header block for why a fifth method
 * there beat a third controller) and its own service.
 *
 * ── ✅ THE GUARD IS REUSED WITH NO NEW APEX, AND THAT IS NOT A COINCIDENCE ────────────────────
 * `c/recordStageGuard` asks its permission question PER RECORD — it passes the recordId to
 * `RecordStageAdvanceController.hasStageActionAccess`, which dispatches on `Id.getSObjectType()`
 * and, for `NDA__c`, on the RECORD TYPE, resolving `Disposition_NDA` to the `DISPOSITION_DRIVER`
 * gate. `c/ndaMarkDeclined` already uses it on this exact object. `c/dealActionGuard` could not
 * serve: its `hasDealActionAccess()` takes no argument and resolves the OPPORTUNITY permission
 * controller at module scope, so it cannot express "which object's gate?".
 *
 * ⚠ THE CLIENT GUARD IS A COURTESY, NOT THE CONTROL. `NdaApprovalService` asserts the same
 * permission as its FIRST statement, server-side. Removing this check would degrade the message,
 * not open a hole. Equally, the Dynamic Actions visibility rule on `NDA_Record_Page` (custom
 * permission AND `Status__c = 'Prepare'` AND `RecordType.DeveloperName = 'Disposition_NDA'`) hides
 * the button declaratively; this component enforces the same rule at CLICK time. The two are
 * COMPLEMENTARY, not alternatives, and neither is duplicated in JS beyond the permission question —
 * the status and record-type gates are the SERVER's, because their refusals need wording.
 *
 * ── 🔴 getRecordNotifyChange IS MANDATORY HERE ────────────────────────────────────────────────
 * The submission goes through IMPERATIVE APEX, so the write happens behind LDS's back. Without it
 * the Path, the highlights panel and every Dynamic Actions visibility rule on the page keep
 * evaluating the OLD values until the user reloads — and since those rules are what show and hide
 * this very button, the button the user just pressed would stay on screen and invite a second
 * submit that the server would then refuse. Conversely it must NOT be added to any LDS-`updateRecord`
 * bundle: those write THROUGH the cache and re-render on their own (ARCHITECTURE.md §5).
 * ⚠ ON THIS ACTION IT ALSO REFRESHES THE **LOCK**. The record becomes `AdminOnly` read-only on
 * submit; without the notify, the inline-edit pencils stay live until reload and every attempted
 * save fails with `ENTITY_IS_LOCKED`.
 *
 * ── ⚠ THIS COMPONENT IS NOT A ROUTE BACK, AND MUST NOT BECOME ONE ────────────────────────────
 * Recall lives on the Approval History related list (`force:relatedListContainer` on
 * `NDA_Record_Page` plus `RelatedProcessHistoryList` on `NDA__c-NDA Layout` — two files, neither of
 * which works alone). A Recall affordance here would be a second, weaker copy of a control the
 * platform already renders with the correct permissions attached.
 *
 * A headless quick action owns no button markup — the platform's action bar renders it — so there
 * is no `disabled` attribute this component could set.
 */
export default class NdaSubmitForApproval extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!(await guardStageAction(this, this.recordId, CONFIRM))) {
            return;
        }
        try {
            // ⚠ THE APEX PARAMETER IS `ndaId`, NOT `recordId`:
            // DispositionApprovalController.submitNdaForApproval(Id ndaId). An imperative Apex call
            // binds by NAME — a mismatch is not a compile error on either side, it simply arrives
            // null and throws a far less obvious error at the server (here, the authored
            // "No record was provided.", which would look like a component bug).
            const message = await submitNdaForApproval({ ndaId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Submitted for approval',
                    message,
                    variant: 'success'
                })
            );
            // Apex DML bypasses the LDS cache — without this the Path, the action bar and the
            // record's new READ-ONLY state all keep showing the pre-submission page.
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            // 🔴 THE SERVICE'S REFUSALS ARE AUTHORED TO BE SHOWN, AND ONE OF THEM IS THE WHOLE
            // REASON THIS BUNDLE EXISTS RATHER THAN THE PLATFORM BUTTON: "This NDA is already
            // pending approval." A second submit while one is pending is refused, and the platform's
            // own version of that refusal is not a sentence to put in front of a user. Surface the
            // body verbatim; the controller has already masked anything unexpected behind a fixed
            // generic message, so there is nothing here to leak.
            // ⚠ `mode: 'sticky'` because these messages tell the user what to DO — change the
            // status, recall the pending approval — and an auto-dismissing toast loses the
            // instruction before it can be acted on.
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
