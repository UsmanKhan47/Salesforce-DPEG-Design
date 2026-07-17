/**
 * Stamps who actually approved a deal gate (and when) onto audit fields, by
 * reading the approval history (ProcessInstanceStep). Approval-process field
 * updates cannot capture the approver's identity - this invocable, called from
 * an after-save flow on the gate's stage/status transition, is the reliable way.
 *
 * Gates:
 *   - Underwriting (default): stamps Opportunity.UW_Approved_By__c / UW_Approval_Date__c.
 *   - LOI: stamps the deal's Primary LOI (LOI_Status = Approved, Approved_By__c,
 *     Approved_Date__c, Approval_Comments__c from the final approver's comments).
 *
 * Defensive posture: an audit-stamp failure must never roll back the approval
 * transaction that triggered it, so failures degrade to debug warnings.
 */
public without sharing class ApprovalAuditService {

    public class Request {
        @InvocableVariable(label='Opportunity Id' required=true)
        public Id recordId;
        @InvocableVariable(label='Gate (Underwriting or LOI; default Underwriting)')
        public String gate;
    }

    @InvocableMethod(
        label='Stamp Approval Audit'
        description='Copies the approving principal + time (+ comments for the LOI gate) from approval history onto the gate audit fields.'
    )
    public static void stampApprovalAudit(List<Request> requests) {
        Set<Id> uwOpps = new Set<Id>();
        Set<Id> loiOpps = new Set<Id>();
        for (Request r : requests) {
            if (r == null || r.recordId == null) {
                continue;
            }
            if (r.gate == 'LOI') {
                loiOpps.add(r.recordId);
            } else {
                uwOpps.add(r.recordId);
            }
        }
        Set<Id> allIds = new Set<Id>(uwOpps);
        allIds.addAll(loiOpps);
        if (allIds.isEmpty()) {
            return;
        }
        Map<Id, ProcessInstanceStep> latestApproval = latestApprovedStepByTarget(allIds);

        List<Opportunity> oppUpdates = new List<Opportunity>();
        Set<Id> approvedUwOpps = new Set<Id>();
        for (Id oppId : uwOpps) {
            ProcessInstanceStep step = latestApproval.get(oppId);
            if (step != null) {
                oppUpdates.add(new Opportunity(
                    Id = oppId,
                    UW_Approved_By__c = step.ActorId,
                    UW_Approval_Date__c = step.CreatedDate
                ));
                approvedUwOpps.add(oppId);
            }
        }

        // On principal sign-off, advance the deal's underwriting record(s) to
        // Approved so the Underwriting Path and Status reflect the decision.
        List<Underwriting__c> uwUpdates = new List<Underwriting__c>();
        if (!approvedUwOpps.isEmpty()) {
            for (Underwriting__c uw : UnderwritingSelector.selectIdsByOpportunityIds(approvedUwOpps)) {
                uwUpdates.add(new Underwriting__c(
                    Id = uw.Id,
                    Stage__c = 'Approved',
                    Status__c = 'Approved by Principals'
                ));
            }
        }

        List<LOI__c> loiUpdates = new List<LOI__c>();
        if (!loiOpps.isEmpty()) {
            for (Opportunity o : OpportunitySelector.selectPrimaryLoiByIds(loiOpps)) {
                ProcessInstanceStep step = latestApproval.get(o.Id);
                if (step != null) {
                    loiUpdates.add(new LOI__c(
                        Id = o.Primary_LOI__c,
                        LOI_Status__c = 'Approved',
                        Approved_By__c = step.ActorId,
                        Approved_Date__c = step.CreatedDate.date(),
                        Approval_Comments__c = step.Comments
                    ));
                }
            }
        }

        try {
            if (!oppUpdates.isEmpty()) {
                update oppUpdates;
            }
            if (!uwUpdates.isEmpty()) {
                update uwUpdates;
            }
            if (!loiUpdates.isEmpty()) {
                update loiUpdates;
            }
        } catch (DmlException e) {
            System.debug(LoggingLevel.WARN, 'ApprovalAuditService: audit stamp failed: ' + e.getMessage());
        }
    }

    /**
     * Newest 'Approved' history step per target record. The SOQL lives in
     * ProcessInstanceStepSelector.AuditReads (without sharing + SYSTEM_MODE) so the
     * audit read still sees the full approval trail regardless of the running user;
     * this method keeps the in-memory newest-per-target fold (the selector returns the
     * steps ordered CreatedDate DESC, so first-wins keeps the latest).
     */
    @TestVisible
    private static Map<Id, ProcessInstanceStep> latestApprovedStepByTarget(Set<Id> targetIds) {
        Map<Id, ProcessInstanceStep> latest = new Map<Id, ProcessInstanceStep>();
        List<ProcessInstanceStep> steps = new ProcessInstanceStepSelector.AuditReads()
            .selectApprovedStepsByTargetIds(targetIds);
        for (ProcessInstanceStep s : steps) {
            Id target = s.ProcessInstance.TargetObjectId;
            if (!latest.containsKey(target)) {
                latest.put(target, s);
            }
        }
        return latest;
    }
}