/**
 * Trigger handler for `Checklist_Item__c`. Extends the project's `TriggerHandler` base
 * (ARCHITECTURE.md §2, `.claude/rules/apex-layering-rule.md`), so the trigger file itself is one
 * line and every context method it does not override is an inherited no-op.
 *
 * layer=handler. No SOQL, no DML, no business logic - it routes context to the domain and the two
 * services and does nothing else.
 *
 * THREE RESPONSIBILITIES:
 *   1. THE COMPLETION STAMP (before insert / before update) - `ChecklistItemDomain.stampCompletion`
 *      writes the real `Completed_By__c` / `Completed_DateTime__c`, retiring the `LastModifiedBy`
 *      approximation that `TaskSelector` and `TransactionTaskController` both carry warnings about.
 *      Pure in-memory, zero SOQL, zero DML, at any record count.
 *   2. THE WIRE-FRAUD PREREQUISITE GATE - `ChecklistItemPrerequisiteService`. In BEFORE UPDATE it
 *      resolves and enforces; in BEFORE INSERT it CLAMPS ONLY, with no sibling lookup, because a
 *      query there would cost 21 SOQL on the fan-out's own insert cascade. The insert REFUSAL comes
 *      from the validation rule reading the clamped value. That asymmetry is deliberate and is
 *      argued in full at `ChecklistItemPrerequisiteService.clampOnInsert`.
 *   3. THE ROLLUPS (all four after contexts) - `ChecklistRollupService`, suppressed during fan-out.
 *
 * ⚠ THIS TRIGGER IS SCOPED TO ONE OBJECT AND CANNOT AFFECT ANYTHING ELSE - WHICH IS THE SINGLE
 * BIGGEST OPERATIONAL DIFFERENCE FROM PHASE 0. The equivalent Task logic lives on
 * `TaskRollupTrigger`, which fires on EVERY Task in the org: the PM Onboarding checklist, Broker
 * Protection pipeline Tasks, EAC companion Tasks, Disposition closing Tasks and every hand-created
 * Activity. That is why `TaskPrerequisiteService` needed an elaborate org-wide cost control (two
 * blank checks and an early return for rows it must not touch). Here the object contains nothing but
 * checklist items, so no such control is needed and no other module can be disturbed by a change to
 * this file. `TaskRollupTrigger` and `TaskRollupTriggerHandler` are NOT modified by Phase 2.
 *
 * CONTEXT SOURCING:
 *   insert / undelete : parent ids from the new records.
 *   delete            : parent ids from the old records.
 *   update            : from BOTH collections. `Checklist__c` is master-detail with
 *                       `reparentableMasterDetail=false`, so the two sets are provably identical -
 *                       collecting both is belt and braces, and free.
 *
 * @see force-app/main/default/triggers/ChecklistItemTrigger.trigger
 * @see force-app/main/default/classes/ChecklistItemPrerequisiteService.cls
 */
public with sharing class ChecklistItemTriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        ChecklistItemDomain.stampCompletion((List<Checklist_Item__c>) newList, null);
        // Clamp only - no sibling lookup on insert. The arithmetic is at `clampOnInsert`.
        ChecklistItemPrerequisiteService.clampOnInsert((List<Checklist_Item__c>) newList);
    }

    protected override void beforeUpdate() {
        ChecklistItemDomain.stampCompletion(
            (List<Checklist_Item__c>) newList, (Map<Id, Checklist_Item__c>) oldMap);
        // Return value deliberately discarded: the refusals are applied to the records via
        // `addError` inside the service, and the map exists only so a unit test can assert the
        // decision without depending on `addError` outside a trigger.
        ChecklistItemPrerequisiteService.enforceOnUpdate(
            (List<Checklist_Item__c>) newList, (Map<Id, Checklist_Item__c>) oldMap);
    }

    protected override void afterInsert() {
        recalcFor(ChecklistItemDomain.collectChecklistIds((List<Checklist_Item__c>) newList));
    }

    protected override void afterUpdate() {
        Set<Id> checklistIds =
            ChecklistItemDomain.collectChecklistIds((List<Checklist_Item__c>) newList);
        checklistIds.addAll(
            ChecklistItemDomain.collectChecklistIds((List<Checklist_Item__c>) oldList));
        recalcFor(checklistIds);
    }

    protected override void afterDelete() {
        recalcFor(ChecklistItemDomain.collectChecklistIds((List<Checklist_Item__c>) oldList));
    }

    protected override void afterUndelete() {
        recalcFor(ChecklistItemDomain.collectChecklistIds((List<Checklist_Item__c>) newList));
    }

    /**
     * Recomputes the counters for the supplied checklists, unless the fan-out has taken ownership.
     *
     * 🔴 THE SUPPRESSION CHECK IS WHAT MAKES THE FAN-OUT'S GOVERNOR BUDGET HOLD. `fanOutNow` inserts
     * up to 50 x 82 = 4,100 items in ONE statement, which the platform fires after-insert against in
     * 21 batches; without this early return that is 21 SOQL + 21 DML spent recomputing counters for
     * rows the same statement is still creating. The fan-out writes them itself, once, from what it
     * knows it created. The flag is false on every other path, so a standard-UI edit, an API write,
     * Data Loader, a delete and an undelete all roll up exactly as before.
     *
     * @param checklistIds Parent checklists touched by this save.
     */
    private void recalcFor(Set<Id> checklistIds) {
        if (ChecklistRollupService.isTriggerRecalcSuppressed()) {
            return;
        }
        if (checklistIds == null || checklistIds.isEmpty()) {
            return;
        }
        ChecklistRollupService.recalcForChecklistIds(checklistIds);
    }
}
