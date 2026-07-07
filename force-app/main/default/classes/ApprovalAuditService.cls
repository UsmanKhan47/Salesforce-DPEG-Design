/**
 * Stamps who actually approved a deal gate (and when) onto audit fields, by
 * reading the approval history (ProcessInstanceStep). Approval-process field
 * updates cannot capture the approver's identity - this invocable, called from
 * an after-save flow on the gate's stage/status transition, is the reliable way.
 *
 * Defensive posture: an audit-stamp failure must never roll back the approval
 * transaction that triggered it, so failures degrade to debug warnings.
 */
public without sharing class ApprovalAuditService {

    public class Request {
        @InvocableVariable(label='Opportunity Id' required=true)
        public Id recordId;
    }

    @InvocableMethod(
        label='Stamp Underwriting Approval Audit'
        description='Copies the approving principal + approval time from approval history onto UW_Approved_By__c / UW_Approval_Date__c.'
    )
    public static void stampUnderwritingAudit(List<Request> requests) {
        Set<Id> oppIds = new Set<Id>();
        for (Request r : requests) {
            if (r != null && r.recordId != null) {
                oppIds.add(r.recordId);
            }
        }
        if (oppIds.isEmpty()) {
            return;
        }
        Map<Id, ProcessInstanceStep> latestApproval = latestApprovedStepByTarget(oppIds);
        List<Opportunity> updates = new List<Opportunity>();
        for (Id oppId : latestApproval.keySet()) {
            ProcessInstanceStep step = latestApproval.get(oppId);
            updates.add(new Opportunity(
                Id = oppId,
                UW_Approved_By__c = step.ActorId,
                UW_Approval_Date__c = step.CreatedDate
            ));
        }
        try {
            update updates;
        } catch (DmlException e) {
            System.debug(LoggingLevel.WARN, 'ApprovalAuditService: audit stamp failed: ' + e.getMessage());
        }
    }

    /** Newest 'Approved' history step per target record. */
    @TestVisible
    private static Map<Id, ProcessInstanceStep> latestApprovedStepByTarget(Set<Id> targetIds) {
        Map<Id, ProcessInstanceStep> latest = new Map<Id, ProcessInstanceStep>();
        for (ProcessInstanceStep s : [
            SELECT ActorId, CreatedDate, ProcessInstance.TargetObjectId
            FROM ProcessInstanceStep
            WHERE ProcessInstance.TargetObjectId IN :targetIds AND StepStatus = 'Approved'
            ORDER BY CreatedDate DESC
        ]) {
            Id target = s.ProcessInstance.TargetObjectId;
            if (!latest.containsKey(target)) {
                latest.put(target, s);
            }
        }
        return latest;
    }
}
