/**
 * The single derivation of NDA expiry state in this application: days remaining, urgency band,
 * reminder-ladder rung, and the rule that decides whether a reminder is owed right now.
 *
 * ONE consumer renders from this class today — `NdaExpiryAlertBatch`, the daily reminder job (FSD
 * Tranche 1, Item 2 / FSD §15.2). It is a service rather than private batch logic for the same two
 * reasons `CallForOffersService` is: the intervals are the thing the FSD calls "configurable", so
 * they need exactly ONE home; and a second consumer is already plausible
 * (`OpportunityDocStatusController`'s NDA row, and the deployed
 * `Acquisitions/NDAs_Expiring_This_Month` report's Apex equivalent). If a badge ever appears, it
 * must not be able to disagree with the bell about whether an NDA is expiring.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE PURE CORE, AND WHY THE SIGNATURE IS (Date, Date)
 * ═══════════════════════════════════════════════════════════════════════════
 * `evaluate(Date expiryDate, Date asOf)` has NO SOQL and NO DML, and it never reads the clock when
 * it is given one — the clock is an ARGUMENT. That is what lets every band be reached from a test
 * with no frozen-clock hack, and what lets the batch evaluate a whole chunk against ONE `asOf`
 * rather than re-reading `Date.today()` per record (two NDAs in one chunk straddling midnight would
 * otherwise produce a run in which one is "expires today" and its neighbour is already "expired").
 *
 * ⚠ PRECISELY, and stated because the equivalent absolute in `CallForOffersService`'s header turned
 * out to be false: there are TWO executable `Date.today()` calls in this class. One is the
 * null-`asOf` guard on the first line of `evaluate(Date, Date)`, so a careless caller gets today's
 * answer instead of a `NullPointerException` inside a batch chunk; the other is the one-line
 * convenience overload `evaluate(Date)` that exists in order to read the clock. **The LADDER never
 * reads a clock** — every threshold decision is made from the two arguments, and `shouldFire` takes
 * no clock at all. That is the invariant that matters.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. THE LADDER IS {5, 2} AND IT LIVES HERE AND NOWHERE ELSE
 * ═══════════════════════════════════════════════════════════════════════════
 * `ALERT_INTERVALS` = {5, 2} — remind 5 days before expiry and again 2 days before. FSD §15.2, and
 * Gate 1 decision Q2.2: **HARDCODED, deliberately not a Custom Setting.** Three reasons:
 *   1. Custom-setting DATA is not deployable, so a config-driven ladder adds a post-deploy gate
 *      whose omission leaves the ladder empty or silently defaulted — the exact class of silent
 *      failure this whole feature is trying to avoid.
 *   2. Both existing Custom Settings in this repo (`Content_Publication_Budget__c`,
 *      `SharePoint_Config__c`) exist because `getOrgDefaults()` costs 0 SOQL on a HOT path (an
 *      after-update trigger, a per-file job). A once-daily batch has no such pressure, so the
 *      precedent's own justification does not transfer.
 *   3. An admin editing an alert ladder with no deploy and no review is the same hole
 *      `RecordStageAdvanceService` cites for keeping its stage map in Apex.
 * ⚠ COST, STATED: changing 5/2 is a one-constant code change plus a deploy. The FSD says "adjusted
 * later as needed", not "adjusted by an admin".
 *
 * ⚠ THE LIST MUST STAY DESCENDING. `intervalFor` returns the LAST entry the countdown is still
 * inside, which is only the SMALLEST such entry when the list is ordered this way.
 *
 * ⚠ THE LADDER HAS NO `0` RUNG, UNLIKE `CallForOffersService`'S {7, 3, 1, 0}, AND THAT IS
 * DELIBERATE RATHER THAN AN OMISSION. The FSD asks for two reminders — 5 days and 2 days — not
 * three. The consequence is worth naming: an NDA at 0 days, or already expired, sits in the `2`
 * rung, so an NDA whose ladder never ran gets exactly ONE catch-up reminder and then never fires
 * again (the marker is monotone). Adding a `0` rung would be a third reminder, i.e. a product
 * decision, not a tidy-up.
 *
 * ⚠ `CRITICAL_DAYS` (2) and `APPROACHING_DAYS` (5) are declared SEPARATELY and merely happen to
 * equal the two ladder entries. Nothing derives one from the other, so editing `ALERT_INTERVALS`
 * alone compiles and silently decouples any future badge from the bell.
 * `NdaExpiryServiceTest.everyRungOfTheLadderMapsToExactlyOneBand` is what couples them — it is the
 * thing that must stay green if any of the three constants moves, and the reason not to "tidy" the
 * three declarations into one.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. 🔴 THE IDEMPOTENCY RULE IS PURE TOO, AND IT IS THE HALF THAT IS EASY TO GET WRONG
 * ═══════════════════════════════════════════════════════════════════════════
 * `shouldFire(...)` is the entire marker decision, and it lives here rather than in the batch so it
 * can be falsified without running a job. TWO fields, two jobs:
 *
 *   `NDA_Alert_Last_Interval__c`  the smallest rung already notified. Fire only when the rung we
 *                                 would fire is STRICTLY SMALLER. Monotone, so a MISSED DAY CATCHES
 *                                 UP (6 days out -> 1 day out fires the "2" rung) and a DOUBLE RUN
 *                                 IS A NO-OP.
 *   `NDA_Alert_Expiry_Date__c`    the expiry date the marker was computed against. When it differs
 *                                 from the LIVE expiry the marker is treated as BLANK and the whole
 *                                 ladder RE-ARMS.
 *
 * 🔴 THE SECOND FIELD IS NOT DEFENSIVE POLISH, AND THE FAILURE IT PREVENTS IS SILENT AND
 * PERMANENT. `NDA_Expiry_Date__c` is a plain, hand-keyed Date that nothing computes — extending an
 * NDA is an ordinary edit. Without the snapshot, an extension leaves the marker armed against a
 * date that NO LONGER EXISTS: the countdown restarts, the rung goes back UP, the strictly-smaller
 * test can never pass again, and the NDA is NEVER REMINDED ABOUT AGAIN — on exactly the NDAs
 * someone cared enough about to extend. The snapshot is also what lets every other writer of the
 * expiry date stay completely ignorant of this feature: they move the date, and the re-arm falls
 * out of the comparison. Do NOT add a marker reset anywhere else.
 *
 * ⚠ AN EXPIRED NDA DOES NOT SPAM. Past the expiry `dueInterval` is 2, and once 2 is stamped the
 * strictly-smaller test can never pass again. That is the design's stated failure to avoid — "the
 * team gets the same alert every day and stops reading them".
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). ZERO SOQL and ZERO DML of any kind — this class never touches the
 * database. The reminder marker's write belongs to `NdaExpiryAlertBatch`, which owns the
 * transaction; the locator belongs to `NdaSelector`.
 *
 * @see NdaExpiryAlertBatch.cls              (the consumer, and the SCOPE inheritance)
 * @see NdaExpiryAlertSchedule.cls           (🔴 the post-deploy scheduling gate)
 * @see NdaSelector.queryExpiryAlerts        (the work queue — SYSTEM_MODE + without sharing)
 * @see CallForOffersService.cls             (the shape this copies, ladder for ladder)
 */
