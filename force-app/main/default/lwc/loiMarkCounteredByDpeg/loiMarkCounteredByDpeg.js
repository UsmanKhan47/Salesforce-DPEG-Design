import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { guardStageAction } from 'c/recordStageGuard';
import advanceTo from '@salesforce/apex/RecordStageAdvanceController.advanceTo';

/**
 * The destination stage, hardcoded. It is a CONSTANT in this bundle and is never derived, wired or
 * passed in — that is what lets RecordStageAdvanceService validate it against the DISPOSITION LOI's
 * per-record-type allow-list and reject it everywhere else. A bundle that computed its own target
 * would defeat the allow-list.
 */
const TARGET_STAGE = 'Countered by DPEG';

/**
 * Unlike c/advanceRecordStage this confirmation CAN name its destination, because this bundle backs
 * exactly ONE action on ONE object with ONE fixed target.
 *
 * The wording says "another round" deliberately: the ordinary way to REACH 'Countered by DPEG' the
 * first time is the linear hop from 'Under Review' (Advance Stage). This action exists for the
 * SECOND and later rounds, i.e. the back-edge from 'Counter Received from Buyer', which is the one
 * edge a linear map provably cannot express.
 */
const CONFIRM = {
    message:
        'Record that DPEG has countered the buyer again? This starts another round of the ' +
        'negotiation — the LOI goes back to Countered by DPEG and the ball returns to the buyer.',
    label: 'Countered by DPEG',
    theme: 'info'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The LOI could not be moved to Countered by DPEG.';

/**
 * Headless quick action: disposition LOI 'Counter Received from Buyer' -> 'Countered by DPEG'.
 *
 * ── 🔴 WHY THIS BUNDLE EXISTS: IT IS THE LOOP'S BACK-EDGE ────────────────────
 * The sell-side path is Received -> Under Review -> Countered by DPEG -> Counter Received from
 * Buyer -> Executed, and the source document (Part 2 line 244) says the negotiation "goes round
 * until both sides are agreed". Countered by DPEG <-> Counter Received from Buyer is therefore a
 * CYCLE, and RecordStageAdvanceService holds a LINEAR Map<String, String> per record type — one
 * key, one value — which cannot hold a back-edge at all. c/advanceRecordStage can only ever take
 * the derived hop, so from 'Counter Received from Buyer' it goes to 'Executed'. This action is the
 * only route back.
 *
 * Its sibling c/loiMarkCounterReceived drives the FORWARD edge of the same loop and deliberately
 * OVERLAPS Advance Stage at that stage — see that bundle and its quick action for why the
 * redundancy is intentional.
 *
 * ⚠ THE ALLOW-LIST IS PER RECORD TYPE, AND THAT IS THE SECURITY HALF. Record-type picklist
 * restriction is enforced by the UI ONLY — Apex DML does not enforce it — so if 'Countered by DPEG'
 * were allow-listed at OBJECT level, this component's exact payload aimed at an ACQUISITION LOI's
 * Id would write a disposition-only value onto it. The server refuses that
 * (RecordStageAdvanceService.LOI_DISPOSITION_EXPLICIT_TARGETS); do not weaken it, and do not add a
 * second bundle that passes a computed target.
 *
 * ⚠ The permission gate this action answers to is DISPOSITION_DRIVER, resolved SERVER-SIDE from the
 * record's own record type. Nothing here names a persona — c/recordStageGuard asks
 * `hasStageActionAccess({ recordId })` and the server dispatches. That per-record signature is the
 * concrete reason c/recordStageGuard exists separately from c/dealActionGuard (ARCHITECTURE.md §5).
 *
 * Siblings: c/loiMarkCounterReceived (the loop's other edge), c/ndaMarkDeclined, c/loiMarkCompleted
 * and c/loiMarkCountered — all identical but for TARGET_STAGE and wording. They are separate
 * bundles rather than one parameterised bundle because a HEADLESS quick action takes no
 * configuration: the platform instantiates it with only recordId, so the target has to live in the
 * module.
 */
export default class LoiMarkCounteredByDpeg extends LightningElement {
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
            // this the Path and the highlights panel keep showing the old stage.
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
