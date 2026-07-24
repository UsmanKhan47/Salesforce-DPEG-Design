/**
 * Test class for CompetingSubmissionController. The error-path test uses the repo's
 * established "bare user, no permission set" technique (see
 * BrokerAssignmentControllerTest.readPathsThrowAuraHandledException) to force the
 * underlying WITH USER_MODE selector read to fail, exercising the controller's
 * generic-exception -> AuraHandledException boundary.
 *
 * @author Unit Testing Agent
 */
@isTest
private class CompetingSubmissionControllerTest {

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createLead(true);
    }

    @isTest
    static void getSubmissions_returnsWinnerSubmissionsOrderedAsc() {
        Id winnerId = [SELECT Id FROM Lead LIMIT 1].Id;
        TestDataFactory.createCompetingBrokerSubmissions(3, winnerId, true);
        List<Competing_Broker_Submission__c> expectedOrder = [
            SELECT Id FROM Competing_Broker_Submission__c WHERE Winning_Lead__c = :winnerId ORDER BY Submitted_DateTime__c ASC
        ];

        Test.startTest();
        List<Competing_Broker_Submission__c> results = CompetingSubmissionController.getSubmissions(winnerId);
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'All 3 submissions for the winning lead should be returned');
        Assert.areEqual(expectedOrder[0].Id, results[0].Id, 'Earliest submission should be first (ASC)');
        Assert.areEqual(expectedOrder[1].Id, results[1].Id, 'Middle submission should be second');
        Assert.areEqual(expectedOrder[2].Id, results[2].Id, 'Latest submission should be last');
        Assert.isTrue(results[0].Is_Winning_Submission__c, 'The earliest submission is the factory\'s winning row');
    }

    @isTest
    static void getSubmissions_noSubmissions_returnsEmptyList() {
        Lead lonely = [SELECT Id FROM Lead LIMIT 1];

        Test.startTest();
        List<Competing_Broker_Submission__c> results = CompetingSubmissionController.getSubmissions(lonely.Id);
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A winning lead with no submissions should return an empty list, not an error');
    }

    // ── error path ────────────────────────────────────────────────────────────

    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'csbare', Email = 'csbare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'CSBare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'csbare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid'
        );
        insert u;
        return u;
    }

    @isTest
    static void getSubmissions_unprivilegedUser_throwsAuraHandledException() {
        Id winnerId = [SELECT Id FROM Lead LIMIT 1].Id;
        User u = bareUser();

        Boolean threw = false;
        System.runAs(u) {
            Test.startTest();
            try {
                CompetingSubmissionController.getSubmissions(winnerId);
                Assert.fail('Expected an AuraHandledException for a user with no Competing_Broker_Submission__c access');
            } catch (AuraHandledException e) {
                threw = true;
                Assert.isNotNull(e.getMessage(), 'A user-safe message should be set via the ahe() helper');
            }
            Test.stopTest();
        }
        Assert.isTrue(threw, 'A read failure under a restricted user must surface as AuraHandledException, not a raw exception');
    }
}
