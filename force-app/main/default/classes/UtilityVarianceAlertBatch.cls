/**
 * The FSD 5.10.2 variance alert: "Before triggering any alert, the system will calculate the
 * variance and break it down into usage and rate components."
 *
 * ============================================================================
 * 🔴 THE THRESHOLD, THE RECIPIENT AND THE CHANNEL BELOW ARE AN ASSUMPTION, NOT A SPEC
 * ============================================================================
 * FSD 5.10 promises variance-triggered alerts in 5.10.2 and is the ONLY functional area in
 * the whole document with no "Automation & Alerts" subsection. It never states a threshold,
 * a recipient, a channel or a cadence. User decision D-UM-8 explicitly keeps that question
 * OPEN rather than letting it be silently defaulted.
 *
 * So: the MECHANISM here is built and proven; the four NUMBERS are a defensible default that
 * must be confirmed before go-live. They are constructor parameters, not constants, so
 * confirming them is a re-schedule and not a code change.
 *
 *   assumed threshold  |Total Variance| >= $250 AND |% variance| >= 20%
 *                      BOTH, deliberately. Amount alone spams on every large property;
 *                      percentage alone spams on every small bill (a $12 water bill going to
 *                      $30 is +150% and nobody cares). Requiring both is what keeps the list
 *                      short enough to be read, which is the actual failure mode of an alert
 *                      feature.
 *   assumed recipient  the `DPEG_Property_Mgmt_Team` public group.
 *   assumed channel    in-app custom notification under the `Property_Mgmt_Update` type,
 *                      via `GroupNotifier`. There is ZERO Apex outbound email in this org -
 *                      if email is wanted, that is a different build, not a parameter.
 *   assumed cadence    daily, with a 1-day look-back. See the idempotency note.
 *
 * ============================================================================
 * WHY A BATCH AND NOT A TRIGGER
 * ============================================================================
 * A monthly bill import inserts hundreds of bills in one transaction. A trigger-fired alert
 * would emit hundreds of notifications inside that load, at the moment the bills exist but
 * their CHARGE LINES DO NOT - so `Total_Charges_Amount__c` is still 0 and every variance
 * reads as a total collapse. The alert has to run after the data has settled. That is not a
 * preference; a trigger-based version of this feature is simply wrong.
 *
 * ============================================================================
 * IDEMPOTENCY WITHOUT A MARKER FIELD - READ THIS BEFORE "FIXING" THE LOOK-BACK
 * ============================================================================
 * The house pattern for an alert job on this project (`NdaExpiryAlertBatch`,
 * `CallForOffersAlertBatch`) is send-then-stamp against a marker field. This job has NO
 * marker field, because this build was scoped to add no fields, and the design's proposed
 * `Variance_Alert_Sent_DateTime__c` was therefore not created.
 *
 * The look-back window replaces it: the locator only considers bills whose
 * `LastModifiedDate` is within `lookbackDays`. A bill that has been sitting untouched since
 * last month is not re-alerted, however far out of line its variance is. A bill EDITED today
 * is alerted today - which is the behaviour you want anyway, since an edit can change the
 * variance. Adding a charge line updates the parent's roll-up and therefore its
 * `LastModifiedDate`, so a bill becomes eligible exactly when it becomes complete.
 *
 * The residual, stated plainly: a bill edited on three consecutive days alerts three times.
 * A marker field would suppress that. If that turns out to matter, add
 * `Variance_Alert_Sent_DateTime__c` and switch to send-first-stamp-second using
 * `GroupNotifier.notifyWithOutcome` (which exists precisely so a stamp only follows a
 * SUCCESSFUL send) - the rest of this class is unchanged by that.
 *
 * ============================================================================
 * SHARING AND SCHEDULING
 * ============================================================================
 * The locator lives in `UtilityBillSelector.queryVarianceSweep`, inside a narrow
 * `private without sharing` inner class. That is not incidental: this batch runs as whoever
 * SCHEDULED it, `Meter__c` is Private OWD and `Utility_Bill__c` is ControlledByParent, and
 * `SYSTEM_MODE` lifts CRUD/FLS but NEVER sharing. A scheduling principal who owns no meters
 * would otherwise get an empty locator and a `finish()` summary of all zeros -
 * indistinguishable from a quiet month. A monitoring job that silently monitors nothing is
 * the worst possible failure for this feature.
 *
 * 🔴 GO-LIVE GATE, NON-DEPLOYABLE, FAILS SILENTLY IF MISSED - TWO ITEMS:
 *   1. SCHEDULE IT. A scheduled-job instance is not metadata. Unscheduled, this class is
 *      present, compiled, covered and completely inert, with no failed `AsyncApexJob` row to
 *      find:
 *        System.schedule('DPEG Utility Variance Alert', '0 0 7 * * ?',
 *                        new UtilityVarianceAlertSchedule());
 *   2. POPULATE `DPEG_Property_Mgmt_Team`. `Group` metadata never carries members, and the
 *      group is EMPTY in `usman-dpeg` today (measured 2026-08-22, 0 GroupMember rows).
 *      `GroupNotifier` degrades an empty group to the group's own Id - proven for QUEUES,
 *      unproven for a Regular group - and degrades every failure to a debug warning. So an
 *      unpopulated group means the alert goes nowhere and says nothing.
 *
 * `Database.Stateful` is used ONLY to carry the three counters into `finish()`.
 */
