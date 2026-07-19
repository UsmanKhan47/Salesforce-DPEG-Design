/**
 * @description Tests WireService — the Wire upsert / verification-stamp workflow extracted
 * from WireController in P6 controller thinning.
 *
 * Covers the create-new, update-existing and turn-verification-off paths, asserting the
 * Verified_DateTime__c stamp/clear behaviour on the persisted record. The service does a
 * single upsert with no savepoint/rollback and no collection DML, so there is no rollback
 * catch to force and no 251-record bulk scenario applies (saveWire is a single-record
 * @AuraEnabled operation invoked once per LWC save).
 *
 * @see force-app/main/default/classes/WireService.cls
 * @author Unit Testing Agent
 */
@isTest
private class WireServiceTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;
    }

    @isTest
    static void saveWireCreatesAndStampsVerifiedDateTime() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        Id wireId = WireService.saveWire(d.Id, null, true, 'Jane Smith', '555-1234',
            'Called title company direct line', 28500000);
        Test.stopTest();

        Assert.isNotNull(wireId, 'saveWire returns the saved Wire Id');
        Wire__c w = [SELECT Verbal_Verification_Completed__c, Verified_DateTime__c, Confirmed_Wire_Amount__c
                     FROM Wire__c WHERE Id = :wireId];
        Assert.isTrue(w.Verbal_Verification_Completed__c, 'Verbal verification is saved as true');
        Assert.isNotNull(w.Verified_DateTime__c, 'Turning verification on stamps Verified_DateTime__c');
        Assert.areEqual(28500000, w.Confirmed_Wire_Amount__c, 'The confirmed amount is saved');
        Integer count = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :d.Id];
        Assert.areEqual(1, count, 'A null wireId creates exactly one Wire');
    }

    @isTest
    static void saveWireUpdatesExistingInPlace() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Wire__c existing = TestDataFactory.createWire(d.Id, true);

        Test.startTest();
        Id savedId = WireService.saveWire(d.Id, existing.Id, true, 'Updated Verifier', '555-9999',
            'Direct line', 30000000);
        Test.stopTest();

        Assert.areEqual(existing.Id, savedId, 'An existing wireId updates in place, not create');
        Wire__c w = [SELECT Verifier_Name__c, Confirmed_Wire_Amount__c FROM Wire__c WHERE Id = :existing.Id];
        Assert.areEqual('Updated Verifier', w.Verifier_Name__c, 'The verifier name is updated');
        Assert.areEqual(30000000, w.Confirmed_Wire_Amount__c, 'The confirmed amount is updated');
        Integer count = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :d.Id];
        Assert.areEqual(1, count, 'Updating an existing Wire does not create a second record');
    }

    @isTest
    static void saveWireTurningVerificationOffClearsDateTime() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Id wireId = WireService.saveWire(d.Id, null, true, 'Jane Smith', '555-1234', 'Called title', 28500000);
        Wire__c onRow = [SELECT Verified_DateTime__c FROM Wire__c WHERE Id = :wireId];
        Assert.isNotNull(onRow.Verified_DateTime__c, 'Sanity check: verification-on stamps the timestamp first');

        Test.startTest();
        WireService.saveWire(d.Id, wireId, false, 'Jane Smith', '555-1234', 'Called title', 28500000);
        Test.stopTest();

        Wire__c offRow = [SELECT Verbal_Verification_Completed__c, Verified_DateTime__c FROM Wire__c WHERE Id = :wireId];
        Assert.isFalse(offRow.Verbal_Verification_Completed__c, 'Verification is now false');
        Assert.isNull(offRow.Verified_DateTime__c, 'Turning verification off clears Verified_DateTime__c');
    }
}
