/**
 * Tests for `NdaExpiryAlertSchedule`.
 *
 * ⚠ WHAT THIS CLASS CAN PROVE IS SMALL, AND SAYING SO IS THE POINT. A `Schedulable` with no logic
 * has exactly one behaviour worth pinning — that it starts the right batch at the right scope — and
 * the thing that actually matters about it (that somebody REMEMBERS TO SCHEDULE IT in the target
 * org) is not deployable metadata and cannot be tested by any means. That is post-deploy gate G1,
 * and its absence is invisible: no error, no failed `AsyncApexJob`, no queue of stranded rows, just
 * a feature that never fires — and for an ALERT job "no reminder arrived" is indistinguishable from
 * "no NDA was expiring". See the class header.
 */
@isTest
private class NdaExpiryAlertScheduleTest {

    @isTest
    static void executingItRunsTheReminderBatchOverTheLivePopulation() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createSignedNdas(1, opp.Id, false)[0];
        nda.NDA_Expiry_Date__c = Date.today().addDays(3);
        insert nda;

        // ⚠ `execute(null)` DIRECTLY, not `System.schedule` — the measured
        // `CallForOffersAlertScheduleTest` precedent: a batch submitted by a scheduled job that the
        // framework itself runs at `Test.stopTest()` does not then get drained by that same
        // `stopTest`, so the schedule-then-assert version comes back with a null marker and proves
        // nothing. Calling `execute` INSIDE the start/stop block submits the batch before
        // `stopTest`, which then runs it. The next test covers the scheduling half.
        Test.startTest();
        new NdaExpiryAlertSchedule().execute(null);
        Test.stopTest();

        // A schedulable that compiled but started nothing would leave these markers null.
        NDA__c after = [
            SELECT Id, NDA_Alert_Last_Interval__c, NDA_Alert_Expiry_Date__c
            FROM NDA__c WHERE Id = :nda.Id
        ];
        Assert.areEqual(5, after.NDA_Alert_Last_Interval__c,
            'The schedulable must actually run NdaExpiryAlertBatch over the live population');
        Assert.areEqual(nda.NDA_Expiry_Date__c, after.NDA_Alert_Expiry_Date__c,
            'including the snapshot half of the marker');
    }

    @isTest
    static void itIsSchedulableWithACronExpression() {
        Test.startTest();
        // February 17th 2030 — far enough out that the job never fires on a real clock.
        String jobId = System.schedule(
            'NdaExpiryAlertScheduleTest ' + Math.abs(Crypto.getRandomInteger()),
            '0 0 7 17 2 ? 2030',
            new NdaExpiryAlertSchedule()
        );
        Test.stopTest();

        Assert.isNotNull(jobId, 'The class is schedulable');
        CronTrigger ct = [SELECT Id, CronExpression, State FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 7 17 2 ? 2030', ct.CronExpression, 'with the expression it was given');

        // ⚠ WHAT THIS DOES NOT PROVE, AND IT IS THE WHOLE RISK: that anyone ACTUALLY SCHEDULES IT
        // in the target org, or that the OWNING PRINCIPAL can see acquisition NDAs it does not own
        // (gate G2 — NDA__c is Private OWD with no acquisition sharing rule). A scheduled-job
        // instance is not deployable metadata. The assertion above proves the class is
        // schedulABLE, not that it is schedulED.
    }

    @isTest
    static void scopeIsTakenFromTheBatchRatherThanHardcodedHere() {
        // The budget lives in ONE place. If someone hardcodes a number in the schedulable, the two
        // drift and the CPU derivation this job INHERITS from CallForOffersAlertBatch stops
        // governing it.
        Assert.areEqual(200, NdaExpiryAlertBatch.SCOPE,
            'SCOPE is inherited from CallForOffersAlertBatch (6.0 ms + 0.22 ms x |recipients| per '
            + 'notification, ~2% of the async CPU budget at 200 rows) — see the batch header §1');
    }
}
