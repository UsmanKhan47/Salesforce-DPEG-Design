/**
 * Selector for `Checklist_Item__c` — the individual checklist rows under a `Checklist__c`.
 * Encapsulates ALL SOQL against the object per ARCHITECTURE.md §2 and
 * `.claude/rules/apex-layering-rule.md`.
 *
 * layer=selector.
 *
 * ┌───────────────────────────────────────────────────────────────────────────────────────────┐
 * │ MODE INVENTORY — THIS CLASS DELIBERATELY MIXES `SYSTEM_MODE` AND `USER_MODE`.              │
 * │   SYSTEM_MODE (automation paths, each justified at its own declaration):                   │
 * │     • selectByIdsWithDeal    <- ChecklistItemPrerequisiteService (BEFORE-UPDATE trigger)    │
 * │     • selectByTransactionIds <- ChecklistRollupService (AFTER-* trigger) and                │
 * │                                ChecklistFanoutService.reconcile                             │
 * │   USER_MODE (a read the running user asked for):                                           │
 * │     • selectForCompletion    <- ChecklistItemService, driven by a human clicking Complete   │
 * │ Read the METHOD, never the class. ARCHITECTURE.md §2.                                      │
 * └───────────────────────────────────────────────────────────────────────────────────────────┘
 *
 * ⚠ SHARING IS NEVER LIFTED IN THIS CLASS, AND UNLIKE `TaskSelector` THAT COSTS NOTHING HERE.
 * `Checklist_Item__c` is `ControlledByParent` under `Checklist__c`, which is `ControlledByParent`
 * under `Transaction__c`. A detail record has NO `OwnerId`, so an item cannot be individually
 * reassigned away from the deal team the way a checklist `Task` could. Access to any one item is
 * access to every item on that deal, which is why:
 *   • the ROLLUP cannot compute a partial count from a partial view (the failure mode
 *     `TaskRollupService`'s header calls out and accepts as a residual), and
 *   • the PREREQUISITE gate cannot be handed a null prerequisite by sharing alone.
 * The remaining sharing residual is all-or-nothing at the deal level and fails CLOSED in both
 * callers (an unresolvable prerequisite refuses the completion; an unreadable deal recomputes
 * nothing rather than recomputing to zero).
 *
 * @see force-app/main/default/classes/ChecklistSelector.cls
 * @see agent-output/design-transaction-fsd-gaps.md §4.2, §5.1, §5.3
 */
