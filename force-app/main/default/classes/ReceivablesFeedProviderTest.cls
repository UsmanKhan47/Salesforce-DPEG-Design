/**
 * Tests for the pluggable ingestion boundary: both providers, the single callout service, the mock,
 * and the `Type.forName` dispatch that selects between them.
 *
 * THE TWO HIGHEST-VALUE TESTS HERE ARE THE ONES THAT PROTECT THE SWAP POINT:
 *   `shouldResolve_WhenGivenEveryShippedProviderName` - a class reached only by a config string can
 *   be deleted or renamed with NO compile error anywhere. This test is the only thing that notices.
 *   `shouldMakeZeroCallouts_WhenStubProviderRuns` - the brief's central claim, that the whole FSD 5.9
 *   workflow runs today with no ASB spoke. Proved by installing a callout mock and asserting it was
 *   never invoked, rather than by asserting the absence of an error.
 */
@isTest
private class ReceivablesFeedProviderTest {

    private static final DateTime RUN_START = DateTime.newInstanceGmt(2026, 8, 22, 3, 0, 0);

    /**
     * @param feedAsOf Optional clock to bake into the payload.
     * @return A well-formed feed envelope as JSON.
     */
    private static String envelope(DateTime feedAsOf) {
        ReceivablesFeedResult payload = new ReceivablesFeedResult();
        payload.feedAsOf = feedAsOf;
        payload.rows = ReceivablesTestData.feedRows(3, 'YU-1', 9000, 95);
        return JSON.serialize(payload);
    }

    // ── The stub provider ────────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldRebaseClock_WhenFixtureOmitsFeedAsOf() {
        // The fixture deliberately carries no clock. Without the rebase every run would halt as stale
        // the day after the fixture was written, and the "live today" claim would be false.
        StubReceivablesFeedProvider.fixtureOverride = envelope(null);

