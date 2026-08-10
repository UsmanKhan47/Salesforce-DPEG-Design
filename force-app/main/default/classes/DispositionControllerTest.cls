/**
 * @description Test class for DispositionController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Adds branch coverage for getClosingSummary's Wires__r subquery (both states),
 * a delete-based negative scenario, and a 251-record data-volume read test
 * (251 Wire__c children under one Disposition — a real scenario, since a
 * Yardi-mirrored Disposition can legitimately accumulate hundreds of wires).
 *
 * P6 controller thinning: findOrCreate's DML now lives in DispositionService, and
 * every @AuraEnabled method wraps its work in a try/catch that maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). The negative test
 * below therefore now expects an AuraHandledException (not the raw QueryException),
 * and readPathsThrowAuraHandledException covers both catch blocks by running the
 * reads under a bare Standard User whose WITH USER_MODE SOQL on the custom
 * Disposition__c object throws.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * DISPOSITION FOUNDATIONS: findOrCreate NOW HAS TWO CATCHES AND THEY SAY DIFFERENT THINGS
 * ─────────────────────────────────────────────────────────────────────────────────────
 * A sell-meter refusal (DispositionService.SellMeterGateException) is a DESIGNED refusal
 * whose message is authored to be shown, so it is rethrown VERBATIM. Everything else is a
 * platform failure and is masked behind the fixed generic write-failure message. The two
 * are pinned by a MATCHED PAIR of tests below — refusalSurfacesTheSellMeterWording and
 * readPathsThrowAuraHandledException — which assert OPPOSITE message contents. Asserting
 * only "an AuraHandledException was thrown" would pass even if the first catch were
 * deleted, which is exactly the bug the catch exists to prevent.
 *
 * ⚠ FIXTURE PRECONDITION: TestDataFactory.createPropertyAssets does not set
 * Peak_Sell_Date__c, and a null peak bands RED, so an unmodified factory asset is now
 * REFUSED. @TestSetup therefore stamps a GREEN peak date; a test that wants a refusal
 * re-bands the asset explicitly. See DispositionServiceTest's header for why the factory
 * default was deliberately left alone.
 * @author Unit Testing Agent
 */
@isTest
private class DispositionControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        // GREEN band (<= 30 days to peak): required before findOrCreate will create.
        asset.Peak_Sell_Date__c = Date.today().addDays(10);
        insert asset;
    }

    // A valid-format but non-existent Id for the given type. The bare-user reads throw on
    // object ACCESS under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL on the custom
    // Disposition__c object (no object access) throws, exercising the controllers'
    // read-failure catch which maps it to a user-safe AuraHandledException (P6).
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

    /**
     * 🔴 THE FIRST CATCH. A red-band refusal must reach the user as the SELL-METER wording,
     * not the generic "This change could not be saved. Refresh the page and try again" —
     * which is advice that can never work, because refreshing will refuse identically
     * forever. This test asserts BOTH halves: the refusal text is present AND the generic
     * text is absent. Deleting DispositionController's SellMeterGateException catch turns
     * this red; asserting only that "an AuraHandledException was thrown" would not.
     */
    @isTest
    static void refusalSurfacesTheSellMeterWording() {
        Property_Asset__c asset = [SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c LIMIT 1];
        asset.Peak_Sell_Date__c = Date.today().addDays(200); // > 90 days => RED
        update asset;

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionController.findOrCreate(asset.Id);
            Assert.fail('A RED asset must be refused at the controller boundary too');
        } catch (AuraHandledException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('not ready to sell'),
                'The user must see the sell-meter refusal, not a generic write failure: ' + e.getMessage());
            Assert.isFalse(e.getMessage().contains('could not be saved'),
                'A designed refusal must NOT be masked behind the generic write-failure message: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The RED asset should have surfaced an AuraHandledException');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused creation must leave no Disposition behind');
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
    static void testGetClosingSummary_invalidId_throwsAuraHandledException() {
        // P6: the selector's raw QueryException is now caught in the controller and
        // re-thrown as a user-safe AuraHandledException at the LWC boundary. A deleted
        // Disposition Id makes the single-row selector SOQL fail under admin — the
        // deterministic way to reach the read-failure catch without a bare user.
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, true);
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        try {
            DispositionController.getClosingSummary(deletedId);
            Assert.fail('Expected an AuraHandledException for a Disposition Id that no longer exists');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'getClosingSummary read failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    // Runs findOrCreate and getClosingSummary under a bare Standard User: WITH USER_MODE
    // on the custom Disposition__c object throws (no object access), exercising both
    // controllers' read-failure catch that maps it to a user-safe AuraHandledException.
    // Kept in its own method: bareUser() inserts a User (setup DML), so mixing it with
    // record DML in one transaction would raise MIXED_DML_OPERATION. The reads throw at
    // the query before any DML, so no record DML runs here.
    @isTest
    static void readPathsThrowAuraHandledException() {
        User u = bareUser();
        Id fakeAssetId = fakeId(Property_Asset__c.SObjectType);
        Id fakeDispId = fakeId(Disposition__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try {
                DispositionController.findOrCreate(fakeAssetId);
                Assert.fail('expected AuraHandledException from findOrCreate under a bare user');
            } catch (AuraHandledException e) {
                // The other half of the matched pair with refusalSurfacesTheSellMeterWording:
                // a PLATFORM failure must be MASKED behind the generic message, and must NOT
                // borrow the sell-meter wording (nothing about the band was even reached here).
                Assert.isTrue(e.getMessage().contains('could not be saved'),
                    'A platform read failure maps to the generic write-failure message: ' + e.getMessage());
                Assert.isFalse(e.getMessage().contains('not ready to sell'),
                    'A platform failure must not be reported as a sell-meter refusal: ' + e.getMessage());
            }
            try {
                DispositionController.getClosingSummary(fakeDispId);
                Assert.fail('expected AuraHandledException from getClosingSummary under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getClosingSummary read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
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
