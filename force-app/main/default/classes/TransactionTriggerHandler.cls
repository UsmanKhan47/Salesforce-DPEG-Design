/**
 * Trigger handler for `Transaction__c`. Extends the project's `TriggerHandler` base, so the trigger
 * file is one line.
 *
 * layer=handler. No SOQL, no DML, no business logic - it routes each context to exactly ONE service
 * and does nothing else.
 *
 * 🔴 THIS IS THE FIRST APEX TRIGGER `Transaction__c` HAS EVER HAD, AND THE OBJECT SITS IN THE MIDDLE
 * OF THE DAY-0 CHAIN. Opportunity 'About to Close' -> `ContractExecutionService` inserts the
 * Transaction -> `Transaction_Task_Fanout` flow -> `TaskFanoutQueueable` -> 82 Task inserts ->
 * `TaskRollupTrigger` -> `TaskRollupService` UPDATES THE TRANSACTION AGAIN. `ChecklistRollupService`
 * and `ChecklistFanoutService` add two more Transaction updates on the new model. So this handler
 * fires several times per deal creation and MUST cost nothing on the saves that are not about
 * stages or dates. Each arm is bounded accordingly:
 *
 *   beforeInsert/beforeUpdate -> `TransactionStageEntryService`: pure in-memory, ZERO SOQL and ZERO
 *       DML at any record count, by construction. Every rollup write leaves through its
 *       "stage did not change" `continue` having spent nothing.
 *   afterUpdate -> `ChecklistFanoutService.reconcile`: entered ONLY when `Loan_Required__c`
 *       actually changed. A rollup write (counters only) collects zero ids and the service is never
 *       called - so a fan-out chunk's Transaction update costs 0 SOQL here, which is what keeps the
 *       fan-out's budget (see that class's header) valid.
 *
 * 🔴 `CriticalDateService` IS NOT WIRED TO THIS TRIGGER AT ALL - NEITHER CONTEXT. The after-insert
 * arm was never added, and the after-update arm was REMOVED by user decision on 2026-09-01. The full
 * conditions for wiring it are recorded AT THE REMOVAL SITE in `afterUpdate` below, not here, so
 * that whoever restores the call reads them at the point of change. Summary: GATE-B2 (a restricted
 * `Critical_Date__c.Type__c` that does not yet contain `Contract Executed`), GATE-B4 (source of
 * truth), and the `required=true` + `deleteConstraint=Restrict` consequence - the moment a critical
 * date exists, its Transaction can never be deleted, which at insert would make `DELETE_FAILED` the
 * default for every deal in the org and break `scripts/seed-transactions.apex` and every scratch
 * rebuild. GATE-B3 also remains open; see `CriticalDateService`'s header.
 * ⚠ This handler therefore routes to ONE service per context, not two. Do not "restore symmetry"
 * by re-adding the call without the gates above.
 *
 * @see force-app/main/default/triggers/TransactionTrigger.trigger
 * @see force-app/main/default/classes/TransactionStageEntryService.cls
 * @see force-app/main/default/classes/ChecklistFanoutService.cls (reconcile)
 * @see force-app/main/default/classes/CriticalDateService.cls (deliberately NOT wired here)
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

        // ═══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 NO `CriticalDateService` ARM. WITHHELD ON PURPOSE — THIS IS NOT AN OVERSIGHT.
        // ═══════════════════════════════════════════════════════════════════════════════════════
        // An `afterUpdate` arm calling `CriticalDateService.ensureFor` existed here and was REMOVED
        // by user decision on 2026-09-01, for the same reason the `afterInsert` arm was never added:
        // wiring it live makes Phase 2 NON-NEUTRAL for every deal in the org on its next stage move,
        // while two design gates are still unanswered.
        //
        // WHAT MUST BE TRUE BEFORE IT IS WIRED — both, not either:
        //   • GATE-B2 — `Contract Executed` must be a valid value on `Critical_Date__c.Type__c`,
        //     which is a RESTRICTED picklist. Until it is, the projection writes a value the
        //     platform refuses (`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`) and the refusal lands
        //     inside an after-update trigger, i.e. it rolls back the user's own deal save.
        //   • GATE-B4 — the source of truth for a deal's critical dates has to be settled. Today
        //     `scripts/seed-critical-dates.apex` and this projection would both write them, and
        //     nothing reconciles the two.
        //   • And re-read the `deleteConstraint=Restrict` note in this class's header: the moment a
        //     critical date exists, its Transaction can never be deleted.
        //
        // THE SERVICE, ITS SELECTOR AND ITS TESTS ARE INTACT AND STAY THAT WAY. `CriticalDateService`
        // is still called directly by `scripts/seed-critical-dates.apex`, which is the only
        // production caller today, and `CriticalDateServiceTest` exercises it directly. Nothing about
        // this removal makes the service dead code.
        //
        // ⚠ RE-WIRING IT IS NOT JUST RESTORING THE CALL. The field-change gate went with it: it
        // collected on `Stage__c`, `Target_Close_Date__c`, `Feasibility_Deadline__c`,
        // `Feasibility_Missed__c` and `Loan_Required__c` — the projection sources. Restore that
        // condition set with the call, or the arm fires on counter writes and re-introduces the
        // per-rollup-write cost this handler's header promises is zero.
        // ⚠ AND THE TWO SELECTOR HEADERS MOVE WITH IT. `TransactionSelector.selectForCriticalDates`
        // and `CriticalDateSelector.selectExistingKeysByTransactionIds` both justify SYSTEM_MODE by naming this
        // trigger; both were amended to name the script instead. Re-wiring must amend them back.
        // ═══════════════════════════════════════════════════════════════════════════════════════

        Set<Id> reconcileCandidates = new Set<Id>();
        for (Transaction__c deal : deals) {
            Transaction__c prior = priorByAd == null ? null : priorByAd.get(deal.Id);
            if (prior == null) {
                continue;
            }
            // The ONLY conditional-group driver today is `Loan_Required__c`
            // (`Task_Group_Def__mdt.Condition_Field__c` = `Loan_Required__c` on group F). If a
            // second conditional group is ever configured, ITS condition field must be added here in
            // the same change, or that group will never reconcile and the omission is invisible.
            // ⚠ This gate is now the ONLY one in this context, and it is still correct on its own:
            // it is specific to the reconcile driver and was never shared with the removed arm. A
            // rollup write (counters only) still collects zero ids and still calls nothing.
            if (prior.Loan_Required__c != deal.Loan_Required__c) {
                reconcileCandidates.add(deal.Id);
            }
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
