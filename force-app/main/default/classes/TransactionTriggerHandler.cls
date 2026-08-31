/**
 * Trigger handler for `Transaction__c`. Extends the project's `TriggerHandler` base, so the trigger
 * file is one line.
 *
 * layer=handler. No SOQL, no DML, no business logic - it routes context to two services and does
 * nothing else.
 *
 * 🔴 THIS IS THE FIRST APEX TRIGGER `Transaction__c` HAS EVER HAD, AND THE OBJECT SITS IN THE MIDDLE
 * OF THE DAY-0 CHAIN. Opportunity 'About to Close' -> `ContractExecutionService` inserts the
 * Transaction -> `Transaction_Task_Fanout` flow -> `TaskFanoutQueueable` -> 82 Task inserts ->
 * `TaskRollupTrigger` -> `TaskRollupService` UPDATES THE TRANSACTION AGAIN. `ChecklistRollupService`
 * and `ChecklistFanoutService` add two more Transaction updates on the new model. So this handler
 * fires several times per deal creation and MUST cost nothing on the saves that are not about
 * stages or dates. Both arms are gated accordingly:
 *
 *   beforeInsert/beforeUpdate -> `TransactionStageEntryService`: pure in-memory, ZERO SOQL and ZERO
 *       DML at any record count, by construction. Every rollup write leaves through its
 *       "stage did not change" `continue` having spent nothing.
 *   afterUpdate -> `CriticalDateService` and `ChecklistFanoutService.reconcile`: BOTH are entered
 *       ONLY when a specific field actually changed. A rollup write (counters only) collects zero
 *       ids and both services are never called - so a fan-out chunk's Transaction update costs 0
 *       SOQL here, which is what keeps the fan-out's budget (see that class's header) valid.
 *
 * ⚠ NO AFTER-INSERT ARM, DELIBERATELY. `CriticalDateService` is NOT wired to insert because
 * `Critical_Date__c.Transaction__c` is `required=true` + `deleteConstraint=Restrict`: the moment a
 * critical date exists, its Transaction can never be deleted. Creating them at insert would make
 * `DELETE_FAILED` the default for every deal in the org the instant it is created, breaking
 * `scripts/seed-transactions.apex` and every scratch rebuild. After-update-only narrows that to
 * deals that have actually moved. IT DOES NOT CLOSE DESIGN GATE-B3, which is still open - see
 * `CriticalDateService`'s header. Do not add the after-insert arm until B3 is answered.
 *
 * @see force-app/main/default/triggers/TransactionTrigger.trigger
 * @see force-app/main/default/classes/TransactionStageEntryService.cls
 * @see force-app/main/default/classes/CriticalDateService.cls
 */
public with sharing class TransactionTriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        TransactionStageEntryService.stampStageEntryDates((List<Transaction__c>) newList, null);
    }

    protected override void beforeUpdate() {
        TransactionStageEntryService.stampStageEntryDates(
            (List<Transaction__c>) newList, (Map<Id, Transaction__c>) oldMap);
    }

    protected override void afterUpdate() {
        List<Transaction__c> deals = (List<Transaction__c>) newList;
        Map<Id, Transaction__c> priorByAd = (Map<Id, Transaction__c>) oldMap;

        Set<Id> criticalDateCandidates = new Set<Id>();
        Set<Id> reconcileCandidates = new Set<Id>();
        for (Transaction__c deal : deals) {
            Transaction__c prior = priorByAd == null ? null : priorByAd.get(deal.Id);
            if (prior == null) {
                continue;
            }
            // The projection sources: a stage move, or a change to either pinned date. Anything else
            // (a counter, a flag, an owner) cannot change what the projection would produce.
            if (prior.Stage__c != deal.Stage__c
                    || prior.Target_Close_Date__c != deal.Target_Close_Date__c
                    || prior.Feasibility_Deadline__c != deal.Feasibility_Deadline__c
                    || prior.Feasibility_Missed__c != deal.Feasibility_Missed__c
                    || prior.Loan_Required__c != deal.Loan_Required__c) {
                criticalDateCandidates.add(deal.Id);
            }
            // The ONLY conditional-group driver today is `Loan_Required__c`
            // (`Task_Group_Def__mdt.Condition_Field__c` = `Loan_Required__c` on group F). If a
            // second conditional group is ever configured, ITS condition field must be added here in
            // the same change, or that group will never reconcile and the omission is invisible.
            if (prior.Loan_Required__c != deal.Loan_Required__c) {
                reconcileCandidates.add(deal.Id);
            }
        }

        if (!criticalDateCandidates.isEmpty()) {
            CriticalDateService.ensureFor(criticalDateCandidates);
        }
        if (!reconcileCandidates.isEmpty()) {
            // Result deliberately discarded here. A refused group removal (work already exists in
            // it) is NOT an error and must not block the user's save - see
            // `ChecklistFanoutService.reconcile`. Surfacing it belongs to the checklist LWC in
            // Phase 3, which will call `reconcile` directly and read the result.
            ChecklistFanoutService.reconcile(reconcileCandidates);
        }
    }
}
