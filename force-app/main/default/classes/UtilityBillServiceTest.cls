/**
 * Tests for `UtilityBillService` - the orchestration between the selectors and
 * `UtilityBillDomain`, and the one DML the chain re-link performs.
 *
 * === VOLUME: 251, NOT 200 (`.claude/rules/bulk-test-rule.md`) ===
 * 251 rows force the trigger to fire in TWO chunks (ceil(251/200) = 2), which is the only
 * way to expose a query or a DML that has crept inside a loop - at exactly 200 a broken
 * implementation still runs once and passes. None of the objects here are
 * `ContentVersion`/`ContentNote`/`ContentDocument`, so the content-publication carve-out in
 * `.claude/rules/content-publication-rule.md` does NOT apply and the full mandate stands.
 *
 * === WHERE THE GOVERNOR ASSERTIONS ARE MEASURED ===
 * Query and DML counts are captured with `Limits.getQueries()` deltas around a DML that runs
 * SYNCHRONOUSLY inside the test transaction. That is safe here because nothing in this
 * feature is async - there is no queueable and no batch on the write path, so there is no
 * `Test.stopTest()` counter reset to be fooled by. (The batch that DOES exist,
 * `UtilityVarianceAlertBatch`, is a read-only sweep and is tested in its own class.)
 */
@isTest
private class UtilityBillServiceTest {

    // `BULK` alone will NOT compile - `bulk` is a RESERVED WORD in Apex, and the parser
    // reports it as "Unexpected token" at the declaration and then as bogus "method does not
    // exist" errors at every use site. Recorded because the second symptom sends the reader
    // hunting for a missing method that is right there.
    private static final Integer BULK_ROWS = 251;

    @TestSetup
    static void setup() {
        // One property with two meters: the "several meters" fixture every chain test needs
        // in order to prove chains do not leak across meters.
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        TestDataFactory.createMeters(2, asset.Id, true);
    }

    /** The @TestSetup meters. NEVER `TestDataFactory.defaultMeter()` here - the static cache
     *  does not cross the @TestSetup boundary and calling it would silently create a THIRD
     *  meter (TestDataFactory class header, warning 1). */
    private static List<Meter__c> setupMeters() {
        return [SELECT Id, Register_Modulus__c FROM Meter__c ORDER BY Meter_Number__c];
    }

    // ==================== consumption through the service ====================

