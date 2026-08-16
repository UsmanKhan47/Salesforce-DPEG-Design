import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import advanceTo from '@salesforce/apex/RecordStageAdvanceController.advanceTo';

/**
 * The destination stage, hardcoded. It is a CONSTANT in this bundle and is never derived, wired or
 * passed in — that is what lets RecordStageAdvanceService validate it against the LOI's allow-list
 * and reject anything else. A bundle that computed its own target would defeat the allow-list.
 *
 * 🔴 RENAMED 'Counter' -> 'Negotiation' ON 2026-08-14 (Acquisition Observations, observation 5),
 * IN THE BUNDLE, DELIBERATELY. The obvious "improvement" — wiring the stage or asking the server
 * for it so a rename never touches this file again — is the one thing that must not be done: the
 * server validates this string against LOI_ACQUISITION_EXPLICIT_TARGETS, an allow-list scoped to
 * the record's own RECORD TYPE, and that check is only meaningful because the value cannot be
 * chosen by the caller. Editing this line on a rename IS the design working.
 *
 * ⚠ It must stay in lockstep with RecordStageAdvanceService.LOI_ACQUISITION_EXPLICIT_TARGETS. A
 * mismatch does not fail silently — the server refuses with "That stage is not available from this
 * action." and the toast below surfaces it verbatim.
 */
const TARGET_STAGE = 'Negotiation';

/**
 * Unlike c/advanceRecordStage this confirmation CAN name its destination, because this bundle backs
 * exactly ONE action on ONE object with ONE fixed target. The generic bundle cannot, since its
 * target is derived server-side from five different stage maps.
 */
const CONFIRM = {
    message: 'Record that the broker countered this LOI?',
    label: 'Negotiation',
    theme: 'info'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The LOI could not be moved to Negotiation.';

/**
 * Headless quick action: LOI 'Submitted' -> 'Negotiation'.
 *
 * ⚠ BOTH STAGE NAMES CHANGED ON 2026-08-14 (observation 5). This action was 'Sent' -> 'Counter';
 * the whole acquisition LOI sequence was renamed to Draft -> Under Review -> Submitted ->
 * Negotiation -> Signed. The SHAPE is identical — same branch point, same two destinations, same
 * reasoning below — so nothing about this bundle changed except the two literals and the wording.
 *
 * ── WHY THIS IS NOT c/advanceRecordStage ─────────────────────────────────────
 * The acquisition LOI is the ONLY stage-controlled child whose path branches. At 'Submitted' the
 * broker either counters or accepts, so there are two legitimate destinations and a single derived
 * hop cannot express both. c/advanceRecordStage would send this LOI to 'Negotiation'
 * (LOI_ACQUISITION_NEXT_STAGE derives it), which is right half the time and silently wrong the
 * other half — so 'Submitted' shows these two NAMED buttons instead and hides the generic one.
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
