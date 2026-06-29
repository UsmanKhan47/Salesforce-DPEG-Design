@isTest
private class BovControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = new Property__c(Name = 'Test Property');
        insert prop;
        Property_Asset__c asset = new Property_Asset__c(
            Property__c = prop.Id, Name = 'Test Asset',
            NOI__c = 2000000, Market_Cap_Rate__c = 6.5, Target_Sale_Price__c = 28500000
        );
        insert asset;
        Disposition__c d = new Disposition__c(
            Property_Asset__c = asset.Id,
            Disposition_Stage__c = 'BOV Outreach',
            Package_Sent__c = Date.today().addDays(-15),
            Submission_Deadline__c = Date.today().addDays(1),
            Responses_Received__c = 4,
            Brokers_Contacted__c = 6,
            Selected_Broker__c = 'CBRE · Mark Chen'
        );
        insert d;
        insert new BOV_Submission__c(
            Disposition__c = d.Id, Broker_Firm__c = 'CBRE', Contact_Name__c = 'Mark Chen',
            BOV_Amount__c = 28500000, Commission_Rate__c = 3.0, Days_To_Market__c = 45,
            Hist_Success_Rate__c = 82, BOV_Score__c = 91, Submission_Status__c = 'Selected'
        );
        insert new BOV_Submission__c(
            Disposition__c = d.Id, Broker_Firm__c = 'JLL', Contact_Name__c = 'K. Rao',
            BOV_Amount__c = 27900000, Commission_Rate__c = 2.5, Days_To_Market__c = 52,
            Hist_Success_Rate__c = 78, BOV_Score__c = 84, Submission_Status__c = 'Backup'
        );
    }

    @isTest
    static void testGetSubmissions() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();
        System.assertEquals(2, rows.size());
        System.assertEquals('CBRE', rows[0].brokerFirm);
        System.assertEquals(true, rows[0].isSelected);
        System.assertEquals(91, rows[0].bovScore);
    }

    @isTest
    static void testGetOutreachSummary() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();
        System.assertEquals(4, s.responsesReceived);
        System.assertEquals(true, s.matrixGenerated);
        System.assertEquals('CBRE · Mark Chen', s.selectedBroker);
    }
}