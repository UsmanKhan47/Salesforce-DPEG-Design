/**
 * @description End-to-end `Approval.process` walks (submit + `ProcessWorkitemRequest` approve/
 * reject) for all FIVE approval processes the 2026-08-19 disposition flow redesign touches or
 * adds. Extends the `StageApprovalGatesTest` / `UnderwritingGateTest` pattern — a real submit,
 * a real workitem query, a real approve or reject — rather than simulating the field updates
 * `Approval.process` itself performs.
 *
 * ── WHY THIS CLASS EXISTS SEPARATELY FROM THE TRIGGER-HANDLER TESTS ─────────
 * `BovSubmissionTriggerHandlerTest` and `DispositionOfferTriggerHandlerTest` simulate the
 * approval's final-action FieldUpdate with a direct DML write to `Approval_Status__c` — that
 * proves the HANDLER's own logic in isolation, at 251-record volume, cheaply. This class proves
 * the OTHER half: that the real approval PROCESS METADATA (entry criteria, `whenMultipleApprovers
 * = FirstResponse`, the `finalApprovalActions` / `finalRejectionActions` FieldUpdate names) is
 * wired correctly end to end. Neither file substitutes for the other.
 *
 * ── FirstResponse, mirrored from UnderwritingGateTest ────────────────────────
 * All five processes share `whenMultipleApprovers = FirstResponse` — ONE principal decides, and
 * the platform withdraws the other principal's work item. Every walk below therefore approves or
 * rejects exactly ONE work item, never loops over both.
 *
 * ── ALL_NDAs_SIGNED_BEFORE_PROGRESSION ──────────────────────────────────────
 * Both the Offer-Selection walk (parent ends at `LOI`) and the Closing walk (parent ends at
 * `Sale Closes`) land the Disposition on a gated stage, so their fixtures sign a buyer NDA first.
 *
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls (Disposition-target
 *      semaphore + Queueable — what runs after Sale Decision / Broker Selection / Closing)
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (synchronous child hand-off)
 * @see force-app/main/default/classes/DispositionOfferTriggerHandler.cls (synchronous child hand-off)
 * @author Unit Testing Agent
 */
@isTest
private class DispositionApprovalProcessesTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c dispositionAt(String recordType, String stage) {
        Disposition__c d = TestDataFactory.createDisposition(assetId(), recordType, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    private static void signBuyerNdaOn(Id dispositionId) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Status__c = 'Signed';
        insert nda;
    }

    private static void submit(Id targetId) {
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(targetId);
        Approval.ProcessResult result = Approval.process(req);
        Assert.isTrue(result.isSuccess(),
            'PRECONDITION FAILED: ' + targetId + ' was not accepted into an approval process. '
            + 'Every downstream assertion in this test is meaningless until this passes.');
    }

    private static void decide(Id targetId, String action) {
        ProcessInstanceWorkitem wi = [
            SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :targetId LIMIT 1
        ];
        Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
        wr.setWorkitemId(wi.Id);
        wr.setAction(action);
        wr.setComments('Unit test decision.');
        Approval.process(wr);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Sale_Decision_Approval — RECORD-TYPE-CORRECT TARGET
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void saleDecisionApproved_onMarket_advancesToBovOutreach() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        submit(d.Id);

        Test.startTest();
        decide(d.Id, 'Approve');
        Test.stopTest();

        Assert.areEqual('BOV Outreach',
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'On_Market must land on BOV Outreach via the D-1 semaphore + Queueable');
    }