        ReceivablesFeedResult result = new StubReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));

        Assert.areEqual(RUN_START, result.feedAsOf,
            'A clock-less fixture must be rebased onto the run start, not left null');
        Assert.areEqual(3, result.rows.size(), 'All three fixture rows must come through');
        Assert.areEqual('Stub', result.source, 'Source must be the provider-declared label');
    }

    @isTest
    static void shouldHonourFixtureClock_WhenFixtureSuppliesOne() {
        // This is how the stale-feed halt is actually testable end to end.
        DateTime baked = RUN_START.addDays(-3);
        StubReceivablesFeedProvider.fixtureOverride = envelope(baked);

        ReceivablesFeedResult result = new StubReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));

        Assert.areEqual(baked, result.feedAsOf,
            'A fixture-supplied clock must be honoured verbatim so a stale feed can be simulated');
    }

    @isTest
    static void shouldReturnClocklessEmpty_WhenFixtureIsMissing() {
        // Missing resource is a HALT, not an empty feed: a fresh-looking empty feed would read as
        // "every tenant paid up".
        StubReceivablesFeedProvider.fixtureOverride = null;
        // The real static resource is not deployed in this transaction's view under an alias that
        // will not resolve, so force the missing path explicitly.
        StubReceivablesFeedProvider.fixtureOverride = '';

        ReceivablesFeedResult result = new StubReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));

        Assert.areEqual(0, result.rows.size(), 'A missing fixture yields no rows');
        Assert.isNull(result.feedAsOf,
            'And NO clock - which the health check reads as stale, producing a recorded halt');
    }

    @isTest
    static void shouldReturnClocklessEmpty_WhenFixtureIsMalformed() {
        StubReceivablesFeedProvider.fixtureOverride = '{ this is not json ';

        ReceivablesFeedResult result = new StubReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));

        Assert.areEqual(0, result.rows.size(), 'A malformed fixture must not throw');
        Assert.isNull(result.feedAsOf, 'It must halt via the clock-less path instead');
    }

    @isTest
    static void shouldReadTheDeployedStaticResource_WhenNoOverrideIsSet() {
        // Exercises StaticResourceSelector against the real deployed fixture.
        StubReceivablesFeedProvider.fixtureOverride = null;

        Test.startTest();
        ReceivablesFeedResult result = new StubReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));
        Test.stopTest();

        Assert.isNotNull(result, 'The provider must always return a result');
        Assert.areEqual('Stub', result.source, 'Source label must be Stub');
        Assert.areEqual(5, result.rows.size(),
            'The deployed fixture carries five rows; reading it proves StaticResourceSelector works');
        Assert.areEqual(RUN_START, result.feedAsOf,
            'The deployed fixture omits feedAsOf on purpose, so the clock must be rebased');
    }

    @isTest
    static void shouldDropKeylessRows_WhenNormalising() {
        // A row with no AR key is unroutable: that value is both the upsert key and the guard key.
        ReceivablesFeedResult payload = new ReceivablesFeedResult();
        payload.rows = ReceivablesTestData.feedRows(2, null, 100, 5);
        payload.rows.add(new ReceivablesFeedDTO());
        payload.rows.add(null);

        payload.normalize();

        Assert.areEqual(2, payload.rows.size(),
            'Keyless and null rows must be dropped before they reach the upsert');
    }

    @isTest
    static void shouldTolerateNullRows_WhenNormalising() {
        ReceivablesFeedResult payload = new ReceivablesFeedResult();
        payload.rows = null;

        payload.normalize();

        Assert.areEqual(0, payload.rows.size(), 'A null collection must become an empty one');
    }

    @isTest
    static void shouldMakeZeroCallouts_WhenStubProviderRuns() {
        // THE BRIEF'S CENTRAL CLAIM, asserted positively rather than by absence of error.
        ReceivablesCalloutMock mock = new ReceivablesCalloutMock(200, envelope(RUN_START));
        Test.setMock(HttpCalloutMock.class, mock);
        StubReceivablesFeedProvider.fixtureOverride = envelope(null);

        Test.startTest();
        new StubReceivablesFeedProvider().fetch(new ReceivablesFeedRequest(null, RUN_START, null));
        Test.stopTest();

        Assert.areEqual(0, mock.requestCount,
            'The stub provider must reach the full lifecycle with ZERO callouts - that is what makes '
            + 'the feature live before the ASB spoke exists');
    }

    // ── The ASB provider and the single callout boundary ─────────────────────────────────────────

    @isTest
    static void shouldParseFeed_WhenBusReturnsWellFormedPayload() {
        Test.setMock(HttpCalloutMock.class, new ReceivablesCalloutMock(200, envelope(RUN_START)));

        Test.startTest();
        ReceivablesFeedResult result = new AsbReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, 500));
        Test.stopTest();

        Assert.areEqual(3, result.rows.size(), 'All rows must parse');
        Assert.areEqual(RUN_START, result.feedAsOf, 'The clock must come from the PAYLOAD');
        Assert.areEqual('ASB', result.source, 'Source must be ASB');
    }

    @isTest
    static void shouldNotRebaseClock_WhenBusOmitsIt() {
        // Unlike the stub, the live provider must never assert freshness it cannot know.
        Test.setMock(HttpCalloutMock.class, new ReceivablesCalloutMock(200, envelope(null)));

        Test.startTest();
        ReceivablesFeedResult result = new AsbReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));
        Test.stopTest();

        Assert.isNull(result.feedAsOf,
            'A bus payload with no clock must stay clock-less and halt, never be rebased');
    }

    @isTest
    static void shouldReturnClocklessEmpty_WhenBusReturnsServerError() {
        Test.setMock(HttpCalloutMock.class, new ReceivablesCalloutMock(500, 'upstream exploded'));

        Test.startTest();
        ReceivablesFeedResult result = new AsbReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));
        Test.stopTest();

        Assert.areEqual(0, result.rows.size(), 'A 500 must not throw');
        Assert.isNull(result.feedAsOf, 'It must degrade to a recorded halt, not an exception');
    }

    @isTest
    static void shouldReturnClocklessEmpty_WhenTransportFails() {
        ReceivablesCalloutMock mock = new ReceivablesCalloutMock(200, envelope(RUN_START));
        mock.throwTransportFailure = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ReceivablesFeedResult result = new AsbReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));
        Test.stopTest();

        Assert.isNull(result.feedAsOf,
            'A CalloutException - the unprovisioned-credential case today - must be caught, not escape');
    }

    @isTest
    static void shouldReturnClocklessEmpty_WhenPayloadIsMalformed() {
        Test.setMock(HttpCalloutMock.class, new ReceivablesCalloutMock(200, '{ nope '));

        Test.startTest();
        ReceivablesFeedResult result = new AsbReceivablesFeedProvider()
            .fetch(new ReceivablesFeedRequest(null, RUN_START, null));
        Test.stopTest();

        Assert.areEqual(0, result.rows.size(), 'A malformed payload must not throw');
        Assert.isNull(result.feedAsOf, 'It must halt through the clock-less path');
    }

    @isTest
    static void shouldReportEmptyBody_WhenBusReturnsTwoHundredWithNothing() {
        Test.setMock(HttpCalloutMock.class, new ReceivablesCalloutMock(200, ''));

        Test.startTest();
        ReceivablesCalloutService.FeedResponse response =
            ReceivablesCalloutService.fetchDelinquencyFeed(RUN_START, 100);
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'A 200 with an empty body is not a success');
        Assert.isTrue(response.errorMessage.contains('empty body'),
            'And it must say so, so an operator is not left reading a bare 200');
    }

    @isTest
    static void shouldComposeQueryString_WhenBothParametersSupplied() {
        ReceivablesCalloutMock mock = new ReceivablesCalloutMock(200, envelope(RUN_START));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ReceivablesCalloutService.fetchDelinquencyFeed(RUN_START, 250);
        Test.stopTest();

        String endpoint = mock.lastRequest.getEndpoint();
        Assert.isTrue(endpoint.startsWith('callout:ASB'),
            'The endpoint must be built from the ONE constant, pointing at the BUS and not at Yardi');
        Assert.isTrue(endpoint.contains('/receivables/delinquency'), 'The spoke path must be present');
        Assert.isTrue(endpoint.contains('maxRows=250'), 'The row cap must be passed through');
        Assert.isTrue(endpoint.contains('asOf='), 'The as-of parameter must be passed through');
    }

    @isTest
    static void shouldOmitQueryString_WhenNoParametersSupplied() {
        ReceivablesCalloutMock mock = new ReceivablesCalloutMock(200, envelope(RUN_START));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ReceivablesCalloutService.fetchDelinquencyFeed(null, null);
        Test.stopTest();

        Assert.isFalse(mock.lastRequest.getEndpoint().contains('?'),
            'With no parameters there must be no dangling query string');
    }

    // ── The swap point ───────────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldResolve_WhenGivenEveryShippedProviderName() {
        // THE DELETION TRIPWIRE. A provider referenced only from a custom setting is invisible to the
        // compiler; if somebody renames one of these classes, this assertion is the only thing in the
        // codebase that fails.
        for (String className : new List<String>{
                'StubReceivablesFeedProvider', 'AsbReceivablesFeedProvider' }) {
            ReceivablesFeedProvider provider = ReceivablesIngestQueueable.resolveProvider(className);
            Assert.isNotNull(provider,
                className + ' must still resolve to a ReceivablesFeedProvider - it is reachable only '
                + 'by config string, so nothing else would notice its removal');
            Assert.isNotNull(provider.sourceLabel(), className + ' must declare a source label');
        }
    }

    @isTest
    static void shouldReturnNull_WhenProviderNameDoesNotExist() {
        Assert.isNull(ReceivablesIngestQueueable.resolveProvider('NoSuchProviderClass'),
            'An unresolvable name must yield null so the caller can HALT rather than fall back');
    }

    @isTest
    static void shouldReturnNull_WhenProviderNameIsBlank() {
        Assert.isNull(ReceivablesIngestQueueable.resolveProvider(null), 'Null name yields null');
        Assert.isNull(ReceivablesIngestQueueable.resolveProvider('  '), 'Blank name yields null');
    }

    @isTest
    static void shouldReturnNull_WhenClassDoesNotImplementTheInterface() {
        // A real class that is not a provider. Without the instanceof check this would ClassCastException
        // at runtime inside the queueable, losing the audit row.
        Assert.isNull(ReceivablesIngestQueueable.resolveProvider('ReceivablesSyncConfig'),
            'A class that does not implement the interface must be refused, not cast');
    }
}
