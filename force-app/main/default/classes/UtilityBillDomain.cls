/**
 * Domain rules for `Utility_Bill__c`. PURE: zero SOQL, zero DML, zero callouts, per
 * `.claude/rules/apex-layering-rule.md` ("Domain classes contain zero SOQL and zero DML...
 * Domain methods are pure functions over `List<SObject>`"). Everything this class needs is
 * passed in by `UtilityBillService`, which owns the queries.
 *
 * Two responsibilities, and deliberately only two:
 *
 *   1. CONSUMPTION (FSD 5.10.5) - `Current - Previous`, with register rollover handled and,
 *      critically, DISTINGUISHED FROM A METER SWAP. See the block below.
 *   2. CHAIN SEQUENCING - deciding which bill is each bill's `Prior_Utility_Bill__c`.
 *
 * It does NOT compute variance. Usage variance, rate variance, total variance and the
 * percentage are cross-object FORMULA fields on `Utility_Bill__c`, evaluated by the platform
 * off `Prior_Utility_Bill__r`. Re-implementing them here would create a second source of
 * truth that silently disagrees the first time someone corrects a prior bill's charge lines.
 * The two stored inputs those formulas need - `Consumption__c` and
 * `Prior_Utility_Bill__c` - are exactly what this class produces, and nothing more.
 *
 * ============================================================================
 * ROLLOVER vs METER SWAP - THE ONE THING TO UNDERSTAND IN THIS FILE
 * ============================================================================
 * Both events present identically on the invoice: `Current_Reading__c < Previous_Reading__c`.
 *
 *   ROLLOVER  A 5-dial register reads 99,980, then wraps and reads 20.
 *             True consumption = 100,000 - 99,980 + 20 = 40.
 *   SWAP      The old device is pulled at 87,412; the replacement starts at 20.
 *             True consumption of the new device = 20. Applying rollover arithmetic gives
 *             100,000 - 87,412 + 20 = 12,608 - a fabricated 300x spike that then flows
 *             through `Rate_Per_Unit__c` and both variance components and fires the alert.
 *
 * A wrong ROLLOVER is a wrong number nobody notices. A wrong SWAP is a wrong number that
 * pages somebody. So this class is asymmetric ON PURPOSE:
 *
 *   IT ONLY APPLIES ROLLOVER ARITHMETIC WHEN IT CAN POSITIVELY ESTABLISH A ROLLOVER.
 *   In every other descending-reading case it REFUSES and leaves `Consumption__c` NULL.
 *
 * Null is the safe direction and it is safe by construction, not by luck: every variance
 * formula on the object is `ISBLANK`-guarded, `Rate_Per_Unit__c` returns blank on zero
 * consumption, so a refused bill produces NO variance figure and therefore CANNOT raise a
 * false alert. It shows up as a blank consumption on the record - a visible question for a
 * human, which is precisely what an ambiguous meter reading is. `Consumption__c` is a
 * writable Number and its own inline help tells the user to type over it "when the provider
 * estimated the read or the meter was swapped mid period".
 *
 * The four things that must ALL hold before rollover arithmetic is applied:
 *
 *   a. A PRIOR BILL EXISTS. With no prior bill there is no evidence of anything, and the
 *      very first bill on a meter reading downwards is a data-entry error or an
 *      already-swapped device - never a wrap this system can verify.
 *   b. THE CHAIN IS CONTINUOUS: this bill's `Previous_Reading__c` equals the prior bill's
 *      `Current_Reading__c`. In an unbroken sequence on one physical device the closing read
 *      IS the next opening read. A swap breaks that equality, because the incoming device's
 *      opening read is a fresh number belonging to a different register. This is the
 *      strongest signal available from the bill data alone and it needs no extra field.
 *   c. NO POSITIVE SWAP EVIDENCE. `Meter__c.Meter_Number__c` is history-tracked, so a device
 *      change on an existing service point leaves a `Meter__History` row. The service passes
 *      that in as `meterSwapEvidence`. See `MeterHistorySelector` for the three platform
 *      facts that shape it.
 *   d. THE REGISTER IS CONFIGURED AND CONSISTENT: `Register_Modulus__c > 0`, and
 *      `Previous_Reading__c < modulus`. A previous reading at or above the modulus means the
 *      configured register size does not describe this meter, so the wrap arithmetic would
 *      be wrong even if the event really was a wrap.
 *
 * (b) and (c) are independent and both are kept: (b) catches a swap nobody recorded on the
 * meter record, (c) catches a swap where the provider happened to carry the reading over.
 * ============================================================================
 */
