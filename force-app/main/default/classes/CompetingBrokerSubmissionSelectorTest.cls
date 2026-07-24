/**
 * Test class for CompetingBrokerSubmissionSelector.
 *
 * @author Unit Testing Agent
 */
@isTest
private class CompetingBrokerSubmissionSelectorTest {

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createLead(true);
    }

    @isTest
    static void selectByWinningLead_returnsSubmissionsOrderedAsc() {
        Id winnerId = [SELECT Id FROM Lead LIMIT 1].Id;
        List<Competing_Broker_Submission__c> created =
            TestDataFactory.createCompetingBrokerSubmissions(3, winnerId, true);

        Test.startTest();
        List<Competing_Broker_Submission__c> results = CompetingBrokerSubmissionSelector.selectByWinningLead(winnerId);
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'All 3 submissions for the winning lead should be returned');
        Assert.isTrue(results[0].Is_Winning_Submission__c,
            'The earliest submission (index 0, per the factory\'s ascending-timestamp convention) should be the winner');
        Assert.isTrue(
            results[0].Submitted_DateTime__c <= results[1].Submitted_DateTime__c
                && results[1].Submitted_DateTime__c <= results[2].Submitted_DateTime__c,
            'Results should be ordered ascending by Submitted_DateTime__c'
        );
    }

    @isTest
    static void selectByWinningLead_noSubmissions_returnsEmpty() {
        Lead lonely = [SELECT Id FROM Lead LIMIT 1];

        Test.startTest();
        List<Competing_Broker_Submission__c> results = CompetingBrokerSubmissionSelector.selectByWinningLead(lonely.Id);
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A winning lead with no logged submissions should return an empty list');
    }

    @isTest
    static void selectByWinningLead_nullLeadId_returnsEmpty() {
        Test.startTest();
        List<Competing_Broker_Submission__c> results = CompetingBrokerSubmissionSelector.selectByWinningLead(null);
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A null leadId should short-circuit to an empty list');
    }

    @isTest
    static void selectByWinningLead_bulk251_returnsAll251() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        TestDataFactory.createCompetingBrokerSubmissions(251, winner.Id, true);

        Test.startTest();
        List<Competing_Broker_Submission__c> results = CompetingBrokerSubmissionSelector.selectByWinningLead(winner.Id);
        Test.stopTest();

        Assert.areEqual(251, results.size(),
            'All 251 submissions logged against one winning lead should be returned by one query');
    }
}
