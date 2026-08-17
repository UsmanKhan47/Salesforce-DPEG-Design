/**
 * Test class for BrokerLeaderboardController — the `@AuraEnabled` boundary for the broker
 * leaderboard (FSD §27.3 / §27.4, tranche 3 item 2).
 *
 * The ranking arithmetic is proved in `BrokerLeaderboardServiceTest`; this class covers
 * only what the CONTROLLER adds: the null-depth default, pass-through of the service's
 * ordering, and the `AuraHandledException` boundary.
 *
 * The error-path test uses the repo's established "bare user, no permission set" technique
 * (`CompetingSubmissionControllerTest.getSubmissions_unprivilegedUser_throwsAuraHandledException`,
 * `BrokerAssignmentControllerTest.readPathsThrowAuraHandledException`) to make the
 * underlying `WITH USER_MODE` aggregate fail. ⚠ That technique is available here precisely
 * BECAUSE both aggregates are USER_MODE — contrast `DispositionTractionController`, whose
 * header records the same test as structurally impossible for it, since SYSTEM_MODE is
 * exactly what stops the throw.
 */
@isTest
private class BrokerLeaderboardControllerTest {

    private static final String BUSY = 'busy.broker@example.invalid';
    private static final String QUIET = 'quiet.broker@example.invalid';

    @TestSetup
    static void setupTestData() {
        Lead winner = TestDataFactory.createLead(true);
        List<Competing_Broker_Submission__c> rows = new List<Competing_Broker_Submission__c>();
        rows.addAll(stamp(TestDataFactory.createCompetingBrokerSubmissions(3, winner.Id, false), BUSY, 2));
        rows.addAll(stamp(TestDataFactory.createCompetingBrokerSubmissions(1, winner.Id, false), QUIET, 0));
        insert rows;
    }

    /**
     * Give every row one shared broker address and a caller-chosen win pattern — the
     * factory mints a unique address per row, which is the opposite of what a leaderboard
     * fixture needs. See BrokerLeaderboardServiceTest's header for the full rationale.
     */
    private static List<Competing_Broker_Submission__c> stamp(
            List<Competing_Broker_Submission__c> rows, String brokerEmail, Integer wins) {
        for (Integer i = 0; i < rows.size(); i++) {
            rows[i].Broker_Email__c = brokerEmail;
            rows[i].Is_Winning_Submission__c = (i < wins);
        }
        return rows;
    }

    @isTest
    static void getLeaderboard_returnsTheServicesRankingUnchanged() {
        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows =
            BrokerLeaderboardController.getLeaderboard(10);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both fixture brokers should appear');
        Assert.areEqual(BUSY, rows[0].brokerEmail, 'The controller must not re-order the service\'s ranking');
        Assert.areEqual(3, rows[0].submissions, 'Counts must pass through untouched');
        Assert.areEqual(2, rows[0].propertiesWon, 'Wins must pass through untouched');
    }

    @isTest
    static void getLeaderboard_nullMaxRows_fallsBackToTheServiceDefault() {
        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows =
            BrokerLeaderboardController.getLeaderboard(null);
        Test.stopTest();

        // A null depth arrives whenever App Builder leaves the property unset, so it must
        // yield the default board rather than the service's deliberate empty-on-null result.
        Assert.areEqual(2, rows.size(),
            'A null depth must become DEFAULT_MAX_ROWS (' + BrokerLeaderboardService.DEFAULT_MAX_ROWS
            + '), not an empty leaderboard');
    }

    @isTest
    static void getLeaderboard_depthIsClampedServerSideRatherThanTrusted() {
        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows =
            BrokerLeaderboardController.getLeaderboard(1000000);
        Test.stopTest();

        // The parameter is a display depth, not a filter — even an absurd value cannot widen
        // what the read sees, only how much of the same public ranking is returned.
        Assert.areEqual(2, rows.size(), 'An oversized depth is clamped and still returns the real rows');
    }

    @isTest
    static void getLeaderboard_zeroDepth_returnsEmptyWithoutError() {
        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardController.getLeaderboard(0);
        Test.stopTest();

        Assert.isTrue(rows.isEmpty(), 'Zero rows requested is a legitimate empty result, not a failure');
    }

    // ── error path ────────────────────────────────────────────────────────────

    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'blbare', Email = 'blbare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'BLBare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'blbare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid'
        );
        insert u;
        return u;
    }

    @isTest
    static void getLeaderboard_unprivilegedUser_throwsAuraHandledException() {
        User u = bareUser();
        Boolean threw = false;

        System.runAs(u) {
            Test.startTest();
            try {
                BrokerLeaderboardController.getLeaderboard(10);
                Assert.fail('Expected an AuraHandledException for a user with no Competing_Broker_Submission__c access');
            } catch (AuraHandledException e) {
                threw = true;
                Assert.isNotNull(e.getMessage(), 'A user-safe message must be set via the ahe() helper');
                Assert.isFalse(e.getMessage().contains('SELECT'),
                    'The boundary must never leak platform detail — the detail belongs in the debug log');
            }
            Test.stopTest();
        }

        Assert.isTrue(threw,
            'A read failure under a restricted user must surface as AuraHandledException, not a raw QueryException');
    }
}
