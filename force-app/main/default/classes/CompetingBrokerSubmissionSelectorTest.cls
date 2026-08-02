/**
 * Test class for CompetingBrokerSubmissionSelector.
 *
 * selectRecentByBrokerEmail coverage was added 2026-07-31. The query had NO direct
 * tests, and the same change that needed them altered its WHERE clause: the
 * `Source_Lead__c != null` filter was REMOVED, because a competing broker no longer
 * receives a Lead and every competing submission now legitimately carries a null
 * source. selectRecentByBrokerEmail_nullSourceLeadRows_areReturned is the test that
 * goes red if that filter is ever restored — it is the query-side twin of
 * PropertyMatchingServiceTest's findBrokerSubmission_nullSourceLead_... test, and BOTH
 * are needed: the exclusion previously existed in two places (this SOQL WHERE and an
 * in-memory `continue` in the caller), so either one alone reintroduces the bug of a
 * competing broker's follow-up being re-logged as a fresh competing claim forever.
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

    // ── selectRecentByBrokerEmail (backs REPEAT detection) ───────────────────

    private static final String BROKER = 'selector.broker@example.invalid';

    /** Recency window matching the caller's own (PropertyMatchingService.LOOKBACK_DAYS). */
    private static Datetime cutoff() {
        return Datetime.now().addDays(-PropertyMatchingService.LOOKBACK_DAYS);
    }

    /**
     * A submission with full control over the four fields this query filters and orders on.
     * Built (not inserted) so a test can insert its whole fixture in ONE DML.
     */
    private static Competing_Broker_Submission__c submission(
            Id winningLeadId, Id sourceLeadId, String brokerEmail, Datetime submittedOn) {
        Competing_Broker_Submission__c sub =
            TestDataFactory.createCompetingBrokerSubmission(winningLeadId, false);
        sub.Source_Lead__c = sourceLeadId;
        sub.Is_Winning_Submission__c = (sourceLeadId != null && sourceLeadId == winningLeadId);
        sub.Broker_Email__c = brokerEmail;
        sub.Submitted_DateTime__c = submittedOn;
        return sub;
    }

    @isTest
    static void selectRecentByBrokerEmail_blankEmail_returnsEmpty() {
        Test.startTest();
        Assert.isTrue(CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(null, cutoff()).isEmpty(),
            'A null broker email should short-circuit to an empty list without querying');
        Assert.isTrue(CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail('   ', cutoff()).isEmpty(),
            'A blank broker email should short-circuit to an empty list without querying');
        Test.stopTest();
    }

    @isTest
    static void selectRecentByBrokerEmail_nullCutoff_returnsEmpty() {
        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, null);
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A null cutoff should short-circuit to an empty list without querying');
    }

    @isTest
    static void selectRecentByBrokerEmail_matchesOnBrokerEmailField() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        insert submission(winner.Id, winner.Id, BROKER, Datetime.now().addDays(-2));

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The broker\'s own recent submission should be returned');
        Assert.areEqual(BROKER, results[0].Broker_Email__c, 'Broker_Email__c is the primary match side');
    }

    @isTest
    static void selectRecentByBrokerEmail_nullSourceLeadRows_areReturned() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        // The shape branch (d) writes for a competing broker: under the winner, no source Lead.
        // The retired `Source_Lead__c != null` filter would have excluded exactly this row.
        insert submission(winner.Id, null, BROKER, Datetime.now().addDays(-2));

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'A submission with a null Source_Lead__c must be returned — it is the normal shape of a competing broker\'s claim, and excluding it would hide their follow-up emails from repeat detection');
        Assert.isNull(results[0].Source_Lead__c, 'The returned row genuinely has no source Lead');
        Assert.areEqual(winner.Id, results[0].Winning_Lead__c,
            'Winning_Lead__c must be selected so the caller can route the repeat onto the winning Lead instead');
    }

    @isTest
    static void selectRecentByBrokerEmail_nullWinnerRows_areExcluded() {
        Lead doomedWinner = TestDataFactory.createLead(true);
        insert submission(doomedWinner.Id, null, BROKER, Datetime.now().addDays(-2));

        // Both lookups are deleteConstraint=SetNull, so deleting the winner's Lead leaves a row
        // with BOTH nulled. The Winning_Lead_Required VR is ISNEW()-scoped, so it does not
        // block the delete — such rows really do exist in the org.
        delete doomedWinner;
        Assert.areEqual(1, [
            SELECT COUNT() FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = null AND Source_Lead__c = null
        ], 'Precondition: deleting the winner must leave a row with both Lead lookups null');

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.isTrue(results.isEmpty(),
            'A row with a null Winning_Lead__c must NEVER be returned. It satisfies no caller: repeat detection would file a follow-up against nothing, and the resulting insert trips the Winning_Lead_Required VR and kills the email. Excluding it is also what lets the property fall through to orphan adoption and stay claimable');
    }

    @isTest
    static void selectRecentByBrokerEmail_matchesViaSourceLeadEmail() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        Lead brokerLead = TestDataFactory.createLead(false);
        brokerLead.Email = BROKER;
        insert brokerLead;

        // Broker_Email__c is nullable and older rows left it blank; the address then survives
        // only on the Lead. The OR clause is what keeps those rows findable.
        insert submission(winner.Id, brokerLead.Id, null, Datetime.now().addDays(-2));

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'A row with a blank Broker_Email__c must still match through Source_Lead__r.Email');
        Assert.isNull(results[0].Broker_Email__c, 'The matched row really does have no Broker_Email__c of its own');
        Assert.areEqual(brokerLead.Id, results[0].Source_Lead__c, 'It matched via its source Lead\'s address');
    }

    @isTest
    static void selectRecentByBrokerEmail_beforeCutoff_isExcluded() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        insert submission(winner.Id, winner.Id, BROKER,
            Datetime.now().addDays(-(PropertyMatchingService.LOOKBACK_DAYS + 10)));

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.isTrue(results.isEmpty(),
            'A submission older than the recency window must not be returned — the window is what bounds the in-memory address scan');
    }

    @isTest
    static void selectRecentByBrokerEmail_differentBroker_isExcluded() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        insert submission(winner.Id, winner.Id, 'someone.else@example.invalid', Datetime.now().addDays(-2));

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'Another broker\'s submission must never be returned for this broker');
    }

    @isTest
    static void selectRecentByBrokerEmail_returnsOldestFirst() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        insert new List<Competing_Broker_Submission__c>{
            submission(winner.Id, null, BROKER, Datetime.now().addDays(-1)),
            submission(winner.Id, null, BROKER, Datetime.now().addDays(-30)),
            submission(winner.Id, null, BROKER, Datetime.now().addDays(-10))
        };

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'All three in-window submissions by this broker should be returned');
        Assert.isTrue(
            results[0].Submitted_DateTime__c <= results[1].Submitted_DateTime__c
                && results[1].Submitted_DateTime__c <= results[2].Submitted_DateTime__c,
            'Ordering must be Submitted_DateTime__c ASC — the caller\'s exact-match short-circuit relies on it to return the ORIGINAL submission rather than a later repeat'
        );
    }

    @isTest
    static void selectRecentByBrokerEmail_bulk251_isCappedAt200() {
        Lead winner = [SELECT Id FROM Lead LIMIT 1];
        // ONE bulk DML, matching the selectByWinningLead_bulk251 convention. The assertion
        // differs on purpose: unlike selectByWinningLead this query carries LIMIT 200, which
        // is a deliberate bound on the caller's in-memory address scan. Asserting 251 here
        // would be asserting a bug.
        List<Competing_Broker_Submission__c> many =
            TestDataFactory.createCompetingBrokerSubmissions(251, winner.Id, false);
        Datetime base = Datetime.now().addDays(-30);
        for (Integer i = 0; i < many.size(); i++) {
            many[i].Broker_Email__c = BROKER;
            many[i].Submitted_DateTime__c = base.addMinutes(i);
        }
        insert many;

        Test.startTest();
        List<Competing_Broker_Submission__c> results =
            CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(BROKER, cutoff());
        Test.stopTest();

        Assert.areEqual(200, results.size(),
            'The query is bounded at LIMIT 200 by design, so 251 in-window submissions by one broker must return exactly 200 — never an unbounded scan');
        Assert.isTrue(results[0].Submitted_DateTime__c <= results[199].Submitted_DateTime__c,
            'Even at the cap the 200 returned rows must still be the OLDEST-first slice, so the original submission is never truncated away');
    }
}
