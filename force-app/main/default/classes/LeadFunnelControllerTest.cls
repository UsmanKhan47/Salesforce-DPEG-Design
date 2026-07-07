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
        // Older lead from a high-priority broker: must surface FIRST despite its age.
        leads.add(new Lead(LastName = 'Patel', Company = 'JLL', Status = 'Under Review',
            LeadSource = 'Manual Entry', Parse_Confidence__c = 'HIGH',
            Guidance_Price__c = 12500000, Broker_First__c = 'JLL',
            Property_Address__c = 'I-35 Strip Center', Asset_Type__c = 'Retail',
            Broker_Priority__c = 'High', Approved_for_UW__c = true,
            First_Seen_Date__c = Datetime.now().addDays(-20)));
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
        System.assertEquals(true, first.approved, 'Approval flag carried to the row');
        System.assertNotEquals(null, first.approvedBy, 'Approver name carried to the row');

        // BP window: First Seen 10 days ago -> ~80 days remaining, expiry still active.
        LeadFunnelController.LeadRow row = data.recent[1];
        System.assertEquals(10, row.days, 'Age derived from First Seen Date');
        System.assertEquals(Date.today().addDays(80), row.bpExpiry, 'BP expiry = First Seen + 90');
        System.assertEquals(true, row.bpActive, 'BP window still active');
        System.assertEquals(false, row.approved, 'Unapproved lead reports approved=false');
    }
}