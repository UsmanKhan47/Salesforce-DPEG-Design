/**
 * Tests for `DelinquencyEscalationDomain` - the one-way escalation ladder, the correction re-arm,
 * the FSD 5.9.5 reason-to-path mapping, and the two threshold predicates.
 *
 * NO DML, NO SOQL. `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not apply: every
 * method under test takes primitives, so there is no collection and no loop for volume to exercise.
 */
@isTest
private class DelinquencyEscalationDomainTest {

    // ── The ladder ───────────────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldNotEscalate_WhenBelowSixtyDays() {
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(0, null, 59);

        Assert.areEqual(0, decision.newLevel, '59 days earns no rung');
        Assert.isFalse(decision.shouldAlert, 'No rung means no alert');
    }

    @isTest
    static void shouldEscalateToSixtyDay_WhenCrossingSixty() {
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(0, null, 60);

        Assert.areEqual(DelinquencyEscalationDomain.LEVEL_60_DAY, decision.newLevel,
            '60 days earns the first rung');
        Assert.isTrue(decision.shouldAlert, 'Crossing a rung must alert');
        Assert.areEqual(60, decision.newBasisDays,
            'The basis snapshot must record the aging the level was computed against');
    }

    @isTest
    static void shouldEscalateToNinetyDay_WhenCrossingNinety() {
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(1, 62, 91);

        Assert.areEqual(DelinquencyEscalationDomain.LEVEL_90_DAY, decision.newLevel,
            '91 days earns the second rung');
        Assert.isTrue(decision.shouldAlert, 'Crossing the second rung must alert');
        Assert.areEqual(91, decision.newBasisDays, 'The basis must move with the level');
    }

    @isTest
    static void shouldNotReFire_WhenAgingGrowsWithinTheSameRung() {
        // The single most important negative: FSD 5.9.7 says send the alert ONCE. Without this the
        // team is alerted every night for the same tenant and learns to ignore the channel.
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(2, 91, 140);

        Assert.areEqual(DelinquencyEscalationDomain.LEVEL_90_DAY, decision.newLevel,
            'Still the top rung');
        Assert.isFalse(decision.shouldAlert,
            'Growing within a rung must NOT re-fire the alert');
    }

    @isTest
    static void shouldHoldLevel_WhenNothingChangedSinceYesterday() {
        // Equal is not below. If equality re-armed, every run would re-fire every alert.
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(2, 95, 95);

        Assert.areEqual(2, decision.newLevel, 'An unchanged aging holds the level');
        Assert.isFalse(decision.shouldAlert, 'An unchanged aging must not alert');
        Assert.isFalse(decision.isRearmed, 'Equal must NOT count as a downward correction');
    }

    @isTest
    static void shouldNotDropLevel_WhenAgingIsUnknown() {
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(2, 95, null);

        Assert.areEqual(2, decision.newLevel, 'An unknown aging must hold the ladder exactly as it is');
        Assert.isFalse(decision.shouldAlert, 'An unknown aging must never alert');
        Assert.isFalse(decision.isRearmed, 'An unknown aging must never re-arm');
    }

    // ── The correction re-arm: the basis snapshot's whole reason for existing ─────────────────────

    @isTest
    static void shouldRearm_WhenYardiCorrectsAgingDownward() {
        // FSD 5.9.5's "Correct" path is a first-class scenario: a billing correction moves aging down.
        // Without the basis snapshot this Case would be permanently level 2 and never alert again.
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(2, 95, 30);

        Assert.isTrue(decision.isRearmed, 'A downward correction must re-arm the ladder');
        Assert.areEqual(0, decision.newLevel, '30 days earns no rung after the correction');
        Assert.isFalse(decision.shouldAlert, 'Re-arming is not itself an alert');
        Assert.areEqual(30, decision.newBasisDays,
            'The basis must follow the corrected number, so the NEXT correction is measured correctly');
    }

    @isTest
    static void shouldAlertAgain_WhenAgingClimbsBackAfterACorrection() {
        // The end-to-end point of the re-arm, in two steps.
        DelinquencyEscalationDomain.Decision corrected =
            DelinquencyEscalationDomain.evaluate(2, 95, 30);
        DelinquencyEscalationDomain.Decision climbed = DelinquencyEscalationDomain.evaluate(
            corrected.newLevel, corrected.newBasisDays, 61);

        Assert.isTrue(climbed.shouldAlert,
            'After a correction, genuinely falling behind again MUST alert - the silent-forever bug');
        Assert.areEqual(DelinquencyEscalationDomain.LEVEL_60_DAY, climbed.newLevel,
            'And it must land on the rung the new aging earns');
    }

    @isTest
    static void shouldTreatNullLevelAsZero_WhenCaseHasNeverEscalated() {
        DelinquencyEscalationDomain.Decision decision =
            DelinquencyEscalationDomain.evaluate(null, null, 75);

        Assert.areEqual(DelinquencyEscalationDomain.LEVEL_60_DAY, decision.newLevel,
            'A null level must be read as 0, not skipped');
        Assert.isTrue(decision.shouldAlert, 'And must still alert on its first rung');
    }

    @isTest
    static void shouldMapLevels_WhenAskedDirectly() {
        Assert.areEqual(0, DelinquencyEscalationDomain.levelFor(null), 'Null aging earns no rung');
        Assert.areEqual(0, DelinquencyEscalationDomain.levelFor(0), 'Zero earns no rung');
        Assert.areEqual(1, DelinquencyEscalationDomain.levelFor(60), '60 is the first rung boundary');
        Assert.areEqual(2, DelinquencyEscalationDomain.levelFor(90), '90 is the second rung boundary');
    }

    // ── FSD 5.9.5 reason to resolution path ──────────────────────────────────────────────────────

    @isTest
    static void shouldMapToCollect_WhenReasonIsAPaymentFailure() {
        Assert.areEqual('Collect',
            DelinquencyEscalationDomain.resolutionPathFor('Non-payment'), 'Non-payment collects');
        Assert.areEqual('Collect',
            DelinquencyEscalationDomain.resolutionPathFor('Short payment'), 'Short payment collects');
    }

    @isTest
    static void shouldMapToCorrect_WhenReasonIsABillingProblem() {
        // The mapping that matters: a billing dispute on the Collect track means chasing a tenant for
        // money DPEG should never have billed - the failure FSD 5.9.5 exists to prevent.
        Assert.areEqual('Correct',
            DelinquencyEscalationDomain.resolutionPathFor('Billing dispute'), 'Disputes are corrected');
        Assert.areEqual('Correct',
            DelinquencyEscalationDomain.resolutionPathFor('Prior-owner balance'),
            'Prior-owner balances are corrected');
    }

    @isTest
    static void shouldReturnNull_WhenReasonIsBlank() {
        Assert.isNull(DelinquencyEscalationDomain.resolutionPathFor(null),
            'A blank reason must NOT be guessed into Collect');
        Assert.isNull(DelinquencyEscalationDomain.resolutionPathFor('   '),
            'Whitespace is blank');
    }

    @isTest
    static void shouldReturnNull_WhenReasonIsUnrecognised() {
        // Also the guard against the restricted-picklist DML failure: an unmapped reason is discarded
        // rather than written, so it cannot fail an insert for a whole chunk.
        Assert.isNull(DelinquencyEscalationDomain.resolutionPathFor('Equipment Complexity'),
            'A stock support reason is not a delinquency reason and must not map');
    }

    // ── The two balance predicates ───────────────────────────────────────────────────────────────

    @isTest
    static void shouldNotTreatNullBalanceAsCleared() {
        // Null is not zero. "The feed said nothing" is not "the tenant paid", and treating it as such
        // auto-closes a live Case and destroys the follow-up trail FSD 5.9.2 protects.
        Assert.isFalse(DelinquencyEscalationDomain.isBalanceCleared(null),
            'A null balance must never auto-close a Case');
        Assert.isTrue(DelinquencyEscalationDomain.isBalanceCleared(0),
            'A stated zero balance is cleared');
        Assert.isTrue(DelinquencyEscalationDomain.isBalanceCleared(-25),
            'A credit balance is cleared');
        Assert.isFalse(DelinquencyEscalationDomain.isBalanceCleared(0.01),
            'A penny outstanding is not cleared');
    }

    @isTest
    static void shouldCrossThreshold_WhenEitherArmIsMet() {
        // The OR combination rule (OQ-1). AND would drop both classes of tenant the two thresholds
        // exist to catch separately.
        Assert.isTrue(
            DelinquencyEscalationDomain.crossesOpeningThreshold(6000, 0.5, 5000, 2),
            'A large tenant two weeks late crosses on dollars alone');
        Assert.isTrue(
            DelinquencyEscalationDomain.crossesOpeningThreshold(1200, 4, 5000, 2),
            'A small tenant four months behind crosses on months alone');
        Assert.isFalse(
            DelinquencyEscalationDomain.crossesOpeningThreshold(1200, 0.5, 5000, 2),
            'Neither arm met means no Case');
    }

    @isTest
    static void shouldIgnoreUnarmedThresholds_WhenOnlyOneIsConfigured() {
        Assert.isFalse(
            DelinquencyEscalationDomain.crossesOpeningThreshold(6000, 9, null, null),
            'With no threshold configured nothing can cross');
        Assert.isTrue(
            DelinquencyEscalationDomain.crossesOpeningThreshold(6000, null, 5000, null),
            'A null months value must not stop the dollar arm firing');
        Assert.isFalse(
            DelinquencyEscalationDomain.crossesOpeningThreshold(null, null, 5000, 2),
            'A feed that stated no balance cannot cross anything');
    }
}
