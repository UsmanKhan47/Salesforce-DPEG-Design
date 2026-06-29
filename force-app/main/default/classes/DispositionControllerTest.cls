@isTest
private class DispositionControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = new Property__c(Name = 'Test Property');
        insert prop;
        Property_Asset__c asset = new Property_Asset__c(
            Property__c = prop.Id, Name = 'Test Asset',
            NOI__c = 1000000, Market_Cap_Rate__c = 6.0, Target_Sale_Price__c = 15000000
        );
        insert asset;
    }

    @isTest
    static void testFindOrCreate() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Test.startTest();
        String dispId = DispositionController.findOrCreate(asset.Id);
        Test.stopTest();
        System.assertNotEquals(null, dispId);
        // calling again returns same record
        String dispId2 = DispositionController.findOrCreate(asset.Id);
        System.assertEquals(dispId, dispId2);
    }

    @isTest
    static void testGetClosingSummary() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = new Disposition__c(Property_Asset__c = asset.Id, Disposition_Stage__c = 'Closing');
        insert d;
        Test.startTest();
        DispositionController.DispositionRow row = DispositionController.getClosingSummary(d.Id);
        Test.stopTest();
        System.assertNotEquals(null, row);
        System.assertEquals('Closing', row.stage);
        System.assertEquals(false, row.wireCreated);
    }
}