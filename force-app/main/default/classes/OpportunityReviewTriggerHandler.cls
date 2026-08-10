/**
 * Trigger handler for Opportunity. Routes the after-insert and after-update contexts to
 * FOUR service calls — two review concerns and two STAGE-KEYED HANDOFFS to other modules:
 *
 *   - OpportunityReviewService.createReviewRecords opens the matching feasibility /
 *     Contract Review / Underwriting / LOI child when the Opp enters (or flips an input
 *     flag for) the relevant stage.
 *   - OpportunityReviewService.ensureNda opens the deal's NDA on creation.
 *   - ContractExecutionService.openTransactionsOnAboutToClose  ('About to Close')
 *   - PropertyAssetService.ensureOnClosedWon                   ('Closed Won')
 *
 * ⚠ The last two are NOT review children and deliberately do not live in
 * OpportunityReviewService. They are here because the TRIGGER POINT is the deal's stage:
 * each is the moment Acquisitions hands a deal to another module (Transactions, then
 * Property Management). Each service's own header carries the full argument.
 *
 * Behaviour preservation note: the previous trigger passed the old-map only on
 * update (null on insert) to BOTH service calls. That is reproduced here by
 * routing after-insert with a null prior-map and after-update with the real
 * oldMap. The service methods themselves decide what each context means.
 *
 * All business logic lives in OpportunityReviewService; this handler only wires
 * the trigger contexts to that service.
 */
public with sharing class OpportunityReviewTriggerHandler extends TriggerHandler {

    protected override void afterInsert() {
        route((List<Opportunity>) newList, null);
    }

    protected override void afterUpdate() {
        route((List<Opportunity>) newList, (Map<Id, Opportunity>) oldMap);
    }

    /**
     * @param opps      The Opportunities in the current trigger context.
     * @param priorById The old-map on update; null on insert.
     */
    private void route(List<Opportunity> opps, Map<Id, Opportunity> priorById) {
        OpportunityReviewService.createReviewRecords(opps, priorById);
        OpportunityReviewService.ensureNda(opps, priorById);
        // Entering 'About to Close' opens the Transaction and, through it, the Day-0 checklist.
        // It lives in ContractExecutionService rather than OpportunityReviewService because it is
        // the TRANSACTIONS HANDOFF, not a review child — that service owns the handoff concept and
        // still stamps the Day 0 this step reads back. Moved off ContractReviewTrigger on
        // 2026-08-05: the trigger point is now the deal's stage, not the contract's status.
        ContractExecutionService.openTransactionsOnAboutToClose(opps, priorById);
        // Entering 'Closed Won' turns the deal into a managed asset (Tranche 5A / D27.3).
        // It lives in PropertyAssetService rather than OpportunityReviewService because a
        // Property_Asset__c is not a REVIEW child and is not part of the deal tree — it is the
        // PROPERTY MANAGEMENT HANDOFF, the same argument ContractExecutionService won above.
        // 🔴 And it lives on THIS trigger rather than in the Transaction_Complete_Close flow
        // because StageAdvanceService.NEXT_STAGE maps BOTH 'PSA' and 'About to Close' to
        // 'Closed Won', so a deal driver can close a deal with no Transaction__c at all;
        // building it in that flow would have missed half the closes, invisibly.
        PropertyAssetService.ensureOnClosedWon(opps, priorById);
    }
}
