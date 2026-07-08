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
        }
        if (devOpps.isEmpty() && conOpps.isEmpty() && contractOpps.isEmpty() && uwOpps.isEmpty()) {
            return;
        }

        // Idempotency: drop opps that already have a review of the matching type.
        for (Development_Feasibility_Review__c d : [
            SELECT Opportunity__c FROM Development_Feasibility_Review__c
            WHERE Opportunity__c IN :devOpps
        ]) {
            devOpps.remove(d.Opportunity__c);
        }
        for (Construction_Feasibility_Review__c c : [
            SELECT Opportunity__c FROM Construction_Feasibility_Review__c
            WHERE Opportunity__c IN :conOpps
        ]) {
            conOpps.remove(c.Opportunity__c);
        }
        for (Contract_Review__c cr : [
            SELECT Opportunity__c FROM Contract_Review__c
            WHERE Opportunity__c IN :contractOpps
        ]) {
            contractOpps.remove(cr.Opportunity__c);
        }
        for (Underwriting__c uw : [
            SELECT Opportunity__c FROM Underwriting__c
            WHERE Opportunity__c IN :uwOpps
        ]) {
            uwOpps.remove(uw.Opportunity__c);
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
    }
}