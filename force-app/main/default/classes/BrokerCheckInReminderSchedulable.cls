public with sharing class BrokerCheckInReminderSchedulable implements Schedulable {
    // Subject stem shared by the reminder Tasks and the idempotency probe. Passed to
    // TaskSelector.selectOpenByWhatIdsAndSubjectPrefix, which appends the '%' — so the
    // relocated probe stays LIKE 'Check in with broker%' exactly as before.
    private static final String REMINDER_SUBJECT_PREFIX = 'Check in with broker';

    public void execute(SchedulableContext sc) { createReminders(); }

    public Integer createReminders() {
        Integer threshold = BrokerAssignmentController.OVERDUE_DAYS;
        List<Broker_Assignment__c> overdue =
            BrokerAssignmentSelector.selectActiveOverdueByCheckInDays(threshold);
        if (overdue.isEmpty()) return 0;

        Set<Id> assignmentIds = new Set<Id>();
        for (Broker_Assignment__c a : overdue) assignmentIds.add(a.Id);

        // idempotency: existing open reminder tasks for these assignments
        Set<Id> alreadyHasOpen = new Set<Id>();
        for (Task t : TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(assignmentIds, REMINDER_SUBJECT_PREFIX)) {
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