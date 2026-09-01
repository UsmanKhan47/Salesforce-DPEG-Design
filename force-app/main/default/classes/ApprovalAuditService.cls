/**
 * Stamps who actually approved a deal gate (and when) onto audit fields, by
 * reading the approval history (ProcessInstanceStep). Approval-process field
 * updates cannot capture the approver's identity - this invocable, called from
 * an after-save flow on the gate's stage/status transition, is the reliable way.
 *
 * Gates:
 *   - Underwriting (default): stamps Opportunity.UW_Approved_By__c / UW_Approval_Date__c,
 *     reading the approval history OF THE DEAL'S UNDERWRITING CHILD (see below).
 *   - LOI: stamps the deal's Primary LOI (LOI_Status = Approved, Approved_By__c,
 *     Approved_Date__c, Approval_Comments__c from the final approver's comments).
 *     ⚠ RETRACTED 2026-09-01. This line read "Reads the OPPORTUNITY's own approval history —
 *     UNCHANGED, and it must stay that way", and it was correct until W4 of the LOI approval
 *     cutover moved that approval onto `LOI__c`. It now reads the **LOI's** history first and
 *     falls back to the deal's; see the repoint block in `stampApprovalAudit`. Keeping the old
 *     sentence would have been the instruction that produced the regression.
 *
 * Defensive posture: an audit-stamp failure must never roll back the approval
 * transaction that triggered it, so failures degrade to debug warnings.
 * ⚠ THAT POSTURE ONLY BECAME TRUE OF THE **READS** ON 2026-09-01. Until then the three selector
 * reads sat outside the try and a `QueryException` from one of them rolled an approval back —
 * measured, not theorised. The reads are inside the try now.
 *
 * ── 🔴 REPOINTED 2026-08-28 — THE UNDERWRITING GATE READS A DIFFERENT RECORD'S HISTORY ────────
 * The principal underwriting approval moved OFF the Opportunity and ONTO the Underwriting__c
 * record. This class reads ProcessInstanceStep by ProcessInstance.TargetObjectId, so once
 * Opportunity.Underwriting_Approval is deactivated there is NO Opportunity ProcessInstance for an
 * underwriting decision, `latestApproval` comes back empty, and UW_Approved_By__c /
 * UW_Approval_Date__c are simply never written.
 *
 * 🔴 THAT REGRESSION WOULD HAVE BEEN COMPLETELY SILENT. This class swallows every failure BY
 * DESIGN (see the catch below), and "no approved step found" is not even a failure — it is the
 * normal not-yet-approved state. Nothing would have thrown, nothing would have logged, and the
 * only thing in the repo that would ever have noticed is
 * scripts/verify-junior-lifecycle.apex's `UW_Approved__c && UW_Approved_By__c != null` assertion.
 *
 * THE FIX, and the deliberate shape of it: the underwriting gate's INPUT CONTRACT IS UNCHANGED —
 * recordId is still an OPPORTUNITY Id, so flows/Opportunity_UW_Approved_Notify needs no edit at
 * all (it passes $Record.Id from the Opportunity and no `gate`). Only the LOOKUP changed: the
 * deal is first mapped to its Underwriting child(ren), and the approval history is read against
 * THOSE Ids, then folded back onto the deal. Where a deal has more than one underwriting child
 * with an approved step, the NEWEST step wins.
 *
 * ⚠ DO NOT "SIMPLIFY" THIS BY MAKING THE GATE TAKE AN UNDERWRITING ID. It would work, and it
 * would require editing Opportunity_UW_Approved_Notify — the flow that carries the market-data
 * freeze, which is the highest-risk file in this change. The mapping query is one SOQL call and
 * buys a zero-edit blast radius on that flow.
 *
 * ⚠ Opportunity_UW_Approved_Notify's OTHER purpose is unchanged and is why this class is still
 * called at all: that flow fires on the deal's transition into Underwriting_Status__c =
 * 'Approved by Principals', which UnderwritingApprovalStampService now performs.
 *
 * `without sharing` justification (ARCHITECTURE.md §2): this stamps the approving
 * principal's identity, time and comments read from the approval history
 * (ProcessInstanceStep, whose SOQL lives in the `without sharing` +
 * WITH SYSTEM_MODE ProcessInstanceStepSelector.AuditReads) onto the gate audit
 * fields. The audit must record the true approver and advance the gate regardless
 * of who fires the after-save flow, so it must see the full approval trail and the
 * target Opportunity / LOI / Underwriting records independently of the running
 * user's sharing. Declared `without sharing` so a user who lacks sharing to a
 * sibling deal record cannot corrupt or blank the audit stamp.
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
        if (uwOpps.isEmpty() && loiOpps.isEmpty()) {
            return;
        }

        // ══ 🔴 EVERY READ BELOW IS INSIDE THE try/catch, AND THAT IS A FIX, NOT TIDYING ═══════
        // ⚠ MOVED 2026-09-01. The three selector reads used to sit OUTSIDE the try that wraps the
        // DML, so this class's stated contract — "an audit-stamp failure must never roll back the
        // approval transaction" — was only ever honoured for the WRITE half. MEASURED, not
        // theorised (test run `707iw000003unI3`,
        // `LoiApprovalStampServiceTest.nonOwningReadOnlyApproverStillUnblocksTheDeal`): the
        // `selectPrimaryLoiByIds` read threw `System.QueryException: No such column
        // 'Primary_LOI__c' on entity 'Opportunity'` for a read-only, non-owning approver, escaped
        // uncaught, surfaced as `CANNOT_EXECUTE_FLOW_TRIGGER`, and ROLLED BACK
        // `LoiApprovalStampService`'s parent stamp — the write that unblocks the deal out of
        // `Under Contract (PSA)`. An audit gap became a blocked deal.
        // ⚠ THE MODE CHANGE IS THE FIX; THIS try IS THE BACKSTOP. That read is now
        // `WITH SYSTEM_MODE` (OpportunitySelector, seventh entrant — and note the FLS grant it
        // appeared to be missing was actually PRESENT, so "grant the field" was never available).
        // Widening the try is what makes the NEXT such read degrade instead of taking an approval
        // down; it is deliberately not being relied on to make this one succeed.
        try {
            // ── The underwriting gate's deal -> child mapping (repointed 2026-08-28) ──────────
            // The approval history now hangs off the UNDERWRITING record, so the step read is
            // keyed on underwriting Ids, not deal Ids. One bulk selector call; no SOQL in a loop.
            Map<Id, Id> dealByUnderwriting = new Map<Id, Id>();
            for (Underwriting__c uw :
                    new UnderwritingSelector.ApprovalAutomationReads().selectByOpportunityIds(uwOpps)) {
                dealByUnderwriting.put(uw.Id, uw.Opportunity__c);
            }

            // ── The LOI gate's deal -> primary-LOI mapping (2026-09-01: MOVED EARLIER) ────────
            // It used to be read after the history lookup, purely to know WHICH LOI to stamp. It
            // now also supplies TARGET Ids for that lookup — see the repoint block below — so it
            // must run first. Still one bulk selector call.
            Map<Id, Id> primaryLoiByDeal = new Map<Id, Id>();
            for (Opportunity o : OpportunitySelector.selectPrimaryLoiByIds(loiOpps)) {
                primaryLoiByDeal.put(o.Id, o.Primary_LOI__c);
            }

            // Targets to read history for: the underwriting CHILDREN for the underwriting gate,
            // and — for the LOI gate — BOTH the deal and its primary LOI. See the repoint block.
            Set<Id> allIds = new Set<Id>(dealByUnderwriting.keySet());
            allIds.addAll(loiOpps);
            allIds.addAll(primaryLoiByDeal.values());
            if (allIds.isEmpty()) {
                return;
            }
            Map<Id, ProcessInstanceStep> latestApproval = latestApprovedStepByTarget(allIds);

            // Fold each deal's underwriting children back onto the deal, newest approved step
            // wins. A deal normally has exactly one underwriting; the comparison exists so that a
            // deal with two never depends on Map iteration order for which approver is recorded.
            Map<Id, ProcessInstanceStep> stepByDeal = new Map<Id, ProcessInstanceStep>();
            for (Id underwritingId : dealByUnderwriting.keySet()) {
                ProcessInstanceStep step = latestApproval.get(underwritingId);
                if (step == null) {
                    continue; // this underwriting has no approved step — normal while pending
                }
                Id dealId = dealByUnderwriting.get(underwritingId);
                ProcessInstanceStep held = stepByDeal.get(dealId);
                if (held == null || step.CreatedDate > held.CreatedDate) {
                    stepByDeal.put(dealId, step);
                }
            }

            List<Opportunity> oppUpdates = new List<Opportunity>();
            for (Id dealId : stepByDeal.keySet()) {
                ProcessInstanceStep step = stepByDeal.get(dealId);
                oppUpdates.add(new Opportunity(
                    Id = dealId,
                    UW_Approved_By__c = step.ActorId,
                    UW_Approval_Date__c = step.CreatedDate
                ));
            }

            // ⚠ DELETED 2026-08-28 — the block that used to sit here wrote the underwriting child:
            //     new Underwriting__c(Id = uw.Id, Stage__c = 'Approved',
            //                         Status__c = 'Approved by Principals')
            // for every deal that had an approved step. It is gone because the Underwriting_Approval
            // process now runs ON that record and its own finalApprovalActions write both fields
            // directly — so this code had become a same-value re-write of a record that was ALREADY
            // in that state by the time this ran. Not merely redundant: it was a second DML on
            // Underwriting__c, which re-fires the every-save flow Underwriting_Opp_Sync (that flow has
            // no entry filter) and pushes the deal's headline numbers again for no reason.
            //
            // Proven safe to remove before deleting: a repo-wide sweep found exactly ONE reader of its
            // effect, the assertion at UnderwritingGateTest (approval advances the underwriting record
            // to Approved), which has been retargeted at the approval process's own field updates.
            // The only other mention was a HEADER CITATION in RecordStageAdvanceService describing
            // this class as the thing that stamps Stage__c = 'Approved'; that sentence has been
            // retracted in place there rather than left pointing at deleted code.
            // Its selector method, UnderwritingSelector.selectIdsByOpportunityIds, is now unused; it
            // was KEPT and annotated rather than deleted (see its docstring for why).

            // ══ 🔴 THE LOI GATE READS TWO HISTORIES NOW — REPOINTED 2026-09-01 (W4) ═══════════
            // The LOI approval has MOVED from the Opportunity onto the LOI__c record
            // (approvalProcesses/LOI__c.LOI_Approval, active since W2), so from W4 onward
            // `ProcessInstance.TargetObjectId` for an LOI decision is THE LOI'S OWN Id. The old
            // `latestApproval.get(o.Id)` — the DEAL's Id — returns null against the new process
            // and this stamp would write NOTHING, FOREVER, with no error: this class swallows
            // its own failures by design, and "no approved step found" is not even a failure, it
            // is the normal not-yet-approved state. That is exactly the regression the
            // underwriting branch suffered on 2026-08-28; read the 🔴 REPOINTED block in the
            // class header.
            //
            // ⚠ IT PREFERS THE LOI'S HISTORY AND FALLS BACK TO THE DEAL'S, RATHER THAN SWAPPING
            // ONE FOR THE OTHER, AND THE FALLBACK IS NOT DEFENSIVE PADDING. Between W4 and W5
            // `approvalProcesses/Opportunity.LOI_Approval` STAYS ACTIVE as the deliberate escape
            // hatch, reachable from the deal's own Approval History related list. A decision
            // taken by that route lands its history on the DEAL. Both routes must stamp, and
            // history taken on the child is the newer, authoritative one, so it wins.
            // ⚠ AFTER W5 the fallback becomes dead for NEW decisions and stays correct for OLD
            // ones — deals approved before the cutover keep their history on the Opportunity.
            // Do not delete it as part of W5.
            List<LOI__c> loiUpdates = new List<LOI__c>();
            for (Id dealId : primaryLoiByDeal.keySet()) {
                Id loiId = primaryLoiByDeal.get(dealId);
                ProcessInstanceStep step = latestApproval.get(loiId);
                if (step == null) {
                    step = latestApproval.get(dealId);
                }
                if (step == null) {
                    continue; // no approved step on either target — normal while pending
                }
                loiUpdates.add(new LOI__c(
                    Id = loiId,
                    LOI_Status__c = 'Approved',
                    Approved_By__c = step.ActorId,
                    Approved_Date__c = step.CreatedDate.date(),
                    Approval_Comments__c = step.Comments
                ));
            }

            // EXPLICIT SYSTEM-MODE DML (2026-08-05). A bare `update` here inherits the calling
            // Flow's access mode, and the calling flow runs as THE APPROVER — who is deliberately
            // read-only on both of these objects (⚠ said "all three" until 2026-08-28, when the
            // Underwriting__c write was deleted; Opportunity and LOI__c remain. DPEG Principal PSG:
            // Read yes, Edit no, measured).
            // Setting <runInMode>SystemModeWithoutSharing</runInMode> on the flow did NOT
            // lift it: the stamp still silently wrote nothing after that change shipped. AccessLevel
            // .SYSTEM_MODE states the requirement at the DML itself, so it no longer depends on how
            // any caller is configured. Do not revert to a bare `update`.
            if (!oppUpdates.isEmpty()) {
                Database.update(oppUpdates, true, AccessLevel.SYSTEM_MODE);
            }
            if (!loiUpdates.isEmpty()) {
                Database.update(loiUpdates, true, AccessLevel.SYSTEM_MODE);
            }
        } catch (Exception e) {
            // Deliberately catches Exception, NOT DmlException. The class contract above is that
            // an audit-stamp failure must never roll back the approval transaction, and a
            // DmlException-only catch did not deliver it: when the approving principal lacked
            // Edit on Opportunity the platform threw System.TypeException ('DML operation UPDATE
            // not allowed on Opportunity'), which is not a DmlException, so it escaped this
            // handler and took the whole approval down with it (2026-08-05, Nikhil approving an
            // Underwriting gate). Narrowing this back to DmlException reopens that hole.
            // ⚠ AND SINCE 2026-09-01 IT ALSO COVERS THE READS — a System.QueryException from a
            // selector was measured escaping this handler and rolling back an approval. See the
            // block at the top of the try.
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