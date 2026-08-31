/**
 * Tests OpportunityReviewTriggerHandler: the Opportunity trigger routes
 * after-insert and after-update to OpportunityReviewService. On insert the deal's
 * NDA is opened; on entering a review stage the matching feasibility review is
 * opened. Behaviour is asserted through the trigger, as it fires in production.
 *
 * Note: TestDataFactory.createOpportunities defaults StageName to 'New', so a
 * plain insert cascades only the NDA; moving to 'Development Review' then opens
 * the feasibility review (same pattern as OpportunityReviewServiceTest).
 *
 * ⚠ SCOPE NOTE 2026-08-31 — THE FIRST SENTENCE IS NOW A SUBSET, NOT THE WHOLE ROUTER.
 * The handler also routes BEFORE insert and BEFORE update, to
 * OpportunityStageEntryService.stampStageEntryDates (design §2 ITEM 2). This class deliberately
 * does NOT test that: it is covered end-to-end, including its 251-record bulk and in-context
 * governor assertions, by OpportunityStageEntryServiceTest. Nothing here changed — the two
 * before-context calls add no query, no DML and no record to any scenario below — but a reader
 * should not conclude from this header that the after contexts are all the handler does.
 */
@isTest
private class OpportunityReviewTriggerHandlerTest {

    private static final String DEV_STAGE = 'Development Review';

    @isTest
    static void afterInsert_OpensNda() {
        // Given / When: a single Opportunity is inserted at 'New'.
        Test.startTest();
        Opportunity o = TestDataFactory.createOpportunity(null, true);
        Test.stopTest();

        // Then: the after-insert handler routed to ensureNda, opening exactly one NDA.
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM NDA__c WHERE Opportunity__c = :o.Id],
            'Inserting an Opportunity opens exactly one NDA via the handler'
        );
    }

    @isTest
    static void afterUpdate_OpensFeasibilityReview() {
        // Given: an Opportunity at 'New' (NDA already opened on insert).
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        insert o;

        // When: it enters the Development Review stage.
        Test.startTest();
        o.StageName = DEV_STAGE;
        update o;
        Test.stopTest();

        // Then: the after-update handler routed to createReviewRecords, opening one review.
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Development_Feasibility_Review__c WHERE Opportunity__c = :o.Id],
            'Entering Development Review opens exactly one feasibility review via the handler'
        );
    }

    /**
     * Bulk insert (.claude/rules/bulk-test-rule.md): 251 Opportunities in one DML
     * forces a second Opportunity trigger batch chunk and proves the after-insert
     * handler opens one NDA per deal across chunks.
     */
    @isTest
    static void bulk251InsertsOpenOneNdaEach() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);

        Test.startTest();
        insert opps; // 251 in one DML
        Test.stopTest();

        Assert.areEqual(
            251,
            [SELECT COUNT() FROM NDA__c WHERE Opportunity__c IN :opps],
            'Every one of the 251 inserted Opportunities opens exactly one NDA'
        );
    }

    /**
     * Bulk update (.claude/rules/bulk-test-rule.md): 251 Opportunities entering
     * Development Review in one DML proves the after-update handler opens one
     * feasibility review per deal across chunks.
     */
    @isTest
    static void bulk251UpdatesOpenOneReviewEach() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        insert opps; // fires after-insert cascade (251 NDAs)

        Test.startTest();
        for (Opportunity o : opps) {
            o.StageName = DEV_STAGE;
        }
        update opps; // 251 in one DML
        Test.stopTest();

        Assert.areEqual(
            251,
            [SELECT COUNT() FROM Development_Feasibility_Review__c WHERE Opportunity__c IN :opps],
            'Every one of the 251 updated Opportunities opens exactly one feasibility review'
        );
    }
}
