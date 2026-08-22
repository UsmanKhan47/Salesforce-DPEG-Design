/**
 * Unit tests for `UtilityBillDomain` - the pure consumption and chain-sequencing rules.
 *
 * === NO DML, NO SOQL, AND NO `TestDataFactory` IN THIS CLASS. THAT IS THE POINT. ===
 * The domain is a pure function over in-memory records, so every branch here is exercised
 * with constructed sObjects and SYNTHETIC Ids. That buys three things a DML-based test of
 * the same logic could not:
 *
 *  1. It proves the class really is pure. If someone adds a query to `UtilityBillDomain`,
 *     these tests fail with "no rows"/limit errors instead of quietly still passing.
 *  2. It reaches states the database refuses to hold - a bill whose previous reading exceeds
 *     its meter's modulus, a chain containing a bill with no read date, a swap the platform
 *     will not let a test create (`Meter__History` is not createable).
 *  3. It runs in milliseconds, so the branch matrix can be exhaustive rather than
 *     representative.
 *
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate targets triggers, batch jobs,
 * DML-performing services and queueables - "no SOQL/DML operations inside loops" is the
 * property it exists to force. This class performs no DML at all, so the volume test for
 * this logic lives where the DML does: `UtilityBillServiceTest` and `UtilityBillTriggerTest`,
 * both at 251.
 */
@isTest
private class UtilityBillDomainTest {

    /** Register modulus for a 5-dial meter (Register_Size__c = 5). */
    private static final Decimal MODULUS_5_DIAL = 100000;

    private static Integer idSeq = 1;

    /**
     * A syntactically valid, never-persisted `Utility_Bill__c` Id.
     *
     * Real Ids are unavailable without DML, and `resolveChains` is keyed on Id. Generating
     * them here keeps the test pure. They ascend, which matters: the chain's tie-break is
     * Id ascending, so a test of two same-day bills needs to know which Id sorts first.
     */
    private static Id fakeBillId() {
        String prefix = Utility_Bill__c.SObjectType.getDescribe().getKeyPrefix();
        return Id.valueOf(prefix + String.valueOf(idSeq++).leftPad(12, '0'));
    }

    private static Utility_Bill__c bill(Decimal previous, Decimal current) {
        return new Utility_Bill__c(Previous_Reading__c = previous, Current_Reading__c = current);
    }

    /** A context representing an ordinary, continuous, well-configured meter. */
    private static UtilityBillDomain.BillContext continuousContext(Decimal priorClosing) {
        UtilityBillDomain.BillContext ctx = new UtilityBillDomain.BillContext();
        ctx.registerModulus = MODULUS_5_DIAL;
        ctx.hasPriorBill = true;
        ctx.priorClosingReading = priorClosing;
        return ctx;
    }

    private static UtilityBillDomain.ConsumptionOutcome runOne(
            Utility_Bill__c b, UtilityBillDomain.BillContext ctx) {
        return UtilityBillDomain.applyConsumption(
            new List<Utility_Bill__c>{ b },
            new List<UtilityBillDomain.BillContext>{ ctx })[0];
    }

    // ==================== consumption: the ordinary path ====================

