/**
 * @description Tests DispositionService — the find-or-create Disposition write workflow
 * extracted from DispositionController in P6 controller thinning.
 *
 * Covers the create-new and idempotent-existing paths. The service does a single insert
 * with no savepoint/rollback and no collection DML, so there is no rollback catch to force
 * and no 251-record bulk scenario applies (findOrCreate is a single-record @AuraEnabled
 * operation invoked once per LWC click).
 *
 * @see force-app/main/default/classes/DispositionService.cls
 * @author Unit Testing Agent
 */
@isTest
private class DispositionServiceTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    @isTest
    static void findOrCreateCreatesWhenNoneExists() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        Id dispId = DispositionService.findOrCreate(asset.Id);
        Test.stopTest();

        Assert.isNotNull(dispId, 'A new Disposition Id should be returned');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        Assert.areEqual(1, count, 'Exactly one Disposition should be created for the asset');
    }

    @isTest
    static void findOrCreateIsIdempotent() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        Id first = DispositionService.findOrCreate(asset.Id);
        Id second = DispositionService.findOrCreate(asset.Id);
        Test.stopTest();

        Assert.areEqual(first, second, 'A second call returns the same Disposition, not a duplicate');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        Assert.areEqual(1, count, 'find-or-create must not duplicate the Disposition');
    }
}