public with sharing class UtilityBillDomain {

    /**
     * What happened to one bill's consumption. Returned index-aligned to the input list so a
     * caller can explain a blank `Consumption__c` instead of merely showing one.
     *
     * ALL_CAPS_SNAKE_CASE per the project Apex rules. Every `UNRESOLVED_*` member means the
     * same thing to the data - consumption is null - and a different thing to the human.
     */
    public enum ConsumptionOutcome {
        /** `Current >= Previous`. The ordinary month. Consumption = the difference. */
        DIRECT_DIFFERENCE,
        /** Descending readings, and all four rollover conditions held. Modulus added back. */
        ROLLOVER_APPLIED,
        /** A human (or an import) supplied the figure. Left exactly as given. */
        MANUAL_OVERRIDE,
        /** One or both readings are blank. Nothing to compute from. */
        UNRESOLVED_NO_READINGS,
        /** Descending readings on a meter with no `Register_Size__c`. Rollover unconfigured. */
        UNRESOLVED_NO_MODULUS,
        /** Descending readings, but `Previous_Reading__c >= modulus`. Register size is wrong. */
        UNRESOLVED_READING_ABOVE_MODULUS,
        /** Descending readings on the first bill for this meter. No evidence either way. */
        UNRESOLVED_NO_PRIOR_BILL,
        /** Descending readings and this bill's opening read != the prior bill's closing read. */
        UNRESOLVED_CHAIN_DISCONTINUITY,
        /** Descending readings and `Meter__History` shows the meter number changed. A SWAP. */
        UNRESOLVED_METER_SWAP
    }

    /**
     * Everything the consumption calculation needs about ONE bill's surroundings, gathered
     * by `UtilityBillService` from the selectors. Keeping it in a struct is what lets this
     * class stay pure and lets every branch be unit-tested without a database.
     */
    public class BillContext {
        /** `Meter__c.Register_Modulus__c` - the value the register wraps at. Null/0 = unset. */
        public Decimal registerModulus;
        /** True when a prior bill exists for this meter, whatever its readings. */
        public Boolean hasPriorBill = false;
        /** The prior bill's `Current_Reading__c`. Null when there is no prior bill. */
        public Decimal priorClosingReading;
        /** True when `Meter__History` shows `Meter_Number__c` changed since the prior read. */
        public Boolean meterSwapEvidence = false;
        /** True when the caller supplied the consumption and it must not be overwritten. */
        public Boolean manualOverride = false;
    }

    /**
     * Computes and WRITES `Consumption__c` on every bill in `bills`.
     *
     * Bulk-safe by construction: no query, no DML, no nested iteration. The caller has
     * already resolved every context, so this is O(n) arithmetic.
     *
     * @param bills    Bills to populate, mutated in place. Null/empty is a no-op.
     * @param contexts One context per bill, INDEX-ALIGNED with `bills`. A shorter list, a
     *                 null list or a null element is treated as "no surrounding evidence",
     *                 which lands on the safe (refusing) branch rather than throwing inside
     *                 a trigger.
     * @return One `ConsumptionOutcome` per input bill, in input order. Never null; always
     *         the same size as `bills`.
     */
    public static List<ConsumptionOutcome> applyConsumption(
            List<Utility_Bill__c> bills, List<BillContext> contexts) {
        List<ConsumptionOutcome> outcomes = new List<ConsumptionOutcome>();
        if (bills == null || bills.isEmpty()) {
            return outcomes;
        }
        for (Integer i = 0; i < bills.size(); i++) {
            BillContext ctx = (contexts != null && i < contexts.size() && contexts[i] != null)
                ? contexts[i]
                : new BillContext();
            outcomes.add(applyOne(bills[i], ctx));
        }
        return outcomes;
    }

    /**
     * The whole decision for a single bill. Written as a flat sequence of early returns
     * (project Apex rule: "Use Return Early pattern") so that each refusal reason is one
     * readable line rather than a nested condition.
     */
    private static ConsumptionOutcome applyOne(Utility_Bill__c bill, BillContext ctx) {
        if (bill == null) {
            return ConsumptionOutcome.UNRESOLVED_NO_READINGS;
        }
        // A supplied figure always wins. The service decides WHETHER it was supplied (see
        // its isManualOverride); the domain only honours the verdict.
        if (ctx.manualOverride == true) {
            return ConsumptionOutcome.MANUAL_OVERRIDE;
        }

        Decimal previous = bill.Previous_Reading__c;
        Decimal current = bill.Current_Reading__c;
        if (previous == null || current == null) {
            bill.Consumption__c = null;
            return ConsumptionOutcome.UNRESOLVED_NO_READINGS;
        }

        // The ordinary month, and the overwhelming majority of rows: the register advanced.
        if (current >= previous) {
            bill.Consumption__c = current - previous;
            return ConsumptionOutcome.DIRECT_DIFFERENCE;
        }

        // ---- Descending readings. Rollover or swap. Refuse unless (a)-(d) all hold. ----
        bill.Consumption__c = null;

        // (c) Positive swap evidence beats everything else - check it first so the reported
        // reason names the swap rather than a downstream symptom of it.
        if (ctx.meterSwapEvidence == true) {
            return ConsumptionOutcome.UNRESOLVED_METER_SWAP;
        }
        // (d) The register has to be configured before its modulus can be added back.
        Decimal modulus = ctx.registerModulus;
        if (modulus == null || modulus <= 0) {
            return ConsumptionOutcome.UNRESOLVED_NO_MODULUS;
        }
        if (previous >= modulus) {
            return ConsumptionOutcome.UNRESOLVED_READING_ABOVE_MODULUS;
        }
        // (a) No prior bill means no evidence at all.
        if (ctx.hasPriorBill != true) {
            return ConsumptionOutcome.UNRESOLVED_NO_PRIOR_BILL;
        }
        // (b) Continuity. Exact equality, deliberately: this test only runs on the rare
        // descending row, so being strict here costs almost nothing and a near-miss is
        // genuinely worth a human's attention. If providers are ever proven to re-read and
        // shift an opening figure, introduce a NAMED tolerance constant here rather than
        // loosening the comparison in place.
        if (ctx.priorClosingReading == null || ctx.priorClosingReading != previous) {
            return ConsumptionOutcome.UNRESOLVED_CHAIN_DISCONTINUITY;
        }

        bill.Consumption__c = modulus - previous + current;
        return ConsumptionOutcome.ROLLOVER_APPLIED;
    }

    /**
     * Resolves the `Prior_Utility_Bill__c` pointer for every bill of every meter given.
     *
     * The prior bill is the immediately preceding bill FOR THE SAME METER by
     * `Read_Date__c` - read date, not bill date, because FSD 5.10.5 keeps them separate and
     * it is the READ that defines the consumption period. Ties (two bills read the same day)
     * are broken by Id, so the chain is a total order and cannot flip between runs.
     *
     * === WHY THE WHOLE CHAIN IS RECOMPUTED RATHER THAN PATCHED ===
     * A stored pointer is invalidated by four different events, three of which look like
     * nothing at all:
     *
     *   BACK-DATED INSERT  January and March exist; February is entered afterwards. March
     *                      still points at January, so March's variance is measured against
     *                      a two-month-old bill and February's is measured against nothing.
     *   READ-DATE EDIT     Correcting a read date re-orders the sequence around it.
     *   MIDDLE DELETE      `Prior_Utility_Bill__c` is `SetNull`, so the successor's pointer
     *                      silently BLANKS and its variance silently disappears.
     *   UNDELETE           A restored bill has to re-enter the sequence it left.
     *
     * Recomputing the full chain per affected meter is the only formulation that is correct
     * for all four without four separate code paths. It is also idempotent, so re-running it
     * is free.
     *
     * === BILLS WITH NO READ DATE ARE EXCLUDED FROM THE CHAIN ENTIRELY ===
     * They have no position in a sequence ordered by read date. Such a bill gets a null
     * prior and is nobody's prior - it is skipped, not sorted to one end, because sorting it
     * to an end would silently make it the neighbour of a real bill.
     *
     * @param billsByMeter Meter Id -> that meter's bills, in ANY order. Null/empty returns
     *                     an empty map. Bills with a null Id or a null read date are ignored.
     * @return billId -> priorBillId, containing an entry for EVERY chain-eligible bill,
     *         with an explicit null value for the oldest one. The explicit null matters: the
     *         caller uses this map to detect pointers that must be CLEARED, and a missing
     *         key is indistinguishable from "leave it alone". Never null.
     */
    public static Map<Id, Id> resolveChains(Map<Id, List<Utility_Bill__c>> billsByMeter) {
        Map<Id, Id> priorByBillId = new Map<Id, Id>();
        if (billsByMeter == null || billsByMeter.isEmpty()) {
            return priorByBillId;
        }
        for (Id meterId : billsByMeter.keySet()) {
            List<Utility_Bill__c> raw = billsByMeter.get(meterId);
            if (raw == null || raw.isEmpty()) {
                continue;
            }
            List<ChainNode> ordered = new List<ChainNode>();
            for (Utility_Bill__c b : raw) {
                if (b != null && b.Id != null && b.Read_Date__c != null) {
                    ordered.add(new ChainNode(b));
                }
            }
            ordered.sort();
            Id previousId = null;
            for (ChainNode node : ordered) {
                priorByBillId.put(node.billId, previousId);
                previousId = node.billId;
            }
        }
        return priorByBillId;
    }

    /**
     * Sort key for the chain: read date ascending, then Id ascending as a tie-break.
     *
     * The Id tie-break is not decoration. Two bills read the same day are perfectly legal
     * (a corrected re-issue, or a master and a sub-meter billed together), and without a
     * second key their relative order would depend on the order SOQL happened to return
     * them - which would make the chain, and therefore every variance figure downstream of
     * it, non-deterministic between two identical runs.
     */
    private class ChainNode implements Comparable {
        final Id billId;
        final Date readDate;

        ChainNode(Utility_Bill__c bill) {
            this.billId = bill.Id;
            this.readDate = bill.Read_Date__c;
        }

        public Integer compareTo(Object other) {
            ChainNode that = (ChainNode) other;
            if (this.readDate != that.readDate) {
                return this.readDate < that.readDate ? -1 : 1;
            }
            String mine = String.valueOf(this.billId);
            String theirs = String.valueOf(that.billId);
            return mine.compareTo(theirs);
        }
    }
}