    @isTest
    static void applyConsumption_ascendingReadings_isTheSimpleDifference() {
        Utility_Bill__c b = bill(1000, 1250);

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, continuousContext(1000));

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.DIRECT_DIFFERENCE, outcome,
            'An advancing register is the ordinary case and must not be treated as ambiguous.');
        Assert.areEqual(250, b.Consumption__c, 'Consumption is current minus previous.');
    }

    @isTest
    static void applyConsumption_identicalReadings_isZeroNotBlank() {
        Utility_Bill__c b = bill(4000, 4000);

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, continuousContext(4000));

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.DIRECT_DIFFERENCE, outcome,
            'Equal readings are not a rollover - the register simply did not move.');
        Assert.areEqual(0, b.Consumption__c,
            'A vacant space consumes zero, and zero is a real measurement. Blanking it here '
            + 'would hide a disconnected space instead of reporting it.');
    }

    // ==================== consumption: rollover, the ONLY case that guesses ====================

    @isTest
    static void applyConsumption_rolloverWithContinuousChain_addsTheModulusBack() {
        // The canonical case: a 5-dial register at 99,980 wraps and reads 20.
        Utility_Bill__c b = bill(99980, 20);

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, continuousContext(99980));

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.ROLLOVER_APPLIED, outcome,
            'All four rollover conditions hold, so the wrap must be applied.');
        Assert.areEqual(40, b.Consumption__c,
            '100000 - 99980 + 20 = 40. Getting this wrong by an order of magnitude is exactly '
            + 'what the register-size ambiguity threatens.');
    }

    // ==================== consumption: the four refusals ====================

    @isTest
    static void applyConsumption_meterSwapEvidence_refusesRatherThanFabricatingASpike() {
        // Same arithmetic shape as a rollover, but Meter__History recorded a device change.
        Utility_Bill__c b = bill(87412, 20);
        UtilityBillDomain.BillContext ctx = continuousContext(87412);
        ctx.meterSwapEvidence = true;

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_METER_SWAP, outcome,
            'A recorded meter-number change is positive swap evidence and must beat the '
            + 'rollover branch even when every other rollover condition holds.');
        Assert.isNull(b.Consumption__c,
            'Rollover arithmetic here would produce 12,608 - a fabricated 300x spike that '
            + 'would flow into both variance components and fire the alert. Null is correct: '
            + 'every variance formula is ISBLANK-guarded, so a refused bill raises nothing.');
    }

    @isTest
    static void applyConsumption_chainDiscontinuity_refuses() {
        // The opening read does not match the prior bill's closing read: two registers.
        Utility_Bill__c b = bill(20, 15);
        UtilityBillDomain.BillContext ctx = continuousContext(87412);

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_CHAIN_DISCONTINUITY,
            outcome,
            'In an unbroken sequence on one device the prior closing read IS this opening '
            + 'read. A mismatch means the readings come from different registers.');
        Assert.isNull(b.Consumption__c, 'A broken chain must not be rollover-corrected.');
    }

    @isTest
    static void applyConsumption_noPriorBill_refusesForWantOfEvidence() {
        Utility_Bill__c b = bill(99980, 20);
        UtilityBillDomain.BillContext ctx = new UtilityBillDomain.BillContext();
        ctx.registerModulus = MODULUS_5_DIAL;
        ctx.hasPriorBill = false;

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_NO_PRIOR_BILL, outcome,
            'The very first bill on a meter reading downwards is a data-entry error or an '
            + 'already-swapped device - never a wrap this system can verify.');
        Assert.isNull(b.Consumption__c, 'No evidence means no number.');
    }

    @isTest
    static void applyConsumption_noRegisterModulus_refuses() {
        Utility_Bill__c b = bill(99980, 20);
        UtilityBillDomain.BillContext ctx = continuousContext(99980);
        ctx.registerModulus = null;

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_NO_MODULUS, outcome,
            'Register_Size__c was never captured, so there is no modulus to add back.');
        Assert.isNull(b.Consumption__c,
            'A negative consumption is nonsense and a fabricated one is worse.');
    }

    @isTest
    static void applyConsumption_zeroModulus_refuses() {
        // Register_Modulus__c is BlankAsZero, so an unset register size arrives as 0, not null.
        Utility_Bill__c b = bill(500, 20);
        UtilityBillDomain.BillContext ctx = continuousContext(500);
        ctx.registerModulus = 0;

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_NO_MODULUS, outcome,
            'Zero is how a blank register size actually arrives from the formula field - '
            + 'guarding only on null would let 0 through and compute 0 - 500 + 20.');
        Assert.isNull(b.Consumption__c, 'Zero modulus cannot correct anything.');
    }

    @isTest
    static void applyConsumption_previousReadingAboveModulus_refuses() {
        // 6-digit reading on a register configured as 5-dial: the configuration is wrong.
        Utility_Bill__c b = bill(120000, 20);
        UtilityBillDomain.BillContext ctx = continuousContext(120000);

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_READING_ABOVE_MODULUS,
            outcome,
            'A reading at or above the modulus proves the configured register size does not '
            + 'describe this meter, so the wrap arithmetic would be wrong anyway.');
        Assert.isNull(b.Consumption__c, 'Refuse rather than compute a negative 19,980.');
    }

    @isTest
    static void applyConsumption_readingExactlyAtModulus_refuses() {
        // Boundary: `previous >= modulus`, not `>`. At exactly the modulus the register has
        // already wrapped to zero, so the reading cannot be a legitimate opening value.
        Utility_Bill__c b = bill(MODULUS_5_DIAL, 20);
        UtilityBillDomain.BillContext ctx = continuousContext(MODULUS_5_DIAL);

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_READING_ABOVE_MODULUS,
            outcome,
            'The guard is >=, not >. A 5-dial register can display 0 through 99,999 and never '
            + '100,000, so a reading of exactly the modulus is already out of range.');
    }

    // ==================== consumption: inputs and overrides ====================

    @isTest
    static void applyConsumption_missingReading_producesNoNumber() {
        Utility_Bill__c noCurrent = bill(1000, null);
        Utility_Bill__c noPrevious = bill(null, 1000);

        List<UtilityBillDomain.ConsumptionOutcome> outcomes =
            UtilityBillDomain.applyConsumption(
                new List<Utility_Bill__c>{ noCurrent, noPrevious },
                new List<UtilityBillDomain.BillContext>{
                    continuousContext(900), continuousContext(900) });

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_NO_READINGS,
            outcomes[0], 'A missing current reading cannot produce a consumption.');
        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_NO_READINGS,
            outcomes[1], 'A missing previous reading cannot produce a consumption.');
        Assert.isNull(noCurrent.Consumption__c, 'Left blank, not zero.');
        Assert.isNull(noPrevious.Consumption__c, 'Left blank, not zero.');
    }

    @isTest
    static void applyConsumption_manualOverride_isLeftExactlyAsGiven() {
        Utility_Bill__c b = bill(1000, 1250);
        b.Consumption__c = 999;
        UtilityBillDomain.BillContext ctx = continuousContext(1000);
        ctx.manualOverride = true;

        UtilityBillDomain.ConsumptionOutcome outcome = runOne(b, ctx);

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.MANUAL_OVERRIDE, outcome,
            'The service decides WHETHER a value was supplied; the domain only honours it.');
        Assert.areEqual(999, b.Consumption__c,
            'An estimated read or a mid-period swap is entered by hand. Recomputing it to 250 '
            + 'would silently discard the correction - the reason this field is stored rather '
            + 'than being a formula.');
    }

    @isTest
    static void applyConsumption_nullAndShortInputs_degradeSafelyInsteadOfThrowing() {
        // This runs inside a trigger. An index error here would roll back a user's save.
        List<UtilityBillDomain.ConsumptionOutcome> none =
            UtilityBillDomain.applyConsumption(null, null);
        Assert.areEqual(0, none.size(), 'A null bill list returns an empty outcome list.');

        Utility_Bill__c b = bill(1000, 1250);
        List<UtilityBillDomain.ConsumptionOutcome> shortContexts =
            UtilityBillDomain.applyConsumption(
                new List<Utility_Bill__c>{ b }, new List<UtilityBillDomain.BillContext>());

        Assert.areEqual(1, shortContexts.size(),
            'The outcome list is always the same size as the bill list - a caller that '
            + 'trusted a SHORT list would report the wrong reason against the wrong record.');
        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.DIRECT_DIFFERENCE,
            shortContexts[0],
            'A missing context is treated as no surrounding evidence, which for an ascending '
            + 'pair still computes.');
    }

    @isTest
    static void applyConsumption_mixedBatch_eachRowGetsItsOwnVerdict() {
        // Index alignment is the whole contract of the outcome list; prove it with a batch
        // whose rows land on four different branches.
        Utility_Bill__c ordinary = bill(1000, 1100);
        Utility_Bill__c rollover = bill(99980, 20);
        Utility_Bill__c swapped = bill(87412, 20);
        Utility_Bill__c blank = bill(null, null);

        UtilityBillDomain.BillContext swapCtx = continuousContext(87412);
        swapCtx.meterSwapEvidence = true;

        List<UtilityBillDomain.ConsumptionOutcome> outcomes =
            UtilityBillDomain.applyConsumption(
                new List<Utility_Bill__c>{ ordinary, rollover, swapped, blank },
                new List<UtilityBillDomain.BillContext>{
                    continuousContext(1000), continuousContext(99980), swapCtx,
                    continuousContext(0) });

        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.DIRECT_DIFFERENCE, outcomes[0],
            'Row 0 advanced normally.');
        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.ROLLOVER_APPLIED, outcomes[1],
            'Row 1 wrapped.');
        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_METER_SWAP, outcomes[2],
            'Row 2 spans a device change.');
        Assert.areEqual(UtilityBillDomain.ConsumptionOutcome.UNRESOLVED_NO_READINGS, outcomes[3],
            'Row 3 has nothing to compute from.');
        Assert.areEqual(100, ordinary.Consumption__c, 'Row 0 value.');
        Assert.areEqual(40, rollover.Consumption__c, 'Row 1 value.');
        Assert.isNull(swapped.Consumption__c, 'Row 2 refused.');
        Assert.isNull(blank.Consumption__c, 'Row 3 refused.');
    }

    // ==================== chain sequencing ====================

    private static Utility_Bill__c chainBill(Date readDate) {
        return new Utility_Bill__c(Id = fakeBillId(), Read_Date__c = readDate);
    }

    @isTest
    static void resolveChains_ordersByReadDate_andTheOldestHasAnExplicitNullPrior() {
        Id fakeMeter = Id.valueOf(
            Meter__c.SObjectType.getDescribe().getKeyPrefix() + '000000000009'.leftPad(12, '0'));
        Utility_Bill__c jan = chainBill(Date.newInstance(2026, 1, 1));
        Utility_Bill__c feb = chainBill(Date.newInstance(2026, 2, 1));
        Utility_Bill__c mar = chainBill(Date.newInstance(2026, 3, 1));

        // Deliberately shuffled: the domain must sort, not trust the caller's order.
        Map<Id, Id> chain = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                fakeMeter => new List<Utility_Bill__c>{ mar, jan, feb } });

        Assert.areEqual(3, chain.size(), 'Every chain-eligible bill gets an entry.');
        Assert.isTrue(chain.containsKey(jan.Id),
            'The oldest bill must be PRESENT with a null value, not absent. A missing key is '
            + 'indistinguishable from "leave the pointer alone", so an absent oldest would '
            + 'never have a stale pointer cleared.');
        Assert.isNull(chain.get(jan.Id), 'The oldest bill has no prior.');
        Assert.areEqual(jan.Id, chain.get(feb.Id), 'February follows January.');
        Assert.areEqual(feb.Id, chain.get(mar.Id), 'March follows February.');
    }

    @isTest
    static void resolveChains_backDatedBill_reSequencesItsSuccessor() {
        // THE named defect: Jan and Mar exist, Feb is entered afterwards. Without a full
        // rebuild, March still points at January.
        Id fakeMeter = Id.valueOf(
            Meter__c.SObjectType.getDescribe().getKeyPrefix() + '000000000010'.leftPad(12, '0'));
        Utility_Bill__c jan = chainBill(Date.newInstance(2026, 1, 1));
        Utility_Bill__c mar = chainBill(Date.newInstance(2026, 3, 1));

        Map<Id, Id> before = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                fakeMeter => new List<Utility_Bill__c>{ jan, mar } });
        Assert.areEqual(jan.Id, before.get(mar.Id),
            'Precondition: with only two bills, March correctly follows January.');

        Utility_Bill__c feb = chainBill(Date.newInstance(2026, 2, 1));
        Map<Id, Id> after = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                fakeMeter => new List<Utility_Bill__c>{ jan, mar, feb } });

        Assert.areEqual(feb.Id, after.get(mar.Id),
            'March must now point at February. Leaving it on January measures a monthly '
            + 'variance across a two-month gap, silently and with no error anywhere.');
        Assert.areEqual(jan.Id, after.get(feb.Id), 'February follows January.');
    }

    @isTest
    static void resolveChains_deletedMiddleBill_reconnectsTheSurvivors() {
        Id fakeMeter = Id.valueOf(
            Meter__c.SObjectType.getDescribe().getKeyPrefix() + '000000000011'.leftPad(12, '0'));
        Utility_Bill__c jan = chainBill(Date.newInstance(2026, 1, 1));
        Utility_Bill__c feb = chainBill(Date.newInstance(2026, 2, 1));
        Utility_Bill__c mar = chainBill(Date.newInstance(2026, 3, 1));

        // February is gone; the domain sees only what survives.
        Map<Id, Id> chain = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                fakeMeter => new List<Utility_Bill__c>{ jan, mar } });

        Assert.areEqual(jan.Id, chain.get(mar.Id),
            'March must reconnect to January. Prior_Utility_Bill__c is deleteConstraint '
            + 'SetNull, so without this March keeps a BLANK pointer and its variance simply '
            + 'disappears from the record page with no error.');
        Assert.isFalse(chain.containsKey(feb.Id), 'A deleted bill is not in the chain.');
    }

    @isTest
    static void resolveChains_sameReadDate_isBrokenDeterministicallyByIdAscending() {
        Id fakeMeter = Id.valueOf(
            Meter__c.SObjectType.getDescribe().getKeyPrefix() + '000000000012'.leftPad(12, '0'));
        Date sameDay = Date.newInstance(2026, 4, 1);
        Utility_Bill__c first = chainBill(sameDay);   // lower Id - fakeBillId ascends
        Utility_Bill__c second = chainBill(sameDay);

        Map<Id, Id> forward = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                fakeMeter => new List<Utility_Bill__c>{ first, second } });
        Map<Id, Id> reversed = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                fakeMeter => new List<Utility_Bill__c>{ second, first } });

        Assert.areEqual(first.Id, forward.get(second.Id),
            'Two bills read the same day are legal (a corrected re-issue, or a master and a '
            + 'sub-meter billed together). The lower Id sorts first.');
        Assert.areEqual(forward.get(second.Id), reversed.get(second.Id),
            'THE POINT OF THE TIE-BREAK: the answer must not depend on the order SOQL '
            + 'happened to return the rows, or every variance downstream would be '
            + 'non-deterministic between two identical runs.');
    }

    @isTest
    static void resolveChains_billWithNoReadDate_isExcludedEntirely() {
        Id fakeMeter = Id.valueOf(
            Meter__c.SObjectType.getDescribe().getKeyPrefix() + '000000000013'.leftPad(12, '0'));
        Utility_Bill__c jan = chainBill(Date.newInstance(2026, 1, 1));
        Utility_Bill__c feb = chainBill(Date.newInstance(2026, 2, 1));
        Utility_Bill__c undated = chainBill(null);

        Map<Id, Id> chain = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                fakeMeter => new List<Utility_Bill__c>{ jan, undated, feb } });

        Assert.isFalse(chain.containsKey(undated.Id),
            'A bill with no read date has no position in a sequence ordered by read date.');
        Assert.areEqual(jan.Id, chain.get(feb.Id),
            'Sorting the undated bill to one end would silently make it a real bill\'s '
            + 'neighbour, which is worse than leaving it out.');
    }

    @isTest
    static void resolveChains_severalMeters_areSequencedIndependently() {
        Id meterA = Id.valueOf(
            Meter__c.SObjectType.getDescribe().getKeyPrefix() + '000000000014'.leftPad(12, '0'));
        Id meterB = Id.valueOf(
            Meter__c.SObjectType.getDescribe().getKeyPrefix() + '000000000015'.leftPad(12, '0'));
        Utility_Bill__c a1 = chainBill(Date.newInstance(2026, 1, 1));
        Utility_Bill__c a2 = chainBill(Date.newInstance(2026, 3, 1));
        Utility_Bill__c b1 = chainBill(Date.newInstance(2026, 2, 1));

        Map<Id, Id> chain = UtilityBillDomain.resolveChains(
            new Map<Id, List<Utility_Bill__c>>{
                meterA => new List<Utility_Bill__c>{ a1, a2 },
                meterB => new List<Utility_Bill__c>{ b1 } });

        Assert.areEqual(a1.Id, chain.get(a2.Id), 'Meter A chains within itself.');
        Assert.isNull(chain.get(b1.Id),
            'Meter B\'s only bill has no prior even though a bill on ANOTHER meter sits '
            + 'earlier in time. A chain that crossed meters would compare readings from two '
            + 'different physical registers.');
    }

    @isTest
    static void resolveChains_emptyAndNullInput_returnEmpty() {
        Assert.areEqual(0, UtilityBillDomain.resolveChains(null).size(),
            'Null input is a no-op, not a failure - this runs inside a trigger.');
        Assert.areEqual(0,
            UtilityBillDomain.resolveChains(new Map<Id, List<Utility_Bill__c>>()).size(),
            'An empty map is a no-op.');
    }
}
