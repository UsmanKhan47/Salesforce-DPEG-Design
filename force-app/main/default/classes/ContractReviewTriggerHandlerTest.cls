/**
 * Tests ContractReviewTriggerHandler: the Contract_Review__c after-update
 * context routes to ContractExecutionService, so executing a PSA opens exactly
 * one Transaction for the deal. Behaviour is asserted through the trigger, as it
 * fires in production.
 */
@isTest
private class ContractReviewTriggerHandlerTest {

    /** Drives an Opportunity to PSA, which auto-creates its Contract Review. */
    private static Contract_Review__c dealAtPsa() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        o.StageName = 'PSA';
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
        for (Opportunity o : opps) {
            o.StageName = 'PSA';
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
