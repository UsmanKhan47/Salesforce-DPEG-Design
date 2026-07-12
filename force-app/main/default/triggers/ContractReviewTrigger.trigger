// PSA execution: when a Contract Review's negotiation status becomes Executed,
// hand the deal off to the Transactions team (stamp the Opp, create the
// Transaction, arm the Day-0 fan-out, notify Transactions/IR/DD).
trigger ContractReviewTrigger on Contract_Review__c (after update) {
    ContractExecutionService.handleExecution(Trigger.new, Trigger.oldMap);
}