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
 * │     • selectForDisplayByTransactionIds                                                     │
 * │                              <- ChecklistController.getChecklist, driven by a human        │
 * │                                 opening the Transaction record page (Phase 3 UI)           │
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
     * ⚠ `Comment__c` IS SELECTED BECAUSE `ChecklistItemService.recordWireVerification` APPENDS TO
     * IT RATHER THAN OVERWRITING IT. Reading a field that was not selected throws
     * `System.SObjectException: SObject row was retrieved via SOQL without querying the requested
     * field` — a runtime failure with no compile-time warning — and the alternative (overwriting
     * the comment) would erase a verifier's own note the moment the standard verification line is
     * added. It is a LongTextArea, so it is the one costly field here; it stays because the caller
     * genuinely needs the prior value, not for display.
     *
     * NOT-FOUND CONTRACT: a map read. A missing key means "does not exist OR the running user
     * cannot read it" — the caller must not distinguish them in a user-facing message, because
     * doing so tells an unauthorised caller that a record exists.
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
                   Verbal_Verification_Completed__c, Blocked_By__c, Comment__c
            FROM Checklist_Item__c
            WHERE Id IN :itemIds
            WITH USER_MODE
        ]);
    }

    /**
     * Every checklist item on the supplied Transactions, for DISPLAY — the read behind
     * `ChecklistController.getChecklist` and therefore behind the whole Phase 3 screen.
     *
     * ✅ `WITH USER_MODE`, AND IT MUST NOT INHERIT THE SYSTEM_MODE JUSTIFICATIONS ABOVE. This is a
     * read the running user ASKED for — they opened a Transaction record page. Per ARCHITECTURE.md
     * §2 a throw here reports a REAL provisioning gap and the fix is a permission set. Degrading
     * to SYSTEM_MODE would render fields to people the org has not granted them, on an object
     * carrying anti-fraud evidence (who was called, on what number).
     *
     * ⚠ CONSEQUENCE, STATED SO IT IS NOT A SURPRISE ON DEPLOY DAY: a Metadata-API-deployed custom
     * field arrives with ZERO FieldPermissions rows for ANY profile, System Administrator
     * included. Until the permission pass grants read on every field below, this query raises
     * `System.QueryException: No such column` — an FLS denial wearing a schema error — and the
     * checklist screen shows its error state for everyone. That is the correct, loud failure, and
     * it is the reason the permission grant is part of this feature's deploy rather than a
     * follow-up.
     *
     * ⚠ `Checklist__c` AND `Checklist__r.Transaction__c` ARE MASTER-DETAIL FIELDS and therefore
     * NON-PERMISSIONABLE — they can never appear in a `fieldPermissions` block and have no FLS to
     * deny, so they are safe in either mode.
     *
     * ⚠ `Completed_By__r.Name` IS A SPANNING READ INTO `User`. It is safe in USER_MODE here:
     * `User.Name` is non-permissionable (no permission set can deny it) and this org's `User` OWD
     * is Read internally, so the traversal returns a value rather than null for an ordinary
     * colleague. The lookup itself, `Completed_By__c`, IS permissionable and does need a grant.
     *
     * ⚠ ORDERED BY parent group sequence then item sequence so the controller never re-sorts and
     * two runs are comparable row-for-row.
     *
     * ⚠ SELECTS ONLY WHAT `ChecklistController.ItemRow` ACTUALLY RENDERS, and that restraint is a
     * SECURITY decision here, not tidiness. Under `USER_MODE` every additional column is an
     * additional FLS grant that must exist or the WHOLE QUERY throws and the whole screen goes
     * dark. `Checklist_Item__c.Stage__c` and `Is_Conditional__c` were dropped for exactly that
     * reason: the phase comes from the PARENT checklist's `Stage__c` and conditionality is a
     * group-level fact, so neither was ever read. Do not add a field here "in case the UI wants
     * it" — add it when the UI reads it.
     *
     * @param transactionIds Parent `Transaction__c` ids; null/empty-safe.
     * @return Items on those deals with the display fields populated; an EMPTY list when the input
     *         is null/empty or nothing matches. An empty list is MEANINGFUL — a deal that has not
     *         been fanned out simply has no items — and the caller renders it as a visible empty
     *         state, never as a blank screen.
     * @example
     * List<Checklist_Item__c> items = ChecklistItemSelector.selectForDisplayByTransactionIds(ids);
     */
    public static List<Checklist_Item__c> selectForDisplayByTransactionIds(Set<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return new List<Checklist_Item__c>();
        }
        return [
            SELECT Id, Checklist__c, Checklist__r.Transaction__c, Subject__c, Sequence__c,
                   Owner_Label__c, Flag__c, Is_Critical__c, Is_Wire_Verification__c,
                   Is_Prerequisite_Met__c, Blocked_By__c, Due_Date__c, Comment__c,
                   Verbal_Verification_Completed__c, Verified_By_Name__c, Verification_Phone__c,
                   Verified_DateTime__c,
                   Completed_By__c, Completed_By__r.Name, Completed_DateTime__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c IN :transactionIds
            WITH USER_MODE
            ORDER BY Checklist__r.Sequence__c ASC NULLS FIRST, Sequence__c ASC NULLS FIRST
        ];
    }
}
