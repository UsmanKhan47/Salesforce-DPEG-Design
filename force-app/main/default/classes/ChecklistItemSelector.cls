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
 * │     • selectByTransactionIds <- ChecklistRollupService (AFTER-* trigger),                   │
 * │                                ChecklistFanoutService.reconcile, and                        │
 * │                                ChecklistMigrationAuditService.compare — the THIRD is        │
 * │                                OPERATOR-driven, not platform-driven, and carries its own    │
 * │                                separate justification at the declaration. Do not merge them.│
 * │     • selectForOutcomeByIds  <- ChecklistOutcomeService (Phase 5), reading the PARENT DEAL   │
 * │                                after a completion has already been saved                    │
 * │     • selectOpenForStageGate <- TransactionStageGateService (BEFORE-UPDATE trigger on        │
 * │                                Transaction__c), Part B of the checklist cutover design       │
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
     * @return Map of item Id -> item with Id, Checklist__c, Checklist__r.Transaction__c,
     *         Checklist__r.Group_Letter__c, Flag__c, Subject__c, Sequence__c, Blocked_By__c and
     *         Is_Critical__c populated. (`Group_Letter__c` was already in the SELECT and missing
     *         from this list; a selector's @return IS its contract, and a caller that trusts an
     *         incomplete one gets `SObject row was retrieved via SOQL without querying the
     *         requested field` at runtime with no compile-time warning.)
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
     * 🔴 `WITH SYSTEM_MODE` — AUTOMATION PATH. ⚠ AMENDED 2026-09-02: THIS SAID "Two callers, both of
     * them platform-driven" AND THEN NAMED A THIRD ELSEWHERE. THERE ARE THREE, AND THE THIRD DOES
     * NOT FIT THE FIRST TWO'S JUSTIFICATION — filing it under theirs would record a wrong reason in
     * a header ARCHITECTURE.md §2 calls authoritative, which is worse than recording none.
     *
     *   1. `ChecklistRollupService.recalc` — fired from `ChecklistItemTrigger`'s after contexts.
     *   2. `ChecklistFanoutService.reconcile` — fired from `TransactionTrigger`'s after-update
     *      context and from the fan-out Queueable.
     *   PLATFORM-DRIVEN, both. Neither is a read the running user asked for, so the
     *   `USER_MODE`-throws-rather-than-degrades reasoning at `selectByIdsWithDeal` applies verbatim,
     *   with one consequence specific to a rollup: a partial or thrown read here does not produce a
     *   visibly broken screen, it produces a WRONG NUMBER on the Wire Sentinel dashboard tile — and
     *   a wrong number in the safe-looking direction (zero open wire risks) is the RISK 1 failure
     *   this whole rewrite exists to eliminate.
     *
     *   3. `ChecklistMigrationAuditService.compare` (added 2026-09-02) — OPERATOR-DRIVEN, from an
     *      anonymous-Apex script. That is closer to "a read the running user asked for", so it does
     *      NOT inherit the two justifications above. `SYSTEM_MODE` is still correct for it, for a
     *      reason of its own: the SELECT spans ELEVEN Metadata-API-deployed custom fields, and under
     *      `USER_MODE` a single missing FLS grant raises `System.QueryException: No such column` —
     *      which would abort THE RECONCILIATION THAT GATES CUTOVER and read as "the two models
     *      disagree" rather than "you lack a grant". A reconciliation that fails closed on a
     *      permission problem while looking like a data problem is the worst possible failure for a
     *      gate whose entire job is to be believed.
     *
     * ⚠ ORDERED BY parent group then sequence so the reconcile and the migration reconciliation
     * report can compare two runs row-for-row without re-sorting.
     *
     * @param transactionIds Parent `Transaction__c` ids; null/empty-safe.
     * @return Items on those deals with Id, Checklist__c, Checklist__r.Transaction__c,
     *         Checklist__r.Group_Letter__c, Sequence__c, Subject__c, Flag__c, Due_Date__c,
     *         Is_Critical__c, Is_Wire_Verification__c, Verbal_Verification_Completed__c and
     *         Blocked_By__c populated; an empty list when the input is null/empty or nothing
     *         matches (never null).
     *         ⚠ `Subject__c` AND `Blocked_By__c` WERE MISSING FROM THIS INVENTORY UNTIL 2026-09-02
     *         EVEN THOUGH THE SELECT HAS ALWAYS RETURNED THEM, AND `Blocked_By__c` IS LOAD-BEARING:
     *         `ChecklistMigrationDomain.viewOf` reads it to set `hasPrerequisiteLink`, which backs
     *         the `PREREQ_UNRESOLVED` check. A future narrowing of this SELECT made in good faith
     *         against an incomplete inventory would silently disarm that check — no compile error,
     *         no test failure, just a migration gate that stops detecting unresolved prerequisites.
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
     * Items a human is about to act on — the read behind `ChecklistItemService.complete` and
     * `.recordWireVerification`. Those are the ONLY two consumers; this header is the
     * authoritative consumer inventory, so it must not advertise a method that does not exist.
     * (An earlier draft listed `.reopen`. Nothing reopens a checklist item today — the LWC
     * disables a completed row's checkbox — and the method was deliberately not built rather
     * than stranded with no caller. If it is ever added, read the `reopen()` note in
     * `ChecklistItemService`'s header first: the evidence fields are not simply carried over.)
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
     * ⚠ `Checklist__r.Group_Letter__c` WAS ADDED IN PHASE 5 AND IT IS NOT COSMETIC. Together with
     * `Sequence__c` it is the COORDINATE `ChecklistCaptureDefProvider` is keyed on, so the
     * completion guard can ask "does this item have to record something before it may close?"
     * without a second query and without ever looking at `Subject__c`. It is readable on
     * `DPEG_Checklist_View` (verified 2026-09-02), so it costs this `USER_MODE` query nothing.
     * 🔴 DO NOT REPLACE THIS WITH A SUBJECT TEST. The whole Phase 2/3 rewrite exists to retire one
     * subject-substring parse; re-introducing one in the capture guard would recreate RISK 1 in a
     * new file, where an admin retitling an item silently disables the guard with no error.
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
     * @return Map of item Id -> item with Id, Checklist__c, Checklist__r.Transaction__c,
     *         Checklist__r.Group_Letter__c, Subject__c, Sequence__c, Flag__c, Is_Critical__c,
     *         Is_Wire_Verification__c, Verbal_Verification_Completed__c, Blocked_By__c and
     *         Comment__c populated; an empty map when the input is null/empty or the running user
     *         cannot see the rows. ⚠ `Checklist__r.Group_Letter__c` is the half
     *         `ChecklistCaptureService` needs — it plus `Sequence__c` IS the capture coordinate.
     * @example
     * Map<Id, Checklist_Item__c> rows = ChecklistItemSelector.selectForCompletion(itemIds);
     */
    public static Map<Id, Checklist_Item__c> selectForCompletion(Set<Id> itemIds) {
        if (itemIds == null || itemIds.isEmpty()) {
            return new Map<Id, Checklist_Item__c>();
        }
        return new Map<Id, Checklist_Item__c>([
            SELECT Id, Checklist__c, Checklist__r.Transaction__c, Checklist__r.Group_Letter__c,
                   Subject__c, Sequence__c, Flag__c, Is_Critical__c, Is_Wire_Verification__c,
                   Verbal_Verification_Completed__c, Blocked_By__c, Comment__c
            FROM Checklist_Item__c
            WHERE Id IN :itemIds
            WITH USER_MODE
        ]);
    }

    /**
     * Items with their PARENT DEAL's earnest-money and feasibility fields traversed - the single
     * read behind `ChecklistOutcomeService`, which decides what a completed A5 / B5 must write on
     * the `Transaction__c` and recomputes `Is_Earnest_At_Risk__c`.
     *
     * 🔴 `WITH SYSTEM_MODE` - AUTOMATION PATH, AND NOT THE SAME QUESTION AS `selectForCompletion`
     * DIRECTLY ABOVE, EVEN THOUGH THE SAME CLICK TRIGGERS BOTH. `selectForCompletion` reads what
     * the user ASKED for (the item they are completing) and is correctly `USER_MODE`. This one
     * reads the DEAL fields the outcome is computed from, on the deal owner's behalf, AFTER the
     * user's completion has already been saved. Three of those fields -
     * `Feasibility_Deadline__c`, `Feasibility_Missed__c` and `Is_Earnest_At_Risk__c` - are granted
     * on `DPEG_Transaction_View` / `_Edit` but NOT on `DPEG_Checklist_View` / `_Edit` (verified
     * 2026-09-02). A `USER_MODE` read would therefore raise `System.QueryException: No such column`
     * for any principal holding only the checklist sets - an FLS denial wearing a schema error -
     * and it would do so AFTER the item was already updated, so the user would see their tick
     * succeed and then a failure they cannot act on.
     * ⚠ Adding those three fields to the checklist permission sets instead was considered and
     * rejected: it would hand every checklist user read on the deal's feasibility posture in order
     * to run a derivation they never see, which is a wider grant than the feature needs.
     *
     * 🔴 `Checklist__r.Transaction__r.Id` IS SELECTED, AND IT IS THE FAIL-CLOSED DISCRIMINATOR
     * RATHER THAN A REDUNDANT COLUMN. SYSTEM_MODE lifts CRUD and FLS and NEVER sharing, and
     * `Transaction__c` is Private OWD, so a spanning read into a deal the running user cannot see
     * returns NULLS for every traversed field instead of throwing. That failure INVERTS the
     * earnest-at-risk derivation rather than degrading it: a null `Feasibility_Deadline__c` reads
     * as "feasibility has not passed", which computes at-risk = FALSE and would CLEAR a flag that
     * should be set, on exactly the deals the KPI exists to surface. The caller must therefore skip
     * any row whose `Checklist__r.Transaction__r.Id` is null rather than compute from the nulls.
     * ⚠ In practice this should never fire on the completion path - `Checklist_Item__c` is
     * `ControlledByParent` under `Checklist__c` under `Transaction__c`, and both master-detail
     * links carry `writeRequiresMasterRead=false` (the STRICTER setting), so a user who just
     * updated an item demonstrably holds EDIT on the deal. It exists for the paths that are not
     * that one: a future migration batch, a Schedulable, or a backfill script running as a
     * principal with no deal access.
     *
     * NOT-FOUND CONTRACT: a map read. A missing key means unresolved - never "no outcome needed".
     *
     * @param itemIds `Checklist_Item__c` ids whose outcome is being applied; null/empty-safe.
     * @return Map of item Id -> item with its coordinate (`Checklist__r.Group_Letter__c`,
     *         `Sequence__c`), its `Flag__c`, and the parent deal's `Id`, `Status__c`, `Stage__c`,
     *         `Earnest_Money_Sent__c`, `Earnest_Money_Sent_Date__c`, `Feasibility_Deadline__c`,
     *         `Feasibility_Missed__c` and `Is_Earnest_At_Risk__c` populated; empty map, never null.
     * @example
     * Map&lt;Id, Checklist_Item__c&gt; rows = ChecklistItemSelector.selectForOutcomeByIds(itemIds);
     */
    public static Map<Id, Checklist_Item__c> selectForOutcomeByIds(Set<Id> itemIds) {
        if (itemIds == null || itemIds.isEmpty()) {
            return new Map<Id, Checklist_Item__c>();
        }
        return new Map<Id, Checklist_Item__c>([
            SELECT Id, Sequence__c, Flag__c,
                   Checklist__c, Checklist__r.Group_Letter__c, Checklist__r.Transaction__c,
                   Checklist__r.Transaction__r.Id,
                   Checklist__r.Transaction__r.Status__c,
                   Checklist__r.Transaction__r.Stage__c,
                   Checklist__r.Transaction__r.Earnest_Money_Sent__c,
                   Checklist__r.Transaction__r.Earnest_Money_Sent_Date__c,
                   Checklist__r.Transaction__r.Feasibility_Deadline__c,
                   Checklist__r.Transaction__r.Feasibility_Missed__c,
                   Checklist__r.Transaction__r.Is_Earnest_At_Risk__c
            FROM Checklist_Item__c
            WHERE Id IN :itemIds
            WITH SYSTEM_MODE
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
     * dark. `Checklist_Item__c.Stage__c`, `Is_Conditional__c` and `Due_Date__c` were all dropped
     * for exactly that reason: the phase comes from the PARENT checklist's `Stage__c`,
     * conditionality is a group-level fact, and the due date is consumed SERVER-SIDE by
     * `ChecklistRollupService` — through `selectByTransactionIds` above, which is `SYSTEM_MODE`
     * and DOES still select it — to compute `Transaction__c.Tasks_Overdue__c`. This screen renders
     * none of the three. Do not add a field here "in case the UI wants it"; add it when the UI
     * reads it. An overdue badge would bring `Due_Date__c` back, together with the FLS grant it
     * implies.
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
                   Is_Prerequisite_Met__c, Blocked_By__c, Comment__c,
                   Verbal_Verification_Completed__c, Verified_By_Name__c, Verification_Phone__c,
                   Verified_DateTime__c,
                   Completed_By__c, Completed_By__r.Name, Completed_DateTime__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c IN :transactionIds
            WITH USER_MODE
            ORDER BY Checklist__r.Sequence__c ASC NULLS FIRST, Sequence__c ASC NULLS FIRST
        ];
    }

    /**
     * Items belonging to the stages a set of deals is about to LEAVE - the single read behind the
     * stage-advancement gate (`TransactionStageGateService`, design Part B).
     *
     * ONE QUERY FOR THE WHOLE TRIGGER CHUNK. `stages` is the UNION of the candidate deals prior
     * stages, so at most four values, and `transactionIds` is every candidate deal in the chunk.
     * The caller re-attributes each returned row to its own deal in memory. Adding a deal or a
     * stage to either set costs nothing - it is still exactly one query, never a function of row
     * count.
     *
     * =========================================================================================
     * `OR Stage__c = NULL` IS DELIBERATE AND LOAD-BEARING. DO NOT SIMPLIFY IT AWAY.
     * =========================================================================================
     * `Checklist_Item__c.Stage__c` has NO default value, deliberately - the field description
     * says a plausible default "would hide a fan-out that failed to stamp the phase", and
     * `ChecklistFanoutService.lastRunUnstagedItemCount` exists to count exactly that failure.
     * With a bare `Stage__c IN :stages` an unstamped item would be INVISIBLE to the gate, and a
     * safety control whose failure mode is "silently stops refusing" is the wrong shape. Returning
     * the row lets the caller attribute it through its parent `Checklist__r.Stage__c`, and count
     * it when even that is blank.
     *
     * =========================================================================================
     * THE DONE TEST IS NOT IN THIS WHERE CLAUSE, AND THAT IS NOT AN OVERSIGHT.
     * =========================================================================================
     * "Open" would be `Flag__c NOT IN ('Completed','Verified')`. Writing that here would create a
     * SECOND definition of done in an org whose single definition is `ChecklistItemDomain.isDone`
     * - a method whose own header says in capitals DO NOT WRITE `Flag__c == 'Completed'` ANYWHERE
     * ELSE, because `Flag__c` is a lossy picklist where `Verified` is also a done state. Nothing
     * would catch a SOQL literal list drifting from that method. The caller filters in memory
     * with `isDone`, which costs one extra pass over rows it already has and keeps the
     * definition singular. `Flag__c` is selected below for exactly that reason.
     *
     * =========================================================================================
     * MODE: `WITH SYSTEM_MODE` - AUTOMATION PATH (ARCHITECTURE.md S2, justified here at its own
     * declaration and NOT by inheriting the justifications above it).
     * =========================================================================================
     * This runs inside a BEFORE-UPDATE trigger on `Transaction__c`, on the saving principal's
     * behalf - it is not a read they asked for; they asked to move a deal to the next stage.
     * `USER_MODE` throws rather than degrades: one missing FLS grant on any of the eight fields
     * below raises `System.QueryException: No such column` - an FLS denial wearing a schema error
     * - which inside a before-update trigger escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`
     * and ROLLS BACK THE USER OWN STAGE SAVE with a message naming a column, not a permission.
     * Every DPEG persona is on Minimum Access and every custom field below arrives from the
     * Metadata API with zero FieldPermissions rows for anybody, System Administrator included, so
     * this is the default case rather than an edge case. Same reasoning as `selectByIdsWithDeal`,
     * which backs the sibling before-update gate on `Checklist_Item__c`.
     * The consequence is stated plainly: this read cannot be denied by FLS, so the GATE cannot be
     * disabled by removing somebody's grants. That is the intent - it is a safety control, not a
     * report.
     *
     * =========================================================================================
     * SHARING, ASKED AS A SEPARATE QUESTION BECAUSE `SYSTEM_MODE` NEVER LIFTS IT.
     * =========================================================================================
     * No escalation, and none is needed. The principal is UPDATING the `Transaction__c`, so they
     * demonstrably hold RECORD-LEVEL EDIT on it - a before-update trigger cannot be reached
     * otherwise. `Checklist_Item__c` is `ControlledByParent` under `Checklist__c`, itself
     * `ControlledByParent` under `Transaction__c`, so record-level access propagates down both
     * hops by definition and they can read every item on that deal.
     *
     * THIS ARGUMENT DOES NOT DEPEND ON THE UNPROVEN `viewAllRecords` PROPAGATION, AND THE TWO ARE
     * EASY TO CONFLATE. `Checklist__c.object-meta.xml` and `ChecklistRollupService` both record
     * that whether OBJECT-LEVEL View All propagates to a `ControlledByParent` detail was never
     * measured. That open question is about a VIEW-ONLY persona reading somebody else's deal.
     * It is a different question from this one, and if it comes back FALSE this method is
     * unaffected. Note also that `DPEG_Transaction_View` grants `allowEdit=false`, so a view-only
     * persona measurably has `HasEditAccess = false` on a deal (measured 2026-09-02, recorded in
     * `TaskRollupService`) and therefore never reaches this read at all.
     * A `private without sharing` inner class would be the shape if an escape were ever needed.
     * It is NOT needed, it is not present, and adding one would need its own written reason -
     * this org took a production outage on 2026-09-02 from confusing these two decisions.
     *
     * ORDERED by parent group sequence then item sequence so the refusal message enumerates
     * outstanding items in checklist order rather than in database order, and so two runs produce
     * a byte-identical message.
     *
     * @param transactionIds Deals whose items are being judged; null/empty-safe.
     * @param stages         The union of `Transaction__c.Stage__c` values those deals are LEAVING;
     *                       null/empty-safe. Items whose `Stage__c` is NULL are returned
     *                       regardless of this set - see above.
     * @return Items on those deals in those stages (plus every unstamped item on those deals),
     *         with Id, Checklist__c, Checklist__r.Transaction__c, Checklist__r.Group_Letter__c,
     *         Checklist__r.Stage__c, Stage__c, Sequence__c, Subject__c and Flag__c populated; an
     *         EMPTY list when either input is null/empty or nothing matches, never null.
     *         An empty list is MEANINGFUL - it means nothing is outstanding - so the caller must
     *         not treat it as an error. Reading any field NOT in this inventory throws
     *         `System.SObjectException` at runtime with no compile-time warning; a selector
     *         @return IS its contract.
     * @example
     * List&lt;Checklist_Item__c&gt; rows = ChecklistItemSelector.selectOpenForStageGate(dealIds, stages);
     */
    public static List<Checklist_Item__c> selectOpenForStageGate(
        Set<Id> transactionIds,
        Set<String> stages
    ) {
        if (transactionIds == null || transactionIds.isEmpty()
                || stages == null || stages.isEmpty()) {
            return new List<Checklist_Item__c>();
        }
        return [
            SELECT Id, Checklist__c, Checklist__r.Transaction__c, Checklist__r.Group_Letter__c,
                   Checklist__r.Stage__c, Stage__c, Sequence__c, Subject__c, Flag__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c IN :transactionIds
              AND (Stage__c IN :stages OR Stage__c = NULL)
            WITH SYSTEM_MODE
            ORDER BY Checklist__r.Sequence__c ASC NULLS FIRST, Sequence__c ASC NULLS FIRST
        ];
    }
}