    @isTest
    static void applyConsumption_onInsert_computesFromTheReadings() {
        Meter__c meter = setupMeters()[0];
        Utility_Bill__c bill = new Utility_Bill__c(
            Meter__c = meter.Id,
            Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 1000,
            Current_Reading__c = 1180);

        Test.startTest();
        insert bill;
        Test.stopTest();

        Utility_Bill__c saved =
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :bill.Id];
        Assert.areEqual(180, saved.Consumption__c,
            'The before-insert context must have written consumption on the same save, so '
            + 'there is no window in which the record is stored without it.');
    }

    @isTest
    static void applyConsumption_rolloverAcrossTwoSavedBills_addsTheModulus() {
        Meter__c meter = setupMeters()[0];
        insert new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 99900, Current_Reading__c = 99980);

        Utility_Bill__c wrapped = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 2, 1),
            Previous_Reading__c = 99980, Current_Reading__c = 20);

        Test.startTest();
        insert wrapped;
        Test.stopTest();

        Utility_Bill__c saved =
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :wrapped.Id];
        Assert.areEqual(40, saved.Consumption__c,
            'Register_Size__c = 5 gives a modulus of 100000, and the chain is continuous '
            + '(99,980 closing = 99,980 opening), so 100000 - 99980 + 20 = 40.');
    }

    @isTest
    static void applyConsumption_descendingWithBrokenChain_isLeftBlankNotFabricated() {
        Meter__c meter = setupMeters()[0];
        insert new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 87000, Current_Reading__c = 87412);

        // The replacement device is billed from its own opening read of 500, which does NOT
        // continue the old device's closing read of 87,412. Same arithmetic shape as a
        // rollover: the current reading is lower than the previous one.
        Utility_Bill__c afterSwap = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 2, 1),
            Previous_Reading__c = 500, Current_Reading__c = 20);

        Test.startTest();
        insert afterSwap;
        Test.stopTest();

        Utility_Bill__c saved =
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :afterSwap.Id];
        Assert.isNull(saved.Consumption__c,
            'The opening read (500) does not continue the prior closing read (87,412), so '
            + 'the two readings come from different registers. Applying the modulus would '
            + 'invent 99,520 units of consumption and fire the variance alert on it.');
    }

    @isTest
    static void applyConsumption_meterSwapEvidence_refusesEvenWhenTheChainLooksContinuous() {
        // Meter__History is NOT createable from Apex and its rows are invisible in the
        // transaction that made them, so a real swap cannot be constructed in a test. The
        // injection seam on UtilityBillService is the ONLY way to cover this branch, and the
        // branch is the most consequential one in the feature.
        Meter__c meter = setupMeters()[0];
        insert new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 99900, Current_Reading__c = 99980);

        UtilityBillService.swapDatesByMeterIdOverride = new Map<Id, List<Date>>{
            meter.Id => new List<Date>{ Date.newInstance(2026, 1, 20) } };

        Utility_Bill__c spanningTheSwap = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 2, 1),
            Previous_Reading__c = 99980, Current_Reading__c = 20);

        Test.startTest();
        insert spanningTheSwap;
        Test.stopTest();

        Utility_Bill__c saved =
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :spanningTheSwap.Id];
        Assert.isNull(saved.Consumption__c,
            'Every rollover condition holds - continuous chain, modulus configured, reading '
            + 'inside the register - and the answer is still a refusal, because '
            + 'Meter_Number__c changed on 20 Jan, between the 1 Jan and 1 Feb reads. Without '
            + 'the swap check this row would report 40 units for a device that measured 20.');
    }

    @isTest
    static void applyConsumption_swapOutsideTheBilledInterval_doesNotSuppressARealRollover() {
        // The falsifier for the test above: a recorded swap that predates the prior read must
        // NOT be allowed to blank a legitimate rollover, or one historical device change
        // would disable consumption on that meter forever.
        Meter__c meter = setupMeters()[0];
        insert new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 99900, Current_Reading__c = 99980);

        UtilityBillService.swapDatesByMeterIdOverride = new Map<Id, List<Date>>{
            meter.Id => new List<Date>{ Date.newInstance(2025, 6, 15) } };

        Utility_Bill__c wrapped = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 2, 1),
            Previous_Reading__c = 99980, Current_Reading__c = 20);

        Test.startTest();
        insert wrapped;
        Test.stopTest();

        Utility_Bill__c saved =
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :wrapped.Id];
        Assert.areEqual(40, saved.Consumption__c,
            'The swap window is (prior read, this read]. A change eight months earlier is '
            + 'outside it and must not suppress the wrap.');
    }

    @isTest
    static void applyConsumption_manualOverrideOnInsert_survives() {
        Meter__c meter = setupMeters()[0];
        Utility_Bill__c bill = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 1000, Current_Reading__c = 1180,
            Consumption__c = 175);

        Test.startTest();
        insert bill;
        Test.stopTest();

        Utility_Bill__c saved =
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :bill.Id];
        Assert.areEqual(175, saved.Consumption__c,
            'A figure supplied on insert is an import or a corrected read and must not be '
            + 'recomputed to 180.');
    }

    @isTest
    static void applyConsumption_typedOnUpdateWithoutTouchingReadings_isAnOverride() {
        Meter__c meter = setupMeters()[0];
        Utility_Bill__c bill = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 1000, Current_Reading__c = 1180);
        insert bill;
        Assert.areEqual(180,
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :bill.Id].Consumption__c,
            'Precondition: the trigger computed 180.');

        Test.startTest();
        update new Utility_Bill__c(Id = bill.Id, Consumption__c = 150);
        Test.stopTest();

        Assert.areEqual(150,
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :bill.Id].Consumption__c,
            'Consumption changed while both readings stayed put - the only shape a deliberate '
            + 'correction can take. Recomputing it back to 180 would make the field '
            + 'un-editable in practice while still looking editable.');
    }

    @isTest
    static void applyConsumption_editingAReading_discardsAnEarlierOverride() {
        // Documented behaviour, pinned so it is a decision rather than a surprise: the
        // readings win. The override existed because the readings were wrong; they are now
        // right.
        Meter__c meter = setupMeters()[0];
        Utility_Bill__c bill = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 1000, Current_Reading__c = 1180, Consumption__c = 175);
        insert bill;

        Test.startTest();
        update new Utility_Bill__c(Id = bill.Id, Current_Reading__c = 1300);
        Test.stopTest();

        Assert.areEqual(300,
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :bill.Id].Consumption__c,
            'A corrected reading recomputes and replaces the manual figure.');
    }

    // ==================== chain re-linking ====================

    @isTest
    static void relinkChains_isIdempotent_andPerformsNoDmlWhenNothingMoved() {
        Meter__c meter = setupMeters()[0];
        TestDataFactory.createUtilityBills(3, meter.Id, true);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        UtilityBillService.relinkChains(new Set<Id>{ meter.Id });
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(dmlBefore, dmlAfter,
            'The chain was already correct, so a second pass must cost ZERO DML. A rebuild '
            + 'that re-wrote every row would make every unrelated bill save quadratically '
            + 'more expensive and would burn row locks during an import.');
    }

    @isTest
    static void relinkChains_nullAndEmptyInput_areNoOps() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        UtilityBillService.relinkChains(null);
        UtilityBillService.relinkChains(new Set<Id>());
        Assert.areEqual(queriesBefore, Limits.getQueries(),
            'Neither a null nor an empty meter set may reach the database.');
        Test.stopTest();
    }

    @isTest
    static void relinkChains_whileSuppressed_doesNothing() {
        // The re-link's own UPDATE re-fires this object's trigger. Prove the guard, not luck,
        // is what stops the second pass.
        Meter__c meter = setupMeters()[0];
        List<Utility_Bill__c> bills = TestDataFactory.createUtilityBills(2, meter.Id, true);
        update new Utility_Bill__c(Id = bills[1].Id, Prior_Utility_Bill__c = null);

        Test.startTest();
        UtilityBillService.suppressRelink = true;
        try {
            UtilityBillService.relinkChains(new Set<Id>{ meter.Id });
        } finally {
            UtilityBillService.suppressRelink = false;
        }
        Test.stopTest();

        Assert.isNull(
            [SELECT Prior_Utility_Bill__c FROM Utility_Bill__c WHERE Id = :bills[1].Id]
                .Prior_Utility_Bill__c,
            'With the guard raised the chain must be left exactly as found - that is what '
            + 'prevents the re-link DML from recursing once per bill in the chain.');
    }

    @isTest
    static void meterIdsToRelink_onUpdate_onlyCountsBillsWhoseReadDateMoved() {
        Meter__c meter = setupMeters()[0];
        Utility_Bill__c bill = TestDataFactory.createUtilityBill(meter.Id, true);
        Utility_Bill__c reloaded =
            [SELECT Id, Meter__c, Read_Date__c FROM Utility_Bill__c WHERE Id = :bill.Id];

        Utility_Bill__c unchangedDate = reloaded.clone(true, true, false, false);
        Set<Id> noMove = UtilityBillService.meterIdsToRelink(
            new List<Utility_Bill__c>{ unchangedDate },
            new Map<Id, Utility_Bill__c>{ reloaded.Id => reloaded });
        Assert.areEqual(0, noMove.size(),
            'An edit to a note or a charge cannot reorder anything. Re-linking on EVERY '
            + 'update would double this feature\'s query cost for no benefit.');

        Utility_Bill__c movedDate = reloaded.clone(true, true, false, false);
        movedDate.Read_Date__c = reloaded.Read_Date__c.addDays(-45);
        Set<Id> moved = UtilityBillService.meterIdsToRelink(
            new List<Utility_Bill__c>{ movedDate },
            new Map<Id, Utility_Bill__c>{ reloaded.Id => reloaded });
        Assert.areEqual(1, moved.size(),
            'A moved read date reorders the sequence around it and must trigger a rebuild.');
        Assert.isTrue(moved.contains(meter.Id), 'And it must name the right meter.');
    }

    @isTest
    static void meterIdsToRelink_skipsBillsWithNoMeter_ratherThanAddingNull() {
        Set<Id> ids = UtilityBillService.meterIdsToRelink(
            new List<Utility_Bill__c>{ new Utility_Bill__c(), null }, null);
        Assert.areEqual(0, ids.size(),
            'A null entry in the set would become a null bind variable in the selector.');
    }

    // ==================== bulk: 251 ====================

    @isTest
    static void applyConsumption_251BillsAcrossManyMeters_staysInsideItsGovernorBudget() {
        // The realistic monthly import: one bill per meter, 251 meters, one DML.
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Meter__c> meters = TestDataFactory.createMeters(BULK_ROWS, asset.Id, true);

        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bills.add(new Utility_Bill__c(
                Meter__c = meters[i].Id,
                Read_Date__c = Date.newInstance(2026, 3, 1),
                Bill_Date__c = Date.newInstance(2026, 3, 6),
                Previous_Reading__c = 1000,
                Current_Reading__c = 1000 + i));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert bills;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS,
            [SELECT COUNT() FROM Utility_Bill__c WHERE Consumption__c != NULL],
            'All 251 bills must have a computed consumption. 251 forces TWO trigger chunks '
            + '(ceil(251/200) = 2), which is the whole reason the mandate is 251 and not 200 '
            + '- at exactly 200 a per-record query would still run once and pass.');

        // BUDGET, stated as arithmetic so a future change that adds one query per RECORD
        // fails here instead of in production:
        //   per chunk: 2 SOQL before-insert (register + chain) + 1 SOQL after-insert (chain)
        //   + 1 DML for the re-link  => 2 chunks x (3 + 1). Plus the caller's own 1 DML.
        Assert.isTrue(queriesUsed <= 8,
            'Expected at most 8 queries for a 251-row insert (2 chunks x 3 + headroom); used '
            + queriesUsed + '. A per-record query would show up here as ~500.');
        Assert.isTrue(dmlUsed <= 4,
            'Expected at most 4 DML statements (the insert itself plus at most one re-link '
            + 'update per chunk); used ' + dmlUsed + '.');
    }

    @isTest
    static void applyConsumption_251BillsOnOneMeter_chainsEveryOneOfThem() {
        // The other shape: a full backfill of one meter's history in a single DML. Every bill
        // except the oldest must find its prior IN THE SAME BATCH - the stored rows alone
        // cannot chain them, because none of them existed a moment ago.
        Meter__c meter = setupMeters()[0];
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bills.add(new Utility_Bill__c(
                Meter__c = meter.Id,
                Read_Date__c = Date.newInstance(2020, 1, 1).addDays(i),
                Previous_Reading__c = 1000 + (i * 10),
                Current_Reading__c = 1010 + (i * 10)));
        }

        Test.startTest();
        insert bills;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS - 1,
            [SELECT COUNT() FROM Utility_Bill__c
             WHERE Meter__c = :meter.Id AND Prior_Utility_Bill__c != NULL],
            'Every bill but the earliest must be linked to a predecessor.');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Utility_Bill__c
             WHERE Meter__c = :meter.Id AND Prior_Utility_Bill__c = NULL],
            'Exactly one bill - the oldest - has no prior.');
        Assert.areEqual(BULK_ROWS,
            [SELECT COUNT() FROM Utility_Bill__c
             WHERE Meter__c = :meter.Id AND Consumption__c = 10],
            'Every bill consumed 10 units. A backfill that could not see its own siblings '
            + 'would still compute these (the readings are self-contained), which is why the '
            + 'chain assertions above are the ones that matter.');
    }

    @isTest
    static void relinkChains_251Bills_rebuildsInOneDmlNotOnePerBill() {
        Meter__c meter = setupMeters()[0];
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bills.add(new Utility_Bill__c(
                Meter__c = meter.Id,
                Read_Date__c = Date.newInstance(2021, 1, 1).addDays(i),
                Previous_Reading__c = 1000, Current_Reading__c = 1100));
        }
        insert bills;

        // Break every pointer, then rebuild from scratch.
        List<Utility_Bill__c> cleared = new List<Utility_Bill__c>();
        for (Utility_Bill__c b : bills) {
            cleared.add(new Utility_Bill__c(Id = b.Id, Prior_Utility_Bill__c = null));
        }
        UtilityBillService.suppressRelink = true;
        try {
            update cleared;
        } finally {
            UtilityBillService.suppressRelink = false;
        }
        Assert.areEqual(0,
            [SELECT COUNT() FROM Utility_Bill__c
             WHERE Meter__c = :meter.Id AND Prior_Utility_Bill__c != NULL],
            'Precondition: the chain is fully broken.');

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        UtilityBillService.relinkChains(new Set<Id>{ meter.Id });
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS - 1,
            [SELECT COUNT() FROM Utility_Bill__c
             WHERE Meter__c = :meter.Id AND Prior_Utility_Bill__c != NULL],
            'A full rebuild must restore all 250 pointers.');
        // MEASURED: 5. The arithmetic, so a future change that adds a query per RECORD fails
        // here instead of in production:
        //   1  the chain read that rebuilds all 250 pointers
        // + 4  the re-link's own UPDATE of 250 rows re-enters this object's BEFORE-update
        //      context in ceil(250/200) = 2 chunks, each spending 2 queries recomputing
        //      consumption (meter register + bill chain).
        // The `suppressRelink` guard bounds the AFTER context - it stops the chain being
        // rebuilt again - and deliberately does NOT suppress the before context, because the
        // readings on those rows still have to be honoured.
        Assert.isTrue(queriesUsed <= 6,
            'ONE query rebuilds the whole chain, plus the four the re-entrant before-update '
            + 'spends across its two chunks; used ' + queriesUsed + '. A per-bill query would '
            + 'be 250 and would break the 100-query limit at row 101.');
        Assert.areEqual(1, dmlUsed,
            'ONE update statement. A per-bill update would be 250 statements and would blow '
            + 'the 150-DML limit long before it finished.');
    }
}
