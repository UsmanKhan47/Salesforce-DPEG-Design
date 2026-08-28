/**
 * Stamps Opportunity.Primary_LOI__c AFTER the transaction that created the LOI has committed.
 *
 * WHY THIS IS ASYNC — it is a record LOCK, not a permission (2026-08-05).
 * The LOI stage is the only stage in the deal path entered by the APPROVAL PROCESS's own field
 * update rather than by a deal driver. While that approval runs, the Opportunity is LOCKED
 * (Underwriting_Approval declares recordEditability=AdminOnly), so ANY write back to the deal from
 * inside that transaction fails with ENTITY_IS_LOCKED — regardless of who the running user is and
 * regardless of AccessLevel. SYSTEM_MODE bypasses CRUD and FLS; it does NOT bypass an approval lock.
 *
 * ⚠ RETRACTED 2026-08-28 — THE CAUSE DESCRIBED ABOVE NO LONGER EXISTS. THE CLASS IS KEPT ANYWAY.
 * "The LOI stage is the only stage entered by the APPROVAL PROCESS's own field update" was true
 * only while `Opportunity.Underwriting_Approval` existed and wrote StageName = 'LOI' on final
 * approval. That process is RETIRED (active = false). LOI is now entered by the deal driver
 * clicking Initiate LOI — an ordinary stage write with NO approval running on the Opportunity —
 * so the deal is NOT locked when this back-stamp is needed.
 *
 * 🔴 DO NOT DELETE THIS QUEUEABLE ON THE STRENGTH OF THAT PARAGRAPH. It is now belt-and-braces
 * rather than strictly required, and collapsing it back to an inline update is a separate change
 * needing its own analysis: `LOI_Approval` still runs on the Opportunity with
 * recordEditability = AdminOnly, so a deal can still be locked while sitting AT the LOI stage,
 * and the async hop costs nothing. Reverting it would re-open a defect that took two attempts to
 * close, to save one enqueue.
 * That is the distinction that produced the second failure on this path:
 *
 *   attempt 1  bare DML in the flow's Apex   -> System.TypeException (approver has no Edit)
 *   attempt 2  AccessLevel.SYSTEM_MODE       -> ENTITY_IS_LOCKED (approval lock, different cause)
 *   attempt 3  this class, post-commit       -> lock already released
 *
 * Both approval processes set finalApprovalRecordLock=false, so the deal is unlocked once the
 * approval transaction commits — which is exactly when a Queueable runs.
 *
 * The LOI record itself is still inserted SYNCHRONOUSLY by OpportunityReviewService: LOI__c is not
 * the record under approval and is not locked, so the user sees the LOI immediately. Only the
 * back-reference is deferred, and only briefly.
 *
 * allOrNone = true on purpose: a failure here must surface as a failed AsyncApexJob rather than
 * vanish. A silent miss would leave Primary_LOI__c null, and ApprovalAuditService's LOI gate
 * resolves its target through that field while swallowing its own errors — so the next approval
 * would stamp nothing, invisibly. That is the precise failure this whole sequence has been chasing.
 *
 * @see force-app/main/default/classes/OpportunityReviewService.cls (enqueues this)
 * @see force-app/main/default/classes/ApprovalAuditService.cls (consumer of Primary_LOI__c)
 */
public with sharing class LoiPrimaryStampQueueable implements Queueable {

    private final Map<Id, Id> loiByOpportunity;

    /**
     * @param loiByOpportunity Opportunity Id -> the LOI__c Id to stamp onto it. Never null.
     */
    public LoiPrimaryStampQueueable(Map<Id, Id> loiByOpportunity) {
        this.loiByOpportunity = loiByOpportunity;
    }

    public void execute(QueueableContext context) {
        if (loiByOpportunity == null || loiByOpportunity.isEmpty()) {
            return;
        }
        List<Opportunity> stamps = new List<Opportunity>();
        for (Id oppId : loiByOpportunity.keySet()) {
            stamps.add(new Opportunity(Id = oppId, Primary_LOI__c = loiByOpportunity.get(oppId)));
        }
        // SYSTEM_MODE for the same reason the insert uses it: this runs as the APPROVER, who is
        // read-only on Opportunity (DPEG Principal PSG: Read yes, Edit no, measured).
        Database.update(stamps, true, AccessLevel.SYSTEM_MODE);
    }
}
