/**
 * Serves the Transaction record's Tasks grouped by Task Group (stage) for the
 * transactionTaskGroups LWC, plus a complete/uncomplete toggle.
 */
public with sharing class TransactionTaskController {

    public class TaskRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public String ownerLabel;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean done;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public Decimal sequence;
        @AuraEnabled public Boolean verifyComplete;
        @AuraEnabled public String verifiedBy;
        @AuraEnabled public Datetime verifiedAt;
        @AuraEnabled public String phone;
        @AuraEnabled public String notes;
        @AuraEnabled public Datetime completedDate;
    }

    public class GroupRow {
        @AuraEnabled public String key;
        @AuraEnabled public String letter;
        @AuraEnabled public String name;
        @AuraEnabled public String ownerLabel;
        @AuraEnabled public Boolean conditional;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer complete;
        @AuraEnabled public Integer pct;
        @AuraEnabled public List<TaskRow> tasks;
    }

    @AuraEnabled(cacheable=true)
    public static List<GroupRow> getTaskGroups(Id transactionId) {
        // Ordered group definitions (drives stage order + name/owner/conditional).
        // CMDT read via provider (getAll), not SOQL — WITH USER_MODE is inert on __mdt.
        List<String> orderedKeys = new List<String>();
        Map<String, Task_Group_Def__mdt> defByKey = new Map<String, Task_Group_Def__mdt>();
        for (Task_Group_Def__mdt d : TaskGroupDefProvider.getAllOrderedBySequence()) {
            String key = d.Letter__c + '. ' + d.Group_Name__c;
            orderedKeys.add(key);
            defByKey.put(key, d);
        }

        // Task SOQL relocated to TaskSelector (bulk Set<Id> shape; single Transaction here).
        Map<String, List<TaskRow>> tasksByGroup = new Map<String, List<TaskRow>>();
        for (Task t : TaskSelector.selectChecklistByTransactionDealIds(new Set<Id>{ transactionId })) {
            TaskRow r = new TaskRow();
            r.id = t.Id;
            r.subject = t.Subject;
            r.ownerLabel = t.Task_Owner_Label__c;
            r.status = t.Status;
            r.done = t.IsClosed;
            r.dueDate = t.ActivityDate;
            r.sequence = t.Task_Sequence__c;
            r.verifyComplete = t.Verbal_Verification_Completed__c;
            r.verifiedBy = t.Verified_By__c;
            r.verifiedAt = t.Verified_At__c;
            r.phone = t.Verification_Phone__c;
            r.notes = t.Description;
            r.completedDate = t.IsClosed ? t.LastModifiedDate : null;
            if (!tasksByGroup.containsKey(t.Task_Group__c)) {
                tasksByGroup.put(t.Task_Group__c, new List<TaskRow>());
            }
            tasksByGroup.get(t.Task_Group__c).add(r);
        }

        List<GroupRow> groups = new List<GroupRow>();
        for (String key : orderedKeys) {
            List<TaskRow> rows = tasksByGroup.get(key);
            if (rows == null || rows.isEmpty()) {
                continue;
            }
            Task_Group_Def__mdt d = defByKey.get(key);
            Integer c = 0;
            for (TaskRow r : rows) {
                if (r.done) {
                    c++;
                }
            }
            GroupRow g = new GroupRow();
            g.key = key;
            g.letter = d.Letter__c;
            g.name = d.Group_Name__c;
            g.ownerLabel = d.Owner_Label__c;
            g.conditional = d.Conditional__c;
            g.tasks = rows;
            g.total = rows.size();
            g.complete = c;
            g.pct = g.total > 0 ? Integer.valueOf(Math.round(100.0 * c / g.total)) : 0;
            groups.add(g);
        }
        return groups;
    }

    @AuraEnabled
    public static void setTaskStatus(Id taskId, Boolean done) {
        update new Task(Id = taskId, Status = done ? 'Completed' : 'Not Started');
    }

    /**
     * Completes a regular task and persists the optional notes/comments captured in the
     * confirm dialog to the task's Description (Comments). Blank notes leave any existing
     * comments untouched.
     */
    @AuraEnabled
    public static void completeTask(Id taskId, String notes) {
        Task t = new Task(Id = taskId, Status = 'Completed');
        if (String.isNotBlank(notes)) {
            t.Description = notes.trim();
        }
        update t;
    }

    /**
     * Closes a wire-fraud verification task only after the verbal verification is captured
     * (DPEG brief Section 06). Records the confirmer's name + phone, stamps the time, and logs
     * the standard verification note to the task's comments. Throws if name/phone are missing.
     */
    @AuraEnabled
    public static void completeWireVerification(Id taskId, String verifiedBy, String phone, String comments) {
        if (String.isBlank(verifiedBy) || String.isBlank(phone)) {
            throw new AuraHandledException(
                'Confirmed-by name and phone number are required before this wire-verification task can close.');
        }
        Task t = TaskSelector.selectRequiredById(taskId);
        Datetime now = Datetime.now();
        String note = 'Verified by phone with ' + verifiedBy.trim() + ' at ' + phone.trim()
            + ' on ' + now.format('MMM d, yyyy h:mm a') + '.';
        // Save the verifier's own comments (if provided) above the standard verification note.
        String combined = String.isNotBlank(comments) ? (comments.trim() + '\n' + note) : note;
        t.Verbal_Verification_Completed__c = true;
        t.Verified_By__c = verifiedBy.trim();
        t.Verification_Phone__c = phone.trim();
        t.Verified_At__c = now;
        t.Description = String.isBlank(t.Description) ? combined : (t.Description + '\n' + combined);
        t.Status = 'Completed';
        update t;
    }
}