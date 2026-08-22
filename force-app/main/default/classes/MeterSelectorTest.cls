/**
 * Tests for `MeterSelector`.
 *
 * Coverage of the mode split is the point here as much as the row counts: this selector
 * mixes `USER_MODE` (user-requested register reads) and `SYSTEM_MODE` (the trigger-path
 * register read), and ARCHITECTURE.md section 2 makes the mode a property of the METHOD.
 * Both are exercised.
 *
 * These are READS. `.claude/rules/bulk-test-rule.md`'s 251-record mandate exists to force a
 * SECOND trigger batch firing, which a query does not have - a selector behaves identically
 * at 12 rows and at 251. The volume proofs for this feature live in `UtilityBillTriggerTest`
 * and `UtilityBillServiceTest`, where the DML is.
 */
@isTest
private class MeterSelectorTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        Unit__c unit = TestDataFactory.createUnit(asset.Id, true);

        List<Meter__c> meters = TestDataFactory.createMeters(3, asset.Id, false);
        meters[1].Unit__c = unit.Id;
        insert meters;
        // A sub-meter under the first, so the master-first ordering has something to order.
        update new Meter__c(Id = meters[2].Id, Master_Meter__c = meters[0].Id);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectByPropertyAssetIds_returnsEveryMeterMasterFirst() {
        Test.startTest();
        List<Meter__c> meters =
            MeterSelector.selectByPropertyAssetIds(new Set<Id>{ assetId() });
        Test.stopTest();

        Assert.areEqual(3, meters.size(), 'All three meters at the property.');
        Assert.isNull(meters[0].Master_Meter__c,
            'ORDER BY Master_Meter__c NULLS FIRST puts masters and standalone meters before '
            + 'sub-meters, so a caller can group without a second pass.');
        Assert.isNotNull(meters[0].Register_Modulus__c,
            'The formula field must be in the field list - a selector that omitted it would '
            + 'throw SObjectException on read rather than returning null.');
    }

    @isTest
    static void selectByPropertyAssetIds_nullAndEmpty_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Assert.areEqual(0, MeterSelector.selectByPropertyAssetIds(null).size(), 'Null input.');
        Assert.areEqual(0, MeterSelector.selectByPropertyAssetIds(new Set<Id>()).size(),
            'Empty input.');
        Assert.areEqual(before, Limits.getQueries(),
            'Neither may reach the database - an empty IN clause is a wasted query on every '
            + 'property with no meters, which is every property before capture.');
        Test.stopTest();
    }

    @isTest
    static void selectByIds_returnsTheNamedMeters() {
        Set<Id> ids = new Map<Id, Meter__c>([SELECT Id FROM Meter__c LIMIT 2]).keySet();

        Test.startTest();
        List<Meter__c> meters = MeterSelector.selectByIds(ids);
        Test.stopTest();

        Assert.areEqual(2, meters.size(), 'Exactly the meters asked for.');
        Assert.areEqual(0, MeterSelector.selectByIds(null).size(), 'Null is safe.');
        Assert.areEqual(0, MeterSelector.selectByIds(new Set<Id>()).size(), 'Empty is safe.');
    }

    @isTest
    static void selectRegisterByIds_systemMode_returnsTheRolloverInputs() {
        Set<Id> ids = new Map<Id, Meter__c>([SELECT Id FROM Meter__c]).keySet();

        Test.startTest();
        Map<Id, Meter__c> byId = MeterSelector.selectRegisterByIds(ids);
        Test.stopTest();

        Assert.areEqual(3, byId.size(), 'Keyed by meter Id for the trigger path.');
        // `any` is a RESERVED identifier in Apex, like `bulk`. Named `sample` instead.
        Meter__c sample = byId.values()[0];
        Assert.areEqual(5, sample.Register_Size__c, 'The factory builds 5-dial meters.');
        Assert.areEqual(100000, sample.Register_Modulus__c,
            'Register_Modulus__c is a FORMULA over Register_Size__c: a value of 12 or less is '
            + 'read as a DIAL COUNT, so 5 becomes 100000. The whole rollover calculation '
            + 'hangs off this one derivation.');
        Assert.isNotNull(sample.Service_Identifier__c,
            'The ESID is read here because it is the durable service-point id that survives a '
            + 'meter swap.');
        Assert.areEqual(0, MeterSelector.selectRegisterByIds(null).size(), 'Null is safe.');
    }

    @isTest
    static void selectForCapture_ordersWholeBuildingMetersFirst() {
        Test.startTest();
        List<Meter__c> meters = MeterSelector.selectForCapture(assetId());
        Test.stopTest();

        Assert.areEqual(3, meters.size(), 'Every meter at the property.');
        Assert.isNull(meters[0].Unit__c,
            'ORDER BY Unit__r.Suite_Number__c NULLS FIRST. A blank unit means the meter '
            + 'serves the whole building (FSD 5.10.4) - meaningful data, not missing data - '
            + 'so those rows lead the capture grid.');
        Assert.areEqual(0, MeterSelector.selectForCapture(null).size(), 'Null is safe.');
    }

    @isTest
    static void selectByServiceIdentifiers_findsTheServicePoint() {
        Meter__c existing = [SELECT Id, Service_Identifier__c FROM Meter__c LIMIT 1];

        Test.startTest();
        List<Meter__c> found = MeterSelector.selectByServiceIdentifiers(
            new Set<String>{ existing.Service_Identifier__c });
        Test.stopTest();

        Assert.areEqual(1, found.size(),
            'This is what lets the capture screen say "that ESID is already on the register" '
            + '- the earliest point at which a physical meter swap can be named.');
        Assert.areEqual(existing.Id, found[0].Id, 'And it is the right meter.');
        Assert.areEqual(0, MeterSelector.selectByServiceIdentifiers(null).size(),
            'Null is safe.');
        Assert.areEqual(0, MeterSelector.selectByServiceIdentifiers(new Set<String>()).size(),
            'Empty is safe.');
    }
}
