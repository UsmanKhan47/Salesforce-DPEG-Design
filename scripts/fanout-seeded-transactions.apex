// Fan out the full PDF checklist across the 5 seeded Active transactions.
// Idempotent: clears any prior fanned-out tasks first. Sets Loan Required = true so the
// conditional Financing group is included (full 82 tasks per deal).
List<Id> ids = new List<Id>();
for (Transaction__c t : [SELECT Id FROM Transaction__c WHERE Status__c = 'Active']) {
    ids.add(t.Id);
}
delete [SELECT Id FROM Task WHERE WhatId IN :ids OR Transaction_Deal__c IN :ids];

List<Transaction__c> ups = new List<Transaction__c>();
for (Id i : ids) {
    ups.add(new Transaction__c(Id = i, Loan_Required__c = true, Tasks_Fanned_Out__c = false));
}
update ups;

TaskFanoutService.fanOut(ids);
System.debug('FANOUT done for ' + ids.size() + ' transactions');
