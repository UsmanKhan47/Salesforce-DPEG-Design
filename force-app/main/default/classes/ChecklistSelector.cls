/**
 * Selector for `Checklist__c` — the 11 task-group rows created per Transaction by
 * `ChecklistFanoutService`. Encapsulates ALL SOQL against the object per ARCHITECTURE.md §2 and
 * `.claude/rules/apex-layering-rule.md` ("All SOQL must live in Selector classes").
 *
 * layer=selector.
 *
 * ┌───────────────────────────────────────────────────────────────────────────────────────────┐
 * │ MODE INVENTORY — EVERY METHOD IN THIS CLASS IS `WITH SYSTEM_MODE`, AND EACH SAYS WHY AT    │
 * │ ITS OWN DECLARATION. That is unusual and is stated here so nobody reads it as a blanket    │
 * │ class-level decision: ARCHITECTURE.md §2 is explicit that "the mode is a property of the   │
 * │ METHOD, never of the class". It happens that every consumer built in Phase 2 is an         │
 * │ AUTOMATION path (a trigger-driven rollup, a Queueable fan-out, a reconcile fired from a    │
 * │ Transaction save). The first UI read added here must be `WITH USER_MODE` and must NOT      │
 * │ inherit these justifications.                                                              │
 * └───────────────────────────────────────────────────────────────────────────────────────────┘
 *
 * ⚠ SHARING IS NOT LIFTED, AND ON THIS OBJECT IT DOES NOT NEED TO BE — WHICH IS A REAL
 * STRUCTURAL GAIN OVER THE TASK MODEL, NOT A LUCKY BREAK. `Checklist__c` is
 * `sharingModel=ControlledByParent` under a master-detail to `Transaction__c`, so "can I see this
 * checklist" is *exactly* "can I see its Transaction" — there is no `OwnerId` on a detail record
 * and therefore no way for one checklist of a deal to be visible while another is hidden. The
 * whole class of failure `TaskSelector` documents (an individually REASSIGNED checklist Task
 * hiding its sibling from a rollup or a prerequisite lookup) cannot occur here. The residual that
 * remains is coarser and louder: a principal who cannot see the Transaction at all reads zero
 * checklists, which the callers treat as "nothing to recompute" rather than "recompute to zero".
 *
 * @see force-app/main/default/classes/ChecklistItemSelector.cls
 * @see force-app/main/default/classes/ChecklistRollupService.cls (the rollup consumer)
 * @see agent-output/design-transaction-fsd-gaps.md §4.1, §5.3
 */
public with sharing class ChecklistSelector {

    /**
     * Checklists belonging to the supplied Transactions, ordered by group sequence then letter so
     * the caller never has to re-sort for display or for deterministic test assertions.
     *
     * 🔴 `WITH SYSTEM_MODE` — AUTOMATION PATH. Called by `ChecklistRollupService.recalc`, which is
     * fired from `ChecklistItemTrigger`'s after contexts: a read performed ON the saving user's
     * behalf, never at their request. `USER_MODE` THROWS rather than degrades
     * (`System.QueryException: No such column` for a single missing FLS grant), and inside a
     * trigger that escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the user's own
     * save of a checklist item. Every field below except `Id` is a Metadata-API-deployed custom
     * field, which arrives with ZERO FieldPermissions rows for any profile including System
     * Administrator, so on the day this deploys a `USER_MODE` read here would fail for EVERYONE.
     * That is not hypothetical in this org: the identical failure on `Transaction_Deal__c` rolled
     * back an entire 82-row Day-0 fan-out (see `TaskSelector`'s header, 2026-08-05).
     *
     * ⚠ `Transaction__c` IS A MASTER-DETAIL FIELD AND IS THEREFORE NON-PERMISSIONABLE — it must
     * never appear in a permission set `fieldPermissions` block (the deploy fails). It is selected
     * here regardless; non-permissionable fields have no FLS to deny, so it is safe in either mode.
     *
     * NOT-FOUND CONTRACT: a list read. Missing rows are meaningful, not exceptional — a Transaction
     * that has never been fanned out simply has no checklists. Returns an EMPTY list, never null.
     *
     * @param transactionIds Parent `Transaction__c` ids; null/empty-safe.
     * @return Checklists on those deals with Id, Transaction__c, Group_Letter__c, Group_Name__c,
     *         Sequence__c, Stage__c, Is_Conditional__c, Items_Total__c and Items_Complete__c
     *         populated; an empty list when the input is null/empty or nothing matches.
     * @example
     * List<Checklist__c> groups = ChecklistSelector.selectByTransactionIds(dealIds);
     */
    public static List<Checklist__c> selectByTransactionIds(Set<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return new List<Checklist__c>();
        }
        return [
            SELECT Id, Transaction__c, Group_Letter__c, Group_Name__c, Owner_Label__c,
                   Sequence__c, Stage__c, Is_Conditional__c, Items_Total__c, Items_Complete__c
            FROM Checklist__c
            WHERE Transaction__c IN :transactionIds
            WITH SYSTEM_MODE
            ORDER BY Sequence__c ASC NULLS FIRST, Group_Letter__c ASC
        ];
    }

    /**
     * Checklists by their own ids, keyed by Id — the checklist-to-Transaction projection the
     * trigger handler needs, because a `Checklist_Item__c` in `Trigger.new` carries only its
     * `Checklist__c` lookup and never the grandparent deal.
     *
     * 🔴 `WITH SYSTEM_MODE` — same automation-path justification as `selectByTransactionIds` above,
     * one hop earlier in the same call chain (`ChecklistItemTriggerHandler` -> here ->
     * `ChecklistRollupService`). Stated again rather than cross-referenced because ARCHITECTURE.md
     * §2 requires the justification to sit at the METHOD's own declaration.
     *
     * ⚠ ON DELETE THIS CAN LEGITIMATELY RETURN FEWER ROWS THAN ASKED FOR, AND THE CALLER MUST NOT
     * TREAT THAT AS AN ERROR. When a whole `Checklist__c` is deleted the platform cascade-deletes
     * its items and fires their after-delete trigger; by then the parent may already be gone, so
     * its Transaction is unreachable from this read. `ChecklistFanoutService.reconcile` — the only
     * production path that deletes a whole checklist — recomputes the affected Transaction
     * EXPLICITLY afterwards for exactly this reason. Deleting a checklist by hand outside that
     * service will leave the Transaction counters stale until the next item save on that deal.
     *
     * @param checklistIds `Checklist__c` ids; null/empty-safe.
     * @return Map of Checklist Id -> Checklist__c with Id and Transaction__c populated; an empty
     *         map when the input is null/empty or none of the rows still exist.
     * @example
     * Map<Id, Checklist__c> parents = ChecklistSelector.selectByIds(checklistIds);
     */
    public static Map<Id, Checklist__c> selectByIds(Set<Id> checklistIds) {
        if (checklistIds == null || checklistIds.isEmpty()) {
            return new Map<Id, Checklist__c>();
        }
        return new Map<Id, Checklist__c>([
            SELECT Id, Transaction__c, Group_Letter__c, Sequence__c
            FROM Checklist__c
            WHERE Id IN :checklistIds
            WITH SYSTEM_MODE
        ]);
    }
}