public with sharing class ChecklistItemSelector {

    /**
     * Items by their own ids, with the grandparent deal traversed, keyed by Id.
     *
     * 🔴 THIS IS THE PREREQUISITE GATE'S SINGLE READ, AND IT ANSWERS TWO QUESTIONS AT ONCE — WHICH
     * IS WHY THE CALLER PASSES BOTH THE BLOCKED ITEMS AND THE ITEMS THEY POINT AT IN ONE SET.
     * `ChecklistItemPrerequisiteService` needs (a) the prerequisite's `Flag__c`, and (b) the deal
     * that BOTH rows belong to, so it can refuse a `Blocked_By__c` that points outside the item's
     * own Transaction. A `Checklist_Item__c` in `Trigger.new` carries only `Checklist__c`, so the
     * deal is one traversal away; asking for the candidates and the prerequisites in the SAME
     * query keeps the gate at EXACTLY ONE SOQL per trigger chunk, never a function of row count.
     *
     * 🔴 `WITH SYSTEM_MODE` — AUTOMATION PATH, AND A CORRECTNESS REQUIREMENT RATHER THAN A
     * CONVENIENCE. This runs inside a BEFORE-UPDATE trigger on the saving user's behalf. Under
     * `USER_MODE` a single missing FLS grant raises `System.QueryException: No such column` — an
     * FLS denial wearing a schema error — which escapes the trigger as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back THE USER'S OWN SAVE of a checklist
     * item that has nothing to do with the missing grant. Every field selected below except `Id`
     * is a Metadata-API-deployed custom field carrying zero FieldPermissions rows on the day it
     * deploys, System Administrator included, so a `USER_MODE` read here would fail for EVERY
     * principal until the permission pass lands. This org has already paid for that exact mistake
     * once (`TaskSelector`, 2026-08-05: an 82-row Day-0 fan-out rolled back).
     *
     * ⚠ `Checklist__c` and `Checklist__r.Transaction__c` are MASTER-DETAIL fields and therefore
     * non-permissionable — they can never appear in a `fieldPermissions` block. `Flag__c`,
     * `Subject__c`, `Sequence__c` and `Is_Critical__c` CAN and must be granted.
     *
     * NOT-FOUND CONTRACT: a map read. A missing key is MEANINGFUL and the caller must treat it as
     * UNRESOLVED and fail closed — never as "the prerequisite is satisfied". Returns an empty map,
     * never null.
     *
     * @param itemIds `Checklist_Item__c` ids — the caller's candidates AND their prerequisites;
     *                null/empty-safe.
     * @return Map of item Id -> item with Id, Checklist__c, Checklist__r.Transaction__c, Flag__c,
     *         Subject__c, Sequence__c, Blocked_By__c and Is_Critical__c populated.
     * @example
     * Map<Id, Checklist_Item__c> rows = ChecklistItemSelector.selectByIdsWithDeal(ids);
     */
    public static Map<Id, Checklist_Item__c> selectByIdsWithDeal(Set<Id> itemIds) {
        if (itemIds == null || itemIds.isEmpty()) {
            return new Map<Id, Checklist_Item__c>();
        }
        return new Map<Id, Checklist_Item__c>([
            SELECT Id, Checklist__c, Checklist__r.Transaction__c, Checklist__r.Group_Letter__c,
                   Flag__c, Subject__c, Sequence__c, Blocked_By__c, Is_Critical__c
            FROM Checklist_Item__c
            WHERE Id IN :itemIds
            WITH SYSTEM_MODE
        ]);
    }

    /**
     * Every checklist item on the supplied Transactions — the rollup's source and the reconcile's
     * "has any item in this group been worked?" evidence.
     *
     * 🔴 `WITH SYSTEM_MODE` — AUTOMATION PATH. Two callers, both of them platform-driven:
     * `ChecklistRollupService.recalc` (fired from `ChecklistItemTrigger`'s after contexts) and
     * `ChecklistFanoutService.reconcile` (fired from `TransactionTrigger`'s after-update context
     * and from the fan-out Queueable). Neither is a read the running user asked for. Same
     * `USER_MODE`-throws-rather-than-degrades reasoning as `selectByIdsWithDeal` above, with one
     * additional consequence specific to a rollup: a partial or thrown read here does not produce
     * a visibly broken screen, it produces a WRONG NUMBER on the Wire Sentinel dashboard tile, and
     * a wrong number in the safe-looking direction (zero open wire risks) is the RISK 1 failure
     * this whole rewrite exists to eliminate.
     *
     * ⚠ ORDERED BY parent group then sequence so the reconcile and the migration reconciliation
     * report can compare two runs row-for-row without re-sorting.
     *
     * @param transactionIds Parent `Transaction__c` ids; null/empty-safe.
     * @return Items on those deals with Id, Checklist__c, Checklist__r.Transaction__c,
     *         Checklist__r.Group_Letter__c, Flag__c, Due_Date__c, Is_Critical__c,
     *         Is_Wire_Verification__c, Verbal_Verification_Completed__c and Sequence__c populated;
     *         an empty list when the input is null/empty or nothing matches (never null).
     * @example
     * List<Checklist_Item__c> items = ChecklistItemSelector.selectByTransactionIds(dealIds);
     */
    public static List<Checklist_Item__c> selectByTransactionIds(Set<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return new List<Checklist_Item__c>();
        }
        return [
            SELECT Id, Checklist__c, Checklist__r.Transaction__c, Checklist__r.Group_Letter__c,
                   Sequence__c, Subject__c, Flag__c, Due_Date__c, Is_Critical__c,
                   Is_Wire_Verification__c, Verbal_Verification_Completed__c, Blocked_By__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c IN :transactionIds
            WITH SYSTEM_MODE
            ORDER BY Checklist__r.Sequence__c ASC NULLS FIRST, Sequence__c ASC NULLS FIRST
        ];
    }

    /**
     * Items a human is about to act on — the read behind `ChecklistItemService.complete`,
     * `.reopen` and `.recordWireVerification`.
     *
     * ✅ `WITH USER_MODE`, AND THAT IS THE POINT OF THE WHOLE CUSTOM-OBJECT MOVE. The Task model
     * could not do this: `Task` object EDIT is un-grantable by permission set on this platform
     * (`ObjectPermissions.SobjectType` excludes Task/Event/Activity, and a set carrying such a
     * block deploys green and is silently discarded), which is why `TransactionTaskService` had to
     * authorise through the `Transaction_Task_Actions` custom permission and then write with
     * `AccessLevel.SYSTEM_MODE`. `Checklist_Item__c` is an ordinary custom object, so CRUD and FLS
     * are grantable normally and a `USER_MODE` read is exactly right: a throw here reports a REAL
     * provisioning gap and the fix is a permission set, per ARCHITECTURE.md §2. Do not "harden"
     * this to SYSTEM_MODE — doing so would reintroduce the workaround the model removed.
     *
     * @param itemIds `Checklist_Item__c` ids the caller intends to update; null/empty-safe.
     * @return Map of item Id -> item with the completion-relevant fields populated; an empty map
     *         when the input is null/empty or the running user cannot see the rows.
     * @example
     * Map<Id, Checklist_Item__c> rows = ChecklistItemSelector.selectForCompletion(itemIds);
     */
    public static Map<Id, Checklist_Item__c> selectForCompletion(Set<Id> itemIds) {
        if (itemIds == null || itemIds.isEmpty()) {
            return new Map<Id, Checklist_Item__c>();
        }
        return new Map<Id, Checklist_Item__c>([
            SELECT Id, Checklist__c, Checklist__r.Transaction__c, Subject__c, Sequence__c,
                   Flag__c, Is_Critical__c, Is_Wire_Verification__c,
                   Verbal_Verification_Completed__c, Blocked_By__c
            FROM Checklist_Item__c
            WHERE Id IN :itemIds
            WITH USER_MODE
        ]);
    }
}
