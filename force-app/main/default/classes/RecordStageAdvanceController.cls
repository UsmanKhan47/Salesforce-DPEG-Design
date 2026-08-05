/**
 * RecordStageAdvanceController — the @AuraEnabled boundary for the generic "advance stage" quick
 * action on the five stage-controlled acquisitions child objects (NDA__c, LOI__c, Underwriting__c,
 * Construction_Feasibility_Review__c, Development_Feasibility_Review__c).
 *
 * Consumed by ONE headless LWC bundle, `c/advanceRecordStage`, which backs one quick action per
 * object; and by its shared pre-flight util `c/recordStageGuard`.
 *
 *   hasStageActionAccess(recordId) - cacheable UX gate; dispatches to the object's configured gate.
 *   advance(recordId)              - asserts the gate server-side, then moves the record one hop.
 *
 * Thin controller (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md): the stage maps, the
 * gate dispatch, and the DML all live in RecordStageAdvanceService. Each method here only marshals
 * input, delegates, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5). No SOQL, no DML, no business logic.
 *
 * ── 🔴 THE PERMISSION ASSERT IS THE FIRST STATEMENT OF advance(), AND THAT IS THE POINT ──
 * The Dynamic Actions visibility rule that hides these buttons is a UX AFFORDANCE ONLY: any user
 * with edit access on the object and Apex class access could call `advance` directly and drive a
 * record through every stage. The assert asks the exact same question the visibility rule asks, so
 * no user gains or loses access — what changes is that the rule is ENFORCED rather than merely
 * displayed. This is the weakness the three Lead status actions still carry (they write via LDS
 * `updateRecord` with no Apex in the path at all) and it is deliberately not repeated here.
 *
 * ── CATCH ORDER MATTERS ──────────────────────────────────────────────────────
 *   1. AccessDeniedException          -> the agreed denial wording, verbatim.
 *   2. RecordStageAdvanceException    -> user-safe and user-actionable: no next step, no stage set,
 *                                        unsupported object, or a SURFACED validation-rule message.
 *   3. Exception (generic)            -> fixed, generic message; the real error is logged, never
 *                                        concatenated into user-facing text.
 * An AccessDeniedException reaching the generic clause would be masked as "could not be loaded",
 * telling the user to refresh the page over a permissions problem — which is why it has its own
 * clause, ahead of the others.
 *
 * ⚠ SURFACING THE DML MESSAGE IS A FEATURE, NOT A LEAK. Clause 2 carries
 * DmlException.getDmlMessage(0) out of the service verbatim. That is the whole reason this program
 * routes stage writes through Apex: a validation rule's own error text has to reach the toast, or
 * the rule ships invisible. Same policy as StageAdvanceController; contrast the Disposition/Wire
 * controllers, which never interpolate platform text.
 *
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (all logic)
 * @see force-app/main/default/classes/StageAdvanceController.cls (the Opportunity sibling)
 * @see force-app/main/default/lwc/advanceRecordStage/advanceRecordStage.js (sole consumer)
 */
public with sharing class RecordStageAdvanceController {

    // Fixed, generic user-safe message for an unexpected failure (e.g. the record could not be
    // loaded). Never interpolate platform text into it (ARCHITECTURE.md §5).
    private static final String WRITE_FAILURE_MESSAGE =
        'This record could not be updated. Refresh the page or contact your administrator.';

    // Fixed, generic message for an unexpected failure of the permission lookup ITSELF. Note this
    // is NOT the denial message — a denial returns false.
    private static final String CHECK_FAILURE_MESSAGE =
        'Unable to verify your permissions. Please try again or contact your administrator.';

    /**
     * Wraps a user-safe message in an AuraHandledException whose getMessage() the LWC can read.
     * Setting the message explicitly is required — the single-arg constructor alone leaves
     * getMessage() returning "Script-thrown exception" at the LWC boundary.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * Whether the running user may drive the stage action on this record.
     *
     * cacheable=true: no DML, and the answer cannot change within a session without a permission or
     * User-record change, so every quick action on the page is served from one round trip.
     *
     * @param recordId the record whose object decides which permission gate applies
     * @return true when the running user passes that object's gate; false otherwise
     * @throws AuraHandledException when the record's object is not stage-controlled, or — with a
     *         fixed generic message — when the permission lookup itself fails unexpectedly. The LWC
     *         treats a thrown check exactly like false, so the gate fails CLOSED.
     * @example
     * const allowed = await hasStageActionAccess({ recordId });
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasStageActionAccess(Id recordId) {
        try {
            return RecordStageAdvanceService.hasStageActionAccess(recordId);
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            // No record supplied / not a stage-controlled object. User-safe and user-actionable.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'RecordStageAdvanceController.hasStageActionAccess on '
                + recordId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(CHECK_FAILURE_MESSAGE);
        }
    }

    /**
     * Moves the record to the single next stage for its current stage. The target is derived
     * server-side from RecordStageAdvanceService's per-object map and can never be supplied by the
     * caller, so this entry point cannot skip a hop.
     *
     * @param recordId the NDA / LOI / Underwriting / Construction or Development Feasibility Review
     *                 record to advance
     * @return a user-facing confirmation message, e.g. 'LOI moved to Sent.'
     * @throws AuraHandledException when the running user is not permitted, when there is no next
     *         step, when a validation rule blocks the write (its message is surfaced verbatim), or
     *         — with a fixed generic message — on an unexpected failure.
     * @example
     * const message = await advance({ recordId });
     */
    @AuraEnabled
    public static String advance(Id recordId) {
        try {
            RecordStageAdvanceService.assertStageActionAccess(recordId);
            return RecordStageAdvanceService.advance(recordId);
        } catch (RecordStageAdvanceService.AccessDeniedException e) {
            // Not permitted. Surface the agreed denial wording verbatim — identical to what the LWC
            // shows for the client-side gate, so one condition never produces two phrasings.
            throw ahe(e.getMessage());
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            // "No next step" / "no stage set" / unsupported object / a SURFACED validation message.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'RecordStageAdvanceController.advance on ' + recordId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    /**
     * Moves the record to an EXPLICIT stage, for an object whose path BRANCHES. Today that is the
     * LOI at 'Sent', where a broker either counters or accepts and one derived hop cannot express
     * both outcomes.
     *
     * 🔴 `target` IS CALLER-SUPPLIED AND THEREFORE UNTRUSTED. The service validates it against that
     * object's allow-list before any write; the four objects with linear paths supply no allowed
     * targets at all, so this entry point cannot move them. Do not add a code path that skips that
     * check — it is the only thing standing between class access and arbitrary stage writes across
     * five objects.
     *
     * @param recordId the stage-controlled record to move
     * @param target   the destination stage; must be on the object's allow-list
     * @return a user-facing confirmation message, e.g. 'LOI moved to Completed.'
     * @throws AuraHandledException when the running user is not permitted, when the target is not
     *         allowed, when a validation rule blocks the write (its message is surfaced verbatim),
     *         or — with a fixed generic message — on an unexpected failure.
     * @example
     * const message = await advanceTo({ recordId, target: 'Completed' });
     */
    @AuraEnabled
    public static String advanceTo(Id recordId, String target) {
        try {
            RecordStageAdvanceService.assertStageActionAccess(recordId);
            return RecordStageAdvanceService.advanceTo(recordId, target);
        } catch (RecordStageAdvanceService.AccessDeniedException e) {
            throw ahe(e.getMessage());
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            // Blank / disallowed target, unsupported object, or a SURFACED validation message.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'RecordStageAdvanceController.advanceTo on ' + recordId
                + ' -> ' + target + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
