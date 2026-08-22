/**
 * Tests for `UtilityBillController` - the bill record-page panel and the variance figures
 * it surfaces from `Utility_Bill__c`.
 *
 * Read-only controller, so `.claude/rules/bulk-test-rule.md`'s 251 mandate does not apply
 * (it exists to force a second trigger batch firing). The volume proofs live in
 * `UtilityBillTriggerTest`.
 */
@isTest
private class UtilityBillControllerTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        Unit__c unit = TestDataFactory.createUnit(asset.Id, true);
        Meter__c meter = TestDataFactory.createMeter(asset.Id, false);
        meter.Unit__c = unit.Id;
        insert meter;

        // prior: 100 units @ $200 -> $2.00/unit
        // current: 150 units @ $345 -> $2.30/unit
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>{
            new Utility_Bill__c(Meter__c = meter.Id,
                Read_Date__c = Date.newInstance(2026, 1, 1),
                Bill_Date__c = Date.newInstance(2026, 1, 6),
                Previous_Reading__c = 1000, Current_Reading__c = 1100),
            new Utility_Bill__c(Meter__c = meter.Id,
                Read_Date__c = Date.newInstance(2026, 2, 1),
                Bill_Date__c = Date.newInstance(2026, 2, 6),
                Previous_Reading__c = 1100, Current_Reading__c = 1250) };
        insert bills;
        TestDataFactory.createChargeLine(bills[0].Id, 200, true);
        insert new List<Charge_Line__c>{
            new Charge_Line__c(Utility_Bill__c = bills[1].Id,
                Charge_Type__c = 'Energy', Charge_Amount__c = 300),
            new Charge_Line__c(Utility_Bill__c = bills[1].Id,
                Charge_Type__c = 'Taxes', Charge_Amount__c = 45) };
    }

    private static Utility_Bill__c currentBill() {
        return [SELECT Id FROM Utility_Bill__c ORDER BY Read_Date__c DESC LIMIT 1];
    }

    private static Utility_Bill__c priorBill() {
        return [SELECT Id FROM Utility_Bill__c ORDER BY Read_Date__c ASC LIMIT 1];
    }


    // ==================== bill detail ====================

    @isTest
    static void getBillDetail_returnsTheDecompositionAndTheComponents() {
        Id billId = currentBill().Id;

        Test.startTest();
        UtilityBillController.BillDetail d = UtilityBillController.getBillDetail(billId);
        Test.stopTest();

        Assert.isNotNull(d, 'The bill is visible.');
        Assert.areEqual(150, d.consumption, 'Computed by the trigger from the readings.');
        Assert.areEqual(345, d.totalCharges, 'Rolled up from the two charge lines.');
        Assert.isTrue(d.hasPrior, 'It has a prior bill.');
        Assert.areEqual(200, d.priorTotalCharges, 'Which totalled $200.');
        Assert.areEqual(2, d.priorRatePerUnit, '$200 over 100 units is $2.00.');
        Assert.areEqual(100, d.usageVariance,
            'FSD 5.10.5 usage variance: (150 - 100) x $2.00.');
        Assert.areEqual(45, d.rateVariance,
            'FSD 5.10.5 rate variance: ($2.30 - $2.00) x 150.');
        Assert.areEqual(145, d.totalVariance, 'The raw dollar change.');
        Assert.areEqual(d.totalVariance, d.usageVariance + d.rateVariance,
            'THE INVARIANT, re-asserted at the boundary the UI actually reads: the two '
            + 'components are exactly additive. If the panel can show a usage and a rate '
            + 'figure that do not sum to the total it displays beside them, the whole '
            + 'decomposition is worthless to the reviewer.');
        Assert.areEqual(72.5, d.totalVariancePct,
            '$200 -> $345 is +72.5%, read straight from Total_Variance_Pct__c.');
        Assert.areEqual(2, d.chargeLines.size(), 'Both components.');
        Assert.areEqual('Energy', d.chargeLines[0].chargeType,
            'Largest amount first, so the driver of the variance leads.');
        Assert.areEqual(87, d.chargeLines[0].sharePct.setScale(0),
            '$300 of $345 is 87% of the bill - the number that tells a reviewer where to '
            + 'look without opening every line.');
    }

    @isTest
    static void getBillDetail_firstBill_showsNoVarianceRatherThanZeroes() {
        Id billId = priorBill().Id;

        Test.startTest();
        UtilityBillController.BillDetail d = UtilityBillController.getBillDetail(billId);
        Test.stopTest();

        Assert.isFalse(d.hasPrior, 'Nothing precedes it.');
        Assert.isNull(d.usageVariance,
            'Zero would be a claim that usage did not change. Null is "there is nothing to '
            + 'compare", which is a different statement and the true one.');
        Assert.isNull(d.totalVariancePct, 'And no percentage.');
        Assert.isNull(d.priorBillId, 'And no prior to name.');
    }

    @isTest
    static void getBillDetail_wholeBuildingMeter_labelsTheSpaceRatherThanLeavingItBlank() {
        Meter__c meter = [SELECT Id FROM Meter__c LIMIT 1];
        update new Meter__c(Id = meter.Id, Unit__c = null);

        Test.startTest();
        UtilityBillController.BillDetail d =
            UtilityBillController.getBillDetail(currentBill().Id);
        Test.stopTest();

        Assert.areEqual('Whole building', d.unitLabel,
            'FSD 5.10.4 makes a blank space meaningful. A blank cell would read as missing '
            + 'data.');
    }

    @isTest
    static void getBillDetail_descendingReadingsWithNoConsumption_carriesTheWarning() {
        // The state UtilityBillDomain leaves behind when it declines to guess between a
        // register rollover and a meter swap. The panel has to SAY that, or a blank
        // consumption looks like an unfinished record.
        Meter__c meter = [SELECT Id FROM Meter__c LIMIT 1];
        Utility_Bill__c ambiguous = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 3, 1),
            Previous_Reading__c = 500, Current_Reading__c = 20);
        insert ambiguous;
        Assert.isNull(
            [SELECT Consumption__c FROM Utility_Bill__c WHERE Id = :ambiguous.Id].Consumption__c,
            'Precondition: the domain refused - the chain is discontinuous.');

        Test.startTest();
        UtilityBillController.BillDetail d = UtilityBillController.getBillDetail(ambiguous.Id);
        Test.stopTest();

        Assert.isNotNull(d.consumptionWarning, 'The warning is present.');
        Assert.isTrue(d.consumptionWarning.containsIgnoreCase('rollover'),
            'And it names BOTH possibilities rather than guessing between them - guessing is '
            + 'exactly what the domain declined to do. Got: ' + d.consumptionWarning);
        Assert.isTrue(d.consumptionWarning.containsIgnoreCase('meter was replaced'),
            'And it tells the user what to DO about it.');
    }

    @isTest
    static void getBillDetail_unfinishedBillWithNoReadings_getsNoWarning() {
        // The falsifier for the test above. A blank consumption with no readings is just an
        // unfinished record; warning about it would make the warning noise nobody reads.
        Meter__c meter = [SELECT Id FROM Meter__c LIMIT 1];
        Utility_Bill__c empty = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 4, 1));
        insert empty;

        Test.startTest();
        UtilityBillController.BillDetail d = UtilityBillController.getBillDetail(empty.Id);
        Test.stopTest();

        Assert.isNull(d.consumptionWarning,
            'No readings means nothing ambiguous happened - the record is simply incomplete.');
    }

    @isTest
    static void getBillDetail_nullId_returnsNullSoTheComponentCanRenderItsEmptyState() {
        Test.startTest();
        Assert.isNull(UtilityBillController.getBillDetail(null),
            'A null return is the right treatment for "there is nothing here" - an exception '
            + 'would put an error banner on a page that is merely empty.');
        Test.stopTest();
    }

    @isTest
    static void getBillDetail_userWithoutAccess_getsTheGenericMessageAndNoPlatformDetail() {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User denied = new User(
            FirstName = 'No', LastName = 'Access', Alias = 'nobc',
            Email = 'dpeg.noaccess@example.invalid',
            Username = 'ubc' + String.valueOf(DateTime.now().getTime())
                + String.valueOf(Math.abs(Crypto.getRandomInteger())) + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id, TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert denied;
        }
        Id billId = currentBill().Id;
        Boolean threw = false;
        String message;

        Test.startTest();
        System.runAs(denied) {
            try {
                UtilityBillController.getBillDetail(billId);
            } catch (AuraHandledException e) {
                threw = true;
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'Minimum Access - Salesforce, with no permission set: the USER_MODE selector '
            + 'genuinely throws. `Standard User` would have masked this with its broad '
            + 'standard-object grants and passed for the wrong reason.');
        Assert.isTrue(message.contains('could not be loaded'),
            'The fixed generic message. Got: ' + message);
        Assert.isFalse(message.containsIgnoreCase('sObject type'),
            'With no platform detail concatenated into it.');
    }
}
