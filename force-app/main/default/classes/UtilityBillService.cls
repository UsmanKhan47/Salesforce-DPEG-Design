/**
 * Orchestration for `Utility_Bill__c` (FSD 5.10.5). Loads what `UtilityBillDomain` needs via
 * the selectors, calls the domain, and performs the one DML the chain re-link requires.
 * Holds NO inline SOQL and NO business arithmetic - ARCHITECTURE.md section 2 and
 * `.claude/rules/apex-layering-rule.md`.
 *
 * Two entry points, both bulk-safe and both called only from `UtilityBillTriggerHandler`:
 *
 *   applyConsumption(bills, oldMap)  before insert / before update
 *   relinkChains(meterIds)           after insert / update / delete / undelete
 *
 * === WHAT THIS CLASS DOES NOT DO ===
 * It does not compute variance. `Usage_Variance_Amount__c`, `Rate_Variance_Amount__c`,
 * `Total_Variance_Amount__c` and `Total_Variance_Pct__c` are cross-object formula fields
 * evaluated by the platform off `Prior_Utility_Bill__r`. This class produces the two stored
 * inputs they need and stops. That split is the whole reason correcting a PRIOR bill's
 * charge lines silently and correctly recomputes every downstream variance with no batch,
 * no recompute job and no staleness.
 *
 * === GOVERNOR BUDGET, MEASURED PER TRIGGER CHUNK (200 records) ===
 * A 251-row insert fires the trigger in ceil(251/200) = 2 chunks, and every figure below is
 * PER CHUNK, so multiply by the chunk count before comparing to a limit:
 *
 *   before insert/update  2 SOQL  (meter register, existing bill chain)
 *                        +1 SOQL  ONLY when some bill in the chunk reads DOWNWARDS
 *                                 (the meter-history swap probe). Zero in a normal month.
 *   after  insert/update  1 SOQL  (bill chain) + at most 1 DML
 *   after  delete/undel.  1 SOQL  (bill chain) + at most 1 DML
 *
 * Worst case for a 251-row insert: 2 x (3 + 1) = 8 SOQL and 2 DML. There is no query and no
 * DML inside any loop in this class, and adding one would break that arithmetic silently -
 * `UtilityBillServiceTest` asserts the counts.
 *
 * === RE-ENTRANCY ===
 * `relinkChains` UPDATES `Utility_Bill__c`, which re-fires this object's own trigger.
 * `suppressRelink` stops the second pass dead. Without it a back-dated insert would recurse
 * once per bill in the chain. It is set and cleared in a `finally`, never left dangling.
 *
 * Sharing: `with sharing`. The SYSTEM_MODE decisions are per-method and are justified where
 * they are taken - see `relinkChains` in particular, where SYSTEM_MODE is deliberately NOT
 * relied on for sharing.
 */
