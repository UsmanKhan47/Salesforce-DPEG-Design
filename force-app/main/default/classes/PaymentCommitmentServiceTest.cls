/**
 * Tests for `PaymentCommitmentService` - FSD 5.9.7 rows 4 and 5.
 *
 * The load-bearing negative is `shouldNotReNotify_WhenBreachAlreadyNotified`: without the one-way
 * marker a commitment that breached in March alerts every night until somebody closes the Case, which
 * is exactly how a team learns to ignore the channel.
 */
@isTest
private class PaymentCommitmentServiceTest {

    private static final String STATUS_IDENTIFIED = 'Identified';

    /**
     * @param caseStatus Status to put the parent Case in.
     * @return The parent Case.
     */
    private static Case parentCase(String caseStatus) {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        return ReceivablesTestData.delinquencyCases(summaries, caseStatus, true)[0];
    }

    @isTest
    static void shouldBreachCommitment_WhenDueDateHasPassed() {
        Case parent = parentCase(STATUS_IDENTIFIED);
        ReceivablesTestData.commitments(1, parent.Id, 'Promise to Pay', Date.today().addDays(-1), true);

        Test.startTest();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Test.stopTest();

        Assert.areEqual(1, result.breached, 'One breach must be recorded');
        Payment_Commitment__c breached = [
            SELECT Status__c, Breached_Date__c, Breach_Notified__c FROM Payment_Commitment__c LIMIT 1];
        Assert.areEqual('Breached', breached.Status__c, 'The commitment must move to Breached');
        Assert.areEqual(Date.today(), breached.Breached_Date__c, 'With the breach date stamped');
        Assert.isTrue(breached.Breach_Notified__c,
            'And the one-way marker set, because the alert actually went out');
    }

    @isTest
    static void shouldNotBreach_WhenDueDateIsStillInTheFuture() {
        Case parent = parentCase(STATUS_IDENTIFIED);
        ReceivablesTestData.commitments(1, parent.Id, 'Promise to Pay', Date.today().addDays(14), true);

        Test.startTest();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Test.stopTest();

        Assert.areEqual(0, result.breached, 'A future promise is not a breach');
        Assert.areEqual('Open', [SELECT Status__c FROM Payment_Commitment__c LIMIT 1].Status__c,
            'And must stay Open');
    }

    @isTest
    static void shouldNotReNotify_WhenBreachAlreadyNotified() {
        Case parent = parentCase(STATUS_IDENTIFIED);
        List<Payment_Commitment__c> commitments = ReceivablesTestData.commitments(
            1, parent.Id, 'Promise to Pay', Date.today().addDays(-30), false);
        commitments[0].Breach_Notified__c = true;
        insert commitments;

        Test.startTest();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Test.stopTest();

        Assert.areEqual(1, result.breached,
            'It is still swept and still moved to Breached - the marker gates the ALERT, not the state');
        Assert.isTrue([SELECT Breach_Notified__c FROM Payment_Commitment__c LIMIT 1].Breach_Notified__c,
            'And the marker stays set, so the alert is never re-fired');
    }

    @isTest
    static void shouldReopenResolvedCase_WhenInstalmentIsMissed() {
        // FSD 5.9.7 row 5. The Case was auto-closed when the tenant agreed a plan and paid down; the
        // plan then broke.
        Case parent = parentCase('Resolved');
        ReceivablesTestData.commitments(
            1, parent.Id, 'Payment Plan Instalment', Date.today().addDays(-2), true);

        Test.startTest();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Test.stopTest();

        Assert.areEqual(1, result.reopened, 'The Case must be reopened');
        Case reopened = [
            SELECT Status, IsClosed, Reopened_Count__c, Auto_Closed_By_Sync__c
            FROM Case WHERE Id = :parent.Id];
        Assert.isFalse(reopened.IsClosed, 'It must actually be open again');
        Assert.areEqual('PM Follow-Up', reopened.Status, 'At a stage that demands action');
        Assert.areEqual(1, reopened.Reopened_Count__c,
            'And the reopen must be COUNTED - a tenant who repeatedly breaks plans is the signal');
        Assert.isFalse(reopened.Auto_Closed_By_Sync__c,
            'The auto-close attribution must be cleared, or the Case reads as closed-by-sync while open');
    }

    @isTest
    static void shouldNotReopen_WhenPromiseToPayBreachesOnAnOpenCase() {
        Case parent = parentCase(STATUS_IDENTIFIED);
        ReceivablesTestData.commitments(
            1, parent.Id, 'Promise to Pay', Date.today().addDays(-2), true);

        Test.startTest();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Test.stopTest();

        Assert.areEqual(1, result.breached, 'The breach must be recorded');
        Assert.areEqual(0, result.reopened,
            'But an already-open Case cannot be reopened, and must not be counted as if it were');
    }

    @isTest
    static void shouldReopenOnce_WhenSeveralInstalmentsBreachTogether() {
        // Three instalments of one broken plan land in the same sweep. The Case must be reopened once,
        // not three times - and there must be one Case update, not three.
        Case parent = parentCase('Resolved');
        ReceivablesTestData.commitments(
            3, parent.Id, 'Payment Plan Instalment', Date.today().addDays(-5), true);

        Test.startTest();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Test.stopTest();

        Assert.areEqual(3, result.breached, 'All three instalments must be marked breached');
        Assert.areEqual(1, result.reopened, 'But the Case must reopen exactly once');
        Assert.areEqual(1, [SELECT Reopened_Count__c FROM Case WHERE Id = :parent.Id].Reopened_Count__c,
            'And the counter must increment by one, not by the number of instalments');
    }

    @isTest
    static void shouldBeNoOp_WhenGivenNoDate() {
        Test.startTest();
        PaymentCommitmentService.SweepResult result = PaymentCommitmentService.sweepBreaches(null);
        Test.stopTest();

        Assert.areEqual(0, result.breached, 'A null as-of date must short-circuit cleanly');
    }

    @isTest
    static void shouldBeNoOp_WhenNothingIsOverdue() {
        Test.startTest();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Test.stopTest();

        Assert.areEqual(0, result.breached, 'An empty sweep must not error');
        Assert.areEqual(0, result.reopened, 'And must reopen nothing');
    }

    @isTest
    static void shouldHoldDmlBudget_WhenManyCommitmentsBreachAtOnce() {
        // A backlog sweep must stay constant-cost in statements. Each bulk DML fires Case triggers in
        // 200-record batches, so a per-commitment update would multiply the cascade.
        Case parent = parentCase(STATUS_IDENTIFIED);
        ReceivablesTestData.commitments(
            60, parent.Id, 'Promise to Pay', Date.today().addDays(-3), true);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        PaymentCommitmentService.SweepResult result =
            PaymentCommitmentService.sweepBreaches(Date.today());
        Integer dmlSpent = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(60, result.breached, 'All 60 must be swept');
        Assert.isTrue(dmlSpent <= 2,
            'The whole sweep must be at most two DML statements - commitments, then Cases. Measured: '
            + dmlSpent);
    }
}
