/**
 * When an Opportunity enters the "Development Review" (Land path) or
 * "Construction Review" (Commercial path) stage, create one feasibility-review
 * child record on the matching object. Idempotent: never creates a second review
 * for the same Opportunity if one of that type already exists, so re-entering or
 * re-saving the stage does not produce duplicates.
 */
public with sharing class OpportunityReviewService {

    @TestVisible private static final String DEV_STAGE = 'Development Review';
    @TestVisible private static final String CON_STAGE = 'Construction Review';
    @TestVisible private static final String CONTRACT_STAGE = 'Under Contract';

    /**
     * Called from the Opportunity after-insert / after-update trigger.
     * @param newOpps Trigger.new
     * @param oldMap  Trigger.oldMap on update; null on insert.
     */
    public static void createReviewRecords(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Set<Id> devOpps = new Set<Id>();
        Set<Id> conOpps = new Set<Id>();
        Set<Id> contractOpps = new Set<Id>();

        for (Opportunity o : newOpps) {
            Opportunity prior = (oldMap == null) ? null : oldMap.get(o.Id);
            String priorStage = (prior == null) ? null : prior.StageName;
            // Only act when the stage just became one of the trigger stages.
            if (priorStage == o.StageName) {
                continue;
            }
            if (o.StageName == DEV_STAGE) {
                devOpps.add(o.Id);
            } else if (o.StageName == CON_STAGE) {
                conOpps.add(o.Id);
            } else if (o.StageName == CONTRACT_STAGE) {
                contractOpps.add(o.Id);
            }
        }
        if (devOpps.isEmpty() && conOpps.isEmpty() && contractOpps.isEmpty()) {
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

        List<Development_Feasibility_Review__c> devToInsert = new List<Development_Feasibility_Review__c>();
        for (Id oppId : devOpps) {
            devToInsert.add(new Development_Feasibility_Review__c(
                Opportunity__c = oppId, Stage__c = 'Requested'));
        }
        List<Construction_Feasibility_Review__c> conToInsert = new List<Construction_Feasibility_Review__c>();
        for (Id oppId : conOpps) {
            conToInsert.add(new Construction_Feasibility_Review__c(
                Opportunity__c = oppId, Stage__c = 'Requested'));
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
    }
}