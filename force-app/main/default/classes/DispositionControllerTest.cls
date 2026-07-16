/**
 * @description Test class for DispositionController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Adds branch coverage for getClosingSummary's Wires__r subquery (both states),
 * a delete-based negative scenario, and a 251-record data-volume read test
 * (251 Wire__c children under one Disposition — a real scenario, since a
 * Yardi-mirrored Disposition can legitimately accumulate hundreds of wires).
 *
 * findOrCreate(Id) carries inline SOQL + DML with no Selector/Service
 * delegation (apex-layering-rule.md violation). NOT tested here at 251 calls:
 * it is a single-record @AuraEnabled method invoked once per LWC click, and a
 * user cannot click 251 times in one transaction — a sequential-call loop
 * would test a state production cannot produce. Logged as a layering finding
 * for Phase 4 (Selectors) / Phase 6 (controller thinning) instead.
 * @author Unit Testing Agent
 */
@isTest
private class DispositionControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    @isTest
    static void testFindOrCreate_noExistingDisposition_createsOne() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        String dispId = DispositionController.findOrCreate(asset.Id);
        Test.stopTest();

        System.assertNotEquals(null, dispId, 'A new Disposition Id should be returned');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        System.assertEquals(1, count, 'Exactly one Disposition should be created for the asset');
    }

    @isTest
    static void testFindOrCreate_existingDisposition_isIdempotent() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        String dispId1 = DispositionController.findOrCreate(asset.Id);
        String dispId2 = DispositionController.findOrCreate(asset.Id);
        Test.stopTest();

        System.assertEquals(dispId1, dispId2, 'Second call should return the same Disposition Id, not create a duplicate');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        System.assertEquals(1, count, 'find-or-create must not duplicate the Disposition');
    }

    @isTest
    static void testGetClosingSummary_noWires_returnsWireCreatedFalse() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;

        Test.startTest();
        DispositionController.DispositionRow row = DispositionController.getClosingSummary(d.Id);
        Test.stopTest();

        System.assertNotEquals(null, row, 'A row should be returned for a valid Disposition Id');
        System.assertEquals('Closing', row.stage, 'Stage should pass through unchanged');
        System.assertEquals(false, row.wireCreated, 'No Wire__c exists yet, so wireCreated should be false');
    }

    @isTest
    static void testGetClosingSummary_withWire_returnsWireCreatedTrue() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;
        TestDataFactory.createWire(d.Id, true);

        Test.startTest();
        DispositionController.DispositionRow row = DispositionController.getClosingSummary(d.Id);
        Test.stopTest();

        System.assertEquals(true, row.wireCreated, 'A Wire__c child exists, so wireCreated should flip to true');
    }

    @isTest
    static void testGetClosingSummary_invalidId_throwsQueryException() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, true);
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        try {
            DispositionController.getClosingSummary(deletedId);
            System.assert(false, 'Expected a QueryException for a Disposition Id that no longer exists');
        } catch (System.QueryException e) {
            System.assertEquals(true, e.getMessage().toLowerCase().contains('no rows'),
                'Exception message should indicate no matching Disposition row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251 Wire__c
     * children under one Disposition, inserted via a single bulk DML statement
     * (TestDataFactory.createWires), to prove the `(SELECT Id FROM Wires__r
     * LIMIT 1)` subquery in getClosingSummary stays correct and cheap at volume.
     */
    @isTest
    static void testGetClosingSummary_251Wires_subqueryStillResolvesCorrectly() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, true);
        TestDataFactory.createWires(251, d.Id, true);

        Test.startTest();
        DispositionController.DispositionRow row = DispositionController.getClosingSummary(d.Id);
        Test.stopTest();

        Integer wireCount = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :d.Id];
        System.assertEquals(251, wireCount, 'All 251 wires should have been inserted');
        System.assertEquals(true, row.wireCreated, 'wireCreated should be true with 251 Wire__c children present');
    }
}
