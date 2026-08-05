import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import advanceTo from '@salesforce/apex/RecordStageAdvanceController.advanceTo';

/**
 * The destination stage, hardcoded. It is a CONSTANT in this bundle and is never derived, wired or
 * passed in — that is what lets RecordStageAdvanceService validate it against the LOI's allow-list
 * and reject anything else. A bundle that computed its own target would defeat the allow-list.
 */
const TARGET_STAGE = 'Completed';

/**
 * Unlike c/advanceRecordStage this confirmation CAN name its destination, because this bundle backs
 * exactly ONE action on ONE object with ONE fixed target.
 *
 * The wording flags finality deliberately: 'Completed' is the LOI's terminal stage, so it has no
 * entry in LOI_NEXT_STAGE and the generic Advance Stage button disappears afterwards. There is no
 * "un-complete" action — correcting a mistake means editing the stage field directly.
 */
const CONFIRM = {
    message:
        'Mark this LOI completed? This is the final stage — the stage buttons will no longer appear.',
    label: 'Completed',
    theme: 'warning'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The LOI could not be marked completed.';

/**
 * Headless quick action: LOI 'Sent' -> 'Completed', skipping 'Counter'.
 *
 * ── 🔴 THIS ACTION IS THE REASON advanceTo EXISTS ────────────────────────────
 * 'Completed' is NOT reachable by c/advanceRecordStage from 'Sent': LOI_NEXT_STAGE derives
 * 'Counter' there, and the generic bundle can only ever take the derived hop. An accepted LOI that
 * was never countered therefore had no route to its terminal stage at all. This is a genuine branch,
 * which is why RecordStageAdvanceService gained a per-object explicit-target allow-list rather than
 * a generic "write any stage" method.
 *
 * Sibling: c/loiMarkCountered, identical but for TARGET_STAGE and its wording. See that bundle's
 * header for why these are two bundles rather than one parameterised bundle.
 */
export default class LoiMarkCompleted extends LightningElement {
    @api recordId;

    @api async invoke() {
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
            // Apex DML bypasses the LDS cache — without this the Path shows a stale stage.
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            // A denial, a disallowed target, or a validation rule's own text: all are user-safe by
            // construction (the controller masks anything unexpected), so surface them verbatim.
            const message =
                (error && error.body && error.body.message) || GENERIC_ERROR;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Cannot advance the stage',
                    message,
                    variant: 'error'
                })
            );
        }
    }
}
