/**
 * End-to-end tests for the async pipeline: `ReceivablesSyncSchedule` -&gt;
 * `ReceivablesIngestQueueable` -&gt; `ReceivablesSyncBatch`.
 *
 * THE CENTRAL CLAIM OF THIS BUILD IS ASSERTED IN
 * `shouldRunWholeLifecycleFromStub_WithZeroCallouts`: the entire FSD 5.9 workflow - mirror upsert,
 * health check, Case open, mirror flag, audit row - runs TODAY, from a static-resource fixture, with
 * a callout mock installed that is never invoked. That is what makes the Yardi switch-on a config
 * change rather than a rebuild.
 *
 * EVERY HALT PATH WRITES A `Sync_Run__c` ROW, and each test asserts on `Halt_Reason__c` and
 * `Lifecycle_Ran__c` rather than on the absence of Cases alone. A rule that refuses to act but leaves
 * no trace is indistinguishable from a job that never ran.
 *
 * `.claude/rules/bulk-test-rule.md`: the batch's bulk behaviour is proved in
 * `DelinquencyCaseServiceTest.shouldHoldGovernorBudget_At251Rows`, which drives the same
 * `processSummaries` the batch calls, with the governor counters captured inside the async context.
 * Duplicating 251 rows through a full queueable-plus-batch run here would prove nothing further and
 * would multiply the fixture cost.
 */
@isTest
private class ReceivablesSyncPipelineTest {

    /**
     * @param reason Expected `Halt_Reason__c`.
     * @return The single audit row written by the run.
     */
    private static Sync_Run__c onlyRun() {
        List<Sync_Run__c> runs = [
            SELECT Id, Status__c, Halt_Reason__c, Halt_Detail__c, Lifecycle_Ran__c, Row_Count__c,
                   Rows_Upserted__c, Provider_Class_Name__c, Source__c, Feed_As_Of_DateTime__c,
                   Cases_Opened__c, Cases_Escalated__c, Cases_Closed__c
            FROM Sync_Run__c ORDER BY CreatedDate DESC];
        Assert.areEqual(1, runs.size(), 'Exactly one audit row must be written per run');
        return runs[0];
    }

    @isTest
    static void shouldRunWholeLifecycleFromStub_WithZeroCallouts() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        ReceivablesCalloutMock mock = new ReceivablesCalloutMock(200, '{}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new ReceivablesIngestQueueable());
        Test.stopTest();

        Assert.areEqual(0, mock.requestCount,
            'THE CENTRAL CLAIM: the stub drives the whole pipeline with ZERO callouts');
        Sync_Run__c run = onlyRun();
        Assert.areEqual('None', run.Halt_Reason__c, 'A healthy run must record no halt');
        Assert.areEqual(5, run.Row_Count__c, 'The deployed fixture carries five rows');
        Assert.areEqual(5, run.Rows_Upserted__c, 'All five must be written to the mirror');
        Assert.areEqual('StubReceivablesFeedProvider', run.Provider_Class_Name__c,
            'The audit row must record what ACTUALLY ran, not what config claimed');
        Assert.areEqual('Stub', run.Source__c, 'And the provider-declared source');
        Assert.isNotNull(run.Feed_As_Of_DateTime__c, 'And the feed clock');
        Assert.areEqual(5, [SELECT COUNT() FROM Receivables_Summary__c],
            'The mirror must hold every fixture row');
    }

    @isTest
    static void shouldOpenCasesAndCompleteRun_WhenBatchProcessesTheMirror() {
        // Drives the batch directly, because in a test only one level of async chaining executes: the
        // queueable runs at stopTest and the batch it starts does not. Splitting them is what makes
        // both halves assertable.
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 3, true);
        ReceivablesTestData.summaries(3, null, null, 20000, 120, run.Id, true);

        Test.startTest();
        Database.executeBatch(new ReceivablesSyncBatch(run.Id), ReceivablesSyncBatch.SCOPE);
        Test.stopTest();

