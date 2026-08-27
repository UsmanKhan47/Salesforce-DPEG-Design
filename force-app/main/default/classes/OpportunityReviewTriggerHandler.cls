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
 *   - DealFolderService.ensureOnClaimStageEntry                (ANY of 'Under Review',
 *     'Underwriting', 'About to Close', 'Closed Won' — see that class's CLAIM_STAGES)
 *
 * ⚠ The last three are NOT review children and deliberately do not live in
 * OpportunityReviewService. They are here because the TRIGGER POINT is the deal's stage:
 * each is the moment Acquisitions hands a deal to another module (Transactions, then
 * Property Management, then document storage). Each service's own header carries the full
 * argument.
 *
 * 🔴 THE LAST TWO HAVE OPPOSITE FAILURE CONTRACTS. DO NOT HARMONISE THEM.
 * PropertyAssetService is allOrNone = true and THROWS on failure by design — its silent
 * absence was the bug being fixed. DealFolderService MUST NEVER THROW, because a SharePoint
 * outage rolling back a user's STAGE ADVANCE is strictly worse than a missing folder.
 * ⚠ Ordering does NOT deliver that: a throw anywhere in a trigger rolls back the whole
 * transaction regardless of statement order. Only the absence of throwing paths inside
 * DealFolderService achieves it. It is placed last for readability, not for safety.
 *
 * ⚠ AMENDED 2026-08-27 — THEY NO LONGER "SHARE A TRIGGER POINT", AND THAT WAS THE PREMISE OF
 * THE PARAGRAPH ABOVE RATHER THAN DECORATION. PropertyAssetService keys on ONE stage
 * ('Closed Won'); DealFolderService keys on FOUR. The relationship is now an OVERLAP — neither
 * an identity nor a separation, which is a subtler thing than either and is why it is spelled
 * out. On a deal entering 'Closed Won' BOTH still run in the SAME transaction, so the
 * opposite-contract warning above is still live and still load-bearing. On the far more common
 * 'New' -> 'Under Review' save only the folder service does any work, and PropertyAssetService's
 * throwing contract is not in the picture at all.
 * 🔴 THE CONTRACT FACT SURVIVES ITS OLD PREMISE, RE-FOUNDED: the hazard is two services with
 * OPPOSITE failure contracts sharing ANY transaction, and they still share the 'Closed Won' one.
 * Do not "simplify" this into "they are unrelated now".
 *
 * Behaviour preservation note: the previous trigger passed the old-map only on
 * update (null on insert) to BOTH service calls. That is reproduced here by
 * routing after-insert with a null prior-map and after-update with the real
 * oldMap. The service methods themselves decide what each context means.
 *
 * All business logic lives in the FOUR services listed at the top of this header; this handler
 * holds none of its own and only wires the trigger contexts to them. (It said "OpportunityReviewService"
 * alone until 2026-08-27 — accurate when this handler was extracted, and wrong ever since
 * ContractExecutionService, PropertyAssetService and DealFolderService joined `route()`.)
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
        // Entering ANY CLAIM STAGE claims the deal's SharePoint folder tree — moved 2026-08-27
        // from 'Closed Won' alone to the four-stage CLAIM_STAGES set.
        // 🔴 IT NO LONGER LIVES HERE FOR PropertyAssetService's REASON. That argument (NEXT_STAGE
        // maps BOTH 'Under Contract (PSA)' and 'About to Close' to 'Closed Won', so a flow keyed on
        // the Transaction would miss half the closes) is MOOT for this service: it now claims at
        // 'Under Review', long before either key matters. What keeps it in Apex is the callout
        // arithmetic (a per-record Flow interview would attempt 251 x 7 = 1,757 HTTP Callout
        // actions against a limit of 100), Flow's absent HttpCalloutMock seam, and the fact that
        // "entered any member of a SET from any non-member" is one contains() pair here and a
        // Decision-per-stage-per-route in Flow. Full argument in that service's header.
        // 🔴 THE SYNCHRONOUS SIDE MAKES ZERO CALLOUTS. It stamps Pending and enqueues exactly ONE
        // DealFolderQueueable per trigger chunk (never one per deal — 200 enqueues would breach
        // the 50-job limit and roll back the save). A chunk entering no claim stage costs zero
        // SOQL, zero DML and zero enqueues — and so does an ordinary move BETWEEN two claim
        // stages, because both halves of the entry test use the set.
        // 🔴 THE NEVER-THROW CONTRACT IS NOW EXERCISED ON ESSENTIALLY EVERY DEAL, at up to four
        // entry points, one of which is inside an approval transaction as a READ-ONLY APPROVER
        // (the LOI_Approval final-rejection field update, 'LOI' -> 'Underwriting'). A throw here
        // surfaces through StageAdvanceService.setStage's catch(DmlException), which rethrows
        // getDmlMessage(0) VERBATIM into the toast of whoever clicked Begin Review.
        DealFolderService.ensureOnClaimStageEntry(opps, priorById);
    }
}
