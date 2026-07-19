@isTest
private class LeaseRenewalControllerTest {
    @testSetup static void setup() {
        Property__c pr = TestDataFactory.createProperty(true);
        Property_Asset__c pa = TestDataFactory.createPropertyAsset(pr.Id, false);
        pa.Name = 'Westgate Plaza';
        insert pa;
        Date t = Date.today();
        // r1 non-responsive + expiring<=90; r2 fresh no contact; r3 critical <=30d;
        // r4 Renewed (flow -> Closed Won + Renewed_Date); r5 Not Renewing (flow -> Closed Lost);
        // r6 negotiating, active.
        List<Lease_Renewal__c> rs = TestDataFactory.createLeaseRenewals(6, pa.Id, false);
        rs[0].Tenant_Name__c = 'Riverside Dental'; rs[0].Unit_Label__c = 'Suite 120';
        rs[0].Lease_End__c = t.addDays(80); rs[0].Stage__c = 'Awaiting Tenant Response'; rs[0].Last_Contact_Date__c = t.addDays(-20);

        rs[1].Tenant_Name__c = 'Pearl Nails'; rs[1].Unit_Label__c = 'Suite 3';
        rs[1].Lease_End__c = t.addDays(150); rs[1].Stage__c = 'Not Yet Started'; rs[1].Last_Contact_Date__c = null;

        rs[2].Tenant_Name__c = 'Golden Wok'; rs[2].Unit_Label__c = 'Unit 8';
        rs[2].Lease_End__c = t.addDays(25); rs[2].Stage__c = 'Negotiating'; rs[2].Last_Contact_Date__c = t.addDays(-3); rs[2].Proposed_Rate__c = 25.20;

        rs[3].Tenant_Name__c = 'Anytime Fitness'; rs[3].Unit_Label__c = 'Anchor B';
        rs[3].Lease_End__c = t.addDays(-2); rs[3].Stage__c = 'Renewed'; rs[3].Last_Contact_Date__c = null;

        rs[4].Tenant_Name__c = 'Elite Barbers'; rs[4].Unit_Label__c = 'Suite 7';
        rs[4].Lease_End__c = t.addDays(28); rs[4].Stage__c = 'Not Renewing'; rs[4].Last_Contact_Date__c = null;

        rs[5].Tenant_Name__c = 'TechHub Coworking'; rs[5].Unit_Label__c = 'Floor 2';
        rs[5].Lease_End__c = t.addDays(40); rs[5].Stage__c = 'Negotiating'; rs[5].Last_Contact_Date__c = t.addDays(-7); rs[5].Proposed_Rate__c = 24.00;
        insert rs;

        // Entry_DateTime__c is the ARCHITECTURE.md §1 rule-9 stamp read by the timeline.
        List<Renewal_Activity__c> acts = TestDataFactory.createRenewalActivities(2, rs[0].Id, false);
        acts[0].Method__c = 'System'; acts[0].Details__c = 'Lease flagged for renewal.'; acts[0].Entry_DateTime__c = Datetime.now().addDays(-30);
        acts[1].Method__c = 'Email'; acts[1].Details__c = 'Sent renewal notice to tenant.'; acts[1].Entry_DateTime__c = Datetime.now().addDays(-20);
        insert acts;
    }
    private static Lease_Renewal__c byTenant(String t) {
        return [SELECT Id, Status__c, Stage__c, Last_Contact_Date__c, Renewed_Date__c FROM Lease_Renewal__c WHERE Tenant_Name__c = :t LIMIT 1];
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
        List<Lease_Renewal__c> extra = TestDataFactory.createLeaseRenewals(3, pa.Id, false);
        for (Integer i = 0; i < 3; i++) {
            extra[i].Tenant_Name__c = 'Extra ' + i;
            extra[i].Lease_End__c = Date.today().addDays(100 + i);
        }
        insert extra;
        List<LeaseRenewalController.Row> rows = LeaseRenewalController.getRecentRenewals();
        System.assertEquals(6, rows.size(), 'capped at 6');
        System.assertEquals('Westgate Plaza', rows[0].property, 'property name spans from the asset');
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
        System.assertEquals('Email', v.entries[0].method, 'newest (by Entry_DateTime__c) first');
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
        Lease_Renewal__c r = TestDataFactory.createLeaseRenewal(pa.Id, false);
        r.Tenant_Name__c = 'Stamp Once'; r.Lease_End__c = Date.today().addDays(10); r.Renewed_Date__c = Date.today().addDays(-30);
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

    // ── P6 boundary coverage ─────────────────────────────────────────────────────
    // A valid-format but non-existent Id for the given type — the bare-user read throws on
    // object access under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL against the custom
    // Lease_Renewal__c / Renewal_Activity__c objects throws for a user with no access,
    // exercising each read method's read-failure catch (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6lr', Email = 'p6lr@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6LeaseRen', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6lr.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers the read-failure catch on all four read methods: under a bare Standard User,
     * WITH USER_MODE on the custom-object queries throws and the controller maps it to a
     * user-safe AuraHandledException. Its own method because bareUser() inserts a User (setup
     * DML) and the reads do no record DML, so no MIXED_DML_OPERATION arises.
     */
    @isTest static void readCatchesThrowAuraHandledException() {
        User u = bareUser();
        Id fakeRenewalId = fakeId(Lease_Renewal__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try { LeaseRenewalController.getHomeKpis(); Assert.fail('getHomeKpis should throw'); }
            catch (AuraHandledException e) { Assert.isNotNull(e); }
            try { LeaseRenewalController.getRecentRenewals(); Assert.fail('getRecentRenewals should throw'); }
            catch (AuraHandledException e) { Assert.isNotNull(e); }
            try { LeaseRenewalController.getAttention(); Assert.fail('getAttention should throw'); }
            catch (AuraHandledException e) { Assert.isNotNull(e); }
            try { LeaseRenewalController.getTimeline(fakeRenewalId); Assert.fail('getTimeline should throw'); }
            catch (AuraHandledException e) { Assert.isNotNull(e); }
            Test.stopTest();
        }
    }

    /**
     * Covers addUpdate's generic write-failure catch: a deleted renewal Id makes the
     * Renewal_Activity__c insert fail on its Master-Detail parent under admin — the
     * deterministic way to reach the catch. Valid method + non-blank details so the typed
     * RenewalUpdateException branch is skipped. Kept apart from the bare-user read test so the
     * setup-object User insert and this record DML never share a transaction (MIXED_DML).
     */
    @isTest static void addUpdateWriteFailureThrowsAuraHandledException() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Lease_Renewal__c r = TestDataFactory.createLeaseRenewal(pa.Id, false);
        r.Tenant_Name__c = 'Doomed Tenant';
        insert r;
        Id deletedId = r.Id;
        delete r;

        Test.startTest();
        Boolean threw = false;
        try {
            LeaseRenewalController.addUpdate(deletedId, 'Call', 'Logged against a deleted renewal.');
            Assert.fail('addUpdate on a deleted renewal should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'write failure maps to AuraHandledException');
    }
}
