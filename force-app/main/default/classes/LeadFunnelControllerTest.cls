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

    // ── P6 boundary coverage ─────────────────────────────────────────────────────
    // A bare Standard User with no DPEG perm sets: LeadSelector.selectRecent selects custom
    // Lead fields (Parse_Confidence__c, Guidance_Price__c, …) the bare user has no FLS on, so
    // WITH USER_MODE throws — exercising getFunnel's read-failure catch (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6lf', Email = 'p6lf@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6LeadFunnel', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6lf.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers the First Seen Date -> CreatedDate fallback: a lead with no First_Seen_Date__c
     * makes getFunnel derive age/BP-window from CreatedDate instead. Isolated in its own
     * method so the seeded three-lead assertions in testGetFunnel are unaffected.
     */
    @isTest
    static void getFunnel_leadWithoutFirstSeenDate_fallsBackToCreatedDate() {
        // Uniquely named/addressed so the org's Lead duplicate rule (which matches live
        // records, including the @testSetup leads, even in tests) does not block the insert.
        String uniq = String.valueOf(DateTime.now().getTime()) + Math.mod(Crypto.getRandomInteger(), 100000);
        String addr = 'No-FirstSeen Parcel ' + uniq;
        Lead l = TestDataFactory.createLeads(1, false)[0];
        l.FirstName = 'NoFS';
        l.LastName = 'NoFirstSeen ' + uniq;
        l.LeadSource = 'Manual Entry';
        l.Parse_Confidence__c = 'HIGH';
        l.Property_Address__c = addr;
        l.First_Seen_Date__c = null;
        insert l;

        Test.startTest();
        LeadFunnelController.FunnelData data = LeadFunnelController.getFunnel();
        Test.stopTest();

        Boolean found = false;
        for (LeadFunnelController.LeadRow r : data.recent) {
            if (r.name == addr) {
                found = true;
                System.assertEquals(Date.today(), r.created, 'Age anchor falls back to CreatedDate when First Seen is null');
                System.assertEquals(0, r.days, 'A lead created today with no First Seen is 0 days old');
                System.assertEquals(Date.today().addDays(90), r.bpExpiry, 'BP expiry derived from the CreatedDate fallback');
            }
        }
        System.assert(found, 'The no-First-Seen lead is present in the funnel');
    }

    /**
     * Covers getFunnel's read-failure catch: under a bare Standard User with no FLS on the
     * custom Lead funnel fields, the WITH USER_MODE recent-leads query throws and the
     * controller maps it to a user-safe AuraHandledException.
     */
    @isTest
    static void getFunnelReadFailureThrowsAuraHandledException() {
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try {
                LeadFunnelController.getFunnel();
                Assert.fail('getFunnel should throw under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getFunnel maps read failure to AuraHandledException');
            }
            Test.stopTest();
        }
    }
}