public with sharing class UtilityBillService {

    /**
     * Re-entrancy guard for the chain re-link's own DML. `@TestVisible` so a test can assert
     * that the guard is what stops the recursion rather than luck.
     */
    @TestVisible
    private static Boolean suppressRelink = false;

    /**
     * TEST SEAM for meter-swap evidence: meter Id -> the dates on which that meter's
     * `Meter_Number__c` changed.
     *
     * === WHY A SEAM AND NOT A MOCKED SELECTOR ===
     * `Meter__History` is NOT createable from Apex (`isCreateable = false`, measured against
     * `usman-dpeg` 2026-08-22), and its rows are not even visible in the transaction that
     * produced them. A test therefore CANNOT construct a real swap, in this org or any
     * other. Without this seam the `UNRESOLVED_METER_SWAP` branch - the single most
     * consequential branch in the feature, the one that stops a fabricated 300x consumption
     * spike from firing an alert - would be permanently uncoverable and permanently
     * unproven. See `MeterHistorySelector`'s header for the three measured facts.
     *
     * Null in production, always. Non-null ONLY inside a test.
     */
    @TestVisible
    private static Map<Id, List<Date>> swapDatesByMeterIdOverride = null;

    /**
     * Computes and writes `Consumption__c` on the given bills. Called from before insert and
     * before update, so the values are stored on the same save with no second DML.
     *
     * @param bills  `Trigger.new`. Mutated in place. Null/empty is a no-op.
     * @param oldMap `Trigger.oldMap` on update; null on insert. Used only to decide whether a
     *               figure was typed by a human (see `isManualOverride`).
     */
    public static void applyConsumption(List<Utility_Bill__c> bills,
            Map<Id, Utility_Bill__c> oldMap) {
        if (bills == null || bills.isEmpty()) {
            return;
        }
        Set<Id> meterIds = collectMeterIds(bills);
        if (meterIds.isEmpty()) {
            // Every bill is missing its master. The platform will reject the save on its own
            // with a clearer message than anything this class could add.
            return;
        }

        Map<Id, Meter__c> registerByMeterId = MeterSelector.selectRegisterByIds(meterIds);

        // The existing chain, keyed so an in-flight UPDATE replaces its own stored row. A
        // bill being edited must be sequenced by its NEW read date, not the one in the
        // database, or a read-date correction would compute against its own stale position.
        Map<Id, List<Reading>> readingsByMeter =
            buildReadingIndex(meterIds, bills);

        List<UtilityBillDomain.BillContext> contexts =
            new List<UtilityBillDomain.BillContext>();
        List<Date> priorReadDates = new List<Date>();
        Boolean anyDescending = false;

        for (Utility_Bill__c bill : bills) {
            UtilityBillDomain.BillContext ctx = new UtilityBillDomain.BillContext();
            ctx.manualOverride = isManualOverride(bill, oldMap);
            Meter__c meter = registerByMeterId.get(bill.Meter__c);
            ctx.registerModulus = (meter == null) ? null : meter.Register_Modulus__c;

            Reading prior = findPrior(readingsByMeter.get(bill.Meter__c), bill);
            if (prior != null) {
                ctx.hasPriorBill = true;
                ctx.priorClosingReading = prior.closingReading;
            }
            priorReadDates.add(prior == null ? null : prior.readDate);
            contexts.add(ctx);

            if (!ctx.manualOverride && bill.Previous_Reading__c != null
                    && bill.Current_Reading__c != null
                    && bill.Current_Reading__c < bill.Previous_Reading__c) {
                anyDescending = true;
            }
        }

        // The swap probe costs a query, so it is only paid when at least one row in the
        // chunk actually reads downwards. A normal month never touches Meter__History.
        if (anyDescending) {
            applySwapEvidence(bills, contexts, priorReadDates, meterIds);
        }

        UtilityBillDomain.applyConsumption(bills, contexts);
    }

    /**
     * Rebuilds `Prior_Utility_Bill__c` for every bill of every affected meter.
     *
     * === WHY THE WHOLE CHAIN, NOT A PATCH ===
     * See `UtilityBillDomain.resolveChains`. Four events invalidate a stored pointer -
     * back-dated insert, read-date edit, middle delete, undelete - and a full rebuild is the
     * only formulation correct for all four. It is idempotent, so the no-op case costs one
     * query and zero DML.
     *
     * === THE TWO ACCESS DECISIONS HERE ARE SEPARATE AND BOTH DELIBERATE ===
     *  1. CRUD/FLS. The write is `AccessLevel.SYSTEM_MODE`. It re-points SIBLING bills the
     *     saving user may have no edit rights on, on their behalf, to keep the register
     *     self-consistent. `USER_MODE` would roll back the user's own perfectly legitimate
     *     save because a NEIGHBOURING record was not editable by them.
     *  2. SHARING. SYSTEM_MODE does NOT lift sharing, and this project has already been bitten
     *     once by assuming it does. It is not relied on here: every record written is a
     *     `Utility_Bill__c` under the SAME `Meter__c` the user is already saving against, and
     *     `Utility_Bill__c.Meter__c` carries `writeRequiresMasterRead = false`, so Read on the
     *     meter is sufficient to edit its bills. The user provably has that - the master-detail
     *     insert would have failed otherwise.
     *
     * === `allOrNone = false`, AND WHY THAT IS THE LESSER EVIL ===
     * A re-link failure (realistically: row locking during a concurrent import) must not roll
     * back the user's bill. The cost is that a failed row keeps a stale pointer and therefore
     * a stale variance, silently. That is mitigated, not ignored: every failure is logged at
     * ERROR with its record Id, and the next save or undelete touching that meter rebuilds
     * the whole chain from scratch. Do NOT "simplify" this to a bare `update` - a bare update
     * throws inside an after-trigger and takes the user's save with it.
     *
     * @param meterIds Meters whose chains must be rebuilt. Null/empty is a no-op.
     */
    public static void relinkChains(Set<Id> meterIds) {
        if (suppressRelink || meterIds == null || meterIds.isEmpty()) {
            return;
        }
        List<Utility_Bill__c> chain = UtilityBillSelector.selectChainByMeterIds(meterIds);
        if (chain.isEmpty()) {
            return;
        }
        Map<Id, List<Utility_Bill__c>> byMeter = new Map<Id, List<Utility_Bill__c>>();
        Map<Id, Utility_Bill__c> currentById = new Map<Id, Utility_Bill__c>();
        for (Utility_Bill__c bill : chain) {
            currentById.put(bill.Id, bill);
            if (!byMeter.containsKey(bill.Meter__c)) {
                byMeter.put(bill.Meter__c, new List<Utility_Bill__c>());
            }
            byMeter.get(bill.Meter__c).add(bill);
        }

        Map<Id, Id> resolved = UtilityBillDomain.resolveChains(byMeter);

        List<Utility_Bill__c> updates = new List<Utility_Bill__c>();
        for (Id billId : resolved.keySet()) {
            Id shouldBe = resolved.get(billId);
            Utility_Bill__c stored = currentById.get(billId);
            if (stored == null || stored.Prior_Utility_Bill__c == shouldBe) {
                continue;
            }
            // A NARROW record carrying only the two fields that may change. Re-sending the
            // queried sObject would push `Meter__c` back at the platform, and that field is
            // not updateable (master-detail, reparentable = false) - measured: the save is
            // refused. It would also re-send stale in-memory values for anything a
            // before-trigger has since changed.
            updates.add(new Utility_Bill__c(Id = billId, Prior_Utility_Bill__c = shouldBe));
        }
        if (updates.isEmpty()) {
            return;
        }

        suppressRelink = true;
        try {
            List<Database.SaveResult> results =
                Database.update(updates, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    continue;
                }
                System.debug(LoggingLevel.ERROR,
                    'UtilityBillService.relinkChains: could not re-link '
                    + updates[i].Id + ' -> ' + updates[i].Prior_Utility_Bill__c + ': '
                    + results[i].getErrors());
            }
        } finally {
            suppressRelink = false;
        }
    }

    /**
     * The meters whose chains a set of bills can have disturbed.
     *
     * @param bills  Bills from any trigger context (`Trigger.new` or `Trigger.old`).
     * @param oldMap `Trigger.oldMap` on update; null otherwise. When supplied, only bills
     *               whose `Read_Date__c` actually moved are counted - an unrelated edit to a
     *               charge or a note cannot reorder anything, and re-linking on every update
     *               would double this feature's query cost for no benefit.
     * @return Affected meter Ids; never null, possibly empty.
     */
    public static Set<Id> meterIdsToRelink(List<Utility_Bill__c> bills,
            Map<Id, Utility_Bill__c> oldMap) {
        Set<Id> meterIds = new Set<Id>();
        if (bills == null) {
            return meterIds;
        }
        for (Utility_Bill__c bill : bills) {
            if (bill == null || bill.Meter__c == null) {
                continue;
            }
            if (oldMap == null) {
                meterIds.add(bill.Meter__c);
                continue;
            }
            Utility_Bill__c old = oldMap.get(bill.Id);
            if (old == null || old.Read_Date__c != bill.Read_Date__c) {
                meterIds.add(bill.Meter__c);
            }
        }
        return meterIds;
    }

    // ================= internals =================

    /** One position in a meter's reading sequence: a read date, a closing read, an order key. */
    private class Reading implements Comparable {
        final Date readDate;
        final Decimal closingReading;
        final String orderKey;

        Reading(Date readDate, Decimal closingReading, String orderKey) {
            this.readDate = readDate;
            this.closingReading = closingReading;
            this.orderKey = orderKey;
        }

        public Integer compareTo(Object other) {
            Reading that = (Reading) other;
            if (this.readDate != that.readDate) {
                return this.readDate < that.readDate ? -1 : 1;
            }
            return this.orderKey.compareTo(that.orderKey);
        }
    }

    /** Meter Ids referenced by the given bills, nulls skipped. */
    private static Set<Id> collectMeterIds(List<Utility_Bill__c> bills) {
        Set<Id> meterIds = new Set<Id>();
        for (Utility_Bill__c bill : bills) {
            if (bill != null && bill.Meter__c != null) {
                meterIds.add(bill.Meter__c);
            }
        }
        return meterIds;
    }

    /**
     * Builds, per meter, the sorted reading sequence the prior lookup walks.
     *
     * Two subtleties, both load-bearing:
     *
     *  1. A BILL IN THIS BATCH REPLACES ITS OWN STORED ROW. On before update the database
     *     still holds the old read date; sequencing against it would place a corrected bill
     *     at its own former position.
     *  2. A BILL IN THIS BATCH CAN BE ANOTHER BILL'S PRIOR. A twelve-month backfill inserted
     *     in one DML must chain to itself, not just to what was already stored - otherwise
     *     eleven of the twelve bills would compute against nothing.
     *
     * New (Id-less) rows take an order key that sorts AFTER any stored row read the same day,
     * so a bill entered today for a date already covered does not displace the stored one.
     */
    private static Map<Id, List<Reading>> buildReadingIndex(
            Set<Id> meterIds, List<Utility_Bill__c> incoming) {
        Set<Id> incomingIds = new Set<Id>();
        for (Utility_Bill__c bill : incoming) {
            if (bill != null && bill.Id != null) {
                incomingIds.add(bill.Id);
            }
        }
        Map<Id, List<Reading>> byMeter = new Map<Id, List<Reading>>();
        for (Id meterId : meterIds) {
            byMeter.put(meterId, new List<Reading>());
        }
        for (Utility_Bill__c stored : UtilityBillSelector.selectChainByMeterIds(meterIds)) {
            if (incomingIds.contains(stored.Id) || stored.Read_Date__c == null) {
                continue;
            }
            List<Reading> bucket = byMeter.get(stored.Meter__c);
            if (bucket != null) {
                bucket.add(new Reading(stored.Read_Date__c, stored.Current_Reading__c,
                    'A' + String.valueOf(stored.Id)));
            }
        }
        Integer seq = 0;
        for (Utility_Bill__c bill : incoming) {
            seq++;
            if (bill == null || bill.Meter__c == null || bill.Read_Date__c == null) {
                continue;
            }
            List<Reading> bucket = byMeter.get(bill.Meter__c);
            if (bucket == null) {
                continue;
            }
            String key = (bill.Id == null)
                ? 'B' + String.valueOf(seq).leftPad(9, '0')
                : 'A' + String.valueOf(bill.Id);
            bucket.add(new Reading(bill.Read_Date__c, bill.Current_Reading__c, key));
        }
        for (Id meterId : byMeter.keySet()) {
            byMeter.get(meterId).sort();
        }
        return byMeter;
    }

    /**
     * The reading immediately before this bill in its meter's sequence, or null when this
     * bill is the earliest (or has no read date at all).
     *
     * The scan is over ONE meter's readings, not over all bills, so this is not an N-squared
     * loop across the trigger chunk - it is bounded by that single meter's bill count.
     */
    private static Reading findPrior(List<Reading> sequence, Utility_Bill__c bill) {
        if (sequence == null || sequence.isEmpty() || bill.Read_Date__c == null) {
            return null;
        }
        String selfKey = (bill.Id == null) ? null : 'A' + String.valueOf(bill.Id);
        Reading best = null;
        for (Reading candidate : sequence) {
            if (selfKey != null && candidate.orderKey == selfKey) {
                continue;
            }
            if (candidate.readDate > bill.Read_Date__c) {
                continue;
            }
            if (candidate.readDate == bill.Read_Date__c) {
                // Same-day rows: only a row that sorts BEFORE this one can be its prior.
                if (selfKey == null || candidate.orderKey.compareTo(selfKey) >= 0) {
                    continue;
                }
            }
            best = candidate;
        }
        return best;
    }

    /**
     * Marks each context whose bill spans a recorded `Meter_Number__c` change - a device
     * swap - so `UtilityBillDomain` refuses to apply rollover arithmetic to it.
     *
     * A change counts when it happened AFTER the prior bill's read date and no later than
     * this bill's read date: that is exactly the window this bill's readings cover. A bill
     * with no prior bill is skipped entirely, because the domain already refuses it for want
     * of evidence and probing history for it would buy nothing.
     *
     * Dates, not instants: `Read_Date__c` is date-only (FSD 5.10.5 records the read to the
     * day), so the history timestamp is reduced to its date before comparison. A swap and a
     * read on the same day are counted as a swap - the conservative direction, since the
     * cost of a false swap is a blank consumption a human fills in, and the cost of a false
     * rollover is a fabricated spike that pages somebody.
     */
    private static void applySwapEvidence(List<Utility_Bill__c> bills,
            List<UtilityBillDomain.BillContext> contexts, List<Date> priorReadDates,
            Set<Id> meterIds) {
        Date earliest = null;
        for (Date d : priorReadDates) {
            if (d != null && (earliest == null || d < earliest)) {
                earliest = d;
            }
        }
        if (earliest == null) {
            return;
        }
        Map<Id, List<Date>> changeDatesByMeter = swapDatesByMeterIdOverride;
        if (changeDatesByMeter == null) {
            changeDatesByMeter = new Map<Id, List<Date>>();
            for (Meter__History row : MeterHistorySelector.selectMeterNumberChanges(
                    meterIds, Datetime.newInstance(earliest, Time.newInstance(0, 0, 0, 0)))) {
                if (!changeDatesByMeter.containsKey(row.ParentId)) {
                    changeDatesByMeter.put(row.ParentId, new List<Date>());
                }
                changeDatesByMeter.get(row.ParentId).add(row.CreatedDate.date());
            }
        }
        if (changeDatesByMeter.isEmpty()) {
            return;
        }
        for (Integer i = 0; i < bills.size(); i++) {
            Utility_Bill__c bill = bills[i];
            Date priorRead = priorReadDates[i];
            if (bill == null || priorRead == null || bill.Read_Date__c == null) {
                continue;
            }
            List<Date> changes = changeDatesByMeter.get(bill.Meter__c);
            if (changes == null) {
                continue;
            }
            for (Date changed : changes) {
                if (changed > priorRead && changed <= bill.Read_Date__c) {
                    contexts[i].meterSwapEvidence = true;
                    break;
                }
            }
        }
    }

    /**
     * Whether `Consumption__c` on this bill was supplied by a human (or an import) and must
     * be left exactly as given.
     *
     * INSERT: any non-null value is an override. A bill created through the standard form or
     * through `TestDataFactory` leaves it blank, so the ordinary path still computes.
     *
     * UPDATE: an override is a change to `Consumption__c` while BOTH readings stayed put.
     * That is the only shape a deliberate correction can take. If the readings moved in the
     * same save, the readings win and the typed figure is recomputed away - documented here
     * because it is a real behaviour a user can hit: re-typing a reading discards a previous
     * manual consumption, which is the correct outcome (the override existed because the
     * readings were wrong; they are now right) but is not obvious.
     */
    @TestVisible
    private static Boolean isManualOverride(Utility_Bill__c bill,
            Map<Id, Utility_Bill__c> oldMap) {
        if (bill == null) {
            return false;
        }
        if (oldMap == null || bill.Id == null) {
            return bill.Consumption__c != null;
        }
        Utility_Bill__c old = oldMap.get(bill.Id);
        if (old == null) {
            return bill.Consumption__c != null;
        }
        Boolean readingsUnchanged =
            old.Previous_Reading__c == bill.Previous_Reading__c
            && old.Current_Reading__c == bill.Current_Reading__c;
        return readingsUnchanged && old.Consumption__c != bill.Consumption__c;
    }
}
