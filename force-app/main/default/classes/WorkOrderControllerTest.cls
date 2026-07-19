@isTest
private class WorkOrderControllerTest {
    @testSetup static void setup() {
        Property__c pr = TestDataFactory.createProperty(true);
        Property_Asset__c pa = TestDataFactory.createPropertyAsset(pr.Id, false);
        pa.Name = 'Westgate Plaza';
        insert pa;
        Datetime n = Datetime.now();
        // w1 Critical breached+escalation (30h ago, 24h SLA), In Progress
        // w2 High new + untouched (2h ago), on track
        // w3 Medium due-soon (160h ago on 168h SLA) In Progress
        // w4 Low resolved (Completed)
        // w5 Critical resolved (Closed)
        // Every override below sets the ARCHITECTURE.md §1 rule-9 _DateTime fields.
        List<Work_Order__c> ws = TestDataFactory.createWorkOrders(5, pa.Id, false);
        ws[0].Subject__c = 'AC down'; ws[0].Unit_Label__c = 'Suite 120'; ws[0].Category__c = 'HVAC';
        ws[0].Priority__c = 'Critical'; ws[0].Status__c = 'In Progress';
        ws[0].Reported_DateTime__c = n.addHours(-30); ws[0].First_Touched_DateTime__c = n.addHours(-29);
        ws[0].Delay_Reason__c = 'Vendor delay';

        ws[1].Subject__c = 'Lot lights out'; ws[1].Unit_Label__c = 'Common'; ws[1].Category__c = 'Electrical';
        ws[1].Priority__c = 'High'; ws[1].Status__c = 'New';
        ws[1].Reported_DateTime__c = n.addHours(-2);
        ws[1].First_Touched_DateTime__c = null;

        ws[2].Subject__c = 'Faucet drip'; ws[2].Unit_Label__c = 'Suite 200'; ws[2].Category__c = 'Plumbing';
        ws[2].Priority__c = 'Medium'; ws[2].Status__c = 'In Progress';
        ws[2].Reported_DateTime__c = n.addHours(-160); ws[2].First_Touched_DateTime__c = n.addHours(-150);

        ws[3].Subject__c = 'Outlet dead'; ws[3].Unit_Label__c = 'Unit 8'; ws[3].Category__c = 'Electrical';
        ws[3].Priority__c = 'Low'; ws[3].Status__c = 'Completed';
        ws[3].Reported_DateTime__c = n.addHours(-100); ws[3].First_Touched_DateTime__c = n.addHours(-90);
        ws[3].Completed_DateTime__c = n.addHours(-20);

        ws[4].Subject__c = 'RTU failure'; ws[4].Unit_Label__c = 'Suite 120'; ws[4].Category__c = 'HVAC';
        ws[4].Priority__c = 'Critical'; ws[4].Status__c = 'Closed';
        ws[4].Reported_DateTime__c = n.addHours(-300); ws[4].First_Touched_DateTime__c = n.addHours(-299);
        ws[4].Completed_DateTime__c = n.addHours(-280);
        insert ws;

        List<Work_Order_Activity__c> acts = TestDataFactory.createWorkOrderActivities(2, ws[0].Id, false);
        acts[0].Kind__c = 'Sync'; acts[0].Actor__c = 'Yardi'; acts[0].Detail__c = 'Created from tenant call.'; acts[0].Entry_DateTime__c = n.addHours(-30);
        acts[1].Kind__c = 'Vendor'; acts[1].Actor__c = 'Yardi'; acts[1].Detail__c = 'Vendor assigned: Gulf Coast HVAC.'; acts[1].Entry_DateTime__c = n.addHours(-28);
        insert acts;
    }
    private static Work_Order__c bySubject(String s) {
        return [SELECT Id, Status__c, First_Touched_DateTime__c, Completed_DateTime__c FROM Work_Order__c WHERE Subject__c = :s LIMIT 1];
    }

