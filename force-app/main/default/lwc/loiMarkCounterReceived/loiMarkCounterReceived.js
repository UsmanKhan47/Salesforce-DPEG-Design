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
const TARGET_STAGE = 'Counter Received from Buyer';

/**
 * Unlike c/advanceRecordStage this confirmation CAN name its destination, because this bundle backs
 * exactly ONE action on ONE object with ONE fixed target.
 */
const CONFIRM = {
    message:
        "Record that the buyer's counter has arrived? The LOI moves to Counter Received from " +
        'Buyer and the ball comes back to DPEG.',
    label: 'Counter Received from Buyer',
    theme: 'info'
};

/** Fallback when the Apex error carries no readable body (e.g. a transport failure). */
const GENERIC_ERROR = 'The LOI could not be moved to Counter Received from Buyer.';

/**
 * Headless quick action: disposition LOI 'Countered by DPEG' -> 'Counter Received from Buyer'.
 *
 * ── ⚠ THIS EDGE IS ALSO THE LINEAR NEXT HOP, AND THE OVERLAP IS DELIBERATE ───
 * c/advanceRecordStage can already derive this transition, so at 'Countered by DPEG' a disposition
 * driver sees BOTH this button and Advance Stage. Two reasons that was chosen over removing one:
 *
 *   1. SYMMETRY. A user driving a LOOP should see the same shape of control at both of its stages.
 *      Making one direction a named button (c/loiMarkCounteredByDpeg, the back-edge, which a linear
 *      map provably cannot express) and the other an anonymous "advance" invites the user to guess.
 *   2. INDEPENDENCE. The linear map lives in RecordStageAdvanceService; if a later change re-points
 *      the hop out of 'Countered by DPEG', a page that relied on Advance Stage for this edge would
 *      silently lose it. An explicit target cannot drift that way.
 *
 * The cost is one redundant button on one stage. Do not "tidy" it away without moving the loop's
 * other edge somewhere it can be expressed, which today is nowhere. Full reasoning:
 * quickActions/LOI__c.Mark_Counter_Received.quickAction-meta.xml.
 *
 * ⚠ THE ALLOW-LIST IS PER RECORD TYPE, AND THAT IS THE SECURITY HALF. Record-type picklist
 * restriction is enforced by the UI ONLY — Apex DML does not enforce it — so if 'Counter Received
 * from Buyer' were allow-listed at OBJECT level, this component's exact payload aimed at an
 * ACQUISITION LOI's Id would write a disposition-only value onto it. The server refuses that
 * (RecordStageAdvanceService.LOI_DISPOSITION_EXPLICIT_TARGETS).
 *
 * ⚠ The permission gate this action answers to is DISPOSITION_DRIVER, resolved SERVER-SIDE from the
 * record's own record type. Nothing here names a persona — c/recordStageGuard asks
 * `hasStageActionAccess({ recordId })` and the server dispatches. That per-record signature is the
 * concrete reason c/recordStageGuard exists separately from c/dealActionGuard (ARCHITECTURE.md §5).
 *
 * ⚠ NAME COLLISION WARNING. c/loiMarkCountered is the ACQUISITION action (it writes
 * Stage__c = 'Negotiation' — the bundle name still says "Countered" because observation 5 renamed
 * the VALUE 'Counter' -> 'Negotiation' on 2026-08-14 without renaming the bundle, which makes this
 * warning sharper rather than obsolete). This bundle and c/loiMarkCounteredByDpeg are the
 * DISPOSITION pair. Three
 * similar names, three different targets, two different record types and two different personas —
 * check TARGET_STAGE before assuming which one you are editing.
 */
export default class LoiMarkCounterReceived extends LightningElement {
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
