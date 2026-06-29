@isTest
private class WireControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = new Property__c(Name = 'Test Property');
        insert prop;
        Property_Asset__c asset = new Property_Asset__c(
            Property__c = prop.Id, Name = 'Test Asset',
            NOI__c = 1000000, Market_Cap_Rate__c = 6.0, Target_Sale_Price__c = 15000000
        );
        insert asset;
        Disposition__c d = new Disposition__c(
            Property_Asset__c = asset.Id, Disposition_Stage__c = 'Closing'
        );
        insert d;
        insert new Wire__c(
            Disposition__c = d.Id,
            Verbal_Verification_Completed__c = false
        );
    }

    @isTest
    static void testGetWire() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Test.startTest();
        WireController.WireRow row = WireController.getWire(d.Id);
        Test.stopTest();
        System.assertNotEquals(null, row);
        System.assertEquals(0, row.fieldsComplete);
        System.assertEquals(false, row.verbalVerificationCompleted);
    }

    @isTest
    static void testSaveWire() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Test.startTest();
        WireController.WireRow row = WireController.saveWire(
            d.Id, null, true, 'Jane Smith', '555-1234',
            'Called title company direct line', 28500000
        );
        Test.stopTest();
        System.assertEquals(true, row.verbalVerificationCompleted);
        System.assertNotEquals(null, row.verifiedDateTime);
        System.assertEquals(6, row.fieldsComplete);
    }
}