    @isTest static void homeKpis() {
        WorkOrderController.HomeKpis k = WorkOrderController.getHomeKpis();
        System.assertEquals(3, k.open, 'w1, w2, w3 are open');
        System.assertEquals(1, k.breached, 'only w1 is breached (w3 medium still within 168h)');
        System.assertEquals(1, k.dueSoon, 'w3 at 160/168h is inside the final 30% window');
        System.assertEquals(1, k.untouched, 'w2 is New with no first-touch');
    }
    @isTest static void recentCapsAtSix() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Work_Order__c> extra = TestDataFactory.createWorkOrders(4, pa.Id, false);
        for (Integer i = 0; i < 4; i++) {
            extra[i].Subject__c = 'Extra ' + i;
            extra[i].Priority__c = 'Low';
            extra[i].Status__c = 'New';
            extra[i].Reported_DateTime__c = Datetime.now().addHours(-i);
        }
        insert extra;
        List<WorkOrderController.Row> rows = WorkOrderController.getRecentWorkOrders();
        System.assertEquals(6, rows.size(), 'capped at 6 open');
        System.assertEquals('Westgate Plaza', rows[0].property, 'property name spans from the asset');
    }
    @isTest static void escalationsOnlyCriticalHighBreached() {
        List<WorkOrderController.Row> rows = WorkOrderController.getEscalations();
        System.assertEquals(1, rows.size());
        System.assertEquals('AC down', rows[0].subject);
        System.assertEquals(true, rows[0].breached);
    }
    @isTest static void untouchedList() {
        List<WorkOrderController.Row> rows = WorkOrderController.getUntouched();
        System.assertEquals(1, rows.size());
        System.assertEquals('Lot lights out', rows[0].subject);
        System.assertEquals(true, rows[0].untouched);
    }
    @isTest static void activityNewestFirstWithContext() {
        WorkOrderController.ActivityView v = WorkOrderController.getActivity(bySubject('AC down').Id);
        System.assertEquals(2, v.entries.size());
        System.assertEquals('Vendor', v.entries[0].kind, 'newest (by Entry_DateTime__c) first');
        System.assertEquals('Yardi', v.entries[0].actor);
        System.assertEquals(false, v.untouched, 'AC down has a first-touch');
    }
    @isTest static void activityEmptyForUntouched() {
        WorkOrderController.ActivityView v = WorkOrderController.getActivity(bySubject('Lot lights out').Id);
        System.assertEquals(0, v.entries.size());
        System.assertEquals(true, v.untouched);
    }
    @isTest static void resolvedCountsInKpiOpenExcluded() {
        // w4 Completed + w5 Closed are excluded from open KPIs and lists.
        for (WorkOrderController.Row r : WorkOrderController.getRecentWorkOrders()) {
            System.assertEquals(true, r.isOpen, 'recent list is open-only');
        }
    }
    @isTest static void touchSyncStampsFirstTouchedThenCompleted() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Work_Order__c w = TestDataFactory.createWorkOrder(pa.Id, false);
        w.Subject__c = 'Flow stamp'; w.Priority__c = 'Low'; w.Status__c = 'New';
        w.Reported_DateTime__c = Datetime.now().addHours(-2);
        insert w;
        w = [SELECT First_Touched_DateTime__c, Is_Untouched__c FROM Work_Order__c WHERE Id = :w.Id];
        System.assertEquals(null, w.First_Touched_DateTime__c, 'a New work order has not been touched');
        System.assertEquals(true, w.Is_Untouched__c);
        Test.startTest();
        update new Work_Order__c(Id=w.Id, Status__c='In Progress');
        Work_Order__c touched = [SELECT First_Touched_DateTime__c, Is_Untouched__c FROM Work_Order__c WHERE Id = :w.Id];
        System.assertNotEquals(null, touched.First_Touched_DateTime__c, 'leaving New stamps First_Touched_DateTime');
        System.assertEquals(false, touched.Is_Untouched__c);
        update new Work_Order__c(Id=w.Id, Status__c='Completed');
        Work_Order__c done = [SELECT Completed_DateTime__c, First_Touched_DateTime__c, Is_Open__c FROM Work_Order__c WHERE Id = :w.Id];
        System.assertNotEquals(null, done.Completed_DateTime__c, 'Completed stamps Completed_DateTime');
        System.assertEquals(touched.First_Touched_DateTime__c, done.First_Touched_DateTime__c, 'first-touch is never overwritten');
        System.assertEquals(false, done.Is_Open__c);
        Test.stopTest();
    }

    // A valid-format but non-existent Id for the given type. The bare-user read throws on
    // object ACCESS under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL on the custom
    // Work_Order__c object (no object access) throws, exercising each read method's failure
    // catch which maps it to a user-safe AuraHandledException (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.wo.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers the read-failure catch on all five @AuraEnabled reads: under a bare Standard
     * User, WITH USER_MODE on the custom Work_Order__c object throws (no object access), and
     * the controller maps it to a user-safe AuraHandledException. getActivity takes an Id, so
     * it is passed a valid-format fake one (the access failure fires before any row match).
     * Its own method because bareUser() inserts a User (setup DML); the reads throw at the
     * query, so no record DML runs here (avoids MIXED_DML_OPERATION).
     */
    @isTest
    static void readCatchesThrowAuraHandledException() {
        User u = bareUser();
        Id fakeWoId = fakeId(Work_Order__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try { WorkOrderController.getHomeKpis(); Assert.fail('getHomeKpis should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getHomeKpis maps read failure to AuraHandledException'); }
            try { WorkOrderController.getRecentWorkOrders(); Assert.fail('getRecentWorkOrders should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getRecentWorkOrders maps read failure to AuraHandledException'); }
            try { WorkOrderController.getEscalations(); Assert.fail('getEscalations should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getEscalations maps read failure to AuraHandledException'); }
            try { WorkOrderController.getUntouched(); Assert.fail('getUntouched should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getUntouched maps read failure to AuraHandledException'); }
            try { WorkOrderController.getActivity(fakeWoId); Assert.fail('getActivity should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getActivity maps read failure to AuraHandledException'); }
            Test.stopTest();
        }
    }
}
