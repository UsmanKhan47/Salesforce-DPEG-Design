/**
 * Tests ContractReviewTriggerHandler: the Contract_Review__c after-update
 * context routes to ContractExecutionService, so executing a PSA opens exactly
 * one Transaction for the deal. Behaviour is asserted through the trigger, as it
 * fires in production.
 */
@isTest
private class ContractReviewTriggerHandlerTest {

    /**
     * Drives an Opportunity to PSA, which auto-creates its Contract Review.
     *
     * LOI -> PSA crosses the signed-NDA gate (which covers PSA) and the approved-LOI gate, so the
     * fixture is prepared to satisfy both rather than the assertions being relaxed.
     */
    private static Contract_Review__c dealAtPsa() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        TestDataFactory.signPrimaryNda(o);
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        // Completed_LOI_Before_PSA (added 2026-08-12) reads the LOI's OWN Stage__c, which
        // placeApprovedLoi deliberately leaves at its factory-default 'Draft'. Drive it to
        // 'Signed' via the real production route before entering PSA — same fix as
        // ContractExecutionServiceTest.dealAtPsa (the identical fixture, duplicated in this class).
        // ⚠ 'Signed' since observation 5 (2026-08-14); this was 'Completed' until the acquisition
        // LOI sequence was renamed. It must stay in step with Completed_LOI_Before_PSA, the
        // validation rule this line exists to satisfy — that rule reads the LOI child's OWN
        // Stage__c by string (design collision C2) and is repointed in the same P3-D2 wave. If this
        // line and that rule ever disagree, EVERY deal in the org is blocked from entering
        // 'Under Contract (PSA)' and this fixture is where it shows up first.
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Signed');
        o.StageName = 'Under Contract (PSA)';
        update o;
        return [SELECT Id, Opportunity__c FROM Contract_Review__c WHERE Opportunity__c = :o.Id];
    }

    @isTest
    static void afterUpdate_HandsOffExecutedContract() {
        // Given: a deal with a Contract Review at PSA.
        Contract_Review__c cr = dealAtPsa();

        // When: the negotiation status becomes Executed.
        Test.startTest();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        // Then: the after-update handler routed to ContractExecutionService, opening one Transaction.
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c],
            'Executing the PSA opens exactly one Transaction via the handler'
        );
    }

    /**
     * Bulk (.claude/rules/bulk-test-rule.md): 251 Contract Reviews executed in
     * one transaction forces a second Contract_Review__c trigger batch chunk and
     * proves the handler routes the whole collection, not a single record.
     */
    @isTest
    static void bulk251ExecutedContractsHandOff() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        for (Opportunity o : opps) {
            o.StageName = 'LOI';
        }
        insert opps;
        // The same gates dealAtPsa() prepares, in bulk: one DML statement per helper.
        TestDataFactory.signPrimaryNda(opps);
        List<LOI__c> primaryLois = TestDataFactory.placeApprovedLoi(opps);

        // Completed_LOI_Before_PSA (added 2026-08-12) reads each LOI's OWN Stage__c, which
        // placeApprovedLoi deliberately leaves at 'Draft'. dealAtPsa() drives this through the real
        // production route (RecordStageAdvanceService.advanceTo) because it is a single-record
        // fixture, but that route is one DML statement PER CALL — looping it 251 times here would
        // blow the 150-DML-statement transaction limit before Test.startTest() is even reached.
        // LOI__c has no validation rules (confirmed: no objects/LOI__c/validationRules folder), so
        // a direct bulk write is a safe, ONE-statement substitute for the same precondition at this
        // volume — same reasoning as ContractExecutionServiceTest.bulkExecution251ContractsHandsOffToTransactions.
        List<LOI__c> completedLois = new List<LOI__c>();
        for (LOI__c primaryLoi : primaryLois) {
            completedLois.add(new LOI__c(Id = primaryLoi.Id, Stage__c = 'Signed'));
        }
        update completedLois;

        for (Opportunity o : opps) {
            o.StageName = 'Under Contract (PSA)';
        }
        update opps; // auto-creates 251 Contract Reviews

        List<Contract_Review__c> reviews = [SELECT Id FROM Contract_Review__c WHERE Opportunity__c IN :opps];
        Assert.areEqual(251, reviews.size(), 'A Contract Review opens for every deal entering PSA');

        Test.startTest();
        for (Contract_Review__c cr : reviews) {
            cr.Negotiation_Status__c = 'Executed';
        }
        update reviews;
        Test.stopTest();

        Assert.areEqual(
            251,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c IN :opps],
            'Every executed deal opens exactly one Transaction'
        );
    }
}
