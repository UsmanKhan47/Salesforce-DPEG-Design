/**
 * Trigger handler for Disposition__c. Routes the after-insert and after-update contexts to
 * DispositionStageEntryService, which creates the disposition's stage-entry child records.
 *
 * The Opportunity twin (OpportunityReviewTriggerHandler) is the shape this copies, including its
 * "old-map on update, null on insert" convention: the SERVICE decides what each context means, so
 * the handler stays a router with no rules of its own.
 *
 * ── ⚠ AFTER, NOT BEFORE — AND BOTH CONTEXTS, NOT JUST UPDATE ─────────────────
 * AFTER because the child NDA needs the parent's Id. INSERT as well as UPDATE because a
 * Disposition__c can legitimately be CREATED at the NDA stage: DispositionService.findOrCreate
 * always creates at Disposition Readiness, but the seed scripts and this tranche's own test
 * surface create off-market rows directly at later stages, and
 * All_NDAs_Signed_Before_Progression is ISCHANGED-only precisely so they can. Handling insert
 * costs one extra routed call and removes a class of "the NDA exists on records made one way and
 * not the other" defect.
 *
 * ── WHY THERE IS NO RECURSION FLAG ──────────────────────────────────────────
 * The service's own DML re-enters this handler twice — once via
 * DispositionNdaStampQueueable's parent stamp, and once if anything else edits the row — and
 * both re-entries no-op because the service fires only on a stage CHANGE INTO a target stage.
 * The stamp update changes Primary_NDA__c and nothing else, so priorStage == newStage. The
 * idempotency read is the second, independent guard. A static boolean would add a third
 * mechanism whose failure mode (a flag left true across a batch chunk silently disabling
 * auto-create for the rest of the transaction) is worse than the problem it solves.
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (all logic)
 * @see force-app/main/default/classes/OpportunityReviewTriggerHandler.cls (the acquisitions twin)
 */
public with sharing class DispositionTriggerHandler extends TriggerHandler {

    protected override void afterInsert() {
        route((List<Disposition__c>) newList, null);
    }

    protected override void afterUpdate() {
        route((List<Disposition__c>) newList, (Map<Id, Disposition__c>) oldMap);
    }

    /**
     * @param dispositions The Dispositions in the current trigger context.
     * @param priorById    The old-map on update; null on insert.
     */
    private void route(List<Disposition__c> dispositions, Map<Id, Disposition__c> priorById) {
        DispositionStageEntryService.createStageEntryRecords(dispositions, priorById);
    }
}
