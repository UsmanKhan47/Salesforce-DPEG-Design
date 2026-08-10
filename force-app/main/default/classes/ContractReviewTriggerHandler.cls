/**
 * Trigger handler for Contract_Review__c. Routes the after-update context to
 * ContractExecutionService.handleExecution, which runs TWO INDEPENDENT ARMS when a Contract
 * Review's Negotiation_Status__c becomes Executed — one per parent lookup, through two separate
 * `if`s and never an `if/else`, so a row with both parents runs both and a row with neither runs
 * neither:
 *
 *   ACQUISITION arm (Opportunity__c populated) — stamps the Opportunity (Contract Signed, Day 0),
 *   arms the Day-0 fan-out, and notifies Transactions / IR / Due Diligence.
 *
 *   DISPOSITION arm (Disposition__c populated, added Tranche 3C) — moves the sale's
 *   Disposition_Stage__c to `Closing`. It carries a no-change filter, `allOrNone = false` and
 *   `AccessLevel.SYSTEM_MODE`, argued in that class's header as THREE mechanisms for three
 *   obstacles that do not substitute for one another.
 *
 * ⚠ TWO CORRECTIONS TO THIS PARAGRAPH, MADE IN PLACE RATHER THAN LEFT TO MISLEAD (review W4).
 * (1) It used to say the acquisition arm "creates the Transaction". IT STOPPED DOING THAT ON
 * 2026-08-05: Transaction creation moved to `openTransactionsOnAboutToClose`, keyed on the
 * OPPORTUNITY stage, and ContractExecutionService's own header says so emphatically. Anyone
 * chasing "where does the Transaction come from" must not start here. (2) The disposition arm was
 * added in 3C and this file was the last one in the chain not to mention it.
 *
 * ⚠ AFTER-UPDATE ONLY, AND THAT IS A KNOWN GAP RATHER THAN A DESIGN POINT (review S5). A Contract
 * Review INSERTED directly at Negotiation_Status__c = 'Executed' runs NEITHER arm — handleExecution
 * tolerates a null oldMap but is never called on insert. Pre-existing and not a 3C regression, but
 * it matters more now that a disposition PSA can be created by hand or by a data load.
 *
 * All business logic lives in ContractExecutionService; this handler only wires
 * the trigger context to that service.
 *
 * @see force-app/main/default/classes/ContractExecutionService.cls (both arms)
 */
public with sharing class ContractReviewTriggerHandler extends TriggerHandler {

    protected override void afterUpdate() {
        ContractExecutionService.handleExecution(
            (List<Contract_Review__c>) newList,
            (Map<Id, Contract_Review__c>) oldMap
        );
    }
}
