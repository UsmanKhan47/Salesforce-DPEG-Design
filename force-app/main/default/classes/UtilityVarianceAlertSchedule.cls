/**
 * The trigger for `UtilityVarianceAlertBatch` - the daily FSD 5.10.2 utility variance alert.
 *
 * === 🔴 SCHEDULING THIS IS A POST-DEPLOY GATE AND MISSING IT FAILS COMPLETELY SILENTLY ===
 * A scheduled-job INSTANCE is not deployable metadata. A deploy that skips this step leaves
 * the class present, compiled, tested, covered and utterly inert: zero alerts, zero errors,
 * zero failed `AsyncApexJob` rows, and a feature that looks shipped from every angle a
 * deploy log or a test run can see.
 *
 *   System.schedule('DPEG Utility Variance Alert', '0 0 7 * * ?',
 *                   new UtilityVarianceAlertSchedule());
 *
 * The 7am daily cadence matches `CallForOffersAlertSchedule` and puts the alert in front of
 * the team at the start of the day it is about. It also matches the batch's default 1-day
 * look-back, and THOSE TWO NUMBERS ARE COUPLED: schedule it less often than daily and bills
 * modified in the gap are never alerted at all, because the look-back is what replaces an
 * idempotency marker field here. If the cadence changes, the batch's `lookbackDays` must
 * change with it - use the three-argument constructor rather than editing a default.
 *
 * === WHO OWNS THE SCHEDULE MATTERS HERE, AND THAT IS ALREADY HANDLED ===
 * The job runs as the scheduling user. `Meter__c` is Private OWD and `Utility_Bill__c` is
 * ControlledByParent, so a principal who owns no meters would sweep an empty set. That is
 * why `UtilityBillSelector.queryVarianceSweep` runs inside a `private without sharing` inner
 * class - the owner is therefore genuinely free, and this note exists so nobody "tidies"
 * that inner class away on the assumption that SYSTEM_MODE covered it. It does not; it never
 * lifts sharing.
 *
 * === THE OTHER GO-LIVE GATE ===
 * `DPEG_Property_Mgmt_Team` is EMPTY (0 members, measured on `usman-dpeg` 2026-08-22) and
 * `Group` metadata never carries members, so membership cannot be deployed. An empty group
 * means the alert reaches nobody and `GroupNotifier` degrades that to a debug warning.
 * Populating it is a manual checklist item, not an assumption.
 *
 * No parameters are taken here. The thresholds are an OPEN QUESTION (user decision D-UM-8);
 * when they are answered, schedule a configured batch instead:
 *
 *   System.schedule('DPEG Utility Variance Alert', '0 0 7 * * ?',
 *                   new UtilityVarianceAlertSchedule(500, 15, 1));
 */
public with sharing class UtilityVarianceAlertSchedule implements Schedulable {

    /** Scope size. 200 is the platform default and nothing here is CPU- or callout-bound. */
    private static final Integer SCOPE = 200;

    private final Decimal minAbsAmount;
    private final Decimal minAbsPct;
    private final Integer lookbackDays;

    /** Schedules the batch on its assumed default thresholds. */
    public UtilityVarianceAlertSchedule() {
        this(null, null, null);
    }

    /**
     * Schedules the batch on confirmed thresholds.
     *
     * @param minAbsAmount Minimum absolute dollar variance; null uses the batch default.
     * @param minAbsPct    Minimum absolute percentage variance; null uses the batch default.
     * @param lookbackDays Days of modification history swept; null uses the batch default.
     *                     Keep this consistent with the cron cadence - see the class header.
     */
    public UtilityVarianceAlertSchedule(Decimal minAbsAmount, Decimal minAbsPct,
            Integer lookbackDays) {
        this.minAbsAmount = minAbsAmount;
        this.minAbsPct = minAbsPct;
        this.lookbackDays = lookbackDays;
    }

    /** Fired by the platform on the cron schedule. */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(
            new UtilityVarianceAlertBatch(minAbsAmount, minAbsPct, lookbackDays), SCOPE);
    }
}
