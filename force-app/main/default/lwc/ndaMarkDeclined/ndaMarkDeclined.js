import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import advanceTo from '@salesforce/apex/RecordStageAdvanceController.advanceTo';

/**
 * The destination stage, hardcoded. It is a CONSTANT in this bundle and is never derived, wired or
 * passed in — that is what lets RecordStageAdvanceService validate it against the DISPOSITION
 * NDA's per-record-type allow-list and reject it everywhere else. A bundle that computed its own
 * target would defeat the allow-list.
 */
const TARGET_STAGE = 'Declined';

/**
 * Unlike c/advanceRecordStage this confirmation CAN name its destination, because this bundle backs
 * exactly ONE action on ONE object with ONE fixed target.
 *
 * The wording flags finality and the downstream consequence deliberately. 'Declined' is a terminal
 * alternative to 'Signed', so it has no entry in NDA_DISPOSITION_NEXT_STAGE and the generic Advance
 * Stage button disappears afterwards. It also does NOT release the disposition: the off-market
 * All_NDAs_Signed_Before_Progression gate counts a Declined NDA toward the TOTAL and not toward the
 * SIGNED total, so declining leaves the disposition blocked. Deleting the NDA is the documented way
 * to take a party out of the process — which is why the prompt says so rather than leaving the user
 * to discover it at the next stage.
 */
const CONFIRM = {
    message:
        'Mark this NDA declined? This is final — the stage buttons will no longer appear, and the ' +
        'disposition stays blocked until every NDA on it is signed. If the party is out of the ' +
        'process entirely, delete the NDA instead.',
    label: 'Mark Declined',
    theme: 'warning'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The NDA could not be marked declined.';

/**
 * Headless quick action: disposition NDA 'Sent' -> 'Declined'.
 *
 * ── 🔴 WHY THIS BUNDLE EXISTS AND WHY IT MUST NOT BE GENERALISED ─────────────
 * 'Declined' is NOT reachable by c/advanceRecordStage: from 'Sent' the disposition sequence derives
 * 'Signed', and the generic bundle can only ever take the derived hop. Declining is a branch, not a
 * step, so it needs an explicit target — which is exactly the case
 * RecordStageAdvanceService.advanceTo's per-record-type allow-list was built for.
 *
 * ⚠ THE ALLOW-LIST IS PER RECORD TYPE, AND THAT IS THE SECURITY HALF. 'Sent' is a status SHARED by
 * both NDA record types, and record-type picklist restriction is enforced by the UI ONLY — Apex DML
 * does not enforce it. So if 'Declined' were allow-listed at OBJECT level, this component's exact
 * payload aimed at an ACQUISITION NDA's Id would write a disposition-only value onto it. The server
 * refuses that; do not weaken it, and do not add a second bundle that passes a computed target.
 *
 * ⚠ The permission gate this action answers to is DISPOSITION_DRIVER, resolved SERVER-SIDE from the
 * record's own record type. Nothing here names a persona — c/recordStageGuard asks
 * `hasStageActionAccess({ recordId })` and the server dispatches. That per-record signature is the
 * concrete reason c/recordStageGuard exists separately from c/dealActionGuard (ARCHITECTURE.md §5).
 *
 * Siblings: c/loiMarkCompleted and c/loiMarkCountered, identical but for TARGET_STAGE and wording.
 */
export default class NdaMarkDeclined extends LightningElement {
    @api recordId;

    @api async invoke() {
        // Order is permission -> confirm -> act. Never ask a user to confirm an action they are
        // not permitted to take.
        if (!(await guardStageAction(this, this.recordId, CONFIRM))) {
            return;
        }
        try {
            const message = await advanceTo({
                recordId: this.recordId,
                target: TARGET_STAGE
            });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Success', message, variant: 'success' })
            );
            // MANDATORY: the write is imperative Apex, which happens behind LDS's back. Without
            // this the Path and the highlights panel keep showing the old status.
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            // A denial, a disallowed target, or a validation rule's own text: all are user-safe by
            // construction (the controller masks anything unexpected), so surface them verbatim.
            const message =
                (error && error.body && error.body.message) || GENERIC_ERROR;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Cannot mark this NDA declined',
                    message,
                    variant: 'error'
                })
            );
        }
    }
}
