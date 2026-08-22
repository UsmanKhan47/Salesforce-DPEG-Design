/**
 * Tests for `ReceivablesSyncService.ingest` - the single entry point every provider funnels into.
 *
 * THE ASSERTION THAT CARRIES THE HALT RULE is that a suspect feed writes NOTHING. Not "opens no
 * Cases" - writes nothing at all. This implementation deliberately runs the health check BEFORE the
 * upsert (a stated deviation from the FSD's step numbering), so `isHealthy = false` means the mirror
 * was never touched, and that is asserted directly by counting mirror rows.
 *
 * `.claude/rules/bulk-test-rule.md`: `ingest` is a DML-performing service taking a collection, so the
 * 251-row mandate applies and is met. `Receivables_Summary__c` has no trigger, so 251 rows is one
 * DML statement; the test still proves the join and mapping do not degrade into per-row queries.
 */
@isTest
private class ReceivablesSyncServiceTest {

    private static final DateTime FRESH = System.now();

    @isTest
    static void shouldUpsertMirror_WhenFeedIsHealthy() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);

        Test.startTest();
        ReceivablesSyncService.IngestResult result =
            ReceivablesSyncService.ingest(ReceivablesTestData.feedRows(5, null, 9000, 95), FRESH, run.Id);
        Test.stopTest();

        Assert.isTrue(result.isHealthy, 'A fresh, correctly sized feed must pass');
        Assert.areEqual(5, result.rowCount, 'Row count must be recorded');
        Assert.areEqual(5, result.rowsUpserted, 'Every row must be written');
        Assert.areEqual(0, result.rowsFailed, 'And none refused');
        Assert.areEqual(5, [SELECT COUNT() FROM Receivables_Summary__c],
            'The mirror must actually hold the rows');
    }

    @isTest
    static void shouldStampRunAndFeedClock_WhenUpserting() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);
        DateTime feedClock = FRESH.addMinutes(-90);

        Test.startTest();
        ReceivablesSyncService.ingest(ReceivablesTestData.feedRows(2, null, 100, 5), feedClock, run.Id);
        Test.stopTest();

        List<Receivables_Summary__c> rows = [
            SELECT Sync_Run__c, Yardi_Last_Synced_DateTime__c FROM Receivables_Summary__c];
        Assert.areEqual(2, rows.size(), 'Both rows must land');
        Assert.areEqual(run.Id, rows[0].Sync_Run__c,
            'Every row must be stamped with the run, so per-row staleness is auditable');
        Assert.areEqual(feedClock, rows[0].Yardi_Last_Synced_DateTime__c,
            'Last-synced must carry the FEED clock, not the moment of the write');
    }

    @isTest
    static void shouldUpdateInPlace_WhenSameKeyArrivesTwice() {
        // Proves the external-id upsert, i.e. that a nightly re-run does not duplicate the mirror.
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);
        List<ReceivablesFeedDTO> rows = ReceivablesTestData.feedRows(1, null, 5000, 40);

        Test.startTest();
        ReceivablesSyncService.ingest(rows, FRESH, run.Id);
        rows[0].totalOutstanding = 12000;
        ReceivablesSyncService.ingest(rows, FRESH, run.Id);
        Test.stopTest();

        List<Receivables_Summary__c> mirror = [
            SELECT Total_Outstanding_Amount__c FROM Receivables_Summary__c];
        Assert.areEqual(1, mirror.size(), 'The same AR key must UPDATE, never duplicate');
        Assert.areEqual(12000, mirror[0].Total_Outstanding_Amount__c, 'And must carry the new balance');
    }

    // ── THE HALT RULE: nothing is written on suspect data ────────────────────────────────────────

    @isTest
    static void shouldWriteNothing_WhenFeedIsStale() {
        ReceivablesTestData.configWithHealthArms(12, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);

        Test.startTest();
        ReceivablesSyncService.IngestResult result = ReceivablesSyncService.ingest(
            ReceivablesTestData.feedRows(5, null, 9000, 95), FRESH.addHours(-48), run.Id);
        Test.stopTest();

        Assert.isFalse(result.isHealthy, 'A 48-hour-old feed must halt at a 12-hour tolerance');
        Assert.areEqual('Stale Feed', result.haltReason, 'With the reason recorded');
        Assert.areEqual(5, result.rowCount, 'The audit row must still say how big the suspect feed was');
        Assert.areEqual(0, result.rowsUpserted, 'But nothing may be written');
        Assert.areEqual(0, [SELECT COUNT() FROM Receivables_Summary__c],
            'THE MIRROR MUST BE UNTOUCHED - a stale feed published to the dashboards is the same '
            + 'deception the halt rule exists to prevent');
    }

    @isTest
    static void shouldWriteNothing_WhenFeedIsBelowTheFloor() {
        ReceivablesTestData.configWithHealthArms(24, 100, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);

        Test.startTest();
        ReceivablesSyncService.IngestResult result =
            ReceivablesSyncService.ingest(ReceivablesTestData.feedRows(3, null, 9000, 95), FRESH, run.Id);
        Test.stopTest();

        Assert.areEqual('Row Count Below Minimum', result.haltReason, 'A truncated feed must halt');
        Assert.areEqual(0, [SELECT COUNT() FROM Receivables_Summary__c], 'And write nothing');
    }

    @isTest
    static void shouldWriteNothing_WhenRowCountChangeExceedsTolerance() {
        ReceivablesTestData.configWithHealthArms(24, 1, 10, 7);
        ReceivablesTestData.syncRun('Completed', 100, true);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);

        Test.startTest();
        ReceivablesSyncService.IngestResult result =
            ReceivablesSyncService.ingest(ReceivablesTestData.feedRows(5, null, 9000, 95), FRESH, run.Id);
        Test.stopTest();

        Assert.areEqual('Row Count Change Exceeded', result.haltReason,
            'A collapse from 100 rows to 5 must halt on the change arm');
        Assert.areEqual(0, [SELECT COUNT() FROM Receivables_Summary__c], 'And write nothing');
    }

    @isTest
    static void shouldHaltAsStale_WhenFeedResultIsNull() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);

        Test.startTest();
        ReceivablesSyncService.IngestResult result =
            ReceivablesSyncService.ingest((ReceivablesFeedResult) null, run.Id);
        Test.stopTest();

        Assert.isFalse(result.isHealthy, 'A null feed carries no clock and must halt');
        Assert.areEqual('Stale Feed', result.haltReason,
            'And it must be routed through the ONE class that owns halt reasons, not short-circuited');
    }

    @isTest
    static void shouldPassButWriteNothing_WhenHealthyFeedIsEmpty() {
        // Legitimate when nobody is delinquent and the floor arm is unarmed.
        ReceivablesTestData.configWithHealthArms(24, null, null, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);

        Test.startTest();
        ReceivablesSyncService.IngestResult result =
            ReceivablesSyncService.ingest(new List<ReceivablesFeedDTO>(), FRESH, run.Id);
        Test.stopTest();

        Assert.isTrue(result.isHealthy, 'An empty feed with the floor unarmed is healthy');
        Assert.areEqual(0, result.rowsUpserted, 'And writes nothing, without erroring');
    }

    @isTest
    static void shouldDelegateFromFeedResultOverload() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);
        ReceivablesFeedResult feed = new ReceivablesFeedResult();
        feed.feedAsOf = FRESH;
        feed.rows = ReceivablesTestData.feedRows(2, null, 100, 5);

        Test.startTest();
        ReceivablesSyncService.IngestResult result = ReceivablesSyncService.ingest(feed, run.Id);
        Test.stopTest();

        Assert.isTrue(result.isHealthy, 'The convenience overload must reach the same path');
        Assert.areEqual(2, result.rowsUpserted, 'And write the same rows');
    }

    @isTest
    static void shouldJoinUnits_WhenFeedReferencesThem() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;
        Unit__c unit = TestDataFactory.createUnits(1, assetId, true)[0];
        List<ReceivablesFeedDTO> rows =
            ReceivablesTestData.feedRows(3, unit.Yardi_Unit_Id__c, 9000, 95);

        Test.startTest();
        ReceivablesSyncService.ingest(rows, FRESH, run.Id);
        Test.stopTest();

        List<Receivables_Summary__c> mirror = [
            SELECT Unit__c, Property_Asset__c FROM Receivables_Summary__c];
        Assert.areEqual(3, mirror.size(), 'All rows must land');
        Assert.areEqual(unit.Id, mirror[0].Unit__c, 'The unit join must resolve');
        Assert.areEqual(assetId, mirror[0].Property_Asset__c,
            'And the property asset must be derived from the unit master');
    }

    @isTest
    static void shouldIngest251Rows_WithoutPerRowQueries() {
        // Bulk mandate. The point is not the row count itself but that the joins stay constant-cost:
        // a per-row unit or user lookup here would be invisible at 5 rows and fatal at 251.
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Sync_Run__c run = ReceivablesTestData.syncRun('Running', 0, true);
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;
        Unit__c unit = TestDataFactory.createUnits(1, assetId, true)[0];
        List<ReceivablesFeedDTO> rows =
            ReceivablesTestData.feedRows(251, unit.Yardi_Unit_Id__c, 9000, 95);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        ReceivablesSyncService.IngestResult result = ReceivablesSyncService.ingest(rows, FRESH, run.Id);
        Integer queriesSpent = Limits.getQueries() - queriesBefore;
        Integer dmlSpent = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(251, result.rowsUpserted, 'All 251 rows must be written');
        Assert.areEqual(251, [SELECT COUNT() FROM Receivables_Summary__c],
            'And all 251 must be in the mirror');
        Assert.isTrue(queriesSpent <= 5,
            'Ingest must cost a CONSTANT handful of queries regardless of row count; spent: '
            + queriesSpent);
        Assert.areEqual(1, dmlSpent,
            'The whole feed must be ONE upsert statement; spent: ' + dmlSpent);
    }
}
