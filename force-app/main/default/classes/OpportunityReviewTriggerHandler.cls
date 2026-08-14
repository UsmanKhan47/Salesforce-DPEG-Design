/**
 * Trigger handler for Opportunity. Routes the after-insert and after-update contexts to
 * FIVE service calls — two review concerns and three STAGE-KEYED HANDOFFS to other modules:
 *
 *   - OpportunityReviewService.createReviewRecords opens the matching feasibility /
 *     Contract Review / Underwriting / LOI child when the Opp enters (or flips an input
 *     flag for) the relevant stage.
 *   - OpportunityReviewService.ensureNda opens the deal's NDA on creation.
 *   - ContractExecutionService.openTransactionsOnAboutToClose  ('About to Close')
 *   - PropertyAssetService.ensureOnClosedWon                   ('Closed Won')
 *   - DealFolderService.ensureOnClosedWon                      ('Closed Won')
 *
 * ⚠ The last three are NOT review children and deliberately do not live in
 * OpportunityReviewService. They are here because the TRIGGER POINT is the deal's stage:
 * each is the moment Acquisitions hands a deal to another module (Transactions, then
 * Property Management, then document storage). Each service's own header carries the full
 * argument.
 *
 * 🔴 THE LAST TWO SHARE A TRIGGER POINT AND HAVE OPPOSITE FAILURE CONTRACTS. DO NOT
 * HARMONISE THEM. PropertyAssetService is allOrNone = true and THROWS on failure by design —
 * its silent absence was the bug being fixed. DealFolderService MUST NEVER THROW, because a
 * SharePoint outage rolling back a Closed Won is strictly worse than a missing folder.
 * ⚠ Ordering does NOT deliver that: a throw anywhere in a trigger rolls back the whole
 * transaction regardless of statement order. Only the absence of throwing paths inside
 * DealFolderService achieves it. It is placed last for readability, not for safety.
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
     * Routes one trigger context through the five service CALLS listed in the class header, in
     * order. They span FOUR services — `OpportunityReviewService` is called twice.
     *
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
        // because StageAdvanceService.NEXT_STAGE maps BOTH 'Under Contract (PSA)' and
        // 'About to Close' to
        // 'Closed Won', so a deal driver can close a deal with no Transaction__c at all;
        // building it in that flow would have missed half the closes, invisibly.
        PropertyAssetService.ensureOnClosedWon(opps, priorById);
        // Entering 'Closed Won' also claims the deal's SharePoint folder tree.
        // It lives HERE for the same reason PropertyAssetService does — StageAdvanceService
        // .NEXT_STAGE maps BOTH 'Under Contract (PSA)' and 'About to Close' to 'Closed Won', so a
        // deal driver can
        // close a deal with no Transaction__c at all and the Transaction_Complete_Close flow would
        // have missed half the closes.
        // 🔴 THE SYNCHRONOUS SIDE MAKES ZERO CALLOUTS. It stamps Pending and enqueues exactly ONE
        // DealFolderQueueable per trigger chunk (never one per deal — 200 enqueues would breach the
        // 50-job limit and roll back the close). A chunk that closes nothing costs zero SOQL, zero
        // DML and zero enqueues. See that service's header for the 7-callouts-per-deal arithmetic
        // and the never-throw contract noted above.
        DealFolderService.ensureOnClosedWon(opps, priorById);
    }
}
