/**
 * FSD 5.9.6 STEP 2 - THE HALT RULE. Decides, from four numbers and no side effects, whether a feed
 * is trustworthy enough to act on.
 *
 * LAYER - Domain. ZERO SOQL, ZERO DML, zero platform state. Every input is a parameter, including
 * `now`, so the whole rule is testable at any point in time without freezing a clock. That purity is
 * why the halt rule can be proved exhaustively in milliseconds instead of through a batch run.
 *
 * === WHY THIS IS THE MOST IMPORTANT CLASS IN THE FEATURE ===
 * FSD 5.9.6 is explicit that a suspect feed must HALT rather than escalate. The failure it prevents
 * is not "a wrong number on a dashboard": it is a Yardi export that truncated overnight, read as
 * "every tenant paid", auto-closing live delinquency Cases and destroying the follow-up trail - or
 * the mirror image, a duplicated export read as balances doubling, emailing principals about
 * tenants who owe nothing. Both are silent. Both are hard to unwind. The halt is what makes them
 * unreachable.
 *
 * === THE THREE ARMS, AND WHY EACH IS NECESSARY ===
 *  1. STALE FEED - measured against the FEED's own `feedAsOf`, never Salesforce's clock. A feed
 *     three days old but fetched two minutes ago is stale. A NULL clock is stale too: a feed that
 *     will not state its own age cannot be proven fresh, and this rule exists precisely to refuse
 *     data of unknown provenance. 🔴 THE NULL-CLOCK HALF IS UNCONDITIONAL - see below.
 *  2. ROW COUNT BELOW MINIMUM - catches truncation and empty exports. The lower bound is the arm
 *     that stops mass auto-closure.
 *  3. ROW COUNT CHANGE EXCEEDED - catches a feed that DOUBLED, which a lower bound structurally
 *     cannot see. Compared against the previous COMPLETED run, so a string of halted runs does not
 *     drag the baseline with it.
 *
 * === EVERY *THRESHOLD COMPARISON* IS DISABLE-ABLE BY LEAVING ITS CONFIG NULL. THE NULL-CLOCK
 *     REFUSAL IS NOT. ===
 * A null threshold disables its comparison rather than defaulting to something. This is the honest
 * behaviour for a rule whose numbers nobody has yet chosen (OQ-2): a made-up tolerance either halts
 * every night or never halts, and both read as "the rule is broken" rather than "the rule is
 * unconfigured".
 *
 * 🔴 THE ONE EXCEPTION, ADDED 2026-08-22, AND IT IS A SAFETY FIX RATHER THAN A REFINEMENT: an ABSENT
 * `feedAsOf` halts unconditionally, whatever the config says. A tolerance answers "how old is too
 * old" and structurally cannot answer "how old is this?". Making the refusal of an unstated clock
 * depend on an OPTIONAL Setup value meant that a blank `Staleness_Tolerance_Hours__c` - the default,
 * and not required by `ReceivablesSyncConfig.isReady()` - turned an unreachable ASB bus into a
 * HEALTHY verdict, because every fetch failure arrives here as `rows = []` with `feedAsOf = null`.
 * An empty feed is indistinguishable from "every tenant paid in full", so FSD 5.9.6 step 6 would
 * have auto-closed every open delinquency Case in the org. That is the precise outcome the halt rule
 * exists to make unreachable, so it must not be switch-off-able by omission.
 *
 * WARNING - with all three thresholds null this method still cannot halt a feed that DID state a
 * clock. That remains a real operational risk, and it is why `ReceivablesSyncConfig.isReady()`
 * refuses to run at all without at least an opening threshold, and why `Sync_Run__c` records which
 * arms were armed.
 *
 * @see ReceivablesSyncService.cls (the only caller)
 * @see Sync_Run__c.Halt_Reason__c (the picklist whose values this class returns verbatim)
 */