public with sharing class UtilityVarianceAlertBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    /** ASSUMED. Minimum absolute dollar change. See the class header. */
    @TestVisible
    private static final Decimal DEFAULT_MIN_ABS_AMOUNT = 250;
    /** ASSUMED. Minimum absolute percentage change, on a human scale (20 means 20%). */
    @TestVisible
    private static final Decimal DEFAULT_MIN_ABS_PCT = 20;
    /** ASSUMED. Days of `LastModifiedDate` history the sweep considers. */
    @TestVisible
    private static final Integer DEFAULT_LOOKBACK_DAYS = 1;
    /** ASSUMED. Recipient public group. */
    @TestVisible
    private static final String RECIPIENT_GROUP = 'DPEG_Property_Mgmt_Team';
    /**
     * The Property Management notification type. NOT the `GroupNotifier` default, which is
     * `Acquisitions_Deal_Update` - a PM alert arriving branded as an Acquisitions
     * notification is not cosmetic, because a user's notification settings are per TYPE, so
     * PM alerts would be un-muteable independently of acquisitions ones.
     */
    @TestVisible
    private static final String NOTIFICATION_TYPE = 'Property_Mgmt_Update';

    private final Decimal minAbsAmount;
    private final Decimal minAbsPct;
    private final Integer lookbackDays;

    /** Bills examined. */
    public Integer scanned = 0;
    /** Bills that cleared BOTH thresholds. */
    public Integer flagged = 0;
    /** Notifications `GroupNotifier` confirmed it sent. */
    public Integer notified = 0;

    /** Production entry point: the assumed defaults above. */
    public UtilityVarianceAlertBatch() {
        this(DEFAULT_MIN_ABS_AMOUNT, DEFAULT_MIN_ABS_PCT, DEFAULT_LOOKBACK_DAYS);
    }

    /**
     * Configured entry point. This is how the open threshold question gets ANSWERED without
     * a code change - re-schedule with different numbers.
     *
     * @param minAbsAmount Minimum absolute dollar variance; null falls back to the default.
     * @param minAbsPct    Minimum absolute percentage variance (20 means 20%); null falls
     *                     back to the default.
     * @param lookbackDays Days of modification history to sweep; null or &lt; 1 becomes 1.
     */
    public UtilityVarianceAlertBatch(Decimal minAbsAmount, Decimal minAbsPct,
            Integer lookbackDays) {
        this.minAbsAmount = (minAbsAmount == null) ? DEFAULT_MIN_ABS_AMOUNT : minAbsAmount;
        this.minAbsPct = (minAbsPct == null) ? DEFAULT_MIN_ABS_PCT : minAbsPct;
        this.lookbackDays = (lookbackDays == null || lookbackDays < 1)
            ? DEFAULT_LOOKBACK_DAYS
            : lookbackDays;
    }

    /**
     * Bills with a prior bill, modified inside the look-back window.
     *
     * The threshold is NOT in the WHERE clause: the variance fields are cross-object
     * formulas, so filtering on them is non-selective and would scan the whole object every
     * run. `LastModifiedDate` is indexed.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return UtilityBillSelector.queryVarianceSweep(
            Datetime.now().addDays(-lookbackDays));
    }

    /**
     * Applies both thresholds and sends one notification per qualifying bill.
     *
     * ONE `GroupNotifier.notify` call per scope chunk, never one per bill. `GroupNotifier`'s
     * own header records the measured cost of a looping caller: 9 queries per record, 1,800
     * for a 200-record chunk. Building the request list and calling once is the difference
     * between 3 queries and 600.
     *
     * The percentage is read from `Total_Variance_Pct__c`, the same field the record page
     * and the register show, so a bill that reads +25% on screen is the one this threshold
     * fires on. The field is null when the prior total is zero, and `qualifies` fails
     * closed on that null rather than treating an undefined change as a large one.
     */
    public void execute(Database.BatchableContext ctx, List<Utility_Bill__c> scope) {
        List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();
        for (Utility_Bill__c bill : scope) {
            scanned++;
            Decimal amount = bill.Total_Variance_Amount__c;
            Decimal pct = bill.Total_Variance_Pct__c;
            if (!qualifies(amount, pct)) {
                continue;
            }
            flagged++;
            requests.add(buildRequest(bill, amount, pct));
        }
        if (requests.isEmpty()) {
            return;
        }
        for (Boolean sent : GroupNotifier.notifyWithOutcome(requests)) {
            if (sent == true) {
                notified++;
            }
        }
    }

    /**
     * BOTH thresholds must be met. A null on either side fails closed - an undefined
     * percentage (prior total of zero) is exactly the case where a fabricated number would
     * page somebody for nothing.
     */
    @TestVisible
    private Boolean qualifies(Decimal amount, Decimal pct) {
        if (amount == null || pct == null) {
            return false;
        }
        return Math.abs(amount) >= minAbsAmount && Math.abs(pct) >= minAbsPct;
    }

    /**
     * The notification body carries the DECOMPOSITION, not just the total - that is the
     * entire point of FSD 5.10.2 ("break it down into usage and rate components"). A reader
     * has to be able to tell "we used more" from "they charged more" without opening the
     * record, because those two have completely different responses.
     */
    private GroupNotifier.Request buildRequest(Utility_Bill__c bill, Decimal amount, Decimal pct) {
        String meterLabel = (bill.Meter__r == null)
            ? 'meter'
            : String.valueOf(bill.Meter__r.Utility_Type__c) + ' meter '
                + String.valueOf(bill.Meter__r.Meter_Number__c);
        String property = (bill.Meter__r == null || bill.Meter__r.Property_Asset__r == null)
            ? 'a property'
            : bill.Meter__r.Property_Asset__r.Property_Name__c;

        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = RECIPIENT_GROUP;
        r.notificationType = NOTIFICATION_TYPE;
        r.targetRecordId = bill.Id;
        r.title = 'Utility variance: ' + property;
        r.body = meterLabel + ' moved ' + money(amount) + ' (' + pct.setScale(0) + '%). '
            + 'Usage ' + money(bill.Usage_Variance_Amount__c)
            + ', rate ' + money(bill.Rate_Variance_Amount__c) + '.';
        return r;
    }

    /** Signed dollar figure, whole dollars - the body is a headline, not a ledger. */
    private static String money(Decimal value) {
        if (value == null) {
            return 'n/a';
        }
        Decimal rounded = value.setScale(0, System.RoundingMode.HALF_UP);
        return (rounded >= 0 ? '+$' : '-$') + String.valueOf(Math.abs(rounded));
    }

    /**
     * Logs a summary. There is nothing to write and nothing to chain, so this is the only
     * evidence a run happened at all.
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO, 'UtilityVarianceAlertBatch: scanned=' + scanned
            + ' flagged=' + flagged + ' notified=' + notified
            + ' (minAbsAmount=' + minAbsAmount + ' minAbsPct=' + minAbsPct
            + ' lookbackDays=' + lookbackDays + ')');
    }
}
