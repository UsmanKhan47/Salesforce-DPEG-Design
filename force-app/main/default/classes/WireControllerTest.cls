/**
 * @description Test class for WireController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Covers both saveWire branches (updating an existing record via wireId, and turning
 * verification back off to clear Verified_DateTime__c), a delete-based negative scenario,
 * and a 251-record data-volume read test (251 Wire__c under one Disposition — a real
 * scenario, since a Yardi-mirrored Disposition can accumulate hundreds of wires).
 *
 * P6 controller thinning: the upsert / stamp logic now lives in WireService, and every
 * @AuraEnabled method wraps its work in a try/catch that maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). The invalid-wireId
 * negative test therefore now expects an AuraHandledException (not the raw
 * QueryException), and readPathsThrowAuraHandledException covers getWire's catch under a
 * bare Standard User whose WITH USER_MODE SOQL on the custom Wire__c object throws.
 *
 * The prior existing-record SObjectException defect is resolved: WireSelector's
 * selectRequiredById returns Verified_DateTime__c, so the update path can read it before
 * deciding whether to (re-)stamp — testSaveWire_existingWireId_updatesInPlace asserts the
 * in-place update directly.
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

    // A valid-format but non-existent Id for the given type. The bare-user read throws on
    // object ACCESS under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL on the custom
    // Wire__c object (no object access) throws, exercising getWire's read-failure catch
    // which maps it to a user-safe AuraHandledException (P6).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
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
    static void testSaveWire_invalidWireId_throwsAuraHandledException() {
        // P6: the selector's raw QueryException is now caught in the controller and
        // re-thrown as a user-safe AuraHandledException at the LWC boundary. A deleted
        // Wire Id makes the single-row selector SOQL fail under admin — the deterministic
        // way to reach saveWire's write-failure catch.
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Wire__c w = TestDataFactory.createWire(d.Id, true);
        Id deletedId = w.Id;
        delete w;

        Test.startTest();
        try {
            WireController.saveWire(d.Id, deletedId, true, 'Jane', '555-1234', 'source', 100);
            Assert.fail('Expected an AuraHandledException for a Wire Id that no longer exists');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'saveWire failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    // Runs getWire under a bare Standard User: WITH USER_MODE on the custom Wire__c object
    // throws (no object access), exercising getWire's read-failure catch that maps it to a
    // user-safe AuraHandledException. Kept in its own method: bareUser() inserts a User
    // (setup DML), and getWire only queries (no record DML), so no MIXED_DML_OPERATION.
    @isTest
    static void readPathsThrowAuraHandledException() {
        User u = bareUser();
        Id fakeDispId = fakeId(Disposition__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try {
                WireController.getWire(fakeDispId);
                Assert.fail('expected AuraHandledException from getWire under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getWire read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251 Wire__c rows
     * under one Disposition, inserted via a single bulk DML statement, to prove the
     * ORDER BY CreatedDate DESC, Id DESC ... LIMIT 1 pattern still resolves to exactly one
     * row at volume.
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
