/**
 * @description Test class for WireController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Adds coverage for the two previously-untested saveWire branches (updating an
 * existing record via wireId, and turning verification back off to clear
 * Verified_DateTime__c — the gap behind the reported 92.3% coverage), a
 * delete-based negative scenario, and a 251-record data-volume read test
 * (251 Wire__c under one Disposition — a real scenario, since a
 * Yardi-mirrored Disposition can legitimately accumulate hundreds of wires).
 *
 * saveWire(...) carries inline SOQL + DML with no Selector/Service delegation
 * (apex-layering-rule.md violation). NOT tested here at 251 calls: it is a
 * single-record @AuraEnabled method invoked once per LWC click, and a user
 * cannot click 251 times in one transaction — a sequential-call loop would
 * test a state production cannot produce. Logged as a layering finding for
 * Phase 4 (Selectors) / Phase 6 (controller thinning) instead.
 *
 * ⚠ KNOWN PRODUCTION DEFECT — testSaveWire_existingWireId_updatesInPlace is
 * EXPECTED TO FAIL until saveWire(...) is fixed; this is not a test-authoring
 * bug. saveWire's existing-record branch queries
 * `[SELECT Id FROM Wire__c WHERE Id = :wireId LIMIT 1]` (Id only) and then,
 * when verbalDone == true, reads `w.Verified_DateTime__c` on the very next
 * line to decide whether to stamp it — a field that row was never queried
 * for. That throws System.SObjectException: SObject row was retrieved via
 * SOQL without querying the requested field: Wire__c.Verified_DateTime__c.
 * (The sibling turn-verification-off test does NOT hit this: verbalDone ==
 * false short-circuits the `&&` before the unqueried field is ever read —
 * only assigned to, which needs no prior query. That's why exactly one of
 * the two existing-record saveWire tests fails, not both.) There is no
 * SOQL in this test class that omits the field — the fix belongs in
 * WireController.saveWire's own SELECT and is out of this agent's
 * test-classes-only boundary. Left asserting the correct behavior on
 * purpose; do not weaken this assertion to route around the bug.
 * @author Unit Testing Agent
 */
@isTest
private class WireControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;
    }

    @isTest
    static void testGetWire_noWireForDisposition_returnsNull() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        WireController.WireRow row = WireController.getWire(d.Id);
        Test.stopTest();

        System.assertEquals(null, row, 'No Wire__c exists yet, so getWire should return null');
    }

    @isTest
    static void testGetWire_allFieldsEmpty_fieldsCompleteIsZero() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Wire__c w = TestDataFactory.createWire(d.Id, false);
        w.Verifier_Name__c = null;
        w.Verifier_Phone__c = null;
        w.Wire_Instructions_Source__c = null;
        w.Confirmed_Wire_Amount__c = null;
        insert w;

        Test.startTest();
        WireController.WireRow row = WireController.getWire(d.Id);
        Test.stopTest();

        System.assertNotEquals(null, row, 'A row should be returned for a Disposition with one Wire__c');
        System.assertEquals(0, row.fieldsComplete, 'No fields populated means fieldsComplete should be 0');
        System.assertEquals(false, row.verbalVerificationCompleted, 'Verbal verification defaults to false');
    }

    @isTest
    static void testGetWire_mostRecentWireWins() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        TestDataFactory.createWire(d.Id, true);
        Wire__c newer = TestDataFactory.createWire(d.Id, false);
        newer.Verifier_Name__c = 'Newest Verifier';
        insert newer;

        Test.startTest();
        WireController.WireRow row = WireController.getWire(d.Id);
        Test.stopTest();

        System.assertEquals('Newest Verifier', row.verifierName,
            'ORDER BY CreatedDate DESC, Id DESC should return the most recently created Wire__c');
    }

    @isTest
    static void testSaveWire_newRecord_setsVerifiedDateTimeAndAllFields() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        WireController.WireRow row = WireController.saveWire(
            d.Id, null, true, 'Jane Smith', '555-1234',
            'Called title company direct line', 28500000
        );
        Test.stopTest();

        System.assertEquals(true, row.verbalVerificationCompleted, 'Verbal verification should be saved as true');
        System.assertNotEquals(null, row.verifiedDateTime, 'Turning verification on should stamp Verified_DateTime__c');
        System.assertEquals(6, row.fieldsComplete, 'All six tracked fields should be complete');
        Integer wireCount = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :d.Id];
        System.assertEquals(1, wireCount, 'saveWire with no wireId should create exactly one Wire__c');
    }

    @isTest
    static void testSaveWire_existingWireId_updatesInPlace() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Wire__c existing = TestDataFactory.createWire(d.Id, true);

        Test.startTest();
        WireController.WireRow row = WireController.saveWire(
            d.Id, existing.Id, true, 'Jane Smith', '555-1234',
            'Called title company direct line', 28500000
        );
        Test.stopTest();

        System.assertEquals(existing.Id, row.id, 'saveWire with an existing wireId should update, not create');
        Integer wireCount = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :d.Id];
        System.assertEquals(1, wireCount, 'Updating an existing Wire__c should not create a second record');
    }

    @isTest
    static void testSaveWire_turningVerificationOff_clearsVerifiedDateTime() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        WireController.WireRow onRow = WireController.saveWire(
            d.Id, null, true, 'Jane Smith', '555-1234', 'Called title company', 28500000
        );
        System.assertNotEquals(null, onRow.verifiedDateTime, 'Sanity check: verification-on should set the timestamp first');

        Test.startTest();
        WireController.WireRow offRow = WireController.saveWire(
            d.Id, onRow.id, false, 'Jane Smith', '555-1234', 'Called title company', 28500000
        );
        Test.stopTest();

        System.assertEquals(false, offRow.verbalVerificationCompleted, 'Verification should now be false');
        System.assertEquals(null, offRow.verifiedDateTime, 'Turning verification back off should clear Verified_DateTime__c');
    }

    @isTest
    static void testSaveWire_invalidWireId_throwsQueryException() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Wire__c w = TestDataFactory.createWire(d.Id, true);
        Id deletedId = w.Id;
        delete w;

        Test.startTest();
        try {
            WireController.saveWire(d.Id, deletedId, true, 'Jane', '555-1234', 'source', 100);
            System.assert(false, 'Expected a QueryException for a Wire Id that no longer exists');
        } catch (System.QueryException e) {
            System.assertEquals(true, e.getMessage().toLowerCase().contains('no rows'),
                'Exception message should indicate no matching Wire__c row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251 Wire__c
     * rows under one Disposition, inserted via a single bulk DML statement, to
     * prove the ORDER BY CreatedDate DESC, Id DESC ... LIMIT 1 pattern still
     * resolves to exactly one row at volume.
     */
    @isTest
    static void testGetWire_251Wires_limitOneStillResolves() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        TestDataFactory.createWires(251, d.Id, true);

        Test.startTest();
        WireController.WireRow row = WireController.getWire(d.Id);
        Test.stopTest();

        Integer wireCount = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :d.Id];
        System.assertEquals(251, wireCount, 'All 251 wires should have been inserted');
        System.assertNotEquals(null, row, 'getWire should still resolve exactly one row at volume');
    }
}