    @isTest
    static void saleDecisionApproved_offMarket_advancesToBrokerSelection() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_OFF_MARKET, 'Disposition Readiness');
        submit(d.Id);

        Test.startTest();
        decide(d.Id, 'Approve');
        Test.stopTest();

        Assert.areEqual('Broker Selection',
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'Off_Market must land on Broker Selection — the SAME approval, a DIFFERENT target');
    }

    @isTest
    static void saleDecisionRejected_leavesTheDispositionAtReadiness() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        submit(d.Id);

        Test.startTest();
        decide(d.Id, 'Reject');
        Test.stopTest();

        // WITH SYSTEM_MODE — Approval_Advance_Pending__c carries no FLS for anyone by design, so
        // it is genuinely unreadable via a plain query regardless of profile.
        Disposition__c after = [
            SELECT Disposition_Stage__c, Approval_Advance_Pending__c FROM Disposition__c WHERE Id = :d.Id
            WITH SYSTEM_MODE
        ];
        Assert.areEqual('Disposition Readiness', after.Disposition_Stage__c,
            'A rejection must never advance the stage');
        Assert.isFalse(after.Approval_Advance_Pending__c,
            'finalRejectionActions is not configured on this process, so the semaphore must never '
            + 'have been set at all');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Broker_Finalize_Approval (BOV_Submission__c) — CHILD APPROVAL, SYNCHRONOUS PARENT WRITE
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void brokerFinalizeApproved_advancesParentToBrokerSelectionAndStampsTheBroker() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'BOV Outreach');
        // Pinned via Broker__c, not a hand-typed literal — see TestDataFactory.createBrokerContactWithFirm.
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, false);
        sub.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - Principal Approved', true).Id;
        sub.Submission_Status__c = 'Selected';
        insert sub;
        submit(sub.Id);

        Test.startTest();
        decide(sub.Id, 'Approve');
        Test.stopTest();

        Disposition__c after = [SELECT Disposition_Stage__c, Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.areEqual('Broker Selection', after.Disposition_Stage__c,
            'The parent must advance SYNCHRONOUSLY — no Queueable is involved on this path');
        Assert.areEqual('CBRE - Principal Approved', after.Selected_Broker__c);
    }

    @isTest
    static void brokerFinalizeRejected_leavesTheParentAtBovOutreach() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'BOV Outreach');
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, false);
        sub.Submission_Status__c = 'Selected';
        insert sub;
        submit(sub.Id);

        Test.startTest();
        decide(sub.Id, 'Reject');
        Test.stopTest();

        Assert.areEqual('BOV Outreach',
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'A rejection records the outcome and leaves the parent at BOV Outreach for a re-pick');
        Assert.areEqual('Rejected',
            [SELECT Approval_Status__c FROM BOV_Submission__c WHERE Id = :sub.Id].Approval_Status__c);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Broker_Selection_Approval (Disposition__c, OFF-MARKET ONLY)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * RETARGETED (unit-testing agent pass, 2026-08-20, off-market broker lookup). The
     * `Broker_Selection_Approval` submit gate now reads `Broker__c` (a Contact lookup), not
     * `Selected_Broker__c` (text) — see DispositionApprovalService.cls:266. A fixture that only set
     * the text field would refuse at `submit()`, before this walk ever reaches the approval engine.
     */
    @isTest
    static void brokerSelectionApproved_offMarket_advancesToNda() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_OFF_MARKET, 'Broker Selection');
        d.Broker__c = TestDataFactory.createBrokerContact(null, true).Id;
        update d;
        submit(d.Id);

        Test.startTest();
        decide(d.Id, 'Approve');
        Test.stopTest();

        Assert.areEqual('NDA',
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'Off_Market Broker Selection must advance to NDA via the D-1 semaphore + Queueable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Offer_Selection_Approval (Disposition_Offer__c) — CHILD, SYNCHRONOUS PARENT WRITE
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void offerSelectionApproved_acceptsOfferAndAdvancesParentToLoi() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Offer Selection');
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = true;
        offer.Offer_Amount__c = 6100000;
        insert offer;
        submit(offer.Id);

        Test.startTest();
        decide(offer.Id, 'Approve');
        Test.stopTest();

        Disposition__c after = [
            SELECT Disposition_Stage__c, Accepted_Offer_Price__c FROM Disposition__c WHERE Id = :d.Id
        ];
        Assert.areEqual('LOI', after.Disposition_Stage__c,
            'The parent must advance to LOI, which auto-creates the sell-side LOI via '
            + 'DispositionStageEntryService');
        Assert.areEqual(6100000, after.Accepted_Offer_Price__c);
        Assert.areEqual('Accepted',
            [SELECT Offer_Status__c FROM Disposition_Offer__c WHERE Id = :offer.Id].Offer_Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM LOI__c WHERE Disposition__c = :d.Id],
            'Entering LOI must auto-create the sell-side LOI — no change was needed in '
            + 'DispositionStageEntryService for this feature, and this is the proof');
    }

    @isTest
    static void offerSelectionRejected_parksTheParentAtOfferSelectionForARePick() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Offer Selection');
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = true;
        insert offer;
        submit(offer.Id);

        Test.startTest();
        decide(offer.Id, 'Reject');
        Test.stopTest();

        Assert.areEqual('Offer Selection',
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'A rejected offer must park the deal at Offer Selection for a re-pick — the stage '
            + 'always tells the truth (design D-3)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Closing_Approval — WIRE-VERIFIED ENTRY CRITERION
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void closingApproved_advancesToSaleCloses() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Closing');
        signBuyerNdaOn(d.Id);
        d.Wire_Verification_Completed__c = true;
        update d;
        submit(d.Id);

        Test.startTest();
        decide(d.Id, 'Approve');
        Test.stopTest();

        Assert.areEqual('Sale Closes',
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'Closing must advance to Sale Closes once the wire is verified');
    }

    /**
     * The entry criterion itself, not the trigger machinery: an unverified wire must never even
     * ENTER the approval — `Approval.process(req)` (the throwing, one-argument form) must throw
     * rather than accept the submission.
     */
    @isTest
    static void closingSubmit_wireNotVerified_isRefusedByThePlatformEntryCriteria() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Closing');
        // Wire_Verification_Completed__c left false.

        Test.startTest();
        Boolean refused = false;
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(d.Id);
            Approval.process(req);
            Assert.fail('Closing_Approval must refuse entry while the wire is unverified');
        } catch (Exception e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused,
            'The entry criterion is what DispositionApprovalService.submitForApproval pre-checks '
            + 'with an authored message so the user never sees this raw platform refusal');
    }
}
