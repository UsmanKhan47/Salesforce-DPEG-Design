public with sharing class DispositionTaskController {

    // The closing checklist, in order. Tasks are scoped to a disposition by WhatId + these subjects.
    private static final List<String> SUBJECTS = new List<String>{
        'PSA Executed',
        'Title Company Engaged',
        'Closing Statement Received'
    };

    public class ClosingTask {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public Integer sequence;
        @AuraEnabled public Boolean done;
        @AuraEnabled public Datetime completedDate;
    }

    /**
     * Returns the three Disposition Closing tasks for a disposition, creating any that don't exist
     * yet (find-or-create) so the checklist self-seeds on first view. Built the same way as the
     * transaction tasks: standard Task records keyed by Task_Group__c, completion via Status.
     * NOT cacheable because it may insert — the LWC calls it imperatively.
     */
    @AuraEnabled
    public static List<ClosingTask> getClosingTasks(Id dispositionId) {
        Set<String> existing = new Set<String>();
        for (Task t : [
            SELECT Subject FROM Task
            WHERE WhatId = :dispositionId AND Subject IN :SUBJECTS
        ]) {
            existing.add(t.Subject);
        }

        List<Task> toCreate = new List<Task>();
        for (Integer i = 0; i < SUBJECTS.size(); i++) {
            if (!existing.contains(SUBJECTS[i])) {
                toCreate.add(new Task(
                    WhatId = dispositionId,
                    Subject = SUBJECTS[i],
                    Status = 'Not Started',
                    Priority = 'Normal'
                ));
            }
        }
        if (!toCreate.isEmpty()) {
            insert toCreate;
        }

        Map<String, Task> bySubject = new Map<String, Task>();
        for (Task t : [
            SELECT Id, Subject, IsClosed, LastModifiedDate FROM Task
            WHERE WhatId = :dispositionId AND Subject IN :SUBJECTS
        ]) {
            bySubject.put(t.Subject, t);
        }

        List<ClosingTask> rows = new List<ClosingTask>();
        for (Integer i = 0; i < SUBJECTS.size(); i++) {
            Task t = bySubject.get(SUBJECTS[i]);
            if (t == null) {
                continue;
            }
            ClosingTask r = new ClosingTask();
            r.id = t.Id;
            r.subject = t.Subject;
            r.sequence = i + 1;
            r.done = t.IsClosed;
            r.completedDate = t.IsClosed ? t.LastModifiedDate : null;
            rows.add(r);
        }
        return rows;
    }

    // Toggles a closing task between Completed and Not Started (mirrors TransactionTaskController).
    @AuraEnabled
    public static void setTaskDone(Id taskId, Boolean done) {
        update new Task(Id = taskId, Status = done ? 'Completed' : 'Not Started');
    }
}