/**
 * Tests for `UtilityBillTrigger` / `UtilityBillTriggerHandler` - the six trigger contexts and
 * the four events that invalidate a `Prior_Utility_Bill__c` pointer.
 *
 * === WHAT THIS CLASS IS FOR THAT `UtilityBillServiceTest` IS NOT ===
 * The service test proves the orchestration in isolation. This one proves that the TRIGGER
 * actually routes to it, in every context - including the two (`after delete`,
 * `after undelete`) whose absence would produce no error at all, just a permanently wrong
 * variance on a record nobody is looking at.
 *
 * It also carries the FSD 5.10.5 ADDITIVE INVARIANT test. That assertion is the cheapest
 * possible proof that the whole decomposition is correct, and it can only be made here,
 * against real records, because the three variance figures are platform-evaluated FORMULA
 * fields - no unit test of Apex can produce them.
 *
 * VOLUME: 251 per `.claude/rules/bulk-test-rule.md`, which forces two trigger chunks.
 */
@isTest
private class UtilityBillTriggerTest {

    // `bulk` is a reserved word in Apex; `BULK_ROWS` is the project's spelling.
    private static final Integer BULK_ROWS = 251;

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        TestDataFactory.createMeters(1, asset.Id, true);
    }

    private static Meter__c theMeter() {
        return [SELECT Id, Register_Modulus__c FROM Meter__c LIMIT 1];
    }

    private static Utility_Bill__c reload(Id billId) {
        return [
            SELECT Id, Read_Date__c, Consumption__c, Prior_Utility_Bill__c,
                   Total_Charges_Amount__c, Rate_Per_Unit__c, Usage_Variance_Amount__c,
                   Rate_Variance_Amount__c, Total_Variance_Amount__c, Total_Variance_Pct__c
            FROM Utility_Bill__c WHERE Id = :billId];
    }

    private static Utility_Bill__c newBill(Id meterId, Date readDate, Decimal previous,
            Decimal current) {
        return new Utility_Bill__c(
            Meter__c = meterId, Read_Date__c = readDate, Bill_Date__c = readDate.addDays(5),
            Previous_Reading__c = previous, Current_Reading__c = current);
    }

    // ==================== insert / chain formation ====================

    @isTest
    static void afterInsert_sequentialBills_chainOldestToNewest() {
        Meter__c meter = theMeter();
        Utility_Bill__c jan = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        Utility_Bill__c feb = newBill(meter.Id, Date.newInstance(2026, 2, 1), 1100, 1250);

        Test.startTest();
        insert new List<Utility_Bill__c>{ jan, feb };
        Test.stopTest();

        Assert.isNull(reload(jan.Id).Prior_Utility_Bill__c,
            'The first bill for a meter has no prior - which is why a first bill correctly '
            + 'shows NO variance rather than a spurious 100% rise.');
        Assert.areEqual(jan.Id, reload(feb.Id).Prior_Utility_Bill__c,
            'February must be linked to January by the after-insert context. Both were '
            + 'inserted in the SAME DML, so the link cannot come from stored rows alone.');
    }

    @isTest
    static void afterInsert_backDatedBill_reSequencesItsSuccessor() {
        // The single most likely defect in the feature: Jan and Mar exist, Feb arrives later.
        Meter__c meter = theMeter();
        Utility_Bill__c jan = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        Utility_Bill__c mar = newBill(meter.Id, Date.newInstance(2026, 3, 1), 1250, 1400);
        insert new List<Utility_Bill__c>{ jan, mar };
        Assert.areEqual(jan.Id, reload(mar.Id).Prior_Utility_Bill__c,
            'Precondition: with two bills, March follows January.');

        Utility_Bill__c feb = newBill(meter.Id, Date.newInstance(2026, 2, 1), 1100, 1250);

        Test.startTest();
        insert feb;
        Test.stopTest();

        Assert.areEqual(feb.Id, reload(mar.Id).Prior_Utility_Bill__c,
            'March must be RE-POINTED at February. Left on January it would measure a '
            + 'one-month bill against a two-month-old one, silently, with no error anywhere '
            + 'and no visible symptom except a variance figure nobody can reproduce.');
        Assert.areEqual(jan.Id, reload(feb.Id).Prior_Utility_Bill__c,
            'And February takes its own place behind January.');
    }

    // ==================== update ====================

    @isTest
    static void afterUpdate_movedReadDate_reordersTheChain() {
        Meter__c meter = theMeter();
        Utility_Bill__c a = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        Utility_Bill__c b = newBill(meter.Id, Date.newInstance(2026, 2, 1), 1100, 1250);
        Utility_Bill__c c = newBill(meter.Id, Date.newInstance(2026, 3, 1), 1250, 1400);
        insert new List<Utility_Bill__c>{ a, b, c };
        Assert.areEqual(b.Id, reload(c.Id).Prior_Utility_Bill__c, 'Precondition: A, B, C.');

        // B's read date was wrong: it was actually read AFTER C.
        Test.startTest();
        update new Utility_Bill__c(Id = b.Id, Read_Date__c = Date.newInstance(2026, 4, 1));
        Test.stopTest();

        Assert.areEqual(a.Id, reload(c.Id).Prior_Utility_Bill__c,
            'With B moved past C, C now follows A.');
        Assert.areEqual(c.Id, reload(b.Id).Prior_Utility_Bill__c,
            'And B now follows C. A correction to one record has to re-sequence BOTH sides '
            + 'of where it moved from and to.');
    }

    // ==================== delete: the silent one ====================

    @isTest
    static void afterDelete_middleBill_reconnectsTheSurvivors() {
        Meter__c meter = theMeter();
        Utility_Bill__c jan = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        Utility_Bill__c feb = newBill(meter.Id, Date.newInstance(2026, 2, 1), 1100, 1250);
        Utility_Bill__c mar = newBill(meter.Id, Date.newInstance(2026, 3, 1), 1250, 1400);
        insert new List<Utility_Bill__c>{ jan, feb, mar };
        Assert.areEqual(feb.Id, reload(mar.Id).Prior_Utility_Bill__c,
            'Precondition: March follows February.');

        Test.startTest();
        delete feb;
        Test.stopTest();

        Assert.areEqual(jan.Id, reload(mar.Id).Prior_Utility_Bill__c,
            'WITHOUT the after-delete context this assertion reads NULL, not February: the '
            + 'lookup is deleteConstraint SetNull, so the platform silently BLANKS March\'s '
            + 'pointer and March\'s entire variance panel disappears from the record page '
            + 'with no error, no warning and nothing in any log.');
    }

    @isTest
    static void afterUndelete_restoredBill_reEntersTheSequence() {
        // There is no `before undelete` context on the platform, so this is the only place a
        // restored bill can be put back into its chain.
        Meter__c meter = theMeter();
        Utility_Bill__c jan = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        Utility_Bill__c feb = newBill(meter.Id, Date.newInstance(2026, 2, 1), 1100, 1250);
        Utility_Bill__c mar = newBill(meter.Id, Date.newInstance(2026, 3, 1), 1250, 1400);
        insert new List<Utility_Bill__c>{ jan, feb, mar };
        delete feb;
        Assert.areEqual(jan.Id, reload(mar.Id).Prior_Utility_Bill__c,
            'Precondition: with February deleted, March fell back to January.');

        Test.startTest();
        undelete feb;
        Test.stopTest();

        Assert.areEqual(feb.Id, reload(mar.Id).Prior_Utility_Bill__c,
            'February is back in the sequence and March follows it again.');
        Assert.areEqual(jan.Id, reload(feb.Id).Prior_Utility_Bill__c,
            'And the restored bill has its own prior restored too - an undelete leaves the '
            + 'record\'s own SetNull-blanked pointer empty, so both ends need repairing.');
    }

    // ==================== the FSD 5.10.5 decomposition ====================

    @isTest
    static void variance_usagePlusRate_reconcilesExactlyToTheTotal() {
        // THE cheapest possible proof that the decomposition is right, and the one thing that
        // catches a sign error in either component. It can only be made against real records:
        // all three figures are platform-evaluated cross-object formulas.
        //
        //   prior:   100 units, $200 total  -> rate $2.00
        //   current: 150 units, $345 total  -> rate $2.30
        //   usage variance = (150 - 100) x 2.00 = +100
        //   rate  variance = (2.30 - 2.00) x 150 = +45
        //   total          = 345 - 200            = +145
        Meter__c meter = theMeter();
        Utility_Bill__c prior = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        Utility_Bill__c current = newBill(meter.Id, Date.newInstance(2026, 2, 1), 1100, 1250);
        insert new List<Utility_Bill__c>{ prior, current };
        TestDataFactory.createChargeLine(prior.Id, 200, true);
        TestDataFactory.createChargeLine(current.Id, 345, true);

        Test.startTest();
        Utility_Bill__c b = reload(current.Id);
        Test.stopTest();

        Assert.areEqual(150, b.Consumption__c, 'Current consumption, from the readings.');
        Assert.areEqual(345, b.Total_Charges_Amount__c, 'Roll-up of the charge lines.');
        Assert.areEqual(100, b.Usage_Variance_Amount__c,
            'Usage variance is the change in consumption valued at the PRIOR rate.');
        Assert.areEqual(45, b.Rate_Variance_Amount__c,
            'Rate variance is the change in rate valued at the CURRENT consumption.');
        Assert.areEqual(145, b.Total_Variance_Amount__c, 'The raw dollar change.');
        Assert.areEqual(b.Total_Variance_Amount__c,
            b.Usage_Variance_Amount__c + b.Rate_Variance_Amount__c,
            'THE INVARIANT: (C_B - C_P)R_P + (R_B - R_P)C_B = R_B.C_B - R_P.C_P = Total_B - '
            + 'Total_P. The two components are exactly additive with no residual. A sign '
            + 'error in either one breaks this equality and nothing else would.');
    }

    @isTest
    static void variance_firstBillEver_showsNothingRatherThanAFabricatedRise() {
        Meter__c meter = theMeter();
        Utility_Bill__c only = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        insert only;
        TestDataFactory.createChargeLine(only.Id, 200, true);

        Test.startTest();
        Utility_Bill__c b = reload(only.Id);
        Test.stopTest();

        Assert.isNull(b.Prior_Utility_Bill__c, 'Nothing to compare against.');
        Assert.isNull(b.Usage_Variance_Amount__c,
            'A first bill must show NO usage variance. Zero would be a claim that usage did '
            + 'not change; a percentage would be a fabricated 100% rise.');
        Assert.isNull(b.Rate_Variance_Amount__c, 'And no rate variance.');
        Assert.isNull(b.Total_Variance_Amount__c, 'And no total variance.');
    }

    @isTest
    static void ratePerUnit_zeroConsumption_isBlankNotZero() {
        // A vacant space legitimately consumes nothing while still costing a standing charge.
        Meter__c meter = theMeter();
        Utility_Bill__c vacant = newBill(meter.Id, Date.newInstance(2026, 1, 1), 5000, 5000);
        insert vacant;
        TestDataFactory.createChargeLine(vacant.Id, 42, true);

        Test.startTest();
        Utility_Bill__c b = reload(vacant.Id);
        Test.stopTest();

        Assert.areEqual(0, b.Consumption__c, 'Zero consumption is a real measurement.');
        Assert.areEqual(42, b.Total_Charges_Amount__c, 'The standing charge is still billed.');
        Assert.isNull(b.Rate_Per_Unit__c,
            'The rate is UNDEFINED at zero consumption, not zero. Returning zero would '
            + 'propagate into the rate variance as a fabricated collapse in price - and there '
            + 'is no division-by-zero error to warn anyone, because the formula guards it.');
    }

    @isTest
    static void totalVariancePct_returnsTheHumanScale_notAHundredfoldOfIt() {
        // REGRESSION PIN for a defect that WAS live (fixed 2026-08-22). The formula ended in
        // `* 100` while the platform also scales a Percent formula result, so a doubling read
        // 10000 instead of 100. Three production readers now take this field directly -
        // `UtilityBillController.getBillDetail`, `UtilityMeterController.getRegister` and
        // `UtilityVarianceAlertBatch.execute` - so its SCALE is load-bearing, not cosmetic:
        // at 100x, the batch's ">= 20%" threshold fires at 0.2% and alerts on nearly every
        // bill in the org. Re-appending `* 100` must fail HERE and not in production.
        Meter__c meter = theMeter();
        Utility_Bill__c prior = newBill(meter.Id, Date.newInstance(2026, 1, 1), 1000, 1100);
        Utility_Bill__c current = newBill(meter.Id, Date.newInstance(2026, 2, 1), 1100, 1200);
        insert new List<Utility_Bill__c>{ prior, current };
        TestDataFactory.createChargeLine(prior.Id, 100, true);
        TestDataFactory.createChargeLine(current.Id, 200, true);

        Test.startTest();
        Utility_Bill__c b = reload(current.Id);
        Utility_Bill__c first = reload(prior.Id);
        Test.stopTest();

        Assert.areEqual(100, b.Total_Variance_Pct__c,
            'A rise from $100 to $200 is +100%. 10000 here means the trailing `* 100` is '
            + 'back on the formula and every reader of this field is overstating by 100x.');
        Assert.isNull(first.Total_Variance_Pct__c,
            'A FIRST bill has nothing to be a percentage of. Zero would be a claim that '
            + 'nothing changed, which is a different statement and a false one - and zero '
            + 'would also read as a real measurement to the alert batch.');
    }

    // ==================== bulk: 251 ====================

    @isTest
    static void bulkInsert_251BillsOnOneMeter_chainsThemAllAcrossTwoTriggerChunks() {
        Meter__c meter = theMeter();
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bills.add(newBill(meter.Id, Date.newInstance(2022, 1, 1).addDays(i),
                1000 + (i * 10), 1010 + (i * 10)));
        }

        Test.startTest();
        insert bills;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS, [SELECT COUNT() FROM Utility_Bill__c],
            'All 251 rows saved. 251 forces ceil(251/200) = 2 trigger chunks, which is the '
            + 'point: at exactly 200 the handler runs once and a per-chunk defect hides.');
        Assert.areEqual(BULK_ROWS - 1,
            [SELECT COUNT() FROM Utility_Bill__c WHERE Prior_Utility_Bill__c != NULL],
            'Every bill but the oldest is chained - INCLUDING across the chunk boundary, '
            + 'where bill 200 must find bill 199 among rows inserted by a different '
            + 'invocation of the handler.');
        Assert.areEqual(BULK_ROWS, [SELECT COUNT() FROM Utility_Bill__c WHERE Consumption__c = 10],
            'And every one has its consumption computed.');
    }

    @isTest
    static void bulkUpdate_251ReadDates_reversesTheWholeChain() {
        Meter__c meter = theMeter();
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bills.add(newBill(meter.Id, Date.newInstance(2023, 1, 1).addDays(i), 1000, 1100));
        }
        insert bills;
        Id oldestBefore = [
            SELECT Id FROM Utility_Bill__c
            WHERE Prior_Utility_Bill__c = NULL LIMIT 1].Id;

        // Invert every read date, so the sequence runs the other way round.
        List<Utility_Bill__c> flipped = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            flipped.add(new Utility_Bill__c(Id = bills[i].Id,
                Read_Date__c = Date.newInstance(2023, 1, 1).addDays(BULK_ROWS - i)));
        }

        Test.startTest();
        update flipped;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS - 1,
            [SELECT COUNT() FROM Utility_Bill__c WHERE Prior_Utility_Bill__c != NULL],
            'The chain is still complete after a 251-row read-date rewrite in two chunks.');
        Id oldestAfter = [
            SELECT Id FROM Utility_Bill__c WHERE Prior_Utility_Bill__c = NULL LIMIT 1].Id;
        Assert.areNotEqual(oldestBefore, oldestAfter,
            'And it genuinely re-sequenced: the bill with no prior is a DIFFERENT one now. '
            + 'Asserting only the count would pass on a chain that never moved.');
    }

    @isTest
    static void bulkDelete_251Bills_leavesNoDanglingPointers() {
        Meter__c meter = theMeter();
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bills.add(newBill(meter.Id, Date.newInstance(2024, 1, 1).addDays(i), 1000, 1100));
        }
        insert bills;

        // Delete the older half. Every survivor's pointer into that half is SetNull-blanked
        // by the platform and has to be rebuilt.
        List<Utility_Bill__c> doomed = new List<Utility_Bill__c>();
        for (Integer i = 0; i < 125; i++) {
            doomed.add(bills[i]);
        }

        Test.startTest();
        delete doomed;
        Test.stopTest();

        Integer survivors = BULK_ROWS - 125;
        Assert.areEqual(survivors, [SELECT COUNT() FROM Utility_Bill__c],
            'Precondition on the delete itself.');
        Assert.areEqual(survivors - 1,
            [SELECT COUNT() FROM Utility_Bill__c WHERE Prior_Utility_Bill__c != NULL],
            'Exactly one survivor - the new oldest - has no prior. Without the after-delete '
            + 'context this reads 125 fewer, because every pointer into the deleted half was '
            + 'silently blanked and never repaired.');
    }
}
