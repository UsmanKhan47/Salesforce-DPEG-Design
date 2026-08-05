/**
 * Creates review child records for an Opportunity. Two triggers for a review:
 *
 *   1. Stage entry - "Development Review" (Land path) / "Construction Review"
 *      (Commercial path) / "PSA" (opens the Contract Review).
 *   2. Input-needed checkboxes - Development_Input_Needed__c /
 *      Construction_Input_Needed__c flipping true opens the matching review at
 *      ANY stage, which is how Development/Construction engage BEFORE
 *      underwriting without reordering the sales path.
 *
 * Idempotent: never creates a second review of the same type for one
 * Opportunity, so re-entering a stage or re-flipping a checkbox is a no-op.
 */
public with sharing class OpportunityReviewService {

    @TestVisible private static final String DEV_STAGE = 'Development Review';
    @TestVisible private static final String CON_STAGE = 'Construction Review';
    @TestVisible private static final String CONTRACT_STAGE = 'PSA';
    @TestVisible private static final String UW_STAGE = 'Underwriting';
    @TestVisible private static final String LOI_STAGE = 'LOI';

    /**
     * Called from the Opportunity after-insert / after-update trigger.
     * @param newOpps Trigger.new
     * @param oldMap  Trigger.oldMap on update; null on insert.
     */
    public static void createReviewRecords(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Set<Id> devOpps = new Set<Id>();
        Set<Id> conOpps = new Set<Id>();
        Set<Id> contractOpps = new Set<Id>();
        Set<Id> uwOpps = new Set<Id>();
        Set<Id> loiOpps = new Set<Id>();
        Map<Id, Id> propertyByOpp = new Map<Id, Id>();

        for (Opportunity o : newOpps) {
            Opportunity prior = (oldMap == null) ? null : oldMap.get(o.Id);
            String priorStage = (prior == null) ? null : prior.StageName;
            Boolean stageChanged = priorStage != o.StageName;
            Boolean devFlip = o.Development_Input_Needed__c == true
                && (prior == null || prior.Development_Input_Needed__c != true);
            Boolean conFlip = o.Construction_Input_Needed__c == true
                && (prior == null || prior.Construction_Input_Needed__c != true);

            if ((stageChanged && o.StageName == DEV_STAGE) || devFlip) {
                devOpps.add(o.Id);
            }
            if ((stageChanged && o.StageName == CON_STAGE) || conFlip) {
                conOpps.add(o.Id);
            }
            if (stageChanged && o.StageName == CONTRACT_STAGE) {
                contractOpps.add(o.Id);
            }
            if (stageChanged && o.StageName == UW_STAGE) {
                uwOpps.add(o.Id);
            }
            if (stageChanged && o.StageName == LOI_STAGE) {
                loiOpps.add(o.Id);
                propertyByOpp.put(o.Id, o.Property__c);
            }
        }
        if (devOpps.isEmpty() && conOpps.isEmpty() && contractOpps.isEmpty()
                && uwOpps.isEmpty() && loiOpps.isEmpty()) {
            return;
        }

        // Idempotency: drop opps that already have a review of the matching type.
        // SOQL relocated to the per-object selectors (Module A2) per ARCHITECTURE.md §2.
        for (Development_Feasibility_Review__c d : DevelopmentFeasibilityReviewSelector.selectByOpportunityIds(devOpps)) {
            devOpps.remove(d.Opportunity__c);
        }
        for (Construction_Feasibility_Review__c c : ConstructionFeasibilityReviewSelector.selectByOpportunityIds(conOpps)) {
            conOpps.remove(c.Opportunity__c);
        }
        for (Contract_Review__c cr : ContractReviewSelector.selectByOpportunityIds(contractOpps)) {
            contractOpps.remove(cr.Opportunity__c);
        }
        for (Underwriting__c uw : UnderwritingSelector.selectByOpportunityIds(uwOpps)) {
            uwOpps.remove(uw.Opportunity__c);
        }
        for (LOI__c loi : LoiSelector.selectByOpportunityIds(loiOpps)) {
            loiOpps.remove(loi.Opportunity__c);
        }

        List<Development_Feasibility_Review__c> devToInsert = new List<Development_Feasibility_Review__c>();
        for (Id oppId : devOpps) {
            devToInsert.add(new Development_Feasibility_Review__c(
                Opportunity__c = oppId, Stage__c = 'Requested',
                Requested_By__c = UserInfo.getUserId()));
        }
        List<Construction_Feasibility_Review__c> conToInsert = new List<Construction_Feasibility_Review__c>();
        for (Id oppId : conOpps) {
            conToInsert.add(new Construction_Feasibility_Review__c(
                Opportunity__c = oppId, Stage__c = 'Requested',
                Requested_By__c = UserInfo.getUserId()));
        }
        List<Contract_Review__c> contractToInsert = new List<Contract_Review__c>();
        for (Id oppId : contractOpps) {
            contractToInsert.add(new Contract_Review__c(
                Opportunity__c = oppId, Stage__c = 'PSA Drafting'));
        }

        if (!devToInsert.isEmpty()) {
            insert devToInsert;
        }
        if (!conToInsert.isEmpty()) {
            insert conToInsert;
        }
        if (!contractToInsert.isEmpty()) {
            insert contractToInsert;
            // Stamp the new Contract Review back onto the Opportunity's Primary_Contract__c
            // so the Contract tab can show its fields via spanning relationships. The
            // re-fired trigger no-ops here because the stage is unchanged on this update.
            List<Opportunity> oppsToStamp = new List<Opportunity>();
            for (Contract_Review__c cr : contractToInsert) {
                oppsToStamp.add(new Opportunity(Id = cr.Opportunity__c, Primary_Contract__c = cr.Id));
            }
            update oppsToStamp;
        }

        // Entering Underwriting opens the Underwriting record (same primary-stamp
        // pattern as the Contract Review at PSA).
        if (!uwOpps.isEmpty()) {
            List<Underwriting__c> uwToInsert = new List<Underwriting__c>();
            for (Id oppId : uwOpps) {
                uwToInsert.add(new Underwriting__c(
                    Opportunity__c = oppId, Stage__c = 'Requested', Status__c = 'In Progress'));
            }
            insert uwToInsert;
            List<Opportunity> uwStamps = new List<Opportunity>();
            for (Underwriting__c uw : uwToInsert) {
                uwStamps.add(new Opportunity(Id = uw.Opportunity__c, Primary_Underwriting__c = uw.Id));
            }
            update uwStamps;
        }

        // Entering LOI opens the LOI record. Added 2026-08-05: LOI was the ONLY child in the deal
        // tree with no auto-creation, so principal approval moved a deal to the LOI stage with
        // nothing to work on.
        //
        // 🔴 STAMPING Primary_LOI__c IS THE LOAD-BEARING HALF, not bookkeeping.
        // ApprovalAuditService's LOI gate resolves its target through
        // OpportunitySelector.selectPrimaryLoiByIds, so a null Primary_LOI__c makes the LOI
        // approval stamp NOTHING — silently, because that service swallows its own failures. An
        // LOI created without this stamp would reproduce the Underwriting-gate defect one stage
        // later. Same insert-then-stamp shape as Contract Review / Underwriting / NDA above.
        //
        // Property__c is carried from the deal so the LOI is not orphaned from the asset; it is
        // read from Trigger.new rather than re-queried. A deal with no Property yields null, which
        // is the pre-existing state for a manually created LOI and is not made worse here.
        if (!loiOpps.isEmpty()) {
            List<LOI__c> loiToInsert = new List<LOI__c>();
            for (Id oppId : loiOpps) {
                loiToInsert.add(new LOI__c(
                    Opportunity__c = oppId,
                    Property__c = propertyByOpp.get(oppId),
                    Stage__c = 'Draft',
                    LOI_Status__c = 'Draft'));
            }
            // ⚠ EXPLICIT SYSTEM MODE — and this block genuinely differs from its five siblings
            // above, which deliberately keep a bare `insert`. Every other child is created when a
            // DEAL DRIVER moves the stage, and a deal driver has Edit. The LOI stage is the only
            // one entered by the APPROVAL PROCESS's own field update, so this code runs as the
            // APPROVER — who is read-only on both Opportunity and LOI__c (DPEG Principal PSG:
            // Read yes, Edit no, measured). That exact difference is what broke
            // ApprovalAuditService twice on 2026-08-05, so it is stated at the DML here rather
            // than assumed from trigger context.
            Database.insert(loiToInsert, true, AccessLevel.SYSTEM_MODE);
            List<Opportunity> loiStamps = new List<Opportunity>();
            for (LOI__c loi : loiToInsert) {
                loiStamps.add(new Opportunity(Id = loi.Opportunity__c, Primary_LOI__c = loi.Id));
            }
            Database.update(loiStamps, true, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * Every new Opportunity opens an NDA to track from the New stage, stamped
     * onto Primary_NDA__c so the NDA tab has a record and the signed-NDA gate has
     * something to check. Insert-only and idempotent - a deal never opens a second
     * NDA. Stamping Primary_NDA__c leaves StageName unchanged, so the
     * NDA_Signed_Before_Underwriting rule (ISCHANGED-gated) never fires here.
     */
    public static void ensureNda(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        if (oldMap != null) {
            return; // only on insert
        }
        Set<Id> oppIds = new Set<Id>();
        for (Opportunity o : newOpps) {
            if (o.Primary_NDA__c == null) {
                oppIds.add(o.Id);
            }
        }
        if (oppIds.isEmpty()) {
            return;
        }
        // Idempotency: skip any deal that already has an NDA.
        // SOQL relocated to NdaSelector (Module A2) per ARCHITECTURE.md §2.
        for (NDA__c existing : NdaSelector.selectByOpportunityIds(oppIds)) {
            oppIds.remove(existing.Opportunity__c);
        }
        if (oppIds.isEmpty()) {
            return;
        }
        List<NDA__c> ndaToInsert = new List<NDA__c>();
        for (Id oppId : oppIds) {
            ndaToInsert.add(new NDA__c(Opportunity__c = oppId, Status__c = 'Pending'));
        }
        insert ndaToInsert;
        List<Opportunity> ndaStamps = new List<Opportunity>();
        for (NDA__c nda : ndaToInsert) {
            ndaStamps.add(new Opportunity(Id = nda.Opportunity__c, Primary_NDA__c = nda.Id));
        }
        update ndaStamps;
    }
}