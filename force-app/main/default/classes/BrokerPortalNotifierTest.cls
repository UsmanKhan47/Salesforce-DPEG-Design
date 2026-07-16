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
}
