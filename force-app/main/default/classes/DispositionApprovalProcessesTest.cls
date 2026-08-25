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
    /**
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ASKING-PRICE GATE MUST NOT REACH THIS PATH. THIS TEST IS THE PROOF.
     * ══════════════════════════════════════════════════════════════════════════════
     * Added 2026-08-22 with the Disposition-Readiness asking-price requirement.
     *
     * The gate is a PRE-CHECK in `DispositionApprovalService.submitForApproval` and
     * deliberately NOT a validation rule (design F-4). This test pins the consequence, and it
     * is written to fail LOUDLY the day somebody adds the rule anyway:
     *
     *   a disposition that is ALREADY INSIDE `Sale_Decision_Approval` with a BLANK price
     *   must still advance on approval.
     *
     * ⚠ "BLANK PRICE" MEANS THE PARENT ASSET'S `Target_Sale_Price__c` SINCE 2026-08-25, not
     * `Disposition__c.Asking_Price__c` — that field was retired from the disposition flow and the
     * gate moved with `BOV_Score__c`'s value basis. The claim and the risk are unchanged; only the
     * field the hypothetical validation rule would name is different.
     *
     * WHY THAT STATE IS REACHABLE AND NOT A STRAW MAN: every disposition that predates the
     * gate is in exactly this shape (measured 2026-08-22 — DISP-0020 sits at Disposition
     * Readiness with no price), and `Sale_Decision_Approval`'s `entryCriteria`
     * tests the STAGE only, so the platform's own Submit button and any direct
     * `Approval.process` call still accept an unpriced record. The submit here is a RAW
     * `Approval.process`, bypassing the service pre-check on purpose — that is the point, not
     * a shortcut.
     *
     * 🔴 WHAT FAILURE LOOKS LIKE, AND WHY IT WOULD OTHERWISE BE INVISIBLE. If a validation
     * rule requiring a price is ever added, `DispositionApprovalAdvanceService.advance`
     * — `Database.update(rows, false, AccessLevel.SYSTEM_MODE)`, where SYSTEM_MODE lifts CRUD
     * and FLS but NEVER a validation rule — would be refused, `allOrNone = false` would DISCARD
     * the error, and the disposition would sit APPROVED at Disposition Readiness with
     * `Approval_Advance_Pending__c` stuck true and nothing shown to the approver. So this test
     * asserts all three: the stage moved, the semaphore cleared, and
     * `lastRunAdvanceFailures` is EMPTY. The third assertion is the one that names the cause;
     * without it a future reader gets "expected BOV Outreach, got Disposition Readiness" and no
     * hint as to why.
     */
    @isTest
    static void saleDecisionApproved_blankPrice_stillAdvances() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        // ⚠ THE PRECONDITION READS THE **ASSET** SINCE 2026-08-25. Reading the Disposition's own
        // retired `Asking_Price__c` would still compile and would still be null — and would
        // therefore assert nothing about the field the gate actually looks at.
        Assert.isNull(
            [SELECT Target_Sale_Price__c FROM Property_Asset__c WHERE Id = :assetId()]
                .Target_Sale_Price__c,
            'PRECONDITION: the fixture asset must be UNPRICED. A priced one would satisfy any '
            + 'future validation rule and this test would pass without testing anything.');
        submit(d.Id);

        Test.startTest();
        decide(d.Id, 'Approve');
        Test.stopTest();

        // WITH SYSTEM_MODE — Approval_Advance_Pending__c carries no FLS for anyone by design.
        Disposition__c after = [
            SELECT Disposition_Stage__c, Approval_Advance_Pending__c FROM Disposition__c
            WHERE Id = :d.Id WITH SYSTEM_MODE
        ];
        Assert.areEqual('BOV Outreach', after.Disposition_Stage__c,
            'A blank target sale price must NOT block the D-1 auto-advance. Still reading '
            + '"Disposition Readiness" means a validation rule (or an approval entry criterion) '
            + 'now requires a price and the Queueable\'s allOrNone = false swallowed the '
            + 'refusal — read TARGET_SALE_PRICE_REQUIRED_MESSAGE in DispositionApprovalService.');
        Assert.isFalse(after.Approval_Advance_Pending__c,
            'The semaphore must be CLEARED. A stuck true is the signature of a swallowed '
            + 'validation-rule refusal inside DispositionApprovalAdvanceQueueable.');
        Assert.areEqual(0, DispositionApprovalAdvanceService.lastRunAdvanceFailures.size(),
            'The advance must record no failures. Contents name the exact refusal: '
            + DispositionApprovalAdvanceService.lastRunAdvanceFailures);
    }

    /**
     * The off-market twin of the test above — same claim, the OTHER advance target. Kept
     * separate rather than parameterised because a record-type-scoped validation rule would
     * break exactly one of the two, and a single combined test could not say which.
     */
    @isTest
    static void saleDecisionApproved_offMarket_blankAskingPrice_stillAdvances() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_OFF_MARKET, 'Disposition Readiness');
        submit(d.Id);

        Test.startTest();
        decide(d.Id, 'Approve');
        Test.stopTest();

        Disposition__c after = [
            SELECT Disposition_Stage__c, Approval_Advance_Pending__c FROM Disposition__c
            WHERE Id = :d.Id WITH SYSTEM_MODE
        ];
        Assert.areEqual('Broker Selection', after.Disposition_Stage__c,
            'An unpriced Off_Market sale must still advance to Broker Selection on approval');
        Assert.isFalse(after.Approval_Advance_Pending__c, 'The semaphore must be cleared');
        Assert.areEqual(0, DispositionApprovalAdvanceService.lastRunAdvanceFailures.size(),
            'No advance failures: ' + DispositionApprovalAdvanceService.lastRunAdvanceFailures);
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

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE PREFERRED BROKER GOES ALL THE WAY THROUGH `Broker_Finalize_Approval`. ADDED 2026-08-24.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The preferred-broker-wins decision was accepted on the expectation that
     * `handleApprovedSelections` "should need no change" because a preferred row is now `Selected`.
     * That expectation is CORRECT, and this test is what verifies it rather than assuming it — it
     * walks the real `Approval.process` submit and approve, exactly as the three neighbouring
     * BOV/offer tests do, and checks all four links in the chain:
     *
     *   1. the row is `Selected` — put there by `BovAutoSelectionService`, NOT by the fixture;
     *   2. `submit()` is ACCEPTED, i.e. the platform entry criterion
     *      (`Submission_Status__c = 'Selected'`, the entire `<entryCriteria>` of that process) is
     *      satisfied by a preferred row;
     *   3. approving it advances the PARENT to `Broker Selection`;
     *   4. and stamps `Selected_Broker__c`.
     *
     * 🔴 LINK 4 IS THE ONE THAT COULD HAVE BROKEN AND DID NOT, SO THE REASON IS RECORDED HERE.
     * `handleApprovedSelections` stamps the parent from `BOV_Submission__c.Broker_Firm__c`, which
     * `BovSubmissionBrokerStampService` derives from the `Broker__c` Contact lookup. A preferred row
     * is exempt from `BOV_Amount_Required_On_Submission` but is **NOT** exempt from
     * `Broker_Required_On_Submission` (`ISBLANK(Broker__c)`, still unguarded — verified in the org
     * 2026-08-24), so `Broker__c` is mandatory on EVERY row and the firm is therefore always
     * derivable. ⚠ IF ANYONE EVER ADDS A PREFERRED EXEMPTION TO THAT SECOND RULE, THIS BREAKS: the
     * sale advances with a BLANK `Selected_Broker__c` and no error anywhere. This test is the alarm.
     *
     * ⚠ THE SUBMISSION HERE CARRIES NO BOV AMOUNT, DELIBERATELY — the accepted consequence of the
     * decision. It is asserted rather than merely allowed, because a fixture that quietly gained an
     * amount would stop testing the case the user actually signed off.
     */
    @isTest
    static void brokerFinalizeApproved_preferredBroker_advancesTheParentAndStampsTheBroker() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'BOV Outreach');
        // A scored response arrives first and is auto-appointed...
        BOV_Submission__c scored = TestDataFactory.createBovSubmission(d.Id, false);
        scored.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - Scored', true).Id;
        scored.BOV_Amount__c = 1200000;
        insert scored;

        // ...then a PREFERRED broker with no quote at all takes the slot from it.
        BOV_Submission__c preferred = TestDataFactory.createBovSubmission(d.Id, false);
        preferred.Broker__c =
            TestDataFactory.createBrokerContactWithFirm('JLL - Preferred', true).Id;
        preferred.Is_Preferred_Broker__c = true;
        preferred.BOV_Amount__c = null;
        preferred.Cap_Rate__c = null;
        preferred.Commission_Rate__c = null;
        preferred.Days_To_Market__c = null;
        preferred.Hist_Success_Rate__c = null;
        insert preferred;

        BOV_Submission__c promoted = [
            SELECT Submission_Status__c, BOV_Amount__c, Broker_Firm__c
            FROM BOV_Submission__c WHERE Id = :preferred.Id
        ];
        Assert.areEqual('Selected', promoted.Submission_Status__c,
            'LINK 1 — the preferred row must have been promoted by BovAutoSelectionService, not by '
            + 'this fixture. Backup here means the whole chain below is untestable.');
        Assert.isNull(promoted.BOV_Amount__c,
            'and it must genuinely carry NO quote — that is the accepted consequence under test');
        Assert.isNotNull(promoted.Broker_Firm__c,
            'LINK 4 PRECONDITION: the firm is derived from the mandatory Broker__c lookup, which is '
            + 'what keeps the parent stamp below non-blank despite the missing quote');

        // LINK 2 — the platform entry criterion. `submit()` asserts isSuccess() itself.
        submit(preferred.Id);

        Test.startTest();
        decide(preferred.Id, 'Approve');
        Test.stopTest();

        Disposition__c after = [
            SELECT Disposition_Stage__c, Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id
        ];
        Assert.areEqual('Broker Selection', after.Disposition_Stage__c,
            'LINK 3 — approving a PREFERRED broker must advance the parent exactly as approving a '
            + 'scored one does. handleApprovedSelections needed no change, and this is the proof.');
        Assert.areEqual('JLL - Preferred', after.Selected_Broker__c,
            'LINK 4 — and stamp the PREFERRED broker firm, not the scored one it displaced');
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
