/**
 * @description Test class for BovController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Read-only class (no DML), already at 100% reported coverage; adds a
 * NULLS-LAST ordering test, an empty-list scenario, a below-threshold
 * matrixGenerated boundary, a delete-based negative scenario, and a 251-record
 * data-volume read test per .claude/rules/bulk-test-rule.md.
 * @author Unit Testing Agent
 */
@isTest
private class BovControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'BOV Outreach';
        d.Package_Sent__c = Date.today().addDays(-15);
        d.Submission_Deadline__c = Date.today().addDays(1);
        d.Responses_Received__c = 4;
        d.Brokers_Contacted__c = 6;
        d.Selected_Broker__c = 'CBRE - Mark Chen';
        insert d;
    }

    @isTest
    static void testGetSubmissions_positiveScenario_ordersByScoreDescending() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c winner = TestDataFactory.createBovSubmission(d.Id, false);
        winner.Broker_Firm__c = 'CBRE';
        winner.Contact_Name__c = 'Mark Chen';
        winner.BOV_Amount__c = 28500000;
        winner.Commission_Rate__c = 3.0;
        winner.Days_To_Market__c = 45;
        winner.Hist_Success_Rate__c = 82;
        winner.BOV_Score__c = 91;
        winner.Submission_Status__c = 'Selected';
        BOV_Submission__c backup = TestDataFactory.createBovSubmission(d.Id, false);
        backup.Broker_Firm__c = 'JLL';
        backup.Contact_Name__c = 'K. Rao';
        backup.BOV_Amount__c = 27900000;
        backup.Commission_Rate__c = 2.5;
        backup.Days_To_Market__c = 52;
        backup.Hist_Success_Rate__c = 78;
        backup.BOV_Score__c = 84;
        backup.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ winner, backup };

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two submissions should be returned');
        System.assertEquals('CBRE', rows[0].brokerFirm, 'Higher BOV_Score__c should sort first');
        System.assertEquals(true, rows[0].isSelected, 'Selected status should map to isSelected = true');
        System.assertEquals(91, rows[0].bovScore, 'Score should pass through as an Integer');
        System.assertEquals(false, rows[1].isSelected, 'Backup status should map to isSelected = false');
    }

    @isTest
    static void testGetSubmissions_nullScore_sortsLast() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c scored = TestDataFactory.createBovSubmission(d.Id, false);
        scored.BOV_Score__c = 70;
        BOV_Submission__c unscored = TestDataFactory.createBovSubmission(d.Id, false);
        unscored.BOV_Score__c = null;
        insert new List<BOV_Submission__c>{ unscored, scored };

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two submissions should be returned');
        System.assertEquals(70, rows[0].bovScore, 'The scored submission should sort first');
        System.assertEquals(null, rows[1].bovScore, 'NULLS LAST should push the unscored submission to the end');
    }

    @isTest
    static void testGetSubmissions_noSubmissions_returnsEmptyList() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'No BOV_Submission__c records exist yet, so the list should be empty');
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251
     * BOV_Submission__c children under one Disposition, inserted via a single
     * bulk DML statement, to prove the row-transform loop in getSubmissions
     * scales without a CPU-time or heap-size breach.
     */
    @isTest
    static void testGetSubmissions_251Submissions_allRowsTransformCleanly() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        TestDataFactory.createBovSubmissions(251, d.Id, true);

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        System.assertEquals(251, rows.size(), 'All 251 submissions should be returned and transformed');
    }

    @isTest
    static void testGetOutreachSummary_positiveScenario() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        System.assertEquals(4, s.responsesReceived, 'Responses received should pass through');
        System.assertEquals(true, s.matrixGenerated, '4 responses meets the >= 3 threshold for matrix generation');
        System.assertEquals('CBRE - Mark Chen', s.selectedBroker, 'Selected broker should pass through');
    }

    @isTest
    static void testGetOutreachSummary_belowThreshold_matrixNotGenerated() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        d.Responses_Received__c = 2;
        update d;

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        System.assertEquals(false, s.matrixGenerated, 'Below the 3-response threshold, the matrix should not be flagged generated');
    }

    /**
     * P6 controller error boundary: a Disposition Id that no longer exists makes the
     * selector's single-row SOQL throw System.QueryException, which getOutreachSummary
     * now catches and re-surfaces as a user-safe AuraHandledException at the LWC boundary
     * (ARCHITECTURE.md §5). Intent preserved from the original raw-QueryException test:
     * a missing Disposition surfaces an error — but now the raw "no rows" detail is
     * masked and only the user-safe message reaches the caller.
     */
    @isTest
    static void testGetOutreachSummary_invalidId_throwsUserSafeAuraException() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        Boolean threw = false;
        try {
            BovController.getOutreachSummary(deletedId);
            System.assert(false, 'Expected an AuraHandledException for a Disposition Id that no longer exists');
        } catch (AuraHandledException e) {
            threw = true;
            System.assertEquals(false, e.getMessage().toLowerCase().contains('no rows'),
                'The raw QueryException detail must be masked at the boundary: ' + e.getMessage());
            System.assertEquals(true, e.getMessage().toLowerCase().contains('could not be loaded'),
                'The user should get the fixed user-safe read-failure message: ' + e.getMessage());
        }
        System.assert(threw, 'A deleted Disposition Id should surface a user-safe AuraHandledException');
        Test.stopTest();
    }

    // A bare user with no DPEG access: both reads query custom objects (BOV_Submission__c /
    // Disposition__c) WITH USER_MODE and throw for the unprivileged user, exercising both
    // read-failure catches which map to a user-safe AuraHandledException at the LWC boundary
    // (P6). getSubmissions has no prior negative-path coverage (an empty list returns early),
    // so this restricted-user path is the only way to reach its catch.
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    @isTest
    static void readPathsThrowAuraHandledException() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try {
                BovController.getSubmissions(d.Id);
                Assert.fail('expected AuraHandledException from getSubmissions under a restricted user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getSubmissions read failure maps to AuraHandledException');
            }
            try {
                BovController.getOutreachSummary(d.Id);
                Assert.fail('expected AuraHandledException from getOutreachSummary under a restricted user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getOutreachSummary read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
    }
}
