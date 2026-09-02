/**
 * Trigger handler for Opportunity. Routes FOUR trigger contexts — before insert, before update,
 * after insert and after update — to SIX service calls in total.
 *
 * ⚠ AMENDED 2026-08-31 — THE TWO SENTENCES THIS HEADER OPENED WITH ARE NOW BOTH WRONG, AND ARE
 * RETRACTED HERE RATHER THAN QUIETLY DELETED. It said, verbatim:
 *     "Routes the after-insert and after-update contexts to FIVE service calls"
 * and then enumerated five calls, all of them after-context. Both statements were exactly true
 * until this handler acquired the BEFORE contexts for stage-entry date stamping (design §2
 * ITEM 2). The count is now six and the context list is now four. Everything else the old header
 * said — in particular the opposite-failure-contracts warning further down — is UNCHANGED and
 * still load-bearing; it is about the after-context services and none of them moved.
 *
 * ── BEFORE INSERT / BEFORE UPDATE — ONE CALL ────────────────────────────────────────────────
 *   - OpportunityStageEntryService.stampStageEntryDates stamps `Stage_Entry_Date__c` on every
 *     record whose stage THIS SAVE is changing (an insert counts as entry into whatever stage the
 *     deal is created at). Zero SOQL and zero DML at any record count — that property is the
 *     entire reason the before contexts could be added to a trigger already routing five
 *     services, and it is asserted by governor counters captured INSIDE this trigger context.
 *     It must run BEFORE the save so the value is written by the user's own DML with no second
 *     statement; see that class's header for why a Flow and an after-context update both lose.
 *
 * ── AFTER INSERT / AFTER UPDATE — FIVE CALLS ────────────────────────────────────────────────
 * Two review concerns and three STAGE-KEYED HANDOFFS to other modules:
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
 * All business logic lives in the FIVE services listed at the top of this header; this handler
 * holds none of its own and only wires the trigger contexts to them. (It said "OpportunityReviewService"
 * alone until 2026-08-27 — accurate when this handler was extracted, and wrong ever since
 * ContractExecutionService, PropertyAssetService and DealFolderService joined `route()`. It said
 * FOUR until 2026-08-31, when OpportunityStageEntryService joined on the before contexts.)
 */
public with sharing class OpportunityReviewTriggerHandler extends TriggerHandler {

    /**
     * Before insert. `oldMap` does not exist in this context, so the prior-stage map is null and
     * every record is treated as ENTERING the stage it is being created at — the same convention
     * `route()` uses below, so the before and after halves cannot disagree about which saves are
     * a stage entry.
     */
    protected override void beforeInsert() {
        OpportunityStageEntryService.stampStageEntryDates((List<Opportunity>) newList, null);
    }

    /**
     * Before update. The real `oldMap` is passed, so only a record whose `StageName` actually
     * differs from its database value is stamped; every other save (amount, owner, close date,
     * an approval field update that does not touch the stage) leaves the date alone.
     *
     * ⚠ This runs AFTER the two RecordBeforeSave Flows on this object, which is why it is here
     * rather than in a third Flow: it observes the FINAL StageName that
     * `Opportunity_Initiate_Underwriting` may have just rewritten, while `oldMap` still holds the
     * true prior DATABASE value.
     */
    protected override void beforeUpdate() {
        OpportunityStageEntryService.stampStageEntryDates(
            (List<Opportunity>) newList,
            (Map<Id, Opportunity>) oldMap
        );
    }

    protected override void afterInsert() {
        route((List<Opportunity>) newList, null);
    }

    protected override void afterUpdate() {
        route((List<Opportunity>) newList, (Map<Id, Opportunity>) oldMap);
    }

    /**
     * Routes one AFTER trigger context through the five service CALLS listed under "AFTER INSERT
     * / AFTER UPDATE" in the class header, in order. They span FOUR services —
     * `OpportunityReviewService` is called twice. The before contexts do not come through here:
     * they route a single service directly, above, precisely because it must stay the only thing
     * running there.
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
        // because Closed Won is reachable without a Transaction ever existing.
        // ⚠ AMENDED 2026-09-02. This comment used to read "…because StageAdvanceService.NEXT_STAGE
        // maps BOTH 'Under Contract (PSA)' and 'About to Close' to 'Closed Won', so a deal driver
        // can close a deal with no Transaction__c at all; building it in that flow would have
        // missed half the closes, invisibly." THAT PAIR IS GONE — PSA was repointed to
        // 'About to Close' when Transaction_Closed_Before_Closed_Won landed. The conclusion holds
        // on a narrower base (API, Data Loader, list view, inline edit, the Path, and insert-at-
        // Closed-Won all bypass both the map and the ISCHANGED-scoped rules), and the full
        // re-argument is in PropertyAssetService's header. DO NOT MOVE THIS SERVICE on the
        // strength of the repoint.
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
