@isTest
private class LeadFunnelControllerTest {
    @testSetup
    static void setup() {
        List<Lead> leads = new List<Lead>();
        leads.add(new Lead(LastName = 'Chen', Company = 'CBRE', Status = 'New',
            LeadSource = 'Email-to-Lead', Parse_Confidence__c = 'HIGH',
            Guidance_Price__c = 18800000, Broker_First__c = 'CBRE',
            Property_Address__c = 'Hwy 290 Retail', Asset_Type__c = 'Retail',
            First_Seen_Date__c = Datetime.now().addDays(-10)));
        leads.add(new Lead(LastName = 'Rivera', Company = 'Marcus & Millichap', Status = 'Under Review',
            LeadSource = 'Broker Portal', Parse_Confidence__c = 'LOW',
            Guidance_Price__c = 9400000, Broker_First__c = 'Marcus & Millichap',
            Property_Address__c = 'Mills Outparcel', Asset_Type__c = 'Retail',
            First_Seen_Date__c = Datetime.now().addDays(-10)));
        insert leads;
    }

    @isTest
    static void testGetFunnel() {
        Test.startTest();
        LeadFunnelController.FunnelData data = LeadFunnelController.getFunnel();
        Test.stopTest();

        System.assertEquals(5, data.stages.size(), 'Five stages expected');
        System.assertEquals(3, data.channels.size(), 'Three channels expected');
        System.assertEquals(2, data.total, 'Two leads seeded');
        System.assertEquals(1, data.reviewQueue, 'One LOW-confidence lead');

        // BP window: First Seen 10 days ago -> ~80 days remaining, expiry still active.
        LeadFunnelController.LeadRow row = data.recent[0];
        System.assertEquals(10, row.days, 'Age derived from First Seen Date');
        System.assertEquals(Date.today().addDays(80), row.bpExpiry, 'BP expiry = First Seen + 90');
        System.assertEquals(true, row.bpActive, 'BP window still active');
    }
}