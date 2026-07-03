@isTest
private class LeaseRenewalControllerTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='Westgate Plaza', Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail');
        insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='Westgate Plaza', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
        insert pa;
        Date t = Date.today();
        // r1 non-responsive + expiring<=90; r2 fresh no contact; r3 critical <=30d;
        // r4 Renewed (flow -> Closed Won + Renewed_Date); r5 Vacating (flow -> Closed Lost);
        // r6 pending approval, active.
        List<Lease_Renewal__c> rs = new List<Lease_Renewal__c>{
            new Lease_Renewal__c(Tenant_Name__c='Riverside Dental', Property_Asset__c=pa.Id, Unit__c='Suite 120', Lease_End__c=t.addDays(80), Stage__c='Awaiting Tenant Response', Last_Contact_Date__c=t.addDays(-20)),
            new Lease_Renewal__c(Tenant_Name__c='Pearl Nails', Property_Asset__c=pa.Id, Unit__c='Suite 3', Lease_End__c=t.addDays(150), Stage__c='Not Yet Started'),
            new Lease_Renewal__c(Tenant_Name__c='Golden Wok', Property_Asset__c=pa.Id, Unit__c='Unit 8', Lease_End__c=t.addDays(25), Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-3), Proposed_Rate__c=25.20),
            new Lease_Renewal__c(Tenant_Name__c='Anytime Fitness', Property_Asset__c=pa.Id, Unit__c='Anchor B', Lease_End__c=t.addDays(-2), Stage__c='Renewed'),
            new Lease_Renewal__c(Tenant_Name__c='Elite Barbers', Property_Asset__c=pa.Id, Unit__c='Suite 7', Lease_End__c=t.addDays(28), Stage__c='Vacating'),
            new Lease_Renewal__c(Tenant_Name__c='TechHub Coworking', Property_Asset__c=pa.Id, Unit__c='Floor 2', Lease_End__c=t.addDays(40), Stage__c='Escalated for Approval', Approval_Status__c='Pending', Last_Contact_Date__c=t.addDays(-7), Proposed_Rate__c=24.00)
        };
        insert rs;
        insert new List<Renewal_Activity__c>{
            new Renewal_Activity__c(Lease_Renewal__c=rs[0].Id, Method__c='System', Details__c='Lease flagged for renewal.', Entry_Date__c=Datetime.now().addDays(-30)),
            new Renewal_Activity__c(Lease_Renewal__c=rs[0].Id, Method__c='Email', Details__c='Sent renewal notice to tenant.', Entry_Date__c=Datetime.now().addDays(-20))
        };
    }
    private static Lease_Renewal__c byTenant(String t) {
        return [SELECT Id, Status__c, Stage__c, Approval_Status__c, Last_Contact_Date__c, Renewed_Date__c FROM Lease_Renewal__c WHERE Tenant_Name__c = :t LIMIT 1];
    }

    @isTest static void homeKpis() {
        LeaseRenewalController.HomeKpis k = LeaseRenewalController.getHomeKpis();
        System.assertEquals(4, k.active, 'r1, r2, r3, r6 are Active');
        System.assertEquals(3, k.expiring90, '80d, 25d, 40d actives are within 90');
        System.assertEquals(1, k.nonResponsive, 'only r1 is >14d silent in an outreach stage');
        System.assertEquals(1, k.renewedYtd, 'r4 stamped Renewed_Date today by the flow');
    }
    @isTest static void recentRenewalsCapsAtSix() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Lease_Renewal__c> extra = new List<Lease_Renewal__c>();
        for (Integer i = 0; i < 3; i++) {
            extra.add(new Lease_Renewal__c(Tenant_Name__c='Extra ' + i, Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(100 + i)));
        }
        insert extra;
        List<LeaseRenewalController.Row> rows = LeaseRenewalController.getRecentRenewals();
        System.assertEquals(6, rows.size(), 'capped at 6');
        System.assertEquals('Westgate Plaza', rows[0].property, 'property name spans from the asset');
    }
    @isTest static void needsApproval() {
        List<LeaseRenewalController.Row> rows = LeaseRenewalController.getNeedsApproval();
        System.assertEquals(1, rows.size());
        System.assertEquals('TechHub Coworking', rows[0].tenant);
        System.assertEquals('Pending', rows[0].approvalStatus);
    }
    @isTest static void attentionListsNonRespAndCritical() {
        List<LeaseRenewalController.Row> rows = LeaseRenewalController.getAttention();
        System.assertEquals(2, rows.size(), 'r1 non-responsive + r3 within 30d');
        System.assertEquals('Golden Wok', rows[0].tenant, 'sorted by lease end ascending (25d first)');
        System.assertEquals('Riverside Dental', rows[1].tenant);
        System.assertEquals(true, rows[1].nonResponsive);
    }
    @isTest static void timelineNewestFirstWithContext() {
        LeaseRenewalController.TimelineView v = LeaseRenewalController.getTimeline(byTenant('Riverside Dental').Id);
        System.assertEquals(2, v.entries.size());
        System.assertEquals('Email', v.entries[0].method, 'newest (by Entry_Date__c) first');
        System.assertEquals(true, v.canLog);
        System.assertEquals(true, v.nonResponsive);
        System.assertEquals(false, v.closed);
        System.assertEquals(20, v.daysSinceContact);
    }
    @isTest static void timelineClosedCannotLog() {
        LeaseRenewalController.TimelineView v = LeaseRenewalController.getTimeline(byTenant('Anytime Fitness').Id);
        System.assertEquals(false, v.canLog);
        System.assertEquals(true, v.closed);
    }
    @isTest static void addUpdateInsertsAndStampsContact() {
        Id rid = byTenant('Pearl Nails').Id;
        Test.startTest();
        LeaseRenewalController.addUpdate(rid, 'Call', 'Reached the owner; scheduling terms talk.');
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Renewal_Activity__c WHERE Lease_Renewal__c = :rid]);
        System.assertEquals(Date.today(), byTenant('Pearl Nails').Last_Contact_Date__c, 'non-System method stamps last contact');
    }
    @isTest static void addUpdateSystemDoesNotStamp() {
        Id rid = byTenant('Pearl Nails').Id;
        LeaseRenewalController.addUpdate(rid, 'System', 'Renewal window opened.');
        System.assertEquals(null, byTenant('Pearl Nails').Last_Contact_Date__c, 'System entries are not tenant contact');
    }
    @isTest static void addUpdateBlankDetailsThrows() {
        Id rid = byTenant('Pearl Nails').Id;
        Boolean threw = false;
        try { LeaseRenewalController.addUpdate(rid, 'Call', '   '); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw);
        System.assertEquals(0, [SELECT COUNT() FROM Renewal_Activity__c WHERE Lease_Renewal__c = :rid]);
    }
    @isTest static void addUpdateBadMethodThrows() {
        Boolean threw = false;
        try { LeaseRenewalController.addUpdate(byTenant('Pearl Nails').Id, 'Fax', 'nope'); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw);
    }
    @isTest static void statusSyncSetsClosedWonAndStampsOnce() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Lease_Renewal__c r = new Lease_Renewal__c(Tenant_Name__c='Stamp Once', Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(10), Renewed_Date__c=Date.today().addDays(-30));
        insert r;
        r.Stage__c = 'Renewed'; update r;
        r = [SELECT Status__c, Renewed_Date__c FROM Lease_Renewal__c WHERE Id = :r.Id];
        System.assertEquals('Closed Won', r.Status__c);
        System.assertEquals(Date.today().addDays(-30), r.Renewed_Date__c, 'existing Renewed_Date is never overwritten');
    }
    @isTest static void statusSyncSetsClosedLost() {
        Lease_Renewal__c r = byTenant('Golden Wok');
        r.Stage__c = 'Not Renewing'; update r;
        System.assertEquals('Closed Lost', byTenant('Golden Wok').Status__c);
    }
    @isTest static void submitForApprovalEscalates() {
        Id rid = byTenant('Golden Wok').Id;
        Test.startTest();
        String msg = LeaseRenewalController.submitForApproval(rid);
        Test.stopTest();
        System.assert(msg != null && msg.length() > 0);
        Lease_Renewal__c r = byTenant('Golden Wok');
        System.assertEquals('Escalated for Approval', r.Stage__c);
        System.assertEquals('Pending', r.Approval_Status__c);
    }
    @isTest static void submitTwiceThrows() {
        Id rid = byTenant('Golden Wok').Id;
        LeaseRenewalController.submitForApproval(rid);
        Boolean threw = false;
        try { LeaseRenewalController.submitForApproval(rid); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'second submit while pending is blocked');
    }
    @isTest static void submitClosedThrows() {
        Boolean threw = false;
        try { LeaseRenewalController.submitForApproval(byTenant('Anytime Fitness').Id); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'closed renewals fail the entry criteria');
    }
}