public with sharing class ReceivablesHealthCheckDomain {

    /** `Sync_Run__c.Halt_Reason__c` values. Restricted picklist - these strings must match exactly. */
    public static final String REASON_NONE = 'None';
    public static final String REASON_STALE_FEED = 'Stale Feed';
    public static final String REASON_ROW_COUNT_LOW = 'Row Count Below Minimum';
    public static final String REASON_ROW_COUNT_CHANGE = 'Row Count Change Exceeded';

    /** The answer: healthy, or a halt with a reason and a human-readable detail. */
    public class Verdict {
        /** True when every armed check passed. */
        public Boolean isHealthy = true;
        /** A `Sync_Run__c.Halt_Reason__c` value; `'None'` when healthy. */
        public String haltReason = REASON_NONE;
        /** Detail for `Sync_Run__c.Halt_Detail__c`; null when healthy. */
        public String haltDetail;
    }

    /**
     * Evaluate one feed against the configured tolerances.
     *
     * Arms are evaluated in the order stale, then floor, then change, and the FIRST failure wins. The
     * order is deliberate rather than incidental: a stale feed's row count tells you nothing, so
     * reporting a row-count problem on a feed that is simply old would send whoever reads the audit
     * row chasing the wrong thing.
     *
     * @param feedAsOf                 The feed's own as-of timestamp. NULL IS TREATED AS STALE
     *                                 UNCONDITIONALLY - `stalenessToleranceHours` does not gate it.
     * @param rowCount                 Rows in the feed after normalization. Null is treated as 0.
     * @param previousRowCount         Row count of the previous COMPLETED run, or null when there is
     *                                 no baseline (first-ever run). No baseline disables arm 3 -
     *                                 a first run cannot be compared to anything and must not halt
     *                                 for it.
     * @param now                      The moment to measure staleness against. Passed in so the rule
     *                                 is deterministic in tests.
     * @param stalenessToleranceHours  Arm 1's AGE COMPARISON tolerance; null disables that
     *                                 comparison only. It never disables the null-clock refusal.
     * @param minimumRowCount          Arm 2 floor; null disables arm 2.
     * @param maximumRowCountChangePct Arm 3 tolerance as a percentage; null disables arm 3.
     * @return A verdict; never null.
     * @example
     * ReceivablesHealthCheckDomain.Verdict v = ReceivablesHealthCheckDomain.evaluate(
     *     feed.feedAsOf, feed.rows.size(), 480, System.now(), 12, 100, 25);
     */
    public static Verdict evaluate(
        DateTime feedAsOf,
        Integer rowCount,
        Decimal previousRowCount,
        DateTime now,
        Integer stalenessToleranceHours,
        Integer minimumRowCount,
        Decimal maximumRowCountChangePct
    ) {
        Verdict verdict = new Verdict();
        Integer rows = (rowCount == null) ? 0 : rowCount;
        DateTime reference = (now == null) ? System.now() : now;

        // ── ARM 1a: NO CLOCK AT ALL. UNCONDITIONAL - IT IS NOT GOVERNED BY THE TOLERANCE. ───────
        // A tolerance answers "how old is too old". It cannot answer "how old is this?", so a feed
        // that states no as-of time is not a lenient case of the same question - it is a DIFFERENT
        // question, and the only safe answer is refusal. Nesting this inside the tolerance gate (as
        // it was until 2026-08-22) made the halt rule dependent on an unrelated, OPTIONAL config
        // value, and that is the shape of a real disaster rather than a tidiness point:
        // `AsbReceivablesFeedProvider` converts EVERY fetch failure - refused credential, 500 from
        // the bus, truncated body, malformed payload - into `rows = []` with `feedAsOf = null`. With
        // `Staleness_Tolerance_Hours__c` left blank in Setup (its default, and not required by
        // `ReceivablesSyncConfig.isReady()`), an unreachable bus was reported HEALTHY, the lifecycle
        // ran against an empty feed, and FSD 5.9.6 step 6 read "no balance" as "everyone paid" -
        // auto-closing every open delinquency Case in the org and destroying the follow-up trail
        // FSD 5.9.2 says must survive a partial sync. Caught by
        // `ReceivablesSyncPipelineTest.shouldHaltCalloutFailure_WhenAsbProviderCannotReachTheBus`.
        if (feedAsOf == null) {
            return halt(verdict, REASON_STALE_FEED,
                'The feed did not state its own as-of timestamp, so its age cannot be established. '
                + 'A feed of unknown provenance is treated as stale. This halt is unconditional and '
                + 'is NOT disabled by leaving Staleness_Tolerance_Hours__c unset - a fetch that '
                + 'failed outright also arrives with no clock, and reading it as healthy would '
                + 'auto-close live Cases against an empty feed.');
        }

        // ── ARM 1b: staleness, against the FEED's clock. Armed only when a tolerance is set. ────
        if (stalenessToleranceHours != null) {
            Long ageMinutes = (reference.getTime() - feedAsOf.getTime()) / (1000L * 60L);
            Long toleranceMinutes = (Long) stalenessToleranceHours * 60L;
            if (ageMinutes > toleranceMinutes) {
                return halt(verdict, REASON_STALE_FEED,
                    'Feed as-of ' + feedAsOf.formatGmt('yyyy-MM-dd HH:mm:ss') + 'Z is ' + ageMinutes
                    + ' minutes old, beyond the configured tolerance of ' + toleranceMinutes + ' minutes ('
                    + stalenessToleranceHours + 'h).');
            }
        }

        // ── ARM 2: absolute floor - catches truncation and empty exports ────────────────────────
        if (minimumRowCount != null && rows < minimumRowCount) {
            return halt(verdict, REASON_ROW_COUNT_LOW,
                'Feed returned ' + rows + ' rows, below the configured minimum of ' + minimumRowCount
                + '. A truncated feed read as "everyone paid" would auto-close live delinquency Cases.');
        }

        // ── ARM 3: change versus the previous COMPLETED run - catches a doubled feed ────────────
        if (maximumRowCountChangePct != null && previousRowCount != null && previousRowCount > 0) {
            Decimal changePct = Decimal.valueOf(Math.abs(rows - previousRowCount.intValue()))
                .divide(previousRowCount, 4) * 100;
            if (changePct > maximumRowCountChangePct) {
                return halt(verdict, REASON_ROW_COUNT_CHANGE,
                    'Feed returned ' + rows + ' rows versus ' + previousRowCount.intValue()
                    + ' on the previous completed run - a change of ' + changePct.setScale(2)
                    + '%, beyond the configured tolerance of ' + maximumRowCountChangePct + '%.');
            }
        }

        return verdict;
    }

    /**
     * @param verdict The verdict to mark.
     * @param reason  A `Halt_Reason__c` picklist value.
     * @param detail  Human-readable explanation for `Halt_Detail__c`.
     * @return The same verdict, marked unhealthy.
     */
    private static Verdict halt(Verdict verdict, String reason, String detail) {
        verdict.isHealthy = false;
        verdict.haltReason = reason;
        verdict.haltDetail = detail;
        return verdict;
    }
}
