/**
 * FSD 5.9.6 STEP 5 - THE ESCALATION LADDER, and FSD 5.9.5's reason-to-path mapping. Pure decision
 * logic over primitives.
 *
 * LAYER - Domain. ZERO SOQL, ZERO DML. Every input is a parameter. The ladder is the part of this
 * feature most likely to be got subtly wrong and least likely to be noticed when it is, so it lives
 * where it can be proved exhaustively without a database.
 *
 * === THE LADDER IS `[DESIGNED - NOT SPECIFIED]` ===
 * FSD 5.9.6 step 5 and 5.9.7 both OPERATE on an escalation level and state it is "one-way - the
 * level never drops without a payment", but neither ever defines the levels. This shape mirrors the
 * proven `NdaExpiryAlertBatch` ladder, whose two load-bearing parts are reproduced here:
 *
 *   LEVEL   a MONOTONE interval marker (0 none, 1 = 60 days, 2 = 90 days). Never decremented
 *           except by the two events below. Its whole job is "this alert has already gone out".
 *   BASIS   `Escalation_Basis_Days__c`, a SNAPSHOT of the `Days_Past_Due` the level was computed
 *           against.
 *
 * === WHY THE BASIS SNAPSHOT EXISTS, AND WHY DROPPING IT IS NOT OPTIONAL ===
 * Without it, a level-2 Case is permanently level 2 and can never alert again. Here that is not a
 * hypothetical edge case, it is a FIRST-CLASS FSD SCENARIO: 5.9.5's "Correct" path exists because
 * roughly a third of DPEG's delinquency notes are billing corrections, and correcting a charge in
 * Yardi moves aging DOWNWARD. A tenant wrongly shown at 95 days, corrected to 30, then genuinely
 * falling behind again would - without the snapshot - never trigger the 60-day or 90-day alert a
 * second time. Silently.
 *
 * So the rule is: ONE-WAY, WITH EXACTLY TWO RE-ARM EVENTS.
 *   1. A CORRECTION. Current days past due is BELOW the recorded basis => Yardi moved the aging
 *      down. Reset the level to whatever the new number earns and re-arm. This is the only place the
 *      level drops without a payment, and it is not a violation of "one-way" - it is the correction
 *      of a level that was computed from a number that turned out to be wrong.
 *   2. A CLOSE. `resetOnResolution()` - the balance cleared, i.e. the payment the FSD's wording
 *      contemplates. A re-delinquenting tenant starts from level 0.
 *
 * WARNING - EQUAL IS NOT BELOW. `daysPastDue == basis` is the ordinary "nothing changed since
 * yesterday" case and must NOT re-arm, or every run would re-fire every alert.
 *
 * @see DelinquencyCaseService.cls (the only caller)
 * @see NdaExpiryService.cls       (the in-repo ladder this mirrors)
 */
