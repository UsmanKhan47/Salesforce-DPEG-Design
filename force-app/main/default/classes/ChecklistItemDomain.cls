/**
 * Per-object business rules for `Checklist_Item__c`.
 *
 * layer=domain (`.claude/rules/apex-layering-rule.md`, "Domain Purity Rule"). ZERO SOQL and ZERO
 * DML at any record count — every method here is a pure function over a `List<SObject>` or a
 * primitive. Anything needing a database read lives in `ChecklistItemPrerequisiteService`
 * (which is a service precisely BECAUSE it needs one).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 `isDone` IS THE SINGLE DEFINITION OF "COMPLETE" FOR THE WHOLE CHECKLIST MODEL, AND IT IS
 *    A TWO-VALUE TEST. DO NOT WRITE `Flag__c == 'Completed'` ANYWHERE ELSE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `Flag__c` is the single, deliberately LOSSY picklist the business chose over the design's
 * recommendation to split severity from state (`None` | `CRITICAL` | `Verified` | `Completed`;
 * see the field's own `<description>`). Two consequences follow and both have already bitten
 * somebody in some org:
 *   1. DONE MEANS `Completed` **OR** `Verified`. A wire item that was verified is done. A count,
 *      a rollup, a report or a gate written against `Completed` alone silently UNDERCOUNTS every
 *      verified item — no error, just a number that is quietly too small.
 *   2. COMPLETING A CRITICAL ITEM OVERWRITES `CRITICAL`. The severity is therefore NOT recoverable
 *      from this field, which is why `Is_Critical__c` exists as an immutable checkbox and why
 *      `Transaction__c.Wire_Open_Risks__c` MUST be computed from `Is_Wire_Verification__c` and
 *      never from `Flag__c`.
 * Three callers depend on this one method agreeing with itself: `ChecklistRollupService` (the
 * counters), `ChecklistItemPrerequisiteService` (the wire-fraud gate) and `stampCompletion` below.
 * If they ever disagree, the gate opens on an item the rollup counts as open.
 *
 * @see force-app/main/default/classes/ChecklistItemTriggerHandler.cls (sole production caller)
 * @see agent-output/design-transaction-fsd-gaps.md §2.9, §4.2, §5.2
 */
