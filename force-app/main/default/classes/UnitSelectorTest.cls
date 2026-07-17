/**
 * Tests for UnitSelector (P4 cleanup wave F2 — PM; custom object).
 *
 * Covers the single relocated query that backs RentRollController.getRentRoll:
 *   - selectByPropertyAssetId : Suite_Number__c ASC NULLS LAST ordering, field
 *     population, the nested Rent_Steps__r subquery ordered by Sort_Order__c ASC
 *     NULLS LAST, the null-input guard, the no-units empty result, and a 251-unit
 *     data-volume read (.claude/rules/bulk-test-rule.md).
 *
 * @TestSetup builds one Property_Asset__c and every test queries for it (never
 * default*()), per the TestDataFactory header warning that the static scaffold cache
 * does NOT survive the @TestSetup boundary.
 *
 * No System.runAs USER_MODE test here: Unit__c is a custom object and P3 proved the
 * custom-field FLS gap is 0, so the running user reads every selected field. The runAs
 * assertion is reserved for standard-object selectors (design §7).
 *
 * @see force-app/main/default/classes/WireSelectorTest.cls (P4 pilot selector-test template)
 */
@isTest
private class UnitSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property_Asset__c pa = TestDataFactory.createPropertyAsset(null, false);
        insert pa;
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectByPropertyAssetId_ordersBySuiteNullsLast_populatesFields() {
        Id paId = assetId();
        List<Unit__c> units = TestDataFactory.createUnits(3, paId, false);
        units[0].Suite_Number__c = 'B-200'; units[0].Tenant_Name__c = 'Tenant B';
        units[0].Status__c = 'Occupied'; units[0].Square_Feet__c = 2000;
        units[0].Current_Monthly_Rent__c = 4000; units[0].NNN_Monthly_Total__c = 700;
        units[1].Suite_Number__c = 'A-100'; units[1].Tenant_Name__c = 'Tenant A';
        units[1].Status__c = 'Occupied'; units[1].Square_Feet__c = 1500;
        units[2].Suite_Number__c = null;    units[2].Tenant_Name__c = null;
        units[2].Status__c = 'Vacant';      units[2].Square_Feet__c = 1000;
        insert units;

        Test.startTest();
        List<Unit__c> rows = UnitSelector.selectByPropertyAssetId(paId);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'All three units under the asset are returned');
        Assert.areEqual('A-100', rows[0].Suite_Number__c, 'Suite_Number__c ASC returns A-100 first');
        Assert.areEqual('B-200', rows[1].Suite_Number__c, 'B-200 sorts after A-100');
        Assert.areEqual(null, rows[2].Suite_Number__c, 'NULLS LAST places the null-suite unit last');
        Assert.areEqual('Tenant A', rows[0].Tenant_Name__c, 'Tenant_Name__c is selected');
        Assert.areEqual('Occupied', rows[0].Status__c, 'Status__c is selected');
        Assert.areEqual(1500, rows[0].Square_Feet__c, 'Square_Feet__c is selected');
        Assert.areEqual(4000, rows[1].Current_Monthly_Rent__c, 'Current_Monthly_Rent__c is selected');
        Assert.areEqual(700, rows[1].NNN_Monthly_Total__c, 'NNN_Monthly_Total__c is selected');
        Assert.isNotNull(rows[0].LastModifiedDate, 'LastModifiedDate is selected for the last-synced stamp');
    }

    @isTest
    static void selectByPropertyAssetId_nestsRentStepsInSortOrder() {
        Id paId = assetId();
        Unit__c u = TestDataFactory.createUnit(paId, false);
        u.Suite_Number__c = 'S-1'; u.Status__c = 'Occupied'; u.Square_Feet__c = 500;
        insert u;
        List<Rent_Step__c> steps = TestDataFactory.createRentSteps(2, u.Id, false);
        steps[0].Sort_Order__c = 2; steps[0].Period_Label__c = 'Years 6-10'; steps[0].Type__c = 'Renewal Option';
        steps[1].Sort_Order__c = 1; steps[1].Period_Label__c = 'Current Term'; steps[1].Type__c = 'Current Term';
        insert steps;

        Test.startTest();
        List<Unit__c> rows = UnitSelector.selectByPropertyAssetId(paId);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One unit returned');
        Assert.areEqual(2, rows[0].Rent_Steps__r.size(), 'Both nested rent steps are returned in the subquery');
        Assert.areEqual('Current Term', rows[0].Rent_Steps__r[0].Period_Label__c,
            'Rent_Steps__r is ordered by Sort_Order__c ASC — Sort_Order__c=1 comes first');
        Assert.areEqual('Years 6-10', rows[0].Rent_Steps__r[1].Period_Label__c,
            'Sort_Order__c=2 comes second');
    }

    @isTest
    static void selectByPropertyAssetId_nullInput_returnsEmpty() {
        Test.startTest();
        List<Unit__c> rows = UnitSelector.selectByPropertyAssetId(null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A null asset Id short-circuits to an empty list, not a query');
    }

    @isTest
    static void selectByPropertyAssetId_noUnits_returnsEmpty() {
        Id paId = assetId();

        Test.startTest();
        List<Unit__c> rows = UnitSelector.selectByPropertyAssetId(paId);
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'An asset with no units returns an empty list, not null');
    }

    @isTest
    static void selectByPropertyAssetId_251Units_returnsAll() {
        Id paId = assetId();
        TestDataFactory.createUnits(BULK_N, paId, true);

        Test.startTest();
        List<Unit__c> rows = UnitSelector.selectByPropertyAssetId(paId);
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(),
            'All 251 units under the asset are returned at data volume (bulk-safe single query)');
    }
}
