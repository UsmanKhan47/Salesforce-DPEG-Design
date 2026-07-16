@isTest
private class LeadFunnelControllerTest {
    @testSetup
    static void setup() {
        List<Lead> leads = TestDataFactory.createLeads(3, false);

        leads[0].LeadSource = 'Email-to-Lead';
        leads[0].Parse_Confidence__c = 'HIGH';
        leads[0].Guidance_Price__c = 18800000;
        leads[0].Broker_First__c = 'CBRE';
        leads[0].Property_Address__c = 'Hwy 290 Retail';
        leads[0].Asset_Type__c = 'Retail';
        leads[0].First_Seen_Date__c = Datetime.now().addDays(-10);

        leads[1].LeadSource = 'Broker Portal';
        leads[1].Parse_Confidence__c = 'LOW';
        leads[1].Guidance_Price__c = 9400000;
        leads[1].Broker_First__c = 'Marcus & Millichap';
        leads[1].Property_Address__c = 'Mills Outparcel';
        leads[1].Asset_Type__c = 'Retail';
        leads[1].First_Seen_Date__c = Datetime.now().addDays(-10);

        // Older lead from a high-priority broker: must surface FIRST despite its age.
        leads[2].LeadSource = 'Manual Entry';
        leads[2].Parse_Confidence__c = 'HIGH';
        leads[2].Guidance_Price__c = 12500000;
        leads[2].Broker_First__c = 'JLL';
        leads[2].Property_Address__c = 'I-35 Strip Center';
        leads[2].Asset_Type__c = 'Retail';
        leads[2].Broker_Priority__c = 'High';
        leads[2].First_Seen_Date__c = Datetime.now().addDays(-20);

        insert leads;
    }

    @isTest
    static void testGetFunnel() {
        Test.startTest();
        LeadFunnelController.FunnelData data = LeadFunnelController.getFunnel();
        Test.stopTest();

        System.assertEquals(5, data.stages.size(), 'Five stages expected');
        System.assertEquals(3, data.channels.size(), 'Three channels expected');
        System.assertEquals(3, data.total, 'Three leads seeded');
        System.assertEquals(1, data.reviewQueue, 'One LOW-confidence lead');

        // High-priority broker leads outrank recency.
        LeadFunnelController.LeadRow first = data.recent[0];
        System.assertEquals('I-35 Strip Center', first.name, 'High-priority broker lead surfaces first');
        System.assertEquals('High', first.priority, 'Priority carried to the row');

        // BP window: First Seen 10 days ago -> ~80 days remaining, expiry still active.
        LeadFunnelController.LeadRow row = data.recent[1];
        System.assertEquals(10, row.days, 'Age derived from First Seen Date');
        System.assertEquals(Date.today().addDays(80), row.bpExpiry, 'BP expiry = First Seen + 90');
        System.assertEquals(true, row.bpActive, 'BP window still active');
    }
}
