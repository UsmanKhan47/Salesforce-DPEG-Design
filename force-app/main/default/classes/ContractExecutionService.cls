/**
 * PSA execution handoff (called from ContractReviewTrigger, after update). When a
 * Contract Review's Negotiation_Status__c just became 'Executed':
 *
 *   1. Stamps the parent Opportunity: Contract_Signed__c, Contract_Executed_Date__c
 *      (Day 0), Deal_Status__c = 'Contract Signed', Stage = 'PSA Executed'.
 *   2. Creates the Transaction__c (idempotent - never a second one per deal) with
 *      Contract_Executed_Date__c set, which ARMS the existing Transaction_Task_Fanout
 *      flow -> TaskFanoutService 75-task Day-0 checklist untouched.
 *   3. Notifies Transactions_Team + Investor_Relations (PSA executed) and
 *      Due_Diligence (Danish: DD materials available once the contract is signed).
 */
public with sharing class ContractExecutionService {

    @TestVisible private static final String EXECUTED = 'Executed';

    public static void handleExecution(List<Contract_Review__c> newCrs, Map<Id, Contract_Review__c> oldMap) {
        Set<Id> executedOppIds = new Set<Id>();
        for (Contract_Review__c cr : newCrs) {
            Contract_Review__c prior = (oldMap == null) ? null : oldMap.get(cr.Id);
            Boolean justExecuted = cr.Negotiation_Status__c == EXECUTED
                && (prior == null || prior.Negotiation_Status__c != EXECUTED);
            if (justExecuted && cr.Opportunity__c != null) {
                executedOppIds.add(cr.Opportunity__c);
            }
        }
        if (executedOppIds.isEmpty()) {
            return;
        }

        // Idempotency: a deal that already has a Transaction is not handed off twice.
        Set<Id> alreadyHandedOff = new Set<Id>();
        for (Transaction__c t : [
            SELECT Opportunity__c FROM Transaction__c WHERE Opportunity__c IN :executedOppIds
        ]) {
            alreadyHandedOff.add(t.Opportunity__c);
        }

        Datetime dayZero = Datetime.now();
        List<Opportunity> oppUpdates = new List<Opportunity>();
        List<Transaction__c> transToInsert = new List<Transaction__c>();
        List<Opportunity> opps = [
            SELECT Id, Name, Property__c, Contract_Executed_Date__c,
                   Primary_Contract__r.Contract_Value__c, Primary_LOI__r.Earnest_Money__c
            FROM Opportunity WHERE Id IN :executedOppIds
        ];
        for (Opportunity o : opps) {
            Opportunity stamp = new Opportunity(
                Id = o.Id,
                Contract_Signed__c = true,
                Deal_Status__c = 'Contract Signed',
                StageName = 'PSA Executed'
            );
            if (o.Contract_Executed_Date__c == null) {
                stamp.Contract_Executed_Date__c = dayZero;
            }
            oppUpdates.add(stamp);

            if (!alreadyHandedOff.contains(o.Id)) {
                transToInsert.add(new Transaction__c(
                    Opportunity__c = o.Id,
                    Property__c = o.Property__c,
                    Contract_Value__c = o.Primary_Contract__r != null ? o.Primary_Contract__r.Contract_Value__c : null,
                    Earnest_Money__c = o.Primary_LOI__r != null ? o.Primary_LOI__r.Earnest_Money__c : null,
                    Contract_Executed_Date__c = dayZero.date(), // arms the Day-0 task fan-out
                    Status__c = 'Active',
                    Stage__c = 'Open Contract',
                    Target_Close_Date__c = Date.today().addDays(60)
                ));
            }
        }
        update oppUpdates;
        if (!transToInsert.isEmpty()) {
            insert transToInsert;
        }

        for (Opportunity o : opps) {
            GroupNotifier.send('Transactions_Team', 'PSA executed - transaction opened',
                o.Name + ': Day 0. The closing checklist has been fanned out.', o.Id);
            GroupNotifier.send('Investor_Relations', 'PSA executed',
                o.Name + ': contract signed - IR phase begins.', o.Id);
            GroupNotifier.send('Due_Diligence', 'Due diligence materials available',
                o.Name + ': the contract is signed - DD materials are ready for review.', o.Id);
        }
    }
}
