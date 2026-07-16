@isTest
private class BrokerCheckInReminderSchedulableTest {
    @testSetup static void setup() {
        Property__c pr = TestDataFactory.createProperty(false); insert pr;
        Property_Asset__c pa = TestDataFactory.createPropertyAsset(pr.Id, false); insert pa;
        Contact b = TestDataFactory.createBrokerContact(null, false);
        b.LastName = 'Webb'; b.Broker_Firm__c = 'Lee';
        insert b;
        Date t = Date.today();
        List<Broker_Assignment__c> assignments = TestDataFactory.createBrokerAssignments(3, pa.Id, b.Id, false);
        assignments[0].Status__c = 'Active'; assignments[0].Listing_End_Date__c = null; assignments[0].Last_Check_In_Date__c = t.addDays(-40); // overdue
        assignments[1].Status__c = 'Active'; assignments[1].Listing_End_Date__c = null; assignments[1].Last_Check_In_Date__c = t.addDays(-5);  // fine
        assignments[2].Status__c = 'Disposed'; assignments[2].Listing_End_Date__c = t.addDays(-1); assignments[2].Last_Check_In_Date__c = t.addDays(-90); // closed -> ignore
        insert assignments;
    }
    @isTest static void createsOneReminderForOverdueActiveOnly() {
        Test.startTest();
        Integer created = new BrokerCheckInReminderSchedulable().createReminders();
        Test.stopTest();
        System.assertEquals(1, created);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Check in with broker%']);
    }
    @isTest static void isIdempotent() {
        new BrokerCheckInReminderSchedulable().createReminders();
        Integer second = new BrokerCheckInReminderSchedulable().createReminders();
        System.assertEquals(0, second, 'second run creates no duplicates');
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Check in with broker%']);
    }
    @isTest static void schedulableExecuteRuns() {
        Test.startTest();
        String jobId = System.schedule('BrokerCheckInTest', '0 0 6 * * ?', new BrokerCheckInReminderSchedulable());
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }

    /**
     * Bulk scenario per .claude/rules/bulk-test-rule.md: 251 overdue Active
     * Broker_Assignment__c records, forcing a second 200-record batch chunk
     * through createReminders()'s single SOQL + single DML shape. The @TestSetup
     * fixture is cleared first so the assertion count matches the inserted count
     * exactly (251), per the rule's "assertion count must match" requirement.
     */
    @isTest static void createsReminderForEachOverdueBulk() {
        delete [SELECT Id FROM Broker_Assignment__c];
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Contact b = [SELECT Id FROM Contact WHERE Is_Broker__c = true LIMIT 1];
        List<Broker_Assignment__c> overdue = TestDataFactory.createBrokerAssignments(251, pa.Id, b.Id, false);
        TestDataFactory.applyOverrides(overdue, new Map<String, Object>{
            'Status__c' => 'Active',
            'Listing_End_Date__c' => null,
            'Last_Check_In_Date__c' => Date.today().addDays(-40)
        });
        insert overdue;

        Test.startTest();
        Integer created = new BrokerCheckInReminderSchedulable().createReminders();
        Test.stopTest();

        System.assertEquals(251, created, 'all 251 overdue active assignments get a reminder');
        System.assertEquals(251, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Check in with broker%']);
    }
}
