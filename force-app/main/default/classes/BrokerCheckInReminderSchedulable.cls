public with sharing class BrokerCheckInReminderSchedulable implements Schedulable {
    public void execute(SchedulableContext sc) { createReminders(); }

    public Integer createReminders() {
        Integer threshold = BrokerAssignmentController.OVERDUE_DAYS;
        List<Broker_Assignment__c> overdue = [
            SELECT Id, Property_Display_Name__c, Broker__c
            FROM Broker_Assignment__c
            WHERE Status__c = 'Active' AND Days_Since_Check_In__c > :threshold
        ];
        if (overdue.isEmpty()) return 0;

        Set<Id> assignmentIds = new Set<Id>();
        for (Broker_Assignment__c a : overdue) assignmentIds.add(a.Id);

        // idempotency: existing open reminder tasks for these assignments
        Set<Id> alreadyHasOpen = new Set<Id>();
        for (Task t : [SELECT WhatId FROM Task WHERE WhatId IN :assignmentIds AND IsClosed = false AND Subject LIKE 'Check in with broker%']) {
            alreadyHasOpen.add(t.WhatId);
        }

        List<Task> toInsert = new List<Task>();
        for (Broker_Assignment__c a : overdue) {
            if (alreadyHasOpen.contains(a.Id)) continue;
            toInsert.add(new Task(
                Subject = 'Check in with broker — ' + (a.Property_Display_Name__c == null ? 'property' : a.Property_Display_Name__c),
                WhatId = a.Id,
                WhoId = a.Broker__c,
                ActivityDate = Date.today(),
                Priority = 'High',
                Status = 'Not Started'
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
        return toInsert.size();
    }
}