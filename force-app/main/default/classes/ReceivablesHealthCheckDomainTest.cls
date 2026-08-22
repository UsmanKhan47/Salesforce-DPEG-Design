/**
 * Tests for `ReceivablesHealthCheckDomain` - FSD 5.9.6 step 2, the halt rule.
 *
 * NO `@TestSetup`, NO DML, NO SOQL ANYWHERE IN THIS CLASS, and that is the point of having built the
 * halt rule as a pure domain: the rule that decides whether a night's data may be acted on is proved
 * exhaustively in milliseconds, against explicit clocks, with no database and no fixture to go stale.
 *
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not apply: `evaluate` takes primitives
 * and a row COUNT, never a collection. There is no loop to force a second batch chunk, so a 251-row
 * variant would exercise not one additional line.
 */
@isTest
private class ReceivablesHealthCheckDomainTest {

    private static final DateTime NOW = DateTime.newInstanceGmt(2026, 8, 22, 3, 0, 0);

    @isTest
    static void shouldPass_WhenEveryArmIsSatisfied() {
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW.addHours(-2), 500, 480, NOW, 12, 100, 25);

        Assert.isTrue(verdict.isHealthy, 'A fresh, correctly sized feed must pass');
        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_NONE, verdict.haltReason,
            'A healthy verdict must carry the None reason');
        Assert.isNull(verdict.haltDetail, 'A healthy verdict must carry no detail');
    }

    @isTest
    static void shouldHaltStale_WhenFeedIsOlderThanTolerance() {
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW.addHours(-13), 500, 480, NOW, 12, 100, 25);

        Assert.isFalse(verdict.isHealthy, 'A 13-hour-old feed must halt at a 12-hour tolerance');
        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_STALE_FEED, verdict.haltReason,
            'The halt reason must be Stale Feed');
        Assert.isTrue(verdict.haltDetail.contains('780'),
            'The detail must state the measured age in minutes so an operator can see the margin');
    }

    @isTest
    static void shouldHaltStale_WhenFeedStatesNoClock() {
        // The load-bearing case: a feed fetched two seconds ago can be three days old. If it will not
        // say how old it is, it cannot be proven fresh, and the rule exists to refuse exactly that.
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            null, 500, 480, NOW, 12, 100, 25);

        Assert.isFalse(verdict.isHealthy, 'A clock-less feed must be treated as stale, never as fresh');
        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_STALE_FEED, verdict.haltReason,
            'A missing clock is a Stale Feed halt');
    }

    @isTest
    static void shouldPass_WhenStalenessArmIsUnarmed() {
        // A null tolerance disables the AGE COMPARISON rather than defaulting to a made-up number,
        // so a four-day-old feed that SAYS it is four days old passes.
        //
        // The fixture states a clock deliberately. Until 2026-08-22 this test passed a null one and
        // asserted healthy, which encoded the unsafe half of the old implementation: it made the
        // refusal of an unstated clock depend on an optional Setup value. A clock-less feed is now
        // refused unconditionally - see shouldHaltStale_WhenClockIsAbsentAndToleranceIsUnarmed - so
        // the fixture was changed to test what this method's NAME says it tests.
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW.addDays(-4), 500, 480, NOW, null, 100, 25);

        Assert.isTrue(verdict.isHealthy,
            'With the staleness arm unarmed, even a four-day-old feed must pass that arm');
    }

    @isTest
    static void shouldHaltStale_WhenClockIsAbsentAndToleranceIsUnarmed() {
        // 🔴 THE SAFETY PIN. Every AsbReceivablesFeedProvider failure - refused credential, 500 from
        // the bus, truncated body, malformed payload - arrives here as zero rows with a null clock.
        // Staleness_Tolerance_Hours__c is OPTIONAL and blank by default, and ReceivablesSyncConfig
        // .isReady() does not require it. If a null clock were only refused when that value happened
        // to be set, an unreachable bus would report HEALTHY, the lifecycle would run against an
        // empty feed, and FSD 5.9.6 step 6 would read "no balance" as "everyone paid" - auto-closing
        // EVERY open delinquency Case in the org. Every threshold below is deliberately null.
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            null, 0, null, NOW, null, null, null);

        Assert.isFalse(verdict.isHealthy,
            'A clock-less feed must be refused even with every configurable threshold left unset - '
            + 'the refusal of unknown provenance must not be switch-off-able by omission');
        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_STALE_FEED, verdict.haltReason,
            'And must be reported as a Stale Feed halt, the same reason as any other unproven feed');
    }

    @isTest
    static void shouldHaltRowCountLow_WhenFeedIsBelowTheFloor() {
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW.addHours(-1), 40, 480, NOW, 12, 100, 500);

        Assert.isFalse(verdict.isHealthy, 'A truncated feed must halt');
        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_ROW_COUNT_LOW, verdict.haltReason,
            'The halt reason must be Row Count Below Minimum');
    }

    @isTest
    static void shouldHaltRowCountLow_WhenFeedIsEmpty() {
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW, 0, 480, NOW, 12, 100, 500);

        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_ROW_COUNT_LOW, verdict.haltReason,
            'An empty feed read as "everyone paid" is the mass-auto-closure failure this arm prevents');
    }

    @isTest
    static void shouldHaltRowCountChange_WhenFeedDoubles() {
        // The arm a lower bound structurally cannot see: 960 clears any floor.
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW, 960, 480, NOW, 12, 100, 25);

        Assert.isFalse(verdict.isHealthy, 'A doubled feed must halt even though it clears the floor');
        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_ROW_COUNT_CHANGE, verdict.haltReason,
            'The halt reason must be Row Count Change Exceeded');
        Assert.isTrue(verdict.haltDetail.contains('100.00'),
            'The detail must state the measured change percentage');
    }

    @isTest
    static void shouldPass_WhenChangeIsInsideTolerance() {
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW, 500, 480, NOW, 12, 100, 25);

        Assert.isTrue(verdict.isHealthy, 'A 4.17% change must pass a 25% tolerance');
    }

    @isTest
    static void shouldPass_WhenThereIsNoBaseline() {
        // A first-ever run has nothing to be compared against and must not be punished for it.
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW, 500, null, NOW, 12, 100, 25);

        Assert.isTrue(verdict.isHealthy, 'No baseline must disable the change arm, not halt the run');
    }

    @isTest
    static void shouldReportStaleness_WhenBothStaleAndUndersized() {
        // Order is deliberate: a stale feed's row count tells you nothing, so reporting a row-count
        // problem would send whoever reads the audit row chasing the wrong thing.
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW.addHours(-48), 3, 480, NOW, 12, 100, 25);

        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_STALE_FEED, verdict.haltReason,
            'Staleness must win over row count - the arms are ordered, and the order is the design');
    }

    @isTest
    static void shouldTreatNullRowCountAsZero_WhenFeedCountIsMissing() {
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW, null, null, NOW, 12, 1, null);

        Assert.areEqual(ReceivablesHealthCheckDomain.REASON_ROW_COUNT_LOW, verdict.haltReason,
            'A null row count must be read as zero rows, not skipped');
    }

    @isTest
    static void shouldPass_WhenEveryArmIsUnarmed() {
        // Documents the real operational risk stated in the class header: with no THRESHOLD
        // configured, a feed that states a clock cannot be halted however small or old it is.
        // ReceivablesSyncConfig.isReady() is what stops the job running in that state.
        //
        // The fixture states a clock on purpose. The one thing an unconfigured domain CAN still
        // refuse is a feed of unknown provenance, which is pinned separately in
        // shouldHaltStale_WhenClockIsAbsentAndToleranceIsUnarmed; passing a null clock here would
        // silently re-test that instead of this.
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            NOW.addDays(-30), 0, null, null, null, null, null);

        Assert.isTrue(verdict.isHealthy,
            'With every threshold unarmed the domain cannot halt a feed that stated its own age - '
            + 'readiness is enforced elsewhere');
    }
}
