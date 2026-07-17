/**
 * Trigger handler for Task. Recomputes Transaction__c rollups
 * (Tasks_Complete__c / Tasks_Overdue__c / Wire_Open_Risks__c) whenever a
 * deal's checklist Tasks change. Checklist Tasks relate to the deal via the
 * Transaction_Deal__c lookup (not WhatId), so they stay off the Activity
 * timeline. Only Transaction__c is updated downstream, so there is no Task
 * re-entry.
 *
 * Context sourcing preserves the original trigger exactly:
 *   - insert / undelete: collect deal ids from the new records.
 *   - delete:            collect deal ids from the old records.
 *   - update:            collect deal ids from BOTH new and old (a re-parent
 *                        must recompute the losing and the gaining deal).
 * TaskRollupService.recalc is called once per context, only when at least one
 * deal id was collected.
 *
 * The id collection is a mechanical projection of a lookup field, not a
 * per-object business rule, so it lives here in the handler rather than in a
 * Domain class (see the phase report for the Domain-vs-handler decision).
 */
public with sharing class TaskRollupTriggerHandler extends TriggerHandler {

    protected override void afterInsert() {
        recalcDeals(collectDealIds((List<Task>) newList));
    }

    protected override void afterUpdate() {
        Set<Id> dealIds = collectDealIds((List<Task>) newList);
        dealIds.addAll(collectDealIds((List<Task>) oldList));
        recalcDeals(dealIds);
    }

    protected override void afterDelete() {
        recalcDeals(collectDealIds((List<Task>) oldList));
    }

    protected override void afterUndelete() {
        recalcDeals(collectDealIds((List<Task>) newList));
    }

    /**
     * Projects the non-null Transaction_Deal__c lookups of a Task collection
     * into a de-duplicated Set of deal ids.
     * @param tasks Tasks from one trigger context (may be null defensively).
     * @return The distinct, non-null deal ids referenced by those Tasks.
     */
    private Set<Id> collectDealIds(List<Task> tasks) {
        Set<Id> dealIds = new Set<Id>();
        if (tasks == null) {
            return dealIds;
        }
        for (Task t : tasks) {
            if (t.Transaction_Deal__c != null) {
                dealIds.add(t.Transaction_Deal__c);
            }
        }
        return dealIds;
    }

    /**
     * Recomputes rollups for the supplied deals, only when the set is non-empty.
     * @param dealIds Transaction__c ids to recompute.
     */
    private void recalcDeals(Set<Id> dealIds) {
        if (!dealIds.isEmpty()) {
            TaskRollupService.recalc(dealIds);
        }
    }
}
