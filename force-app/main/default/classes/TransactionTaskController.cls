/**
 * Serves the Transaction record's Tasks grouped by Task Group (stage) for the
 * transactionTaskGroups LWC, plus complete/uncomplete toggles and the wire-verification
 * close.
 *
 * All SOQL is delegated to TaskSelector and the CMDT read to TaskGroupDefProvider per
 * ARCHITECTURE.md §2 — this controller holds no inline SOQL.
 *
 * Thin controller (P6 controller thinning). The checklist write DML and the wire
 * verification business rule live in TransactionTaskService per
 * .claude/rules/apex-layering-rule.md; the write methods only marshal input, delegate,
 * and map failures to an AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 * Every @AuraEnabled method (read and write) maps failures the same way: platform detail
 * goes to the debug log (admin-only) and the user gets a message. A user-actionable rule
 * violation (WireVerificationException) is surfaced verbatim; an unexpected platform
 * failure gets a fixed, generic message with no exception detail concatenated into it.
 */
public with sharing class TransactionTaskController {

    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';
    // Fixed, generic user-safe message for an unexpected failed write. Never interpolate
    // platform text or exception detail into it (ARCHITECTURE.md §5) — raw DmlException
    // text leaks field API names and validation-rule internals.
    private static final String WRITE_FAILURE_MESSAGE =
        'This task could not be updated. Refresh the page and try again, or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

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
        // Who actually completed the task. Populated only when done (IsClosed), exactly like
        // completedDate above. NOT the same thing as ownerLabel — see getTaskGroups.
        @AuraEnabled public String completedByName;
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
        try {
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
                // ⚠ ROLE, NOT PERSON. Task_Owner_Label__c is static text seeded from
                // Transaction_Task_Def__mdt ('Danish', 'Accounting', 'Legal', 'CFO', 'FES',
                // 'Prop. Mgmt.') — the role the task is OWED BY. It never changes and is not the
                // record owner. Do NOT render it next to a completion date: that reads as
                // "completed by X" and is false for everyone but the one role it names (the
                // 2026-08-28 defect — Usman completed a task and the row said "Danish").
                // Use completedByName below for that. As of 2026-08-28 this member has no LWC
                // consumer; the group header's role pill is fed by GroupRow.ownerLabel, which is
                // a DIFFERENT field (Task_Group_Def__mdt.Owner_Label__c) and is correct.
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
                // ⚠ HONEST NAMING CAVEAT — THIS IS NOT EXACT. Task has no dedicated
                // "completed by" field, so this is LastModifiedBy: who last TOUCHED the record,
                // not who closed it. Edit a completed task and the name becomes the editor's.
                // It is still strictly better than what this line pairs with in the UI used to
                // be (ownerLabel — a static role, wrong for everyone except that one role).
                // If exactness ever matters here, the fix is a real Completed_By__c lookup
                // stamped by TransactionTaskService at close time, not a smarter read.
                // Gated on IsClosed to mirror completedDate; null-guarded because a
                // sharing-restricted or external reader gets a null LastModifiedBy back.
                r.completedByName = (t.IsClosed && t.LastModifiedBy != null) ? t.LastModifiedBy.Name : null;
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TransactionTaskController.getTaskGroups on ' + transactionId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled
    public static void setTaskStatus(Id taskId, Boolean done) {
        try {
            TransactionTaskService.setTaskStatus(taskId, done);
        } catch (TaskPrerequisiteService.PrerequisiteNotMetException e) {
            // Phase 0 wire-fraud gate (Story 28). User-actionable rule violation — surface the
            // guidance verbatim, exactly as completeWireVerification does for WireVerificationException.
            // WITHOUT THIS BRANCH the generic message below tells the user to "refresh the page and
            // try again", which can never work: refreshing does not complete the anti-fraud
            // verification. The message this throws names the step they actually need to finish.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TransactionTaskController.setTaskStatus on ' + taskId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    /**
     * Completes a regular task and persists the optional notes/comments captured in the
     * confirm dialog to the task's Description (Comments). Blank notes leave any existing
     * comments untouched. A Phase 0 wire-fraud prerequisite refusal is surfaced verbatim; any other
     * failure gets the generic message.
     */
    @AuraEnabled
    public static void completeTask(Id taskId, String notes) {
        try {
            TransactionTaskService.completeTask(taskId, notes);
        } catch (TaskPrerequisiteService.PrerequisiteNotMetException e) {
            // Phase 0 wire-fraud gate (Story 28) — surfaced verbatim. See setTaskStatus above.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TransactionTaskController.completeTask on ' + taskId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    /**
     * Closes a wire-fraud verification task only after the verbal verification is captured
     * (DPEG brief Section 06). Records the confirmer's name + phone, stamps the time, and logs
     * the standard verification note to the task's comments. The missing-name/phone rule is a
     * WireVerificationException surfaced verbatim; any other failure gets the generic message.
     */
    @AuraEnabled
    public static void completeWireVerification(Id taskId, String verifiedBy, String phone, String comments) {
        try {
            TransactionTaskService.completeWireVerification(taskId, verifiedBy, phone, comments);
        } catch (TransactionTaskService.WireVerificationException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TransactionTaskController.completeWireVerification on ' + taskId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
