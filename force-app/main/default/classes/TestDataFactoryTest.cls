/**
 * Tests TestDataFactory's own record-type stamping (Task 3, IR/Acquisitions
 * segregation, 2026-08-10): every Lead / Account / Contact the factory builds
 * must land on the acquisition-side record type, never on the org's default,
 * so factory-built data continues to match the acquisition sharing rules once
 * OWD tightens.
 */
@isTest
private class TestDataFactoryTest {

    @isTest
    static void factoryStampsAcquisitionSideRecordTypes() {
        Lead l = TestDataFactory.createLead(true);
        Account a = TestDataFactory.createAccount(true);
        Contact c = TestDataFactory.createContact(a.Id, true);

        Lead readLead = [SELECT RecordType.DeveloperName FROM Lead WHERE Id = :l.Id];
        Account readAccount = [SELECT RecordType.DeveloperName FROM Account WHERE Id = :a.Id];
        Contact readContact = [SELECT RecordType.DeveloperName FROM Contact WHERE Id = :c.Id];

        Assert.areEqual('Acquisition_Broker', readLead.RecordType.DeveloperName,
            'Factory Leads must be acquisition-side; an unstamped Lead matches no sharing rule once OWD is Private.');
        Assert.areEqual('Broker_Firm', readAccount.RecordType.DeveloperName,
            'Factory Accounts must be broker firms.');
        Assert.areEqual('Broker', readContact.RecordType.DeveloperName,
            'Factory Contacts must be brokers, matching their Account per Record_Type_Matches_Account.');
    }
}
