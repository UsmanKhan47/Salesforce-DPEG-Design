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
const TARGET_STAGE = 'Counter';

/**
 * Unlike c/advanceRecordStage this confirmation CAN name its destination, because this bundle backs
 * exactly ONE action on ONE object with ONE fixed target. The generic bundle cannot, since its
 * target is derived server-side from five different stage maps.
 */
const CONFIRM = {
    message: 'Record that the broker countered this LOI?',
    label: 'Counter',
    theme: 'info'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The LOI could not be moved to Counter.';

/**
 * Headless quick action: LOI 'Sent' -> 'Counter'.
 *
 * ── WHY THIS IS NOT c/advanceRecordStage ─────────────────────────────────────
 * The LOI is the ONLY stage-controlled child whose path branches. At 'Sent' the broker either
 * counters or accepts, so there are two legitimate destinations and a single derived hop cannot
 * express both. c/advanceRecordStage would send this LOI to 'Counter' (LOI_NEXT_STAGE derives it),
 * which is right half the time and silently wrong the other half — so 'Sent' shows these two NAMED
 * buttons instead and hides the generic one.
 *
 * Sibling: c/loiMarkCompleted, identical but for TARGET_STAGE and its wording. They are two bundles
 * rather than one parameterised bundle because a HEADLESS quick action takes no configuration — the
 * platform instantiates it with only recordId — so the target has to live in the module. Same shape
 * as the three Opportunity branch bundles (dealSendToDevelopmentReview and friends).
 *
 * getRecordNotifyChange is MANDATORY here for the same reason as every Apex-writing bundle in this
 * program: the DML happens behind LDS's back, so without it the Path keeps showing the old stage.
 */
export default class LoiMarkCountered extends LightningElement {
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
