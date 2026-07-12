@isTest
private class WorkOrderControllerTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='Westgate Plaza', Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail');
        insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='Westgate Plaza', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
        insert pa;
        Datetime n = Datetime.now();
        // w1 Critical breached+escalation (30h ago, 24h SLA), In Progress
        // w2 High new + untouched (2h ago), on track
        // w3 Medium due-soon (160h ago on 168h SLA) In Progress
        // w4 Low resolved (Completed)
        // w5 Critical resolved (Closed)
        List<Work_Order__c> ws = new List<Work_Order__c>{
            new Work_Order__c(Subject__c='AC down', Property_Asset__c=pa.Id, Unit__c='Suite 120', Category__c='HVAC', Priority__c='Critical', Status__c='In Progress', Reported_Date__c=n.addHours(-30), First_Touched_Date__c=n.addHours(-29), Delay_Reason__c='Vendor delay'),
            new Work_Order__c(Subject__c='Lot lights out', Property_Asset__c=pa.Id, Unit__c='Common', Category__c='Electrical', Priority__c='High', Status__c='New', Reported_Date__c=n.addHours(-2)),
            new Work_Order__c(Subject__c='Faucet drip', Property_Asset__c=pa.Id, Unit__c='Suite 200', Category__c='Plumbing', Priority__c='Medium', Status__c='In Progress', Reported_Date__c=n.addHours(-160), First_Touched_Date__c=n.addHours(-150)),
            new Work_Order__c(Subject__c='Outlet dead', Property_Asset__c=pa.Id, Unit__c='Unit 8', Category__c='Electrical', Priority__c='Low', Status__c='Completed', Reported_Date__c=n.addHours(-100), First_Touched_Date__c=n.addHours(-90), Completed_Date__c=n.addHours(-20)),
            new Work_Order__c(Subject__c='RTU failure', Property_Asset__c=pa.Id, Unit__c='Suite 120', Category__c='HVAC', Priority__c='Critical', Status__c='Closed', Reported_Date__c=n.addHours(-300), First_Touched_Date__c=n.addHours(-299), Completed_Date__c=n.addHours(-280))
        };
        insert ws;
        insert new List<Work_Order_Activity__c>{
            new Work_Order_Activity__c(Work_Order__c=ws[0].Id, Kind__c='Sync', Actor__c='Yardi', Detail__c='Created from tenant call.', Entry_Date__c=n.addHours(-30)),
            new Work_Order_Activity__c(Work_Order__c=ws[0].Id, Kind__c='Vendor', Actor__c='Yardi', Detail__c='Vendor assigned: Gulf Coast HVAC.', Entry_Date__c=n.addHours(-28))
        };
    }
    private static Work_Order__c bySubject(String s) {
        return [SELECT Id, Status__c, First_Touched_Date__c, Completed_Date__c FROM Work_Order__c WHERE Subject__c = :s LIMIT 1];
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
        List<Work_Order__c> extra = new List<Work_Order__c>();
        for (Integer i = 0; i < 4; i++) {
            extra.add(new Work_Order__c(Subject__c='Extra ' + i, Property_Asset__c=pa.Id, Priority__c='Low', Status__c='New', Reported_Date__c=Datetime.now().addHours(-i)));
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
        System.assertEquals('Vendor', v.entries[0].kind, 'newest (by Entry_Date__c) first');
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
        Work_Order__c w = new Work_Order__c(Subject__c='Flow stamp', Property_Asset__c=pa.Id,
            Priority__c='Low', Status__c='New', Reported_Date__c=Datetime.now().addHours(-2));
        insert w;
        w = [SELECT First_Touched_Date__c, Untouched__c FROM Work_Order__c WHERE Id = :w.Id];
        System.assertEquals(null, w.First_Touched_Date__c, 'a New work order has not been touched');
        System.assertEquals(true, w.Untouched__c);
        Test.startTest();
        update new Work_Order__c(Id=w.Id, Status__c='In Progress');
        Work_Order__c touched = [SELECT First_Touched_Date__c, Untouched__c FROM Work_Order__c WHERE Id = :w.Id];
        System.assertNotEquals(null, touched.First_Touched_Date__c, 'leaving New stamps First_Touched_Date');
        System.assertEquals(false, touched.Untouched__c);
        update new Work_Order__c(Id=w.Id, Status__c='Completed');
        Work_Order__c done = [SELECT Completed_Date__c, First_Touched_Date__c, Is_Open__c FROM Work_Order__c WHERE Id = :w.Id];
        System.assertNotEquals(null, done.Completed_Date__c, 'Completed stamps Completed_Date');
        System.assertEquals(touched.First_Touched_Date__c, done.First_Touched_Date__c, 'first-touch is never overwritten');
        System.assertEquals(false, done.Is_Open__c);
        Test.stopTest();
    }
}