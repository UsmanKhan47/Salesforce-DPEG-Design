/**
 * Trigger handler for Contract_Review__c. Routes the after-update context to
 * ContractExecutionService: when a Contract Review's negotiation status becomes
 * Executed, the PSA is handed off to the Transactions team (stamp the Opp,
 * create the Transaction, arm the Day-0 fan-out, notify Transactions/IR/DD).
 *
 * All business logic lives in ContractExecutionService; this handler only wires
 * the trigger context to that service.
 */
public with sharing class ContractReviewTriggerHandler extends TriggerHandler {

    protected override void afterUpdate() {
        ContractExecutionService.handleExecution(
            (List<Contract_Review__c>) newList,
            (Map<Id, Contract_Review__c>) oldMap
        );
    }
}