public with sharing class DelinquencyEscalationDomain {

    /** No alert has fired. */
    public static final Integer LEVEL_NONE = 0;
    /** The 60-day alert has fired. */
    public static final Integer LEVEL_60_DAY = 1;
    /** The 90-day alert has fired. */
    public static final Integer LEVEL_90_DAY = 2;

    /** FSD 5.9.7 row 2. */
    public static final Integer DAYS_60 = 60;
    /** FSD 5.9.7 row 3. */
    public static final Integer DAYS_90 = 90;

    /** `Case.Resolution_Path__c` values (restricted picklist). */
    public static final String PATH_COLLECT = 'Collect';
    public static final String PATH_CORRECT = 'Correct';

    /** `Case.Reason` values on the Delinquency record type (restricted by the record type). */
    public static final String REASON_NON_PAYMENT = 'Non-payment';
    public static final String REASON_SHORT_PAYMENT = 'Short payment';
    public static final String REASON_BILLING_DISPUTE = 'Billing dispute';
    public static final String REASON_PRIOR_OWNER = 'Prior-owner balance';

    /** `Case.Dashboard_Flag__c` is a FORMULA in the org; these mirror its thresholds for alerting. */
    public class Decision {
        /** The level the Case should carry after this run. Never null. */
        public Integer newLevel;
        /** The basis to snapshot alongside it. Null only when `daysPastDue` was null. */
        public Integer newBasisDays;
        /** True when an alert must be SENT for this run (and only then may the level be stamped). */
        public Boolean shouldAlert = false;
        /** True when a downward aging correction reset the ladder. Diagnostic only. */
        public Boolean isRearmed = false;
    }

    /**
     * Decide the escalation outcome for one Case.
     *
     * @param currentLevel The Case's `Escalation_Level__c` (Number(1,0), so a `Decimal`). Null =&gt; 0.
     * @param basisDays    The Case's `Escalation_Basis_Days__c`. Null =&gt; never escalated.
     * @param daysPastDue  The mirror's current `Days_Past_Due__c`. Null =&gt; unknown; no change, no
     *                     alert. An unknown aging must never move a ladder either direction.
     * @return The decision; never null.
     * @example
     * DelinquencyEscalationDomain.Decision d =
     *     DelinquencyEscalationDomain.evaluate(1, 62, 91);   // d.newLevel = 2, d.shouldAlert = true
     */
    public static Decision evaluate(Decimal currentLevel, Decimal basisDays, Integer daysPastDue) {
        Decision decision = new Decision();
        Integer level = (currentLevel == null) ? LEVEL_NONE : currentLevel.intValue();
        decision.newLevel = level;
        decision.newBasisDays = (basisDays == null) ? null : basisDays.intValue();

        if (daysPastDue == null) {
            // Unknown aging: hold everything exactly where it is. Neither escalate nor re-arm.
            return decision;
        }

        // RE-ARM 1 of 2: Yardi corrected the aging DOWNWARD. Strictly below - equal is "no change".
        if (decision.newBasisDays != null && daysPastDue < decision.newBasisDays) {
            level = levelFor(daysPastDue);
            decision.isRearmed = true;
        }

        Integer earned = levelFor(daysPastDue);
        if (earned > level) {
            decision.newLevel = earned;
            decision.newBasisDays = daysPastDue;
            decision.shouldAlert = true;
            return decision;
        }

        decision.newLevel = level;
        // Keep the basis in step when a re-arm dropped the level, so the NEXT correction is measured
        // against the number this level was actually computed from rather than a stale higher one.
        if (decision.isRearmed) {
            decision.newBasisDays = daysPastDue;
        }
        return decision;
    }

    /**
     * The level a given aging earns, independent of history.
     *
     * @param daysPastDue Days past due; null =&gt; `LEVEL_NONE`.
     * @return 0, 1 or 2.
     */
    public static Integer levelFor(Integer daysPastDue) {
        if (daysPastDue == null) {
            return LEVEL_NONE;
        }
        if (daysPastDue >= DAYS_90) {
            return LEVEL_90_DAY;
        }
        if (daysPastDue >= DAYS_60) {
            return LEVEL_60_DAY;
        }
        return LEVEL_NONE;
    }

    /**
     * FSD 5.9.5's Case Reason to Resolution Path mapping - the SINGLE most consequential mapping in
     * this feature, because getting it wrong means chasing a tenant for money DPEG should never have
     * billed. Kept in Apex AND enforced by the live `Reason_Matches_Resolution_Path` validation rule
     * on purpose: the rule is the backstop for a human editing the Case, this is the source for the
     * sync creating one, and they must agree.
     *
     * WARNING - AN UNRECOGNISED OR BLANK REASON RETURNS NULL, AND THAT IS THE CORRECT ANSWER. See
     * `DelinquencyCaseService` for why guessing 'Collect' here would re-create the exact failure FSD
     * 5.9.5 exists to prevent. The validation rule is deliberately inert while either field is blank,
     * so a null path does not block the sync's own insert.
     *
     * @param caseReason A `Case.Reason` value, or null.
     * @return `'Collect'`, `'Correct'`, or null when the reason is blank or unrecognised.
     */
    public static String resolutionPathFor(String caseReason) {
        if (String.isBlank(caseReason)) {
            return null;
        }
        if (caseReason == REASON_NON_PAYMENT || caseReason == REASON_SHORT_PAYMENT) {
            return PATH_COLLECT;
        }
        if (caseReason == REASON_BILLING_DISPUTE || caseReason == REASON_PRIOR_OWNER) {
            return PATH_CORRECT;
        }
        return null;
    }

    /**
     * Whether a balance has cleared enough to auto-close (FSD 5.9.6 step 6).
     *
     * WARNING - NULL IS NOT ZERO HERE EITHER. A mirror row whose `Total_Outstanding_Amount__c` is
     * null means the feed did not state a balance, which is not the same claim as "the tenant owes
     * nothing" - and treating it as such would auto-close a live Case and destroy the follow-up
     * trail FSD 5.9.2 says must survive a partial sync.
     *
     * @param totalOutstanding The mirror's current total. Null =&gt; false.
     * @return True only when the feed positively states a balance at or below zero.
     */
    public static Boolean isBalanceCleared(Decimal totalOutstanding) {
        return totalOutstanding != null && totalOutstanding <= 0;
    }

    /**
     * Whether a balance crosses the configured opening threshold (FSD 5.9.6 step 4).
     *
     * === THE COMBINATION RULE IS `OR`, AND IT IS A DESIGN DECISION, NOT A READING OF THE FSD ===
     * OQ-1 records that the FSD references the opening threshold five times and never quantifies it,
     * and never says whether dollars and months-of-rent combine with AND or OR. `OR` is chosen
     * because the two thresholds catch DIFFERENT tenants and `AND` would silently drop both classes:
     * a large tenant two weeks late clears a dollar bar while nowhere near a months-of-rent bar, and
     * a small tenant four months behind is the reverse - and FSD 5.9.1 says the team reasons in
     * months of rent precisely because the second kind is the one that gets missed.
     * An unset threshold does not participate; `ReceivablesSyncConfig.isReady()` guarantees at least
     * one is set.
     *
     * @param totalOutstanding  The mirror total; null =&gt; the amount arm cannot fire.
     * @param monthsOutstanding The mirror's `Months_Outstanding__c` formula; null =&gt; the months arm
     *                          cannot fire (which is the OQ-3 case - no monthly rent, no denominator).
     * @param thresholdAmount   Configured dollar threshold, or null.
     * @param thresholdMonths   Configured months-of-rent threshold, or null.
     * @return True when either armed threshold is met or exceeded.
     */
    public static Boolean crossesOpeningThreshold(
        Decimal totalOutstanding,
        Decimal monthsOutstanding,
        Decimal thresholdAmount,
        Decimal thresholdMonths
    ) {
        Boolean byAmount = thresholdAmount != null && totalOutstanding != null
            && totalOutstanding >= thresholdAmount;
        Boolean byMonths = thresholdMonths != null && monthsOutstanding != null
            && monthsOutstanding >= thresholdMonths;
        return byAmount || byMonths;
    }
}
