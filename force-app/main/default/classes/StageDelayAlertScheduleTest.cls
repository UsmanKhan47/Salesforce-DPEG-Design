/**
 * Tests for `StageDelayAlertSchedule`.
 *
 * ⚠ WHAT THIS CLASS CAN PROVE IS SMALL, AND SAYING SO IS THE POINT. A `Schedulable` with no logic
 * has exactly one behaviour worth pinning — that it starts the right batch at the right scope — and
 * the thing that actually matters about it (that somebody REMEMBERS TO SCHEDULE IT in the target
 * org) is not deployable metadata and cannot be tested by any means. That is post-deploy step P2,
 * and its absence is invisible: no error, no failed `AsyncApexJob`, no queue of stranded rows, just
 * a feature that never fires — and for an ALERT job "no reminder arrived" is indistinguishable from
 * "no deal was stalled". See the class header.
 */
@isTest
private class StageDelayAlertScheduleTest {

    @isTest
    static void executingItRunsTheReminderBatchOverTheLivePopulation() {
        // ⚠ NO Stage_Threshold_Def__mdt OVERRIDE: static state is not carried into an
        // asynchronously-executed job, so this fixture is aged FOUR HUNDRED DAYS to be delayed
        // under any sane configuration the org may hold — none (the shipped 14-day fallback), the
        // eight loaded rows, or eight retuned ones.
        //
        // ⚠ Stage_Entry_Date__c cannot be seeded on insert: OpportunityStageEntryService overwrites
        // it on every stage entry, and an insert is an entry. A second save that leaves StageName
        // alone is not a transition, so the aged value written there survives. Same device as
        // StageDelayAlertBatchTest's fixture helper, and SYSTEM_MODE for the same reason (the field
        // is a Metadata-API-deployed custom with no FLS for any profile).
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        Database.update(
            new Opportunity(Id = deal.Id, Stage_Entry_Date__c = Date.today().addDays(-400)),
            true, AccessLevel.SYSTEM_MODE
        );

        // ⚠ `execute(null)` DIRECTLY, not `System.schedule` — the measured
        // `CallForOffersAlertScheduleTest` / `NdaExpiryAlertScheduleTest` precedent: a batch
        // submitted by a scheduled job that the framework itself runs at `Test.stopTest()` does not
        // then get drained by that same `stopTest`, so the schedule-then-assert version comes back
        // with a null marker and proves nothing. Calling `execute` INSIDE the start/stop block
        // submits the batch before `stopTest`, which then runs it. The next test covers the
        // scheduling half.
        Test.startTest();
        new StageDelayAlertSchedule().execute(null);
        Test.stopTest();

        // A schedulable that compiled but started nothing would leave these markers null.
        Opportunity after = [
            SELECT Id, Stage_Alert_Stage__c, Stage_Alert_Last_Sent_Date__c
            FROM Opportunity WHERE Id = :deal.Id
            WITH SYSTEM_MODE
        ];
        Assert.areEqual('New', after.Stage_Alert_Stage__c,
            'The schedulable must actually run StageDelayAlertBatch over the live population');
        Assert.areEqual(Date.today(), after.Stage_Alert_Last_Sent_Date__c,
            'including the date half of the marker');
    }

    @isTest
    static void itIsSchedulableWithACronExpression() {
        Test.startTest();
        // February 17th 2030 — far enough out that the job never fires on a real clock.
        String jobId = System.schedule(
            'StageDelayAlertScheduleTest ' + Math.abs(Crypto.getRandomInteger()),
            '0 30 7 17 2 ? 2030',
            new StageDelayAlertSchedule()
        );
        Test.stopTest();

        Assert.isNotNull(jobId, 'The class is schedulable');
        CronTrigger ct = [SELECT Id, CronExpression, State FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 30 7 17 2 ? 2030', ct.CronExpression,
            'with the expression it was given');

        // ⚠ WHAT THIS DOES NOT PROVE, AND IT IS THE WHOLE RISK: that anyone ACTUALLY SCHEDULES IT in
        // the target org (post-deploy step P2), or that the `Acquisition` queue has any members
        // (step P1), or that `scripts/load-stage-threshold-defs.apex` was ever run (step P3). A
        // scheduled-job instance, queue membership and Custom Metadata RECORDS are all
        // non-deployable and all invisible to every test in this repo.
    }

    @isTest
    static void itDoesNotOverrideTheBatchesOwnScope() {
        // The budget lives in exactly one place. Hardcoding a number here would put it in two, and
        // the arithmetic that justifies it (StageDelayAlertBatch header §1) would then be
        // describing a value this class does not use.
        Assert.areEqual(200, StageDelayAlertBatch.SCOPE,
            'SCOPE is inherited from CallForOffersAlertBatch\'s five measured probes and is read '
            + 'from the batch, never restated by the scheduler');
    }
}
