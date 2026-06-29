@IsTest
private class BrokerPortalNotifierTest {

    @IsTest
    static void notify_runsForNewLead_withoutError() {
        Lead l = new Lead(
            FirstName = 'Jane', LastName = 'Broker', Company = 'Acme Realty',
            Property_Address__c = '123 Main St', LeadSource = 'Broker Portal', Status = 'New'
        );
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