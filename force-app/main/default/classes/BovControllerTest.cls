/**
 * @description Test class for BovController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Read-only class (no DML), already at 100% reported coverage; adds a
 * NULLS-LAST ordering test, an empty-list scenario, a below-threshold
 * matrixGenerated boundary, a delete-based negative scenario, and a 251-record
 * data-volume read test per .claude/rules/bulk-test-rule.md.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * DISPOSITION FOUNDATIONS: OutreachSummary.ndaStatus
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The BOV Outreach tile used to render a hard-coded "Signed" NDA pill, misreporting a
 * COMPLIANCE state on every disposition. It now carries the real Status__c of the
 * disposition's most recent NDA__c, or null when there is none.
 *
 * ⚠ THE FAIL-SOFT CATCH IN BovController.readNdaStatusFailSoft IS NOT COVERED HERE, AND
 * THAT IS A KNOWN, ACCEPTED GAP — not an oversight. It only fires when the running user
 * can read Disposition__c but NOT NDA__c, and there is no way to construct that principal
 * in Apex in this org: a bare Standard User throws on the Disposition read FIRST (which is
 * what readPathsThrowAuraHandledException exercises), and every permission set that grants
 * Disposition__c now also grants NDA__c (Gate 1 Q7), so no assignable persona sits in the
 * gap. Design §5.6 says the same thing in general terms — "an FLS test that runs as an
 * admin cannot fail" — and names persona acceptance testing (§8 gate B5) as the only real
 * proof. A @TestVisible seam was deliberately NOT added: it would put test-only branching
 * into a live read path to cover three lines of defence-in-depth.
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
        // 🔴 Broker_Firm__c IS PINNED VIA Broker__c, NOT A HAND-TYPED LITERAL, AS OF 2026-08-20
        // (Tranche 2, requirements §3 D1). BovSubmissionBrokerStampService overwrites any
        // hand-typed Broker_Firm__c the instant Broker__c is set (which is now every save) — see
        // that service's header ("the stamp wins") and TestDataFactory.createBrokerContactWithFirm.
        BOV_Submission__c winner = TestDataFactory.createBovSubmission(d.Id, false);
        winner.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE', true).Id;
        winner.BOV_Amount__c = 28500000;
        winner.Commission_Rate__c = 3.0;
        winner.Days_To_Market__c = 45;
        winner.Hist_Success_Rate__c = 82;
        winner.BOV_Score__c = 91;
        winner.Submission_Status__c = 'Selected';
        BOV_Submission__c backup = TestDataFactory.createBovSubmission(d.Id, false);
        backup.Broker__c = TestDataFactory.createBrokerContactWithFirm('JLL', true).Id;
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

    // ═══════════════════════════════════════════════════════════════════════════
    // ndaStatus — the real NDA pill (replaces the hard-coded 'Signed')
    // ═══════════════════════════════════════════════════════════════════════════

    /** A disposition-parented NDA: NDA__c is dual-parented and both lookups are optional. */
    private static NDA__c dispositionNda(Id dispositionId, String status) {
        NDA__c nda = TestDataFactory.createNda(null, false);
        nda.Disposition__c = dispositionId;
        nda.Status__c = status;
        insert nda;
        return nda;
    }

    /**
     * 🔴 THE DEFECT THIS CLOSES. The pill previously read "Signed" on every disposition
     * whether or not an NDA existed. The @TestSetup disposition has NO NDA, so the honest
     * answer is null — and asserting NULL here is what makes the old hard-coded value
     * impossible to reintroduce on the server side.
     */
    @isTest
    static void testGetOutreachSummary_noNda_ndaStatusIsNull() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.isNull(s.ndaStatus,
            'With no NDA on the disposition the status must be null, not a hard-coded "Signed"');
    }

    @isTest
    static void testGetOutreachSummary_withNda_returnsItsRealStatus() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        dispositionNda(d.Id, 'Pending');

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.areEqual('Pending', s.ndaStatus,
            'The pill must show the NDA\'s REAL status, including an unflattering one');
    }

    /** Many NDAs, one pill: the most recently created row wins (mirrors the selector contract). */
    @isTest
    static void testGetOutreachSummary_multipleNdas_showsTheLatest() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        NDA__c older = dispositionNda(d.Id, 'Pending');
        dispositionNda(d.Id, 'Signed');
        // In-transaction CreatedDate ties would make ORDER BY CreatedDate DESC arbitrary.
        Test.setCreatedDate(older.Id, System.now().addMinutes(-5));

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.areEqual('Signed', s.ndaStatus, 'The latest NDA defines the pill');
    }

    /**
     * An NDA hanging off an OPPORTUNITY must never leak into a disposition's pill —
     * NDA__c is dual-parented, so this is a live confusion risk rather than a hypothetical.
     */
    @isTest
    static void testGetOutreachSummary_opportunityNdaDoesNotLeakIn() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createNda(opp.Id, true);

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.isNull(s.ndaStatus,
            'An Opportunity-parented NDA is not this disposition\'s NDA and must not populate the pill');
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

    // ═══════════════════════════════════════════════════════════════════════════
    // replaceSelectedBroker — thin wrapper over BovSubmissionService (DEV-6)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void replaceSelectedBroker_positiveScenario_returnsTheWarningMessage() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        String msg = BovController.replaceSelectedBroker(
            d.Id, challenger.Id, 'Company Decision', 'Owner asked for a change.');
        Test.stopTest();

        System.assertEquals('Selected',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :challenger.Id].Submission_Status__c);
        System.assertEquals('Backup',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :incumbent.Id].Submission_Status__c);
        System.assert(msg.contains('must be approved'), 'The warning must survive the controller boundary: ' + msg);
        // The two new parameters are PASSED THROUGH, not swallowed — proved on the row the service
        // writes rather than by mocking, because "the controller is thin" is only meaningful if the
        // values actually arrive at the far end.
        BOV_Broker_Change__c row = [
            SELECT Reason__c, Notes__c FROM BOV_Broker_Change__c WHERE Disposition__c = :d.Id LIMIT 1
        ];
        Assert.areEqual('Company Decision', row.Reason__c,
            'The reason must reach the history row through the controller');
        Assert.areEqual('Owner asked for a change.', row.Notes__c,
            'And so must the notes');
    }

    /**
     * A blank reason is a SERVICE rule, and the controller must surface it through the SECOND
     * catch — verbatim — rather than adding a rule of its own or masking it as a system failure.
     * This is the same three-catch-order proof as the two tests below, on the newest refusal path.
     */
    @isTest
    static void replaceSelectedBroker_blankReason_surfacesTheRefusalVerbatim() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        Boolean refused = false;
        try {
            BovController.replaceSelectedBroker(d.Id, challenger.Id, null, 'notes');
            Assert.fail('A blank reason must be refused');
        } catch (AuraHandledException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('reason'),
                'The service\'s authored refusal must surface verbatim, not the generic '
                + 'REPLACE_FAILURE_MESSAGE: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The controller must surface the BovSubmissionException verbatim');
        Assert.areEqual(0,
            [SELECT COUNT() FROM BOV_Broker_Change__c WHERE Disposition__c = :d.Id],
            'And nothing may be recorded');
    }

    /**
     * 🔴 THE THREE-CATCH ORDER, PROVED THE SAME WAY DispositionControllerTest proves
     * findOrCreate's two-catch order: a user-actionable refusal must surface VERBATIM, not be
     * masked behind the generic REPLACE_FAILURE_MESSAGE.
     */
    @isTest
    static void replaceSelectedBroker_challengerNotOnDisposition_surfacesTheRefusalVerbatim() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c other = TestDataFactory.createDisposition(asset.Id, false);
        other.Disposition_Stage__c = 'BOV Outreach';
        insert other;
        BOV_Submission__c foreign = TestDataFactory.createBovSubmission(other.Id, true);

        Test.startTest();
        Boolean refused = false;
        try {
            BovController.replaceSelectedBroker(d.Id, foreign.Id, 'Other', null);
            Assert.fail('A cross-disposition submission must be refused');
        } catch (AuraHandledException e) {
            refused = true;
            System.assert(e.getMessage().contains('does not belong to this disposition'),
                'The refusal must surface verbatim, not the generic message: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(refused, 'The controller must surface the BovSubmissionException verbatim');
    }

    /**
     * The permission-denial leg of the three-catch order — verbatim, ordered FIRST, mirroring
     * DispositionApprovalController's own argument for why a denial must never fall through to
     * the generic clause.
     */
    @isTest
    static void replaceSelectedBroker_bareUser_isDeniedVerbatim() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        insert new List<BOV_Submission__c>{ incumbent, challenger };
        User u = bareUser();

        DispositionActionPermissionService.clearCache();
        System.runAs(u) {
            Test.startTest();
            Boolean denied = false;
            try {
                BovController.replaceSelectedBroker(d.Id, challenger.Id, 'Other', null);
                Assert.fail('A bare user with no disposition-driver grant must be denied');
            } catch (AuraHandledException e) {
                denied = true;
                System.assert(e.getMessage().contains('permission'),
                    'The denial must surface the shared permission wording verbatim: ' + e.getMessage());
            }
            Test.stopTest();
            System.assert(denied);
        }
        DispositionActionPermissionService.clearCache();
        System.assertEquals('Selected',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :incumbent.Id].Submission_Status__c,
            'A denied call must write nothing');
    }
}
