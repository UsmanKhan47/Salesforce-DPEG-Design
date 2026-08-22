/**
 * Tests for `DelinquencyCaseService` - FSD 5.9.6 steps 3-6.
 *
 * THE THREE TESTS THAT CARRY THE FEATURE:
 *   `shouldNotDuplicate_WhenOpenCaseAlreadyExists`      - the never-duplicate guarantee.
 *   `shouldNotEscalateTwice_WhenRunTwiceInTheSameState`  - FSD 5.9.7's "send the alert once".
 *   `shouldRetainTimeline_WhenAutoClosing`               - FSD 5.9.2's history guarantee.
 *
 * GOVERNOR PINNING: `shouldHoldGovernorBudget_At251Rows` asserts on counters captured INSIDE
 * `processSummaries` (`lastRunQueryCount` / `lastRunDmlCount`), NOT on `Limits.getQueries()` after
 * `Test.stopTest()` - stopTest restores the pre-test counters and makes the obvious assertion
 * silently vacuous.
 */
@isTest
private class DelinquencyCaseServiceTest {

    private static final String STATUS_IDENTIFIED = 'Identified';

    /**
     * @param amount Dollar opening threshold.
     * @param months Months-of-rent opening threshold.
     */
    private static void configure(Decimal amount, Decimal months) {
        ReceivablesTestData.config(true, 'StubReceivablesFeedProvider', amount, months);
    }