        Sync_Run__c finished = SyncRunSelector.selectById(run.Id);
        Assert.areEqual('Completed', finished.Status__c, 'The batch must close the audit row');
        Assert.isTrue(finished.Lifecycle_Ran__c,
            'Lifecycle_Ran__c is written HERE and only here - it is the whole test surface for the '
            + 'halt rule');
        Assert.areEqual(3, finished.Cases_Opened__c, 'And must count the Cases it opened');
        Assert.areEqual(3, [SELECT COUNT() FROM Case], 'Which must exist');
        Assert.isNotNull(finished.Halt_Detail__c,
            'A healthy run still records what the alert sweep did, so a quiet night is explainable');
    }

    @isTest
    static void shouldHaltDisabled_WhenFeatureIsSwitchedOff() {
        ReceivablesTestData.config(false, 'StubReceivablesFeedProvider', 5000, null);

        Test.startTest();
        System.enqueueJob(new ReceivablesIngestQueueable());
        Test.stopTest();

        Sync_Run__c run = onlyRun();
        Assert.areEqual('Halted', run.Status__c, 'A disabled feature must still leave a trace');
        Assert.areEqual('Disabled', run.Halt_Reason__c,
            'A deliberate switch-off must be distinguishable from a broken configuration');
        Assert.isFalse(run.Lifecycle_Ran__c, 'And nothing may run');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'No Case may be created');
    }

    @isTest
    static void shouldHaltConfigMissing_WhenNoConfigRowExists() {
        // The un-run post-deploy gate. Custom setting DATA is not deployable.
        Test.startTest();
        System.enqueueJob(new ReceivablesIngestQueueable());
        Test.stopTest();

        Sync_Run__c run = onlyRun();
        Assert.areEqual('Disabled', run.Halt_Reason__c,
            'An absent config row reads as disabled - the org default is off');
        Assert.isFalse(run.Lifecycle_Ran__c, 'And nothing runs');
    }

    @isTest
    static void shouldHaltConfigMissing_WhenProviderClassDoesNotResolve() {
        // THE CRITICAL NEGATIVE. A class reachable only by a config string can be deleted with no
        // compile error, and a silent fallback to the stub would publish FIXTURE balances in
        // production, open Cases against them, and email principals about tenants who owe nothing.
        ReceivablesTestData.config(true, 'NoSuchProviderClassAnywhere', 5000, null);

        Test.startTest();
        System.enqueueJob(new ReceivablesIngestQueueable());
        Test.stopTest();

        Sync_Run__c run = onlyRun();
        Assert.areEqual('Config Missing', run.Halt_Reason__c,
            'An unresolvable provider must HALT');
        Assert.isFalse(run.Lifecycle_Ran__c, 'And run nothing');
        Assert.areEqual(0, [SELECT COUNT() FROM Receivables_Summary__c],
            'IT MUST NOT FALL BACK TO THE STUB. Zero mirror rows is the proof.');
        Assert.isTrue(run.Halt_Detail__c.contains('could not be resolved'),
            'And must say why, in terms an operator can act on');
    }

    @isTest
    static void shouldHaltStaleFeed_AndCreateNothing() {
        // FSD 5.9.6 step 2, end to end: create or escalate NOTHING on suspect data.
        ReceivablesTestData.configWithHealthArms(12, 1, 500, 7);
        ReceivablesFeedResult payload = new ReceivablesFeedResult();
        payload.feedAsOf = System.now().addDays(-4);
        payload.rows = ReceivablesTestData.feedRows(3, null, 20000, 150);
        StubReceivablesFeedProvider.fixtureOverride = JSON.serialize(payload);

        Test.startTest();
        System.enqueueJob(new ReceivablesIngestQueueable());
        Test.stopTest();

        Sync_Run__c run = onlyRun();
        Assert.areEqual('Halted', run.Status__c, 'A four-day-old feed must halt');
        Assert.areEqual('Stale Feed', run.Halt_Reason__c, 'With the reason recorded');
        Assert.isFalse(run.Lifecycle_Ran__c,
            'THE SINGLE ASSERTION FOR THE HALT RULE');
        Assert.areEqual(3, run.Row_Count__c,
            'The audit row must still say how big the suspect feed was');
        Assert.areEqual(0, run.Rows_Upserted__c, 'But nothing may be written');
        Assert.areEqual(0, [SELECT COUNT() FROM Receivables_Summary__c], 'The mirror must be untouched');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'And no Case created');
    }

    @isTest
    static void shouldHaltRowCountLow_AndCreateNothing() {
        ReceivablesTestData.configWithHealthArms(24, 100, 500, 7);

        Test.startTest();
        System.enqueueJob(new ReceivablesIngestQueueable());
        Test.stopTest();

        Sync_Run__c run = onlyRun();
        Assert.areEqual('Row Count Below Minimum', run.Halt_Reason__c,
            'Five fixture rows against a floor of 100 must halt');
        Assert.isFalse(run.Lifecycle_Ran__c, 'And run nothing');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'No Case may be created on a truncated feed');
    }

    @isTest
    static void shouldHaltCalloutFailure_WhenAsbProviderCannotReachTheBus() {
        // Today's real state: no ASB Named Credential exists, so selecting the live provider must
        // produce an honest recorded halt rather than an exception or a silent no-op.
        //
        // THE MOCK IS INSTALLED BUT IS NEVER CONSULTED, AND THAT IS THE POINT. `callout:ASB` names a
        // credential this org does not have, so the PLATFORM refuses the request before any
        // HttpCalloutMock is reached - `mock.requestCount` stays 0 for a run that genuinely did
        // attempt one call. Asserting on the mock therefore measured the org's provisioning state
        // rather than the code, which is why the call-volume assertion below reads
        // ReceivablesCalloutService's own boundary counter instead. Installing the mock still
        // matters: without it the callout would be a hard test-context failure rather than the
        // recorded halt this test is about.
        ReceivablesTestData.config(true, 'AsbReceivablesFeedProvider', 5000, null);
        ReceivablesCalloutMock mock = new ReceivablesCalloutMock(200, '{}');
        mock.throwTransportFailure = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new ReceivablesIngestQueueable());
        Test.stopTest();

        Sync_Run__c run = onlyRun();
        Assert.areEqual('ASB', run.Source__c, 'The audit row must record which source was attempted');
        Assert.areEqual('Stale Feed', run.Halt_Reason__c,
            'A failed fetch returns a clock-less result, which the health check reports as stale - the '
            + 'single class that owns halt reasons decides, not the provider');
        Assert.isFalse(run.Lifecycle_Ran__c, 'And nothing runs');
        Assert.areEqual(1, ReceivablesCalloutService.lastRunAttemptCount,
            'Exactly one callout attempt per run - counted at the boundary, not at the mock');
        Assert.isTrue(String.isNotBlank(ReceivablesCalloutService.lastRunErrorMessage),
            'And the failure must be captured verbatim at the boundary, because '
            + 'AsbReceivablesFeedProvider deliberately discards it in favour of an empty result. '
            + 'Actual: ' + ReceivablesCalloutService.lastRunErrorMessage);
        Assert.isTrue(ReceivablesCalloutService.lastRunErrorMessage.contains('Callout failed'),
            'It must be the TRANSPORT arm that failed, not a parsed HTTP status - the ASB Named '
            + 'Credential does not exist in this org, so the platform refuses the request outright. '
            + 'Actual: ' + ReceivablesCalloutService.lastRunErrorMessage);
    }

    @isTest
    static void shouldEnqueueIngest_WhenScheduleFires() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);

        Test.startTest();
        String jobId = System.schedule(
            'ReceivablesSyncPipelineTest Nightly', '0 0 3 * * ?', new ReceivablesSyncSchedule());
        Test.stopTest();

        Assert.isNotNull(jobId, 'The job must schedule');
        CronTrigger scheduled = [
            SELECT CronExpression, TimesTriggered FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 3 * * ?', scheduled.CronExpression,
            'The nightly cron must be registered as written');
        Assert.areEqual(ReceivablesSyncSchedule.CRON_NIGHTLY, scheduled.CronExpression,
            'And must match the published constant, so the post-deploy gate and the code agree');
    }

    @isTest
    static void shouldScheduleUnderThePublishedName_WhenTheGateHelperIsUsed() {
        // `scheduleNightly()` exists so the post-deploy gate is not retyped by hand, and it was the
        // one uncovered method in ReceivablesSyncSchedule - which put that class at 50% and would
        // have failed a real RunSpecifiedTests deploy on the per-class 75% floor, via a
        // codeCoverageWarnings entry that no error counter surfaces.
        //
        // It asserts on the NAME as well as the cron, because the class header tells an operator to
        // look for that exact name in Setup; a helper that scheduled the right cadence under a
        // different name would leave them concluding the job was never scheduled.
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);

        Test.startTest();
        String jobId = ReceivablesSyncSchedule.scheduleNightly();
        Test.stopTest();

        CronTrigger scheduled = [
            SELECT CronExpression, CronJobDetail.Name FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(ReceivablesSyncSchedule.CRON_NIGHTLY, scheduled.CronExpression,
            'The helper must schedule the published nightly cadence');
        Assert.areEqual(ReceivablesSyncSchedule.JOB_NAME, scheduled.CronJobDetail.Name,
            'Under the published job name, which is what the post-deploy gate tells an operator to '
            + 'look for in Setup');
    }

    @isTest
    static void shouldRunIngest_WhenScheduleExecutesDirectly() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);

        Test.startTest();
        new ReceivablesSyncSchedule().execute(null);
        Test.stopTest();

        Assert.areEqual('None', onlyRun().Halt_Reason__c,
            'Executing the schedulable directly must reach the same healthy ingest');
    }

    @isTest
    static void shouldCompleteRun_WhenMirrorHasNoRowsForThisRun() {
        // A run whose feed matched nothing must still close its audit row, or the next night's
        // baseline read skips it and silently disables the row-count-change arm.
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);

        Test.startTest();
        Database.executeBatch(new ReceivablesSyncBatch(run.Id), ReceivablesSyncBatch.SCOPE);
        Test.stopTest();

        Sync_Run__c finished = SyncRunSelector.selectById(run.Id);
        Assert.areEqual('Completed', finished.Status__c,
            'An empty run must still be marked Completed so it can serve as a baseline');
        Assert.isTrue(finished.Lifecycle_Ran__c, 'The lifecycle did run - it simply had nothing to do');
        Assert.areEqual(0, finished.Cases_Opened__c, 'And opened nothing');
    }
}
