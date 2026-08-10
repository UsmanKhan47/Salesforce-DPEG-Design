// GATE. Every count below MUST be 0 before the OWD flip.
Id leadRt    = Lead.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Acquisition_Broker').getRecordTypeId();
Id contactRt = Contact.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker').getRecordTypeId();
Id accountRt = Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker_Firm').getRecordTypeId();

System.debug('Leads unstamped:    ' + [SELECT COUNT() FROM Lead    WHERE RecordTypeId != :leadRt    AND IsConverted = false]);
System.debug('Contacts unstamped: ' + [SELECT COUNT() FROM Contact WHERE RecordTypeId != :contactRt]);
System.debug('Accounts unstamped: ' + [SELECT COUNT() FROM Account WHERE RecordTypeId != :accountRt]);
