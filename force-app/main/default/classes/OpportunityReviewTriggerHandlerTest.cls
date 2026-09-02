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

    /**
     * ROUTING PROOF for the SIXTH after-context call, added 2026-09-02 with
     * OpportunityReviewService.syncNdaProperty (design item A, HALF 2).
     *
     * 🔴 THIS CLASS ASSERTS ROUTING, NOT BEHAVIOUR, AND THAT DISTINCTION IS WHY THIS METHOD IS
     * NOT A DUPLICATE OF OpportunityReviewServiceTest's. The service tests call the service; this
     * one proves the HANDLER actually wires it into `route()`. Delete the
     * `OpportunityReviewService.syncNdaProperty(opps, priorById);` line from the handler and
     * every service-level test still passes — only this one goes red. That is the failure mode
     * this class exists for, and it is exactly why afterInsert_OpensNda exists too.
     *
     * ⚠ The NDA must start BLANK. It does, because this deal is inserted with no Property — the
     * lead-conversion state. A fixture that set the Property before insert would let HALF 1 do
     * the work and this test would pass with the handler line deleted.
     */
    @isTest
    static void afterUpdate_SyncsTheDealsPropertyOntoItsNda() {
        Property__c p = TestDataFactory.defaultProperty();
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        insert o; // after-insert routes to ensureNda; no Property yet, so the NDA opens blank

        NDA__c before = [SELECT Property__c FROM NDA__c WHERE Opportunity__c = :o.Id LIMIT 1];
        Assert.areEqual(null, before.Property__c,
            'PRECONDITION: the NDA opens blank, or this asserts HALF 1 rather than the routing');

        Test.startTest();
        update new Opportunity(Id = o.Id, Property__c = p.Id);
        Test.stopTest();

        Assert.areEqual(
            p.Id,
            [SELECT Property__c FROM NDA__c WHERE Opportunity__c = :o.Id LIMIT 1].Property__c,
            'The after-update handler routed to syncNdaProperty, stamping the deal\'s Property '
            + 'onto its NDA'
        );
    }

    /**
     * Bulk update (.claude/rules/bulk-test-rule.md) for the sixth call: 251 Opportunities each
     * gaining a Property in ONE DML forces a second trigger batch chunk and proves the
     * after-update handler routes syncNdaProperty across BOTH of them.
     *
     * ⚠ Distinct Properties per deal, deliberately — one shared Property would pass even against
     * a mis-keyed map, because every NDA would receive the single right answer by accident.
     * The per-chunk QUERY BUDGET for this path is asserted in OpportunityReviewServiceTest
     * .bulk251Updates_syncNdaPropertyCostsOneQueryPerChunkNotPerRecord, which owns that fact;
     * this method owns only "the handler routes it for all 251".
     */
    @isTest
    static void bulk251UpdatesStampTheNdaPropertyEach() {
        List<Property__c> props = TestDataFactory.createProperties(251, true);
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        insert opps; // 251 blank NDAs open here

        for (Integer i = 0; i < opps.size(); i++) {
            opps[i].Property__c = props[i].Id;
        }

        Test.startTest();
        update opps; // 251 in one DML
        Test.stopTest();

        Map<Id, Id> propertyByOpp = new Map<Id, Id>();
        for (Opportunity o : opps) {
            propertyByOpp.put(o.Id, o.Property__c);
        }
        Integer stamped = 0;
        for (NDA__c n : [
            SELECT Opportunity__c, Property__c FROM NDA__c WHERE Opportunity__c IN :opps
        ]) {
            if (n.Property__c == propertyByOpp.get(n.Opportunity__c)) {
                stamped++;
            }
        }
        Assert.areEqual(251, stamped,
            'Every one of the 251 updated Opportunities stamped its own Property onto its own '
            + 'NDA through the handler, across both trigger chunks. A value near 200 is the '
            + 'cross-chunk drift a 200-record test cannot see. Stamped: ' + stamped);
    }
}
