@IsTest
private class BrokerPortalNotifierTest {

    @IsTest
    static void notify_runsForNewLead_withoutError() {
        Lead l = TestDataFactory.createLead(false);
        l.FirstName = 'Jane';
        l.LastName = 'Broker';
        l.Company = 'Acme Realty';
        l.Property_Address__c = '123 Main St';
        l.LeadSource = 'Broker Portal';
        insert l;

        Test.startTest();
        BrokerPortalNotifier.notifyNewLeads(new List<Id>{ l.Id });
        Test.stopTest();

        // Custom notifications cannot be queried in tests; success = the method completes without throwing.
        System.Assert.areEqual(1, [SELECT COUNT() FROM Lead], 'Lead remains intact after notify');
    }

    @IsTest
    static void notify_emptyOrNull_isNoOp() {
        Test.startTest();
        BrokerPortalNotifier.notifyNewLeads(new List<Id>());
        BrokerPortalNotifier.notifyNewLeads(null);
        Test.stopTest();
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No leads created by a no-op notify');
    }

    /**
     * Covers the "not configured" early return (queue == null): temporarily
     * renames the real deployed 'Broker_Portal_Leads' queue's DeveloperName so
     * QueueGroupSelector.selectQueueByDeveloperName finds no match. This is safe
     * and non-destructive — all DML in a test method rolls back automatically at
     * the end, restoring the real queue. (CustomNotificationType itself cannot be
     * created, updated, or deleted via Apex DML at all — see
     * NotificationTypeSelectorTest — so the queue is the only side of the
     * `notifType == null || queue == null` guard this suite can flip; either half
     * of the OR reaches the identical early return.)
     */
    @IsTest
    static void notify_queueNotConfigured_isNoOpWithoutThrowing() {
        Group queue = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Broker_Portal_Leads' LIMIT 1];
        queue.DeveloperName = 'Broker_Portal_Leads_Temp_Renamed';
        update queue;

        Lead l = TestDataFactory.createLead(false);
        l.LeadSource = 'Broker Portal';
        insert l;

        Test.startTest();
        BrokerPortalNotifier.notifyNewLeads(new List<Id>{ l.Id });
        Test.stopTest();

        System.Assert.areEqual(1, [SELECT COUNT() FROM Lead],
            'Lead remains intact when the queue is not configured (no-op, no exception)');
    }
}
