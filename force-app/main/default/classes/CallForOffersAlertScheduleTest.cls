/**
 * Tests for `CallForOffersAlertSchedule`.
 *
 * ⚠ WHAT THIS CLASS CAN PROVE IS SMALL, AND SAYING SO IS THE POINT. A `Schedulable` with no logic
 * has exactly one behaviour worth pinning — that it starts the right batch at the right scope — and
 * the thing that actually matters about it (that somebody REMEMBERS TO SCHEDULE IT in the target
 * org) is not deployable metadata and cannot be tested by any means. That is requirements gate G1,
 * and its absence is invisible: no error, no failed `AsyncApexJob`, no queue of stranded rows, just
 * a feature that never fires. See the class header.
 */
@isTest
private class CallForOffersAlertScheduleTest {

    @isTest
    static void executingItRunsTheAlertBatchOverTheLivePopulation() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        update deal;

        // ⚠ `execute(null)` DIRECTLY, not `System.schedule` — MEASURED, not preferred. A batch
        // submitted by a scheduled job that the framework itself runs at `Test.stopTest()` does not
        // then get drained by that same `stopTest`, so the schedule-then-assert version came back
        // with a null marker and proved nothing. Calling `execute` INSIDE the start/stop block
        // submits the batch before `stopTest`, which then runs it. The other test below covers the
        // scheduling half.
        Test.startTest();
        new CallForOffersAlertSchedule().execute(null);
        Test.stopTest();

        // A schedulable that compiled but started nothing would leave this marker null.
        Opportunity after = [
            SELECT Id, Offer_Alert_Last_Interval__c, Offer_Alert_Due_Date__c
            FROM Opportunity WHERE Id = :deal.Id
        ];
        Assert.areEqual(3, after.Offer_Alert_Last_Interval__c,
            'The schedulable must actually run CallForOffersAlertBatch over the live population');
        Assert.areEqual(deal.Offer_Due_Date__c, after.Offer_Alert_Due_Date__c,
            'including the snapshot half of the marker');
    }

    @isTest
    static void itIsSchedulableWithACronExpression() {
        Test.startTest();
        // February 17th 2030 — far enough out that the job never fires on a real clock.
        String jobId = System.schedule(
            'CallForOffersAlertScheduleTest ' + Math.abs(Crypto.getRandomInteger()),
            '0 0 7 17 2 ? 2030',
            new CallForOffersAlertSchedule()
        );
        Test.stopTest();

        Assert.isNotNull(jobId, 'The class is schedulable');
        CronTrigger ct = [SELECT Id, CronExpression, State FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 7 17 2 ? 2030', ct.CronExpression, 'with the expression it was given');

        // ⚠ WHAT THIS DOES NOT PROVE, AND IT IS THE WHOLE RISK: that anyone ACTUALLY SCHEDULES IT in
        // the target org. A scheduled-job instance is not deployable metadata, so post-deploy gate
        // G1 is the only thing standing between this class and a feature that never fires. No test
        // can cover it — the assertion above proves the class is schedulABLE, not that it is
        // schedulED.
    }

    @isTest
    static void scopeIsTakenFromTheBatchRatherThanHardcodedHere() {
        // The budget lives in ONE place. If someone hardcodes a number in the schedulable, the two
        // drift and the measured CPU derivation in CallForOffersAlertBatch's header stops governing.
        Assert.areEqual(200, CallForOffersAlertBatch.SCOPE,
            'SCOPE is a measured blast-radius choice (6.20 ms per notification, ~2% of the async '
            + 'CPU budget at 200 deals) — see the batch class header §1 before changing it');
    }
}
