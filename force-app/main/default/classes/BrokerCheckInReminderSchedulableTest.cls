@isTest
private class BrokerCheckInReminderSchedulableTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='P', Address__c='A', Square_Footage__c=1000, Asset_Type__c='Retail'); insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='P', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active'); insert pa;
        Contact b = new Contact(LastName='Webb', Is_Broker__c=true, Broker_Firm__c='Lee'); insert b;
        Date t = Date.today();
        insert new List<Broker_Assignment__c>{
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=b.Id, Status__c='Active', Last_Check_In_Date__c=t.addDays(-40)), // overdue
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=b.Id, Status__c='Active', Last_Check_In_Date__c=t.addDays(-5)),  // fine
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=b.Id, Status__c='Disposed', Last_Check_In_Date__c=t.addDays(-90)) // closed -> ignore
        };
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
}