/**
 * Tests for MarketDataSnapshotService — the market-data freeze at underwriting approval.
 *
 * ⚠ THE THREE MOST IMPORTANT TESTS HERE ARE FALSIFIERS, NOT COVERAGE. Each exists to go
 * RED if a specific, plausible "improvement" is made to the service:
 *
 *   aSecondApprovalReSnapshots            -> reds if anyone makes the stamp fill-if-blank.
 *   aDealWithNoPropertySaysSoInTheField   -> reds if a blank snapshot is ever accepted.
 *   aReadFailureIsWrittenIntoTheFieldAndNeverThrown
 *                                         -> reds if the wide catch stops self-reporting,
 *                                            OR if it starts rethrowing.
 *
 * ⚠ BULK VOLUME IS 251 AND THE `.claude/rules/bulk-test-rule.md` PER-TRANSACTION-SINGLETON
 * EXEMPTION DOES **NOT** APPLY. This is an `@InvocableMethod`: Flow batches record-triggered
 * interviews and hands the whole batch to ONE invocation, so the multi-record path is real
 * production behaviour rather than a hypothetical.
 *
 * ⚠ GOVERNOR ASSERTIONS ARE TAKEN INSIDE THE TRANSACTION, BEFORE `Test.stopTest()`.
 * `stopTest()` restores the pre-test limit counters, so a `Limits.getQueries()` assertion
 * written after it is silently vacuous (the `OpportunitySelectorTest` /
 * `ExtractAddressQueueable` precedent).
 */
@isTest
private class MarketDataSnapshotServiceTest {

    private static final Integer BULK_N = 251;

    // ─────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * One deal linked to a Property carrying a populated market block.
     *
     * ⚠ The factory does NOT set the Placer/CoStar fields (they are new in this tranche),
     * so they are set here explicitly. Setting at least one value in EACH provider block is
     * what makes `snapshotNamesBothProviderBlocks` non-vacuous — a composer that emitted
     * only one block would otherwise pass.
     */
    private static Opportunity dealWithMarketData() {
        Property__c property = TestDataFactory.createProperty(false);
        property.Placer_State_Rank__c = 12;
        property.Placer_State_Percentile__c = 94.50;
        property.Placer_MSA_Rank__c = 3;
        property.Placer_National_Rank__c = 187;
        property.Monthly_Visits__c = 125000;
        property.Placer_Data_Source__c = 'Manual';
        property.CoStar_Pct_Leased__c = 92.25;
        property.CoStar_Location_Score__c = 8.5;
        property.CoStar_Asking_Rent_PSF__c = 34.00;
        property.CoStar_Exit_Cap_Rate__c = 6.75;
        property.CoStar_Data_Source__c = 'Manual';
        insert property;

        Opportunity deal = TestDataFactory.createOpportunity((Id) null, false);
        deal.Property__c = property.Id;
        insert deal;
        return deal;
    }

    private static List<MarketDataSnapshotService.Request> requestsFor(List<Opportunity> deals) {
        List<MarketDataSnapshotService.Request> requests =
            new List<MarketDataSnapshotService.Request>();
        for (Opportunity o : deals) {
            MarketDataSnapshotService.Request r = new MarketDataSnapshotService.Request();
            r.recordId = o.Id;
            requests.add(r);
        }
        return requests;
    }

    private static List<MarketDataSnapshotService.Request> requestFor(Opportunity deal) {
        return requestsFor(new List<Opportunity>{ deal });
    }

