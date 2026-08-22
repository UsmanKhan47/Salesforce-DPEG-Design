/**
 * Tests for `ReceivablesSyncConfig`.
 *
 * The highest-value assertion here is `shouldCostZeroSoql_WhenReadingSettings`: the hierarchy custom
 * setting was chosen over Custom Metadata (design GATE-4, user decision D-AR-6) SPECIFICALLY because
 * `getOrgDefaults()` is a platform cache read, and this feature consults it inside a queueable and a
 * batch. If that ever stops being true the choice was wrong and the test is what says so.
 *
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not apply: there is one org-default row
 * by definition, and no collection anywhere in the class.
 */
@isTest
private class ReceivablesSyncConfigTest {

    @isTest
    static void shouldCostZeroSoql_WhenReadingSettings() {
        ReceivablesTestData.config(true, 'StubReceivablesFeedProvider', 5000, 2);

        Test.startTest();
        Integer before = Limits.getQueries();
        ReceivablesSyncConfig.isReady();
        ReceivablesSyncConfig.providerClassName();
        ReceivablesSyncConfig.openingThresholdAmount();
        ReceivablesSyncConfig.stalenessToleranceHours();
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, spent,
            'getOrgDefaults() must cost ZERO SOQL - a platform cache read is the whole reason a '
            + 'hierarchy custom setting was chosen over Custom Metadata for a batch-hot path');
    }

    @isTest
    static void shouldNotBeReady_WhenNoRowHasEverBeenCreated() {
        // getOrgDefaults() returns an EMPTY INSTANCE rather than null, which is why isReady() tests
        // field values and not the reference. This is the un-run post-deploy gate.
        Assert.isFalse(ReceivablesSyncConfig.isReady(),
            'With no config row the feature must refuse to run');
        Assert.areEqual('Disabled', ReceivablesSyncConfig.unavailableReason(),
            'An absent row reads as disabled, not as a missing configuration');
    }

    @isTest
    static void shouldNotBeReady_WhenExplicitlyDisabled() {
        ReceivablesTestData.config(false, 'StubReceivablesFeedProvider', 5000, 2);

        Assert.isFalse(ReceivablesSyncConfig.isReady(), 'A disabled feature must not run');
        Assert.areEqual('Disabled', ReceivablesSyncConfig.unavailableReason(),
            'A deliberate switch-off must be distinguishable from a broken configuration');
    }

    @isTest
    static void shouldReportConfigMissing_WhenProviderIsBlank() {
        ReceivablesTestData.config(true, null, 5000, 2);

        Assert.isFalse(ReceivablesSyncConfig.isReady(), 'No provider means nothing can run');
        Assert.areEqual('Config Missing', ReceivablesSyncConfig.unavailableReason(),
            'An enabled feature with no provider is a forgotten post-deploy gate, not a pause');
    }

    @isTest
    static void shouldReportConfigMissing_WhenNeitherThresholdIsSet() {
        // The subtle one this guard exists for: without a threshold the job would upsert the mirror,
        // run the whole lifecycle, open nothing, and report a perfectly healthy run every night.
        ReceivablesTestData.config(true, 'StubReceivablesFeedProvider', null, null);

        Assert.isFalse(ReceivablesSyncConfig.isReady(),
            'A run that can never open a Case is inert and must not be treated as healthy');
        Assert.areEqual('Config Missing', ReceivablesSyncConfig.unavailableReason(),
            'A missing threshold is a configuration gap');
    }

    @isTest
    static void shouldBeReady_WhenOnlyOneThresholdIsSet() {
        ReceivablesTestData.config(true, 'StubReceivablesFeedProvider', null, 2);

        Assert.isTrue(ReceivablesSyncConfig.isReady(),
            'Either threshold alone is enough - the arms are independent by design');
        Assert.areEqual('None', ReceivablesSyncConfig.unavailableReason(),
            'A ready configuration reports no unavailability reason');
    }

    @isTest
    static void shouldReturnNull_WhenOptionalValuesAreUnset() {
        ReceivablesTestData.config(true, 'StubReceivablesFeedProvider', 5000, null);

        Assert.isNull(ReceivablesSyncConfig.stalenessToleranceHours(),
            'An unset tolerance must be null - a hardcoded default would either halt every night or '
            + 'never halt, and both read as a broken rule');
        Assert.isNull(ReceivablesSyncConfig.minimumRowCount(), 'Unset floor must be null');
        Assert.isNull(ReceivablesSyncConfig.maximumRowCountChangePct(), 'Unset tolerance must be null');
        Assert.isNull(ReceivablesSyncConfig.staleFollowUpDays(),
            'Unset stale-follow-up days must be null, NOT the FSD default of 7');
        Assert.isNull(ReceivablesSyncConfig.openingThresholdMonths(), 'Unset months must be null');
    }

    @isTest
    static void shouldReturnConfiguredValues_WhenEveryFieldIsSet() {
        ReceivablesTestData.configWithHealthArms(12, 100, 25, 7);

        Assert.areEqual('StubReceivablesFeedProvider', ReceivablesSyncConfig.providerClassName(),
            'Provider name must round-trip');
        Assert.areEqual(1000, ReceivablesSyncConfig.openingThresholdAmount(), 'Amount must round-trip');
        Assert.areEqual(12, ReceivablesSyncConfig.stalenessToleranceHours(),
            'Number(x,0) arrives as Decimal and must be cast to Integer exactly once, here');
        Assert.areEqual(100, ReceivablesSyncConfig.minimumRowCount(), 'Floor must round-trip');
        Assert.areEqual(25, ReceivablesSyncConfig.maximumRowCountChangePct(),
            'Change tolerance must round-trip');
        Assert.areEqual(7, ReceivablesSyncConfig.staleFollowUpDays(),
            'Stale-follow-up days must round-trip');
    }
}