public with sharing class NdaExpiryService {

    /**
     * The reminder ladder: remind 5 days before expiry, and again 2 days before. FSD §15.2.
     * DESCENDING, and it must stay descending — see the class header §2. This is the ONE place
     * these numbers appear in Apex; if you find yourself writing `5` or `2` in `NdaExpiryAlertBatch`
     * or anywhere else, stop.
     *
     * ⚠ ONE OTHER PLACE CARRIES THE WIDEST RUNG AND CANNOT READ IT FROM HERE:
     * `NdaSelector.queryExpiryAlerts`'s `TODAY + 5` ceiling. A `Database.QueryLocator` cannot bind
     * an Apex collection, and a selector calling a service would invert the layering, so that number
     * is DUPLICATED KNOWLEDGE by design and is documented as such at both ends. It is a CEILING, not
     * a threshold: widening it merely costs rows the in-memory ladder then skips, and narrowing it
     * below the widest rung is the only way to break the feature. **Whoever adds a rung above 5 must
     * widen that ceiling too.**
     */
    @TestVisible
    private static final List<Integer> ALERT_INTERVALS = new List<Integer>{ 5, 2 };

    /**
     * Days out at or below which a consumer would paint the NDA red. Numerically equal to the
     * ladder's `2` rung — but ⚠ NOT DERIVED FROM IT; see the class header §2.
     */
    @TestVisible
    private static final Integer CRITICAL_DAYS = 2;

    /**
     * Days out at or below which a consumer would paint the NDA amber. Numerically equal to the
     * ladder's `5` rung, and independent of it in the same way `CRITICAL_DAYS` is.
     */
    @TestVisible
    private static final Integer APPROACHING_DAYS = 5;

    /**
     * How close one NDA is to expiring.
     *
     * ⚠ ORDER IS MEANINGFUL and is relied on by `isUrgent`: everything from `CRITICAL` onward is a
     * state a human is expected to act on today. Insert a new member in the right place or
     * `isUrgent` silently changes meaning — the `CallForOffersService.Urgency` convention.
     */
    public enum Urgency {
        /** No `NDA_Expiry_Date__c`. NOT "expires today" and not "expired" — there is no date at all. */
        NO_EXPIRY_DATE,
        /** More than 5 days out. Outside the reminder ladder entirely. */
        SCHEDULED,
        /** 3-5 days out. The "5 day" rung has fired or is about to. */
        APPROACHING,
        /** 1-2 days out. */
        CRITICAL,
        /** The NDA expires today. */
        EXPIRES_TODAY,
        /** The expiry date has passed. */
        EXPIRED
    }

    /** One NDA's computed expiry state. Every field is derived; none is stored. */
    public class NdaExpiry {
        /** `NDA__c.NDA_Expiry_Date__c` verbatim; null means `NO_EXPIRY_DATE`. */
        @AuraEnabled public Date expiryDate;
        /** Whole days from `asOf` to the expiry. NEGATIVE once expired; null with no expiry date. */
        @AuraEnabled public Integer daysRemaining;
        /** `Urgency` name — an enum cannot cross the `@AuraEnabled` boundary, so it travels as text. */
        @AuraEnabled public String urgency;
        /** Short badge label, e.g. `Expires in 2 days`. */
        @AuraEnabled public String label;
        /** One sentence saying what the state means. Never a promise that anyone was notified. */
        @AuraEnabled public String detail;
        /** True from `CRITICAL` onward — the single flag a consumer would colour off. */
        @AuraEnabled public Boolean isUrgent;
        /** False when there is no expiry date, so a caller can render that differently from "0 days". */
        @AuraEnabled public Boolean hasExpiryDate;
        /** The reminder rung this countdown sits in (5 or 2), or null above 5 days out. */
        @AuraEnabled public Integer dueInterval;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE PURE CORE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * THE PURE FUNCTION. Every NDA-expiry urgency decision in this application is made here and
     * nowhere else.
     *
     * No SOQL, no DML, and no clock READ when a clock is supplied — it is the second argument. See
     * the class header §1 for the one exception (the null-`asOf` guard on the first line).
     *
     * @param expiryDate `NDA__c.NDA_Expiry_Date__c`; null means there is no expiry at all.
     * @param asOf       The date to count from. Null is treated as `Date.today()` so a careless
     *                   caller gets today's answer rather than a `NullPointerException` inside a
     *                   batch chunk.
     * @return The computed state. Never null.
     */
    public static NdaExpiry evaluate(Date expiryDate, Date asOf) {
        Date today = (asOf == null) ? Date.today() : asOf;
        NdaExpiry e = new NdaExpiry();
        e.expiryDate = expiryDate;

        // RETURN EARLY. "No expiry" is not "expires today" and not "expired" — collapsing those is
        // how a non-expiring NDA ends up in a reminder queue it has no business being in.
        if (expiryDate == null) {
            e.urgency = Urgency.NO_EXPIRY_DATE.name();
            e.hasExpiryDate = false;
            e.isUrgent = false;
            e.label = 'No expiry date';
            e.detail = 'This NDA has no expiry date.';
            return e;
        }

        Integer days = today.daysBetween(expiryDate);
        e.hasExpiryDate = true;
        e.daysRemaining = days;
        e.dueInterval = intervalFor(days);

        if (days < 0) {
            Integer past = Math.abs(days);
            e.urgency = Urgency.EXPIRED.name();
            e.isUrgent = true;
            e.label = 'Expired ' + past + (past == 1 ? ' day ago' : ' days ago');
            e.detail = 'This NDA expired on ' + formatDate(expiryDate) + '.';
            return e;
        }
        if (days == 0) {
            e.urgency = Urgency.EXPIRES_TODAY.name();
            e.isUrgent = true;
            e.label = 'Expires today';
            e.detail = 'This NDA expires today, ' + formatDate(expiryDate) + '.';
            return e;
        }
        if (days <= CRITICAL_DAYS) {
            e.urgency = Urgency.CRITICAL.name();
            e.isUrgent = true;
            e.label = 'Expires in ' + days + (days == 1 ? ' day' : ' days');
            e.detail = 'This NDA expires on ' + formatDate(expiryDate) + '.';
            return e;
        }
        if (days <= APPROACHING_DAYS) {
            e.urgency = Urgency.APPROACHING.name();
            e.isUrgent = false;
            e.label = 'Expires in ' + days + ' days';
            e.detail = 'This NDA expires on ' + formatDate(expiryDate) + '.';
            return e;
        }

        e.urgency = Urgency.SCHEDULED.name();
        e.isUrgent = false;
        e.label = 'Expires in ' + days + ' days';
        e.detail = 'This NDA expires on ' + formatDate(expiryDate) + '.';
        return e;
    }

    /**
     * `evaluate` against today's clock. The DELIBERATELY impure entry point — see the class header
     * §1, which also gives the honest count (two `Date.today()` calls, of which this is one).
     * Deliberately NOT used by the batch, which evaluates a whole chunk against a single `asOf` so
     * two NDAs in one run can never straddle midnight.
     *
     * @param expiryDate `NDA__c.NDA_Expiry_Date__c`; null means there is no expiry.
     * @return The computed state as of today. Never null.
     */
    public static NdaExpiry evaluate(Date expiryDate) {
        return evaluate(expiryDate, Date.today());
    }

    /**
     * The reminder rung a countdown sits in: the SMALLEST configured interval the NDA is still
     * inside.
     *
     * Pure. Null above the widest rung, so an NDA 30 days out is not "in the 5-day window".
     *
     * @param daysRemaining Whole days to the expiry; negative once expired.
     * @return 5, 2 or null.
     */
    @TestVisible
    private static Integer intervalFor(Integer daysRemaining) {
        if (daysRemaining == null) {
            return null;
        }
        Integer chosen = null;
        for (Integer interval : ALERT_INTERVALS) {
            if (daysRemaining <= interval) {
                chosen = interval;
            }
        }
        return chosen;
    }

    /**
     * 🔴 THE IDEMPOTENCY DECISION. Should the reminder job notify for this NDA right now?
     *
     * Pure — no SOQL, no DML, no clock. See the class header §3 for what each field does and why
     * the second one exists at all.
     *
     * @param dueInterval  The rung this NDA currently sits in (`NdaExpiry.dueInterval`); null means
     *                     it is outside the ladder and nothing fires.
     * @param lastInterval `NDA_Alert_Last_Interval__c`; null means nothing has fired yet.
     * @param liveExpiry   The NDA's CURRENT `NDA_Expiry_Date__c`.
     * @param markerExpiry `NDA_Alert_Expiry_Date__c` — the expiry the marker was computed against.
     * @return True when a reminder is owed.
     */
    public static Boolean shouldFire(
        Integer dueInterval,
        Integer lastInterval,
        Date liveExpiry,
        Date markerExpiry
    ) {
        if (dueInterval == null) {
            return false;
        }
        // AN EXPIRY THAT MOVED RE-ARMS EVERYTHING. `==` on Date is null-safe in Apex, so a
        // never-reminded NDA (both null, or a marker date against a real live date) also lands here
        // and fires. The anomalous shape — an interval stamped with no snapshot — deliberately
        // re-arms too: an extra reminder is recoverable, a permanently silent NDA is not.
        Integer effective = (markerExpiry == liveExpiry) ? lastInterval : null;
        return effective == null || dueInterval < effective;
    }

    /** Month abbreviations. See `formatDate` for why this is not `DateTime.format`. */
    private static final List<String> MONTHS = new List<String>{
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    /**
     * `Aug 20, 2026` — the one date format every consumer of this class shares, so a future badge
     * and the notification body cannot render the same expiry two ways.
     *
     * ⚠ DELIBERATELY NOT `DateTime.format('MMM d, yyyy')`. That renders in the RUNNING USER's
     * locale and time zone, so the same date reads differently for two people looking at one NDA,
     * and any test asserting the string is silently locale-dependent — green on this machine, red
     * on a CI box with a different default. This is a fixed, asserted format.
     *
     * @param value The date to render; null-safe.
     * @return The formatted date, or an em dash.
     */
    @TestVisible
    private static String formatDate(Date value) {
        if (value == null) {
            return '—';
        }
        return MONTHS[value.month() - 1] + ' ' + value.day() + ', ' + value.year();
    }
}