    private static Opportunity reread(Id dealId) {
        return [
            SELECT Id, Market_Data_Snapshot__c, Market_Data_As_Of_Date__c
            FROM Opportunity
            WHERE Id = :dealId
        ];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Happy path
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void happyPathStampsANonBlankSnapshotAndTodaysAsOfDate() {
        Opportunity deal = dealWithMarketData();

        Test.startTest();
        List<MarketDataSnapshotService.Result> results =
            MarketDataSnapshotService.snapshotMarketData(requestFor(deal));
        Test.stopTest();

        Opportunity after = reread(deal.Id);
        Assert.isNotNull(after.Market_Data_Snapshot__c, 'The snapshot body must be written');
        Assert.areEqual(Date.today(), after.Market_Data_As_Of_Date__c,
            'The as-of date is the day the freeze ran');
        Assert.areEqual(1, results.size(), 'One Result per input Request, index-aligned');
        Assert.isTrue(results[0].success, 'A deal with a Property snapshots successfully');
    }

    @isTest
    static void snapshotNamesBothProviderBlocksAndCarriesTheValues() {
        Opportunity deal = dealWithMarketData();

        Test.startTest();
        MarketDataSnapshotService.snapshotMarketData(requestFor(deal));
        Test.stopTest();

        String body = reread(deal.Id).Market_Data_Snapshot__c;
        Assert.isTrue(body.contains('-- PLACER.AI --'), 'The Placer block must be labelled');
        Assert.isTrue(body.contains('-- COSTAR --'), 'The CoStar block must be labelled');
        // One value from each provider, so a composer that dropped a whole block reds here.
        Assert.isTrue(body.contains('State Rank: 12'), 'A Placer value must be carried verbatim');
        Assert.isTrue(body.contains('Location Score: 8.5'), 'A CoStar value must be carried verbatim');
    }

    /**
     * A null market value must render `(not set)`, NOT an omitted line and NOT an empty tail.
     *
     * 🔴 This is the falsifier for "just skip the nulls". An omitted line cannot be told
     * apart from a field the composer forgot to include, which destroys the one property
     * the block exists to have: that a reader can trust what is NOT in it.
     */
    @isTest
    static void aNullMarketValueRendersNotSetRatherThanBeingOmitted() {
        Property__c property = TestDataFactory.createProperty(true); // no Placer/CoStar values
        Opportunity deal = TestDataFactory.createOpportunity((Id) null, false);
        deal.Property__c = property.Id;
        insert deal;

        Test.startTest();
        MarketDataSnapshotService.snapshotMarketData(requestFor(deal));
        Test.stopTest();

        String body = reread(deal.Id).Market_Data_Snapshot__c;
        Assert.isTrue(body.contains('State Rank: (not set)'),
            'An unset Placer metric must say so rather than vanish from the block');
        Assert.isTrue(body.contains('Location Score: (not set)'),
            'An unset CoStar metric must say so rather than vanish from the block');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Residual R1 — a deal with no Property
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 FALSIFIER for treating an empty snapshot as acceptable. Only `LeadConvertService`
     * creates and links a `Property__c`, so a manually built deal has none — and a BLANK
     * field for that deal would be indistinguishable from "the freeze never ran".
     */
    @isTest
    static void aDealWithNoPropertySaysSoInTheField() {
        Opportunity deal = TestDataFactory.createOpportunity((Id) null, true); // Property__c null

        Test.startTest();
        List<MarketDataSnapshotService.Result> results =
            MarketDataSnapshotService.snapshotMarketData(requestFor(deal));
        Test.stopTest();

        Opportunity after = reread(deal.Id);
        Assert.areEqual(
            'No property linked to this deal - no market data to snapshot.',
            after.Market_Data_Snapshot__c,
            'A deal with no Property gets the literal explanation, never a blank');
        Assert.areEqual(Date.today(), after.Market_Data_As_Of_Date__c,
            'The as-of date still stamps, so the state is legible rather than absent');
        Assert.isTrue(results[0].success,
            'This is a legitimate outcome, not a failure — the deal genuinely has no market data');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Re-approval
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 FALSIFIER against a fill-if-blank "optimisation".
     *
     * The flow's `doesRequireRecordChangedToMeetCriteria = true` means a second invocation
     * can only follow a genuine reject → re-approve cycle, i.e. a SECOND REVIEW of the data
     * as it then stood. Fill-if-blank would leave that second review permanently
     * misrepresented by the first approval's numbers — the field would then assert evidence
     * that is false rather than merely superseded.
     */
    @isTest
    static void aSecondApprovalReSnapshots() {
        Opportunity deal = dealWithMarketData();
        MarketDataSnapshotService.snapshotMarketData(requestFor(deal));

        String firstBody = reread(deal.Id).Market_Data_Snapshot__c;
        Assert.isTrue(firstBody.contains('Monthly Visits: 125000'),
            'precondition: the first freeze captured the original figure');

        // The live layer moves between the two approvals — which is exactly what §18.3
        // says must not silently change the numbers already reviewed.
        Property__c property = [SELECT Id FROM Property__c WHERE Id = :deal.Property__c];
        property.Monthly_Visits__c = 999000;
        update property;

        Test.startTest();
        MarketDataSnapshotService.snapshotMarketData(requestFor(deal));
        Test.stopTest();

        String secondBody = reread(deal.Id).Market_Data_Snapshot__c;
        Assert.isTrue(secondBody.contains('Monthly Visits: 999000'),
            'The re-approval must freeze the data as it stood at the SECOND review');
        Assert.isFalse(secondBody.contains('Monthly Visits: 125000'),
            'and must NOT retain the first review\'s figure — fill-if-blank would fail here');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The wide, self-reporting catch
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE HEADLINE FALSIFIER. ARCHITECTURE.md §2 records that a `DmlException`-only catch
     * let a `TypeException` roll back a whole approval — AND that the widened catch alone
     * would have been WORSE than the bug, because the approval then succeeds while the
     * stamp stays silently blank.
     *
     * This asserts BOTH halves at once: nothing is thrown (so the approval survives) AND the
     * reason is legible on the record (so the failure is not silent).
     */
    @isTest
    static void aReadFailureIsWrittenIntoTheFieldAndNeverThrown() {
        Opportunity deal = dealWithMarketData();
        MarketDataSnapshotService.simulateReadFailure = true;

        Test.startTest();
        List<MarketDataSnapshotService.Result> results = null;
        try {
            results = MarketDataSnapshotService.snapshotMarketData(requestFor(deal));
        } catch (Exception e) {
            Assert.fail('A snapshot failure must NEVER escape — it would roll back the approval. '
                + 'Thrown: ' + e.getTypeName() + ': ' + e.getMessage());
        }
        Test.stopTest();

        Opportunity after = reread(deal.Id);
        Assert.isTrue(
            after.Market_Data_Snapshot__c.startsWith('Market data snapshot failed: '),
            'The field must REPORT ITS OWN ABSENCE. A blank here is the failure mode the '
            + 'wide catch would otherwise have introduced');
        Assert.areEqual(Date.today(), after.Market_Data_As_Of_Date__c,
            'The as-of date still stamps, so gate G5 can find "a stamped date beside a failure body"');
        Assert.isFalse(results[0].success,
            'and the Result says false, so a future Flow caller can branch on it');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Degenerate input
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void nullAndEmptyInputAreSafeAndCostNothing() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        List<MarketDataSnapshotService.Result> fromNull =
            MarketDataSnapshotService.snapshotMarketData(null);
        List<MarketDataSnapshotService.Result> fromEmpty =
            MarketDataSnapshotService.snapshotMarketData(
                new List<MarketDataSnapshotService.Request>());

        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(fromNull.isEmpty(), 'Null input returns an empty list, never null');
        Assert.isTrue(fromEmpty.isEmpty(), 'Empty input returns an empty list, never null');
        Assert.areEqual(0, queriesUsed, 'Degenerate input must not query');
        Assert.areEqual(0, dmlUsed, 'Degenerate input must not write');
    }

    /**
     * A Request carrying a null `recordId` must not break the batch around it — Flow can
     * hand over an interview whose record was deleted mid-wave.
     */
    @isTest
    static void aNullRecordIdIsSkippedWithoutTakingTheBatchDown() {
        Opportunity deal = dealWithMarketData();
        List<MarketDataSnapshotService.Request> requests = requestFor(deal);
        requests.add(new MarketDataSnapshotService.Request()); // recordId left null

        Test.startTest();
        List<MarketDataSnapshotService.Result> results =
            MarketDataSnapshotService.snapshotMarketData(requests);
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Results stay INDEX-ALIGNED to the input list');
        Assert.isTrue(results[0].success, 'The real deal still snapshots');
        Assert.isFalse(results[1].success, 'and the null-Id request reports failure rather than throwing');
        Assert.isNotNull(reread(deal.Id).Market_Data_Snapshot__c, 'The good row was still written');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bulk — the governor contract
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 251 deals in ONE invocation: 1 SOQL and 1 DML, CONSTANT in record count.
     *
     * 🔴 THE BUDGET ASSERTION IS THE POINT OF THIS TEST, not the row count. It makes a future
     * change that adds one query or one DML per deal fail HERE rather than in production —
     * where the cost is a rolled-back approval, not a slow page.
     *
     * ⚠ 251 forces a second trigger batch chunk on the fixture insert, which is the reason
     * `.claude/rules/bulk-test-rule.md` names that number rather than 200.
     */
    @isTest
    static void bulk251DealsCostOneQueryAndOneDml() {
        List<Property__c> properties = TestDataFactory.createProperties(BULK_N, false);
        for (Integer i = 0; i < BULK_N; i++) {
            properties[i].Monthly_Visits__c = 1000 + i;
        }
        insert properties;

        List<Opportunity> deals = TestDataFactory.createOpportunities(BULK_N, false);
        for (Integer i = 0; i < BULK_N; i++) {
            deals[i].Property__c = properties[i].Id;
        }
        insert deals;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        List<MarketDataSnapshotService.Result> results =
            MarketDataSnapshotService.snapshotMarketData(requestsFor(deals));

        // Captured INSIDE the transaction — Limits.* after Test.stopTest() is restored to
        // pre-test values and the assertion would be silently vacuous.
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, results.size(), 'One Result per input Request at 251');
        Assert.areEqual(1, queriesUsed,
            'ONE query for the whole batch, regardless of deal count');
        Assert.areEqual(1, dmlUsed,
            'ONE DML statement for the whole batch, regardless of deal count');

        // ⚠ THE NON-BLANK TEST IS IN APEX, NOT IN THE `WHERE` CLAUSE, AND MUST STAY THERE.
        // `Market_Data_Snapshot__c` is a Long Text Area, and a Long Text Area cannot be
        // FILTERED in SOQL — the platform rejects it at COMPILE time ("field
        // 'Market_Data_Snapshot__c' can not be filtered in a query call"), so restoring the
        // filter does not fail this test, it fails the whole deploy. SELECTING the field is
        // legal; only WHERE / ORDER BY / GROUP BY are not.
        Integer stamped = 0;
        for (Opportunity o : [
            SELECT Id, Market_Data_Snapshot__c
            FROM Opportunity
            WHERE Id IN :deals
        ]) {
            if (o.Market_Data_Snapshot__c != null) {
                stamped++;
            }
        }
        Assert.areEqual(BULK_N, stamped, 'Every one of the 251 deals is stamped');
    }

    /**
     * A 251-deal batch whose READ fails still costs exactly ONE DML — the self-reporting
     * body rides the very statement that would have carried the snapshot.
     *
     * ⚠ Without this, a plausible "report each failure individually" refactor would turn one
     * DML into 251 inside an approval transaction and nothing would catch it.
     */
    @isTest
    static void bulk251FailuresStillCostOneDmlAndAllReportThemselves() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(BULK_N, true);
        MarketDataSnapshotService.simulateReadFailure = true;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        MarketDataSnapshotService.snapshotMarketData(requestsFor(deals));
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, dmlUsed, 'The failure path costs the SAME one DML as the happy path');

        // ⚠ THE PREFIX TEST IS IN APEX, NOT A SOQL `LIKE`, AND MUST STAY THERE — a Long Text
        // Area cannot be filtered in SOQL and the rejection is a COMPILE error, so restoring
        // the `LIKE` breaks the deploy rather than this test. `startsWith` is the exact
        // equivalent of the `'Market data snapshot failed:%'` pattern it replaces (stricter
        // only in that it is case-sensitive, and the service writes a fixed literal), so this
        // still proves every one of the 251 rows names its own reason rather than sitting blank.
        Integer reported = 0;
        for (Opportunity o : [
            SELECT Id, Market_Data_Snapshot__c
            FROM Opportunity
            WHERE Id IN :deals
        ]) {
            if (o.Market_Data_Snapshot__c != null
                && o.Market_Data_Snapshot__c.startsWith('Market data snapshot failed:')) {
                reported++;
            }
        }
        Assert.areEqual(BULK_N, reported,
            'Every deal in the failed batch reports the reason on its own record');
    }
}
