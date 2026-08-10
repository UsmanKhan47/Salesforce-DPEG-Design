/**
 * Trigger handler for Disposition__c. Routes four contexts to DispositionStageEntryService:
 *
 *   before insert / before update  -> stampListingDates      (in-memory, no DML)
 *   after insert  / after update   -> createStageEntryRecords (the four child auto-creates)
 *
 * The Opportunity twin (OpportunityReviewTriggerHandler) is the shape this copies, including its
 * "old-map on update, null on insert" convention: the SERVICE decides what each context means, so
 * the handler stays a router with no rules of its own.
 *
 * ── ⚠ WHY BOTH BEFORE AND AFTER, AND WHY THE SPLIT IS NOT ARBITRARY ─────────
 * AFTER is required for every CHILD insert: a child needs the parent's Id, which does not exist
 * until after insert.
 *
 * BEFORE is required for the one thing that is NOT a child — `Listing_Date__c`, a field on the
 * Disposition itself. Writing it after the save would mean a SECOND DML against a record that
 * three approval processes lock (`recordEditability = AdminOnly` on all three), which is the
 * ENTITY_IS_LOCKED shape that produced `DispositionNdaStampQueueable` — and a Queueable does not
 * fix it here (D20/W1). Setting it in `before` makes it part of the save the user was already
 * permitted to make, so no lock can refuse it. Full argument at
 * `DispositionStageEntryService.stampListingDates`.
 *
 * ⚠ THE VALUE IS WHAT DECIDES THE CONTEXT, NOT THE OBJECT. `Primary_NDA__c` is also a field on
 * `Disposition__c` and CANNOT move to the before context: its value is the child NDA's Id, which
 * does not exist until after the insert. `Listing_Date__c` depends on nothing but the transition
 * being made, which is fully known in before-update. Do not "harmonise" the two.
 *
 * ── INSERT AS WELL AS UPDATE, IN BOTH HALVES ────────────────────────────────
 * A Disposition__c can legitimately be CREATED at a target stage: DispositionService.findOrCreate
 * always creates at Disposition Readiness, but the seed scripts and several test surfaces create
 * rows directly at later stages, and All_NDAs_Signed_Before_Progression is ISCHANGED-only
 * precisely so they can. Handling insert costs one extra routed call and removes a class of "the
 * child exists on records made one way and not the other" defect.
 *
 * ── WHY THERE IS NO RECURSION FLAG ──────────────────────────────────────────
 * The service's own DML re-enters this handler twice — once via DispositionNdaStampQueueable's
 * parent stamp, and once if anything else edits the row — and both re-entries no-op because the
 * service fires only on a stage CHANGE INTO a target stage. The stamp update changes
 * Primary_NDA__c and nothing else, so priorStage == newStage. The idempotency read is the second,
 * independent guard. A static boolean would add a third mechanism whose failure mode (a flag left
 * true across a batch chunk silently disabling auto-create for the rest of the transaction) is
 * worse than the problem it solves.
 *
 * ⚠ The before-context stamp adds NO recursion risk of its own: an in-memory assignment during a
 * save fires no additional trigger, and the stamp is fill-if-blank, so even a re-save that did
 * re-enter would find the value already set and change nothing.
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (all logic)
 * @see force-app/main/default/classes/OpportunityReviewTriggerHandler.cls (the acquisitions twin)
 */
public with sharing class DispositionTriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        DispositionStageEntryService.stampListingDates((List<Disposition__c>) newList, null);
    }

    protected override void beforeUpdate() {
        DispositionStageEntryService.stampListingDates(
            (List<Disposition__c>) newList,
            (Map<Id, Disposition__c>) oldMap
        );
    }

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