public with sharing class ChecklistItemDomain {

    /** `Flag__c` value meaning "no state yet". Also the picklist's default. */
    public static final String FLAG_NONE = 'None';

    /** `Flag__c` value meaning "open AND high-severity" — set at fan-out from `Is_Critical__c`. */
    public static final String FLAG_CRITICAL = 'CRITICAL';

    /** `Flag__c` value meaning done-by-completion. */
    public static final String FLAG_COMPLETED = 'Completed';

    /**
     * `Flag__c` value meaning done-by-verification — used by the two wire-verification items.
     * ⚠ IT IS A DONE STATE, NOT A PROGRESS STATE. See `isDone`.
     */
    public static final String FLAG_VERIFIED = 'Verified';

    /** The two values that mean "done". The single source of truth for that question. */
    @TestVisible
    private static final Set<String> DONE_FLAGS = new Set<String>{ FLAG_COMPLETED, FLAG_VERIFIED };

    /**
     * Whether a `Flag__c` value means the item is done.
     *
     * @param flag The raw `Flag__c` value; null- and blank-safe (both mean not done).
     * @return true for `Completed` and `Verified`, false for everything else including null.
     * @example
     * if (ChecklistItemDomain.isDone(item.Flag__c)) { completed++; }
     */
    public static Boolean isDone(String flag) {
        return flag != null && DONE_FLAGS.contains(flag);
    }

    /**
     * The `Flag__c` an item should carry when it is OPEN — `CRITICAL` for a critical item, `None`
     * otherwise.
     *
     * ⚠ CORRECTED 2026-09-02 — THIS SAID "Exists so the fan-out and `ChecklistItemService.reopen`
     * cannot disagree." THERE IS NO `reopen`, AND THERE DELIBERATELY IS NOT ONE:
     * `ChecklistItemService`'s header records that it was considered and left out rather than
     * stranded with no caller, and that building it is not a one-line flag flip on a wire item.
     * Citing a method that does not exist makes this helper look like it has a second caller
     * keeping it honest when it has exactly one — the fan-out.
     *
     * WHAT IT IS ACTUALLY FOR, WHICH IS STILL A REAL REASON TO EXIST: the open-state flag has to be
     * derived from `Is_Critical__c` in ONE place. `Flag__c` conflates severity with state, so an
     * item put back into an open state must have `CRITICAL` RESTORED rather than being left at
     * `None` — and a second site computing that is how the red flag quietly disappears from the
     * closing wire. Today only the fan-out sets an open flag; the day anything reopens an item, it
     * calls this and the two cannot drift. Read the `reopen()` note in `ChecklistItemService`'s
     * header BEFORE building that caller: the wire-evidence fields are not simply carried over.
     *
     * @param isCritical The item's immutable `Is_Critical__c`; null-safe (null is treated as false).
     * @return `CRITICAL` when the item is critical, otherwise `None`.
     * @example
     * item.Flag__c = ChecklistItemDomain.openFlagFor(item.Is_Critical__c);
     */
    public static String openFlagFor(Boolean isCritical) {
        return isCritical == true ? FLAG_CRITICAL : FLAG_NONE;
    }

    /**
     * Stamps `Completed_By__c` / `Completed_DateTime__c` when an item enters a done state, and
     * clears both when it leaves one. Before-context, in-memory only.
     *
     * 🔴 THIS RETIRES THE `LastModifiedBy` APPROXIMATION, WHICH IS THE POINT OF THE TWO FIELDS.
     * `TaskSelector.cls:119-126` and `TransactionTaskController.cls:50` both carry warnings that
     * pairing the ROLE label (`Danish`, `CFO`, `Legal` …) with a `LastModifiedDate` reads as
     * "completed by <role>" and is false — `Owner_Label__c` is a role string, never a person, and
     * `LastModifiedBy` is whoever last touched the row for any reason. `Completed_By__c` is a real
     * `User` lookup written at the moment of transition and never recomputed afterwards, so a
     * later unrelated edit cannot rewrite history.
     *
     * ⚠ WRITTEN ONLY ON A TRANSITION, NEVER RE-STAMPED. An edit to a comment or a due date on an
     * already-complete item leaves both fields exactly as they were. That is what makes them
     * history rather than a second copy of `LastModifiedDate`.
     *
     * ⚠ A CALLER-SUPPLIED VALUE ON A GENUINE TRANSITION IS PRESERVED, NOT OVERWRITTEN. The
     * migration batch (Phase 4, §7 M1) carries historical completions across from the Task model
     * and must be able to state who completed them; overwriting its supplied `Completed_By__c`
     * with the running migration user would destroy exactly the history it is preserving. On a
     * transition where the caller supplied nothing, the running user is stamped.
     *
     * ⚠ FLS: a before-context assignment is an in-memory SObject mutation, NOT a DML payload, so it
     * is not FLS-checked and needs no `isCreateable` guard — measured in this org for
     * `Opportunity.Stage_Entry_Date__c`, a field that had FieldPermissions rows for nobody at all
     * and was still stamped correctly by its own before-trigger.
     *
     * @param newItems Trigger.new. Null/empty-safe.
     * @param oldMap   Trigger.oldMap on update; NULL on insert, where an item created directly in a
     *                 done state counts as entering it.
     * @example
     * ChecklistItemDomain.stampCompletion((List<Checklist_Item__c>) newList, (Map<Id, Checklist_Item__c>) oldMap);
     */
    public static void stampCompletion(
        List<Checklist_Item__c> newItems,
        Map<Id, Checklist_Item__c> oldMap
    ) {
        if (newItems == null || newItems.isEmpty()) {
            return;
        }
        // Hoisted so every row stamped by one save carries an identical timestamp, and so a
        // 200-row chunk makes one call rather than 200.
        Datetime now = Datetime.now();
        Id runningUserId = UserInfo.getUserId();
        for (Checklist_Item__c item : newItems) {
            Checklist_Item__c prior = (oldMap == null || item.Id == null) ? null : oldMap.get(item.Id);
            Boolean wasDone = prior != null && isDone(prior.Flag__c);
            Boolean nowDone = isDone(item.Flag__c);
            if (wasDone == nowDone) {
                // Not a transition. Includes every ordinary edit of an already-complete item.
                continue;
            }
            if (nowDone) {
                if (item.Completed_By__c == null) {
                    item.Completed_By__c = runningUserId;
                }
                if (item.Completed_DateTime__c == null) {
                    item.Completed_DateTime__c = now;
                }
            } else {
                // Reopened. Clearing both is deliberate: a completion stamp that survives a reopen
                // reads as "this was completed by X" on a row that is demonstrably not complete.
                item.Completed_By__c = null;
                item.Completed_DateTime__c = null;
            }
        }
    }

    /**
     * Projects the non-null `Checklist__c` master-detail values of an item collection into a
     * de-duplicated set of parent ids — the rollup's entry point.
     *
     * ⚠ ONE COLLECTION IS ENOUGH ON UPDATE, UNLIKE THE TASK MODEL'S `Transaction_Deal__c`. A
     * master-detail field with `reparentableMasterDetail=false` CANNOT change after insert, so the
     * "collect from both `Trigger.new` and `Trigger.old` because a re-parent must recompute the
     * losing and the gaining parent" rule that `TaskRollupTriggerHandler` needs does not apply
     * here. The handler still passes both collections on update — belt and braces, and free — but
     * the sets are provably identical.
     *
     * @param items Items from one trigger context; null-safe.
     * @return The distinct, non-null `Checklist__c` ids referenced by those items; never null.
     * @example
     * Set<Id> parents = ChecklistItemDomain.collectChecklistIds((List<Checklist_Item__c>) newList);
     */
    public static Set<Id> collectChecklistIds(List<Checklist_Item__c> items) {
        Set<Id> checklistIds = new Set<Id>();
        if (items == null) {
            return checklistIds;
        }
        for (Checklist_Item__c item : items) {
            if (item.Checklist__c != null) {
                checklistIds.add(item.Checklist__c);
            }
        }
        return checklistIds;
    }
}
