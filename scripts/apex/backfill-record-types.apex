// Every pre-existing Lead / Contact / Account is Acquisitions - IR is net new, so there is
// nothing to classify. Chunked at 10000; re-run until the verify script reports 0.
Id leadRt    = Lead.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Acquisition_Broker').getRecordTypeId();
Id contactRt = Contact.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker').getRecordTypeId();
Id accountRt = Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker_Firm').getRecordTypeId();

// ACCOUNTS FIRST - deliberate. A Contact stamped Broker under a still-Master Account is the
// exact mismatch the Contact validation rule forbids, so the parent must lead.
List<Account> accounts = [SELECT Id FROM Account WHERE RecordTypeId != :accountRt LIMIT 10000];
for (Account a : accounts) { a.RecordTypeId = accountRt; }
update accounts;
System.debug('Accounts stamped: ' + accounts.size());

List<Contact> contacts = [SELECT Id FROM Contact WHERE RecordTypeId != :contactRt LIMIT 10000];
for (Contact c : contacts) { c.RecordTypeId = contactRt; }
update contacts;
System.debug('Contacts stamped: ' + contacts.size());

List<Lead> leads = [SELECT Id FROM Lead WHERE RecordTypeId != :leadRt AND IsConverted = false LIMIT 10000];
for (Lead l : leads) { l.RecordTypeId = leadRt; }
update leads;
System.debug('Leads stamped: ' + leads.size());