    // ── STEP 4: open ─────────────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldOpenCase_WhenBalanceCrossesDollarThreshold() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(1, result.casesOpened, 'One Case must open');
        List<Case> opened = [
            SELECT Status, Yardi_AR_Id__c, Balance_At_Open_Amount__c, Days_Past_Due_At_Open__c,
                   Current_Balance_Amount__c, Escalation_Level__c, Receivables_Summary__c
            FROM Case];
        Assert.areEqual(1, opened.size(), 'And exist');
        Assert.areEqual(STATUS_IDENTIFIED, opened[0].Status, 'At the default lifecycle stage');
        Assert.areEqual(summaries[0].Yardi_AR_Id__c, opened[0].Yardi_AR_Id__c,
            'Carrying the denormalised guard key');
        Assert.areEqual(9000, opened[0].Balance_At_Open_Amount__c,
            'The balance at open must be STAMPED, not left to be re-derived later');
        Assert.areEqual(95, opened[0].Days_Past_Due_At_Open__c, 'And the aging at open');
        Assert.areEqual(summaries[0].Id, opened[0].Receivables_Summary__c,
            'And be linked back to the mirror row');
    }

    @isTest
    static void shouldOpenCase_WhenOnlyMonthsThresholdIsCrossed() {
        // Months_Outstanding__c is a formula over Monthly_Rent__c (5000 in the fixture), so 20000
        // outstanding is 4 months, which clears a 2-month bar while the dollar arm is unarmed.
        //
        // 🔴 THE ROW MUST BE READ BACK, NOT HANDED STRAIGHT FROM THE BUILDER. A FORMULA FIELD IS
        // COMPUTED BY THE DATABASE AND IS NEVER POPULATED ON AN IN-MEMORY sObject - inserting it does
        // not fill it in. So the builder's list carries Months_Outstanding__c = null, the months arm
        // reads null as "no denominator" (its documented and correct behaviour, OQ-3), and the test
        // measured a fixture artefact instead of the rule. Reading through the selector is also what
        // production does - ReceivablesSyncBatch's scope comes from
        // ReceivablesSummarySelector.queryLifecycleLocator, which selects the formula - so this now
        // exercises the DEPLOYED formula end to end rather than an Apex re-derivation of it.
        // Same pattern as shouldClearHasOpenCaseFlag_WhenCaseAutoCloses below.
        configure(null, 2);
        List<Receivables_Summary__c> built =
            ReceivablesTestData.summaries(1, null, null, 20000, 120, null, true);
        List<Receivables_Summary__c> summaries =
            ReceivablesSummarySelector.selectByIds(new Set<Id>{ built[0].Id });
        // intValue() because Assert.areEqual boxes both sides: Integer 4 against Decimal 4.0 fails.
        Assert.areEqual(4, summaries[0].Months_Outstanding__c.intValue(),
            'PREMISE: the deployed formula must actually read 4 months of rent, or the arm below is '
            + 'being proved against a number this test invented');

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(1, result.casesOpened,
            'The months-of-rent arm must open a Case on its own - FSD 5.9.1 says the team reasons in '
            + 'months, and those tenants are the ones a dollar bar misses');
    }

    @isTest
    static void shouldNotOpenCase_WhenBelowEveryThreshold() {
        configure(5000, 2);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 400, 12, null, true);

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(0, result.casesOpened, 'A small, recent balance must not open a Case');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'And none must exist');
    }

    @isTest
    static void shouldSetHasOpenCaseFlag_WhenCaseIsOpened() {
        // The stored projection the section 6.1 "Delinquent Tenants" tile counts, because a report
        // cannot read a custom setting and therefore cannot apply the threshold itself.
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);

        Test.startTest();
        DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.isTrue([SELECT Has_Open_Delinquency_Case__c FROM Receivables_Summary__c][0]
            .Has_Open_Delinquency_Case__c,
            'The mirror flag must be written by the sync - it cannot be a formula (design GATE-3)');
    }

    @isTest
    static void shouldSetReasonAndPathTogether_WhenReasonIsSupplied() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        Map<String, String> reasons = new Map<String, String>{
            summaries[0].Yardi_AR_Id__c => 'Billing dispute' };

        Test.startTest();
        DelinquencyCaseService.processSummaries(summaries, reasons);
        Test.stopTest();

        Case opened = [SELECT Reason, Resolution_Path__c FROM Case LIMIT 1];
        Assert.areEqual('Billing dispute', opened.Reason, 'The reason must carry through');
        Assert.areEqual('Correct', opened.Resolution_Path__c,
            'And route to Correct - a billing dispute on the Collect track means chasing a tenant for '
            + 'money DPEG should never have billed');
    }

    @isTest
    static void shouldLeaveReasonBlank_WhenReasonIsUnrecognised() {
        // Guards the restricted-picklist DML failure: an unmapped value would fail the insert for the
        // whole chunk, not just this row.
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        Map<String, String> reasons = new Map<String, String>{
            summaries[0].Yardi_AR_Id__c => 'Equipment Complexity' };

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries, reasons);
        Test.stopTest();

        Assert.areEqual(1, result.casesOpened, 'The Case must still open');
        Case opened = [SELECT Reason, Resolution_Path__c FROM Case LIMIT 1];
        Assert.isNull(opened.Reason, 'But the stray reason must be discarded, not written');
        Assert.isNull(opened.Resolution_Path__c, 'And the path with it - they move together');
    }

    // ── STEP 3: never duplicate ──────────────────────────────────────────────────────────────────

    @isTest
    static void shouldNotDuplicate_WhenOpenCaseAlreadyExists() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(0, result.casesOpened, 'No second Case may be opened');
        Assert.areEqual(1, [SELECT COUNT() FROM Case],
            'THE NEVER-DUPLICATE GUARANTEE. Exactly one open Case per delinquent tenant.');
    }

    @isTest
    static void shouldRefreshBalance_WhenCaseAlreadyExists() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> existing = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        update new Receivables_Summary__c(Id = summaries[0].Id,
            Total_Outstanding_Amount__c = 14000, Days_Past_Due__c = 130);
        List<Receivables_Summary__c> refreshed = ReceivablesSummarySelector.selectByIds(
            new Set<Id>{ summaries[0].Id });

        Test.startTest();
        DelinquencyCaseService.processSummaries(refreshed);
        Test.stopTest();

        Case updated = [
            SELECT Current_Balance_Amount__c, Current_Days_Past_Due__c, Balance_At_Open_Amount__c
            FROM Case WHERE Id = :existing[0].Id];
        Assert.areEqual(14000, updated.Current_Balance_Amount__c, 'The current balance must refresh');
        Assert.areEqual(130, updated.Current_Days_Past_Due__c, 'And the current aging');
        Assert.areEqual(9000, updated.Balance_At_Open_Amount__c,
            'While the AT-OPEN stamp must be immutable - it is the record of what triggered the Case');
    }

    // ── STEP 5: escalate, one-way ────────────────────────────────────────────────────────────────

    @isTest
    static void shouldEscalate_WhenAgingCrossesSixtyDays() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 65, null, true);
        List<Case> existing = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(1, result.casesEscalated, 'One escalation must be counted');
        Case escalated = [
            SELECT Escalation_Level__c, Escalation_Basis_Days__c, Escalated_DateTime__c
            FROM Case WHERE Id = :existing[0].Id];
        Assert.areEqual(1, escalated.Escalation_Level__c, 'The 60-day rung must be stamped');
        Assert.areEqual(65, escalated.Escalation_Basis_Days__c,
            'With the basis snapshot, without which a later downward correction silences the Case '
            + 'forever');
        Assert.isNotNull(escalated.Escalated_DateTime__c, 'And the escalation timestamp');
    }

    @isTest
    static void shouldNotEscalateTwice_WhenRunTwiceInTheSameState() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 65, null, true);
        ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        Test.startTest();
        DelinquencyCaseService.processSummaries(summaries);
        List<Receivables_Summary__c> secondPass =
            ReceivablesSummarySelector.selectByIds(new Set<Id>{ summaries[0].Id });
        DelinquencyCaseService.LifecycleResult second =
            DelinquencyCaseService.processSummaries(secondPass);
        Test.stopTest();

        Assert.areEqual(0, second.casesEscalated,
            'A second run in the same state must NOT re-fire the alert - that is how a team learns to '
            + 'ignore the channel, the failure FSD 5.9.7 is written to prevent');
    }

    @isTest
    static void shouldEscalateToNinety_WhenAgingCrossesNinetyDays() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 20000, 95, null, true);
        List<Case> existing = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        Test.startTest();
        DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(2, [SELECT Escalation_Level__c FROM Case WHERE Id = :existing[0].Id]
            .Escalation_Level__c, 'The 90-day rung notifies the principals as well as the PM team');
    }

    @isTest
    static void shouldRearm_WhenYardiCorrectsAgingDownward() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 20000, 95, null, true);
        List<Case> existing = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        Test.startTest();
        DelinquencyCaseService.processSummaries(summaries);
        // The billing correction: Yardi moves the aging down.
        update new Receivables_Summary__c(Id = summaries[0].Id, Days_Past_Due__c = 20);
        DelinquencyCaseService.processSummaries(
            ReceivablesSummarySelector.selectByIds(new Set<Id>{ summaries[0].Id }));
        Test.stopTest();

        Case corrected = [
            SELECT Escalation_Level__c, Escalation_Basis_Days__c FROM Case WHERE Id = :existing[0].Id];
        Assert.areEqual(0, corrected.Escalation_Level__c,
            'A downward correction must re-arm the ladder so a genuine future slide alerts again');
        Assert.areEqual(20, corrected.Escalation_Basis_Days__c,
            'And the basis must follow the corrected number');
    }

    // ── STEP 6: auto-close ───────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldAutoClose_WhenBalanceClears() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 0, 0, null, true);
        List<Case> existing = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(1, result.casesClosed, 'One close must be counted');
        Case closed = [
            SELECT Status, IsClosed, Auto_Closed_By_Sync__c, Escalation_Level__c
            FROM Case WHERE Id = :existing[0].Id];
        Assert.areEqual('Resolved', closed.Status, 'The Case must reach the terminal stage');
        Assert.isTrue(closed.IsClosed, 'Which must actually close it');
        Assert.isTrue(closed.Auto_Closed_By_Sync__c,
            'And be attributable to the sync rather than to a human');
        Assert.areEqual(0, closed.Escalation_Level__c,
            'A close is the payment the one-way rule contemplates, so the ladder resets for a '
            + 're-delinquenting tenant');
    }

    @isTest
    static void shouldRetainTimeline_WhenAutoClosing() {
        // FSD 5.9.2: a failed or partial sync can never destroy follow-up history.
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 0, 0, null, true);
        List<Case> existing = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        ReceivablesTestData.commitments(2, existing[0].Id, 'Promise to Pay', Date.today(), true);
        insert new CaseComment(ParentId = existing[0].Id, CommentBody = 'Spoke to tenant 3 Aug');

        Test.startTest();
        DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Payment_Commitment__c WHERE Case__c = :existing[0].Id],
            'Auto-closing must not destroy the payment commitments');
        Assert.areEqual(1, [SELECT COUNT() FROM CaseComment WHERE ParentId = :existing[0].Id],
            'Nor the follow-up comments - the timeline is the most useful thing on the record');
    }

    @isTest
    static void shouldNotAutoClose_WhenBalanceIsUnknown() {
        // Null is not zero. "The feed said nothing" must never be read as "the tenant paid".
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, null, null, null, true);
        List<Case> existing = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(0, result.casesClosed, 'An unknown balance must never auto-close');
        Assert.isFalse([SELECT IsClosed FROM Case WHERE Id = :existing[0].Id].IsClosed,
            'The Case must stay open');
    }

    @isTest
    static void shouldClearHasOpenCaseFlag_WhenCaseAutoCloses() {
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 0, 0, null, true);
        ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        update new Receivables_Summary__c(Id = summaries[0].Id, Has_Open_Delinquency_Case__c = true);

        Test.startTest();
        DelinquencyCaseService.processSummaries(
            ReceivablesSummarySelector.selectByIds(new Set<Id>{ summaries[0].Id }));
        Test.stopTest();

        Assert.isFalse([SELECT Has_Open_Delinquency_Case__c FROM Receivables_Summary__c][0]
            .Has_Open_Delinquency_Case__c,
            'A closed Case must clear the flag, or the section 6.1 tile over-counts forever');
    }

    // ── Edges and budget ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldReturnEmpty_WhenGivenNoSummaries() {
        Test.startTest();
        DelinquencyCaseService.LifecycleResult result = DelinquencyCaseService.processSummaries(null);
        Test.stopTest();

        Assert.areEqual(0, result.casesOpened, 'Null input must be a clean no-op');
        Assert.areEqual(0, DelinquencyCaseService.lastRunQueryCount,
            'And must not even reach the guard query');
    }

    @isTest
    static void shouldHoldGovernorBudget_At251Rows() {
        // THE HIGHEST-VALUE TEST IN THIS CLASS. It makes a future change that adds one query per row
        // fail HERE rather than in production.
        //
        // Counters are read from statics captured INSIDE processSummaries. Asserting
        // Limits.getQueries() after Test.stopTest() would be silently vacuous - stopTest restores the
        // pre-test counters.
        configure(5000, null);
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(251, null, null, 9000, 95, null, true);

        Test.startTest();
        DelinquencyCaseService.LifecycleResult result =
            DelinquencyCaseService.processSummaries(summaries);
        Test.stopTest();

        Assert.areEqual(251, result.casesOpened, 'All 251 tenants must get a Case');
        Assert.areEqual(251, [SELECT COUNT() FROM Case], 'And all 251 must exist');
        Assert.isTrue(DelinquencyCaseService.lastRunQueryCount <= 6,
            'The lifecycle must cost a CONSTANT handful of queries per chunk regardless of row count. '
            + 'Budget 6; measured ' + DelinquencyCaseService.lastRunQueryCount);
        Assert.isTrue(DelinquencyCaseService.lastRunDmlCount <= 3,
            'And at most three DML statements - insert Cases, update Cases, update mirror. Each bulk '
            + 'DML fires triggers in 200-record batches, so extra statements multiply. Budget 3; '
            + 'measured ' + DelinquencyCaseService.lastRunDmlCount);
    }
}
