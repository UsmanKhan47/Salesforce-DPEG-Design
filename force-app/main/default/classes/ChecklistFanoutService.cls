/**
 * Day-0 fan-out onto the `Checklist__c` / `Checklist_Item__c` model - creates the 11 task-group
 * checklists and their ~82 items for a Transaction, from `Task_Group_Def__mdt` +
 * `Transaction_Task_Def__mdt`. Replaces `TaskFanoutService`, which STAYS LIVE and untouched
 * through the dual-model window. Design §5, §8, §10 Phase 2.
 *
 * layer=service. All SOQL delegated to `TransactionSelector` / `ChecklistSelector` /
 * `ChecklistItemSelector`; CMDT read through the two providers (`getAll()`, never SOQL - and every
 * new column is short text / number / checkbox precisely so that stays safe, because `getAll()`
 * SILENTLY TRUNCATES LongTextArea and Html to 255 characters and that cost this org a live P0 on
 * 2026-08-31).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 DUAL-MODEL COEXISTENCE - WHY THIS DOES NOT DISTURB THE LIVE TASK CHECKLIST.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `TaskFanoutService`, `TaskFanoutQueueable`, `TaskRollupService`, `TaskPrerequisiteService` and
 * `TaskRollupTrigger` are DEPLOYED AND ENFORCING right now. Nothing here deletes, guts or repoints
 * any of them. The two models are kept apart by ONE discriminator:
 *
 *     legacy fan-out guard : Transaction__c.Tasks_Fanned_Out__c     (written only by TaskFanoutService)
 *     new    fan-out guard : Transaction__c.Checklist_Fanned_Out__c (written only by THIS class)
 *
 * They are separate fields on purpose. Sharing one would make either fan-out suppress the other,
 * which the field's own `<description>` calls the single most important fact of the migration.
 * Because `Checklist_Fanned_Out__c` is false on every Transaction in the org the day this deploys,
 * and because `flows/Transaction_Task_Fanout` is NOT repointed in Phase 2, THIS CLASS RUNS FOR
 * NOBODY UNTIL SOMEONE DELIBERATELY INVOKES IT. Phase 2 is therefore a behaviour-neutral deploy for
 * every live deal - the property that makes it safe to ship while the Task model is still the one
 * users see.
 * ⚠ `ChecklistRollupService` carries the other half of the same discriminator: it refuses to write
 * the four `Transaction__c` counters unless `Checklist_Fanned_Out__c` is true, so the two rollups
 * cannot fight over the same four fields. Read that header before changing either.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 GOVERNOR ARITHMETIC - RE-DERIVED, NOT INHERITED. `CHUNK_SIZE` IS 50, NOT 100.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `TaskFanoutQueueable.CHUNK_SIZE = 100` was justified as "82 Tasks per Transaction, so 100
 * Transactions = ~8,200 rows, comfortably inside the 10,000 DML-row limit". THAT SIZING DOES NOT
 * SURVIVE THIS MODEL. Per Transaction (a loan deal, all 11 groups):
 *
 *     11  Checklist__c inserts
 *   + 82  Checklist_Item__c inserts
 *   +  2  Checklist_Item__c updates  <- THE SECOND PASS. `Blocked_By__c` is a REAL self-lookup now,
 *                                       so the target Id does not exist until the items are
 *                                       inserted. Only the GATED rows are re-touched (B3, I8), not
 *                                       all 82. The Phase 0 Text key needed no such pass - that is
 *                                       the one price of the real relationship.
 *   +  1  Transaction__c update (guard flag + the four counters)
 *   ───
 *     96  rows per Transaction with the rollup trigger suppressed
 *   + 12  Checklist/Transaction rollup writes if it is NOT suppressed  => 108
 *
 *     chunk 100, suppressed   =  9,600 rows -> 4% headroom; one added write per item breaks it.
 *     chunk 100, unsuppressed = 10,800 rows -> 🔴 `Too many DML rows: 10001`, hard failure.
 *     chunk  50, suppressed   =  4,800 rows -> 52% headroom.  ✅ CHOSEN
 *     chunk  50, unsuppressed =  5,400 rows -> survives on rows, but see the SOQL line below.
 *
 * SUPPRESSION IS NOT OPTIONAL, AND THE BINDING LIMIT IS SOQL, NOT DML ROWS. Inserting 50 x 82 =
 * 4,100 items in ONE statement fires the after-insert trigger in ceil(4100/200) = 21 batches. Left
 * unsuppressed that is 21 SOQL + 21 DML for the item insert alone, plus more for the second pass,
 * against a 100-query limit - to recompute counters for rows the same statement is still creating.
 * This org has a measured incident of exactly that shape (routing a new parent into a Task trigger
 * cost `ceil(rows/200)` SOQL *and* DML at fan-out scale). So the fan-out suppresses the rollup and
 * WRITES THE COUNTERS ITSELF from what it just created - it knows them exactly.
 *
 *   DML statements per chunk : 4 (checklists, items, prerequisite pass, transactions). Limit 150.
 *   SOQL per chunk           : 1 - `TransactionSelector.selectForChecklistFanout`. The second pass
 *                              needs NO query: the inserted items are still in memory with their
 *                              new Ids, so the prerequisite index is built for free.
 *   Queueable chaining       : exactly ONE `System.enqueueJob` per invocation; the chain advances
 *                              from the Finalizer. KEEP THAT SHAPE - it is what stops one failed
 *                              chunk stranding every chunk behind it.
 *   ⚠ NEW FAILURE MODE: a master-detail child insert LOCKS ITS MASTER. A concurrent user edit of a
 *     `Transaction__c` during fan-out can now raise `UNABLE_TO_LOCK_ROW` where the Task model could
 *     not. Bounded by the chunk (50 deals) and by fan-out being a one-shot at deal creation.
 *
 * @see force-app/main/default/classes/ChecklistFanoutQueueable.cls
 * @see force-app/main/default/classes/ChecklistRollupService.cls
 * @see agent-output/design-transaction-fsd-gaps.md §5.6, §8, §10
 */
public with sharing class ChecklistFanoutService {

    // Test injection points (CMDT cannot be inserted in tests, but can be built in memory).
    @TestVisible
    static List<Task_Group_Def__mdt> groupDefsOverride;
    @TestVisible
    static List<Transaction_Task_Def__mdt> taskDefsOverride;
    @TestVisible
    static Boolean bypassDedupe = false;

    /**
     * Items whose group carried no `Stage__c` and whose definition carried no `Stage_Override__c`,
     * summed over the last run. MUST BE ZERO once the CMDT loaders have been re-run.
     *
     * 🔴 A COUNTER RATHER THAN A DEFAULT, ON PURPOSE. `Checklist_Item__c.Stage__c` has NO default
     * value, deliberately - "a plausible default would hide a fan-out that failed to stamp the
     * phase" (the field's own description). Stamping a guessed `Open Contract` would make every
     * phase tab on the record page silently wrong instead of visibly empty. This counter turns "the
     * CMDT rows were never reloaded with the new `Stage__c` column" into an assertable fact rather
     * than a mystery on the UI.
     */
    @TestVisible
    private static Integer lastRunUnstagedItemCount = 0;

    /**
     * Prerequisite links the definitions asked for but that could not be pointed at a real row,
     * summed over the last run.
     *
     * ⚠ THIS FAILS OPEN, AND THAT IS A DELIBERATE, NARROW CHOICE. A lookup cannot point at nothing,
     * so an unresolvable definition leaves `Blocked_By__c` null and the dependent UNGATED. The
     * alternative - refusing to create the item - would brick a whole checklist over one bad
     * definition row. It matches `scripts/backfill-task-blocked-by.apex`, which likewise refuses to
     * write a key whose target it cannot find and REPORTS the deals instead of bricking them. The
     * realistic cause is a definition naming a prerequisite in a CONDITIONAL group this deal did not
     * get (a J item blocked by an F item on a no-loan deal). Neither live pair (B3->B2, I8->I7)
     * crosses a group, so this is 0 for every real deal today.
     */
    @TestVisible
    private static Integer lastRunUnresolvedPrereqCount = 0;

    /** Checklists created by the last run. Test instrumentation only. */
    @TestVisible
    private static Integer lastRunChecklistCount = 0;

    /** Items created by the last run. Test instrumentation only. */
    @TestVisible
    private static Integer lastRunItemCount = 0;

    /**
     * SOQL consumed by the last `fanOutNow` body.
     * 🔴 CAPTURED INSIDE THE ASYNC CONTEXT. `Test.stopTest()` restores the pre-test governor
     * counters, so a `Limits.getQueries()` assertion written AFTER `stopTest` measures nothing and
     * passes vacuously. Assert on this instead.
     */
    @TestVisible
    private static Integer lastRunQueryCount = 0;

    /** DML statements consumed by the last `fanOutNow` body. Same in-context capture rule. */
    @TestVisible
    private static Integer lastRunDmlCount = 0;

    /** Zeroes the instrumentation. Test-only; production never calls it. */
    @TestVisible
    private static void resetRunCounters() {
        lastRunUnstagedItemCount = 0;
        lastRunUnresolvedPrereqCount = 0;
        lastRunChecklistCount = 0;
        lastRunItemCount = 0;
        lastRunQueryCount = 0;
        lastRunDmlCount = 0;
    }

    /**
     * Flow / Apex entry point. Does NOT fan out inline - it hands the work to a chunked Queueable
     * chain and returns.
     *
     * WHY ASYNC (arithmetic, not preference): 96 rows per Transaction means a 200-record trigger
     * chunk would attempt 19,200 rows against the 10,000-row limit and break before anything else in
     * the cascade ran. The synchronous ceiling is ~104 Transactions per transaction; no amount of
     * query tuning moves that.
     *
     * @param requests One request per Transaction to fan out. Null/empty-safe.
     * @example
     * ChecklistFanoutService.fanOut(new List<ChecklistFanoutService.InputDTO>{ request });
     */
    @InvocableMethod(label='Fan Out Transaction Checklists'
        description='Queues creation of the Checklist and Checklist Item rows for a Transaction.')
    public static void fanOut(List<InputDTO> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        List<Id> transactionIds = new List<Id>();
        Set<Id> seen = new Set<Id>();
        for (InputDTO request : requests) {
            if (request != null && request.transactionId != null && seen.add(request.transactionId)) {
                transactionIds.add(request.transactionId);
            }
        }
        if (transactionIds.isEmpty()) {
            return;
        }
        // Exactly ONE enqueue; the Queueable chains the rest from its Finalizer.
        System.enqueueJob(new ChecklistFanoutQueueable(transactionIds, 0));
    }

    /** Flow input: one Transaction to fan out. */
    public class InputDTO {
        @InvocableVariable(required=true label='Transaction Id'
            description='The Transaction whose checklist should be created.')
        public Id transactionId;
    }

    /**
     * The synchronous worker. Called by `ChecklistFanoutQueueable` per chunk, and directly by tests
     * that assert checklist content. Callers keep the chunk small enough to fit the DML-row budget
     * derived in the class header.
     *
     * FOUR STATEMENTS, IN THIS ORDER, AND THE ORDER IS LOAD-BEARING:
     *   1. insert `Checklist__c`  - items are master-detail children and need parent Ids.
     *   2. insert `Checklist_Item__c` with `Blocked_By__c` BLANK.
     *   3. update the gated items with their `Blocked_By__c` - THE SECOND PASS. A real self-lookup
     *      has no target Id until step 2 has committed. It is also why the gate's insert context
     *      never has to resolve anything (see `ChecklistItemPrerequisiteService.clampOnInsert`).
     *   4. update `Transaction__c` - guard flag plus the four counters, computed here rather than by
     *      the rollup because this code knows exactly what it just created.
     *
     * @param transactionIds Transactions to fan out (chunked by the caller). Null/empty-safe.
     * @throws System.DmlException on a platform save failure (`allOrNone = true`, deliberately: a
     *         partially fanned-out checklist is worse than none, and the Finalizer keeps the chain
     *         moving for the other chunks).
     * @example
     * ChecklistFanoutService.fanOutNow(new List<Id>{ transactionId });
     */
    public static void fanOutNow(List<Id> transactionIds) {
        resetRunCounters();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            fanOutChunk(transactionIds);
        } finally {
            lastRunQueryCount = Limits.getQueries() - queriesBefore;
            lastRunDmlCount = Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * The fan-out itself, wrapped by `fanOutNow` for instrumentation.
     *
     * @param transactionIds Transactions to fan out.
     */
    private static void fanOutChunk(List<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return;
        }

        Set<String> conditionFields = conditionFieldNames();
        List<Transaction_Task_Def__mdt> definitions = itemDefs();
        Map<Id, Transaction__c> transactions = TransactionSelector.selectForChecklistFanout(
            new Set<Id>(transactionIds), conditionFields);

        // ── PASS 1: build the checklists, remembering which definitions belong to each ──
        List<Checklist__c> checklists = new List<Checklist__c>();
        List<PendingGroup> pending = new List<PendingGroup>();
        for (Transaction__c deal : transactions.values()) {
            if (deal.Checklist_Fanned_Out__c == true && bypassDedupe != true) {
                continue;
            }
            for (Task_Group_Def__mdt groupDef : groupDefs()) {
                if (!isGroupApplicable(groupDef, deal)) {
                    continue;
                }
                Checklist__c checklist = buildChecklist(groupDef, deal.Id);
                checklists.add(checklist);
                pending.add(pendingGroup(checklist, groupDef, deal));
            }
        }
        if (checklists.isEmpty()) {
            return;
        }

        Boolean alreadySuppressed = ChecklistRollupService.isTriggerRecalcSuppressed();
        try {
            // 🔴 SUPPRESSION SPANS ALL FOUR STATEMENTS. See the class header for the SOQL
            // arithmetic; without it the item insert alone costs 21 SOQL + 21 DML per chunk.
            ChecklistRollupService.suppressTriggerRecalc(true);

            // ⚠ EXPLICIT SYSTEM MODE, CARRIED OVER IN SUBSTANCE FROM `TaskFanoutService.fanOutNow`
            // (2026-08-05) BECAUSE NOTHING ABOUT THE SITUATION CHANGED: the fan-out is invoked from
            // a record-triggered Flow that declares no `runInMode`, so it runs in the CALLING
            // USER's context - the deal driver who just executed the contract. Every DPEG persona
            // is on Minimum Access, and a Metadata-API-deployed object arrives with no CRUD and no
            // FLS for anybody, System Administrator included, so a `USER_MODE` DML here would throw
            // `System.TypeException` and roll the whole chain back. The checklist is created BY the
            // process, so the access level is stated here rather than inferred from whoever clicked.
            // ⚠ SYSTEM_MODE lifts CRUD/FLS and NEVER sharing. A master-detail child insert needs no
            // sharing beyond its parent; step 4's Transaction update is the one statement where
            // sharing could bite, and it is discussed there.
            Database.insert(checklists, true, AccessLevel.SYSTEM_MODE);
            lastRunChecklistCount = checklists.size();

            // ── PASS 2: items, with `Blocked_By__c` deliberately BLANK ──
            List<Checklist_Item__c> items = new List<Checklist_Item__c>();
            Map<String, Checklist_Item__c> itemByCoordinate = new Map<String, Checklist_Item__c>();
            Map<Id, DealTally> tallyByDeal = new Map<Id, DealTally>();
            Date today = Date.today();
            for (PendingGroup group : pending) {
                DealTally tally = tallyByDeal.get(group.dealId);
                if (tally == null) {
                    tally = new DealTally();
                    tallyByDeal.put(group.dealId, tally);
                }
                Integer inGroup = 0;
                for (Transaction_Task_Def__mdt itemDef : definitions) {
                    if (itemDef.Group_Letter__c != group.groupDef.Letter__c) {
                        continue;
                    }
                    Checklist_Item__c item = buildItem(itemDef, group);
                    items.add(item);
                    itemByCoordinate.put(
                        coordinateKey(group.dealId, itemDef.Group_Letter__c, itemDef.Sequence__c),
                        item);
                    inGroup++;
                    tally.total++;
                    if (item.Due_Date__c != null && item.Due_Date__c < today) {
                        tally.overdue++;
                    }
                    if (item.Is_Wire_Verification__c == true) {
                        tally.wireOpen++;
                    }
                    if (String.isBlank(item.Stage__c)) {
                        lastRunUnstagedItemCount++;
                    }
                }
                group.checklist.Items_Total__c = inGroup;
                group.checklist.Items_Complete__c = 0;
            }
            if (!items.isEmpty()) {
                Database.insert(items, true, AccessLevel.SYSTEM_MODE);
                lastRunItemCount = items.size();
            }

            // ── PASS 3: the prerequisite links, now that every item has an Id. ZERO SOQL - the
            // index was built in memory as the rows were constructed, and `Database.insert`
            // populates `Id` on those very instances. ONLY the gated rows are touched.
            List<Checklist_Item__c> links = resolveLinks(pending, definitions, itemByCoordinate,
                itemByCoordinate);
            if (!links.isEmpty()) {
                Database.update(links, true, AccessLevel.SYSTEM_MODE);
            }

            // ── PASS 4: the guard flag and the four counters ──
            List<Transaction__c> deals = new List<Transaction__c>();
            for (Id dealId : tallyByDeal.keySet()) {
                DealTally tally = tallyByDeal.get(dealId);
                deals.add(new Transaction__c(
                    Id = dealId,
                    Checklist_Fanned_Out__c = true,
                    Tasks_Total__c = tally.total,
                    Tasks_Complete__c = 0,
                    Tasks_Overdue__c = tally.overdue,
                    Wire_Open_Risks__c = tally.wireOpen
                ));
            }
            if (!deals.isEmpty()) {
                // ⚠ SYSTEM_MODE for CRUD/FLS; sharing is NOT lifted. The Day-0 path runs as the
                // deal driver, who owns the Transaction they just created, so sharing is satisfied
                // by ownership. A future path fanning out someone else's deal fails LOUDLY rather
                // than silently - `allOrNone = true` guarantees it, and that is the right direction
                // for a guard flag: a silently unset `Checklist_Fanned_Out__c` would re-fan the deal
                // on the next invocation and duplicate the entire checklist.
                Database.update(deals, true, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            // Restore rather than blindly clear: `reconcile` may already have suppressed.
            ChecklistRollupService.suppressTriggerRecalc(alreadySuppressed);
        }
    }

    /**
     * Reconciles a deal's checklists with its CURRENT conditional-group state - the
     * `Loan_Required__c` correction path (design §5.6, Story 10).
     *
     * 🔴 RECONCILE, NEVER BLANKET RE-FAN. Re-running the fan-out on a live deal would destroy every
     * completion on it. This adds only the MISSING groups and removes only the ones that should not
     * exist, and it removes ONLY when no item in that group has been worked.
     *
     * ⚠ A REFUSED REMOVAL IS NOT AN ERROR AND MUST NOT BLOCK THE USER'S SAVE. Deleting worked
     * history is worse than an inconsistent checklist, and refusing a `Loan_Required__c` edit
     * because somebody once ticked F3 would be hostile. The refused letters are RETURNED so a caller
     * with a UI can surface them; `TransactionTriggerHandler` discards the result deliberately, and
     * surfacing it in the checklist LWC is Phase 3 work.
     *
     * ⚠ ONLY ACTS ON DEALS WHOSE `Checklist_Fanned_Out__c` IS TRUE. A deal that was never fanned out
     * has no checklist to reconcile, and creating one here would fan out a deal behind the guard's
     * back - which is exactly the coexistence property the guard exists to hold.
     *
     * GOVERNOR SHAPE: 3 SOQL (transactions, checklists, items) + at most 3 DML regardless of how
     * many deals are passed, plus the rollup's own 2 SOQL + 2 DML at the end. At realistic scale it
     * is one deal; a 200-row bulk flip costs 200 x 12 = 2,400 item rows, inside the limit.
     *
     * @param transactionIds Deals whose conditional groups may have changed. Null/empty-safe.
     * @return One result per deal that changed or refused a change; empty when nothing moved.
     * @example
     * List<ChecklistFanoutService.ReconcileResult> results = ChecklistFanoutService.reconcile(ids);
     */
    public static List<ReconcileResult> reconcile(Set<Id> transactionIds) {
        List<ReconcileResult> results = new List<ReconcileResult>();
        if (transactionIds == null || transactionIds.isEmpty()) {
            return results;
        }

        Map<Id, Transaction__c> transactions = TransactionSelector.selectForChecklistFanout(
            transactionIds, conditionFieldNames());
        Set<Id> fannedOut = new Set<Id>();
        for (Transaction__c deal : transactions.values()) {
            if (deal.Checklist_Fanned_Out__c == true) {
                fannedOut.add(deal.Id);
            }
        }
        if (fannedOut.isEmpty()) {
            return results;
        }

        Map<Id, Map<String, Checklist__c>> checklistsByDeal = new Map<Id, Map<String, Checklist__c>>();
        for (Checklist__c checklist : ChecklistSelector.selectByTransactionIds(fannedOut)) {
            Map<String, Checklist__c> byLetter = checklistsByDeal.get(checklist.Transaction__c);
            if (byLetter == null) {
                byLetter = new Map<String, Checklist__c>();
                checklistsByDeal.put(checklist.Transaction__c, byLetter);
            }
            byLetter.put(checklist.Group_Letter__c, checklist);
        }
        Map<Id, Boolean> workedByChecklist = new Map<Id, Boolean>();
        Map<String, Checklist_Item__c> existingByCoordinate = new Map<String, Checklist_Item__c>();
        for (Checklist_Item__c item : ChecklistItemSelector.selectByTransactionIds(fannedOut)) {
            if (ChecklistItemDomain.isDone(item.Flag__c)) {
                workedByChecklist.put(item.Checklist__c, true);
            }
            existingByCoordinate.put(
                coordinateKey(item.Checklist__r.Transaction__c, item.Checklist__r.Group_Letter__c,
                    item.Sequence__c),
                item);
        }

        List<Checklist__c> toAdd = new List<Checklist__c>();
        List<PendingGroup> pendingAdds = new List<PendingGroup>();
        List<Checklist__c> toRemove = new List<Checklist__c>();
        Map<Id, ReconcileResult> resultByDeal = new Map<Id, ReconcileResult>();

        for (Id dealId : fannedOut) {
            Transaction__c deal = transactions.get(dealId);
            Map<String, Checklist__c> existing = checklistsByDeal.get(dealId);
            if (existing == null) {
                existing = new Map<String, Checklist__c>();
            }
            for (Task_Group_Def__mdt groupDef : groupDefs()) {
                Boolean shouldExist = isGroupApplicable(groupDef, deal);
                Checklist__c present = existing.get(groupDef.Letter__c);
                if (shouldExist && present == null) {
                    Checklist__c checklist = buildChecklist(groupDef, dealId);
                    toAdd.add(checklist);
                    pendingAdds.add(pendingGroup(checklist, groupDef, deal));
                    resultFor(resultByDeal, results, dealId).addedGroupLetters.add(groupDef.Letter__c);
                } else if (!shouldExist && present != null) {
                    if (workedByChecklist.get(present.Id) == true) {
                        resultFor(resultByDeal, results, dealId)
                            .refusedGroupLetters.add(groupDef.Letter__c);
                    } else {
                        toRemove.add(new Checklist__c(Id = present.Id));
                        resultFor(resultByDeal, results, dealId)
                            .removedGroupLetters.add(groupDef.Letter__c);
                    }
                }
            }
        }

        if (toAdd.isEmpty() && toRemove.isEmpty()) {
            return results;
        }

        Boolean alreadySuppressed = ChecklistRollupService.isTriggerRecalcSuppressed();
        try {
            ChecklistRollupService.suppressTriggerRecalc(true);
            if (!toAdd.isEmpty()) {
                applyAdditions(toAdd, pendingAdds, existingByCoordinate);
            }
            if (!toRemove.isEmpty()) {
                // Cascade-deletes the items. Every one of them is provably unworked - that is what
                // `workedByChecklist` established above.
                Database.delete(toRemove, true, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            ChecklistRollupService.suppressTriggerRecalc(alreadySuppressed);
        }

        // 🔴 RECOMPUTE EXPLICITLY. A cascade delete fires the items' after-delete trigger, but by
        // then the parent checklist may already be gone and the deal is unreachable from the child -
        // see `ChecklistSelector.selectByIds`. This call is what keeps the counters honest after a
        // removal, and it is the reason that selector's caveat is survivable.
        ChecklistRollupService.recalc(fannedOut);
        return results;
    }

    /**
     * Inserts the missing checklists, their items, and their prerequisite links.
     *
     * @param toAdd               Unsaved checklists.
     * @param pendingAdds         Their pending-group wrappers, parallel in content.
     * @param existingByCoordinate Items that already exist on those deals, so a newly added group
     *                             can point a prerequisite at one of them.
     */
    private static void applyAdditions(
        List<Checklist__c> toAdd,
        List<PendingGroup> pendingAdds,
        Map<String, Checklist_Item__c> existingByCoordinate
    ) {
        Database.insert(toAdd, true, AccessLevel.SYSTEM_MODE);
        List<Transaction_Task_Def__mdt> definitions = itemDefs();
        List<Checklist_Item__c> items = new List<Checklist_Item__c>();
        Map<String, Checklist_Item__c> newByCoordinate = new Map<String, Checklist_Item__c>();
        for (PendingGroup group : pendingAdds) {
            Integer inGroup = 0;
            for (Transaction_Task_Def__mdt itemDef : definitions) {
                if (itemDef.Group_Letter__c != group.groupDef.Letter__c) {
                    continue;
                }
                Checklist_Item__c item = buildItem(itemDef, group);
                items.add(item);
                newByCoordinate.put(
                    coordinateKey(group.dealId, itemDef.Group_Letter__c, itemDef.Sequence__c), item);
                inGroup++;
            }
            group.checklist.Items_Total__c = inGroup;
            group.checklist.Items_Complete__c = 0;
        }
        if (!items.isEmpty()) {
            Database.insert(items, true, AccessLevel.SYSTEM_MODE);
        }
        // A newly added group's prerequisites may point at items that already existed, so the
        // resolution index is the union of the new rows and the ones read by the caller.
        Map<String, Checklist_Item__c> allByCoordinate =
            new Map<String, Checklist_Item__c>(existingByCoordinate);
        allByCoordinate.putAll(newByCoordinate);
        List<Checklist_Item__c> links = resolveLinks(pendingAdds, definitions, newByCoordinate,
            allByCoordinate);
        if (!links.isEmpty()) {
            Database.update(links, true, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * Builds the `Blocked_By__c` second-pass payload for a set of just-created groups.
     *
     * ZERO SOQL by construction: both indexes are in-memory maps the caller already holds.
     *
     * @param groups             The groups whose items were just created.
     * @param definitions        All item definitions.
     * @param dependentIndex     Coordinate -> item, for the DEPENDENT side (new rows only).
     * @param prerequisiteIndex  Coordinate -> item, for the PREREQUISITE side (may include rows
     *                           that already existed on the deal).
     * @return Sparse update payload carrying Id + Blocked_By__c + Is_Prerequisite_Met__c.
     */
    private static List<Checklist_Item__c> resolveLinks(
        List<PendingGroup> groups,
        List<Transaction_Task_Def__mdt> definitions,
        Map<String, Checklist_Item__c> dependentIndex,
        Map<String, Checklist_Item__c> prerequisiteIndex
    ) {
        List<Checklist_Item__c> links = new List<Checklist_Item__c>();
        for (PendingGroup group : groups) {
            for (Transaction_Task_Def__mdt itemDef : definitions) {
                if (itemDef.Group_Letter__c != group.groupDef.Letter__c
                        || itemDef.Blocked_By_Sequence__c == null) {
                    continue;
                }
                Checklist_Item__c dependent = dependentIndex.get(
                    coordinateKey(group.dealId, itemDef.Group_Letter__c, itemDef.Sequence__c));
                // Blank means "the same group as this row", which is true of both live pairs.
                String prerequisiteLetter = String.isNotBlank(itemDef.Blocked_By_Group_Letter__c)
                    ? itemDef.Blocked_By_Group_Letter__c
                    : itemDef.Group_Letter__c;
                Checklist_Item__c prerequisite = prerequisiteIndex.get(coordinateKey(
                    group.dealId, prerequisiteLetter, itemDef.Blocked_By_Sequence__c));
                if (dependent == null || prerequisite == null || dependent.Id == prerequisite.Id) {
                    lastRunUnresolvedPrereqCount++;
                    continue;
                }
                links.add(new Checklist_Item__c(
                    Id = dependent.Id,
                    Blocked_By__c = prerequisite.Id,
                    // Explicitly false: the prerequisite was just created open, so nothing is met.
                    // Mirrors `clampOnInsert` and never relies on the field default.
                    Is_Prerequisite_Met__c = false
                ));
            }
        }
        return links;
    }

    /** One deal's reconcile outcome. */
    public class ReconcileResult {
        /** The deal reconciled. */
        public Id transactionId;
        /** Group letters added because the deal now qualifies for them. */
        public List<String> addedGroupLetters = new List<String>();
        /** Group letters removed because the deal no longer qualifies and nothing was worked. */
        public List<String> removedGroupLetters = new List<String>();
        /** Group letters KEPT despite no longer qualifying, because worked items exist in them. */
        public List<String> refusedGroupLetters = new List<String>();
    }

    /**
     * @param resultByDeal Accumulator keyed by deal.
     * @param results      The ordered result list being built.
     * @param dealId       Deal to fetch or create a result for.
     * @return The (possibly newly created) result for that deal.
     */
    private static ReconcileResult resultFor(
        Map<Id, ReconcileResult> resultByDeal,
        List<ReconcileResult> results,
        Id dealId
    ) {
        ReconcileResult result = resultByDeal.get(dealId);
        if (result == null) {
            result = new ReconcileResult();
            result.transactionId = dealId;
            resultByDeal.put(dealId, result);
            results.add(result);
        }
        return result;
    }

    /** @return Every distinct `Condition_Field__c` named by the group definitions. */
    private static Set<String> conditionFieldNames() {
        Set<String> conditionFields = new Set<String>();
        for (Task_Group_Def__mdt groupDef : groupDefs()) {
            if (String.isNotBlank(groupDef.Condition_Field__c)) {
                conditionFields.add(groupDef.Condition_Field__c);
            }
        }
        return conditionFields;
    }

    /**
     * Whether a conditional group applies to this deal. An unconditional group always applies.
     *
     * @param groupDef The group definition.
     * @param deal     The deal, carrying the describe-validated condition field.
     * @return true when the group's items should exist on this deal.
     */
    private static Boolean isGroupApplicable(Task_Group_Def__mdt groupDef, Transaction__c deal) {
        if (groupDef.Conditional__c != true) {
            return true;
        }
        if (String.isBlank(groupDef.Condition_Field__c)) {
            return false;
        }
        // `TransactionSelector` describe-validates the field name before it reaches the SELECT, so
        // an unknown field is simply absent here. `getPopulatedFieldsAsMap` keeps that from throwing
        // `SObjectException` on a field the query did not return.
        Object value = deal.getPopulatedFieldsAsMap().get(groupDef.Condition_Field__c);
        return value == true;
    }

    /**
     * @param checklist The unsaved checklist.
     * @param groupDef  Its definition.
     * @param deal      Its deal.
     * @return A populated pending-group wrapper.
     */
    private static PendingGroup pendingGroup(
        Checklist__c checklist,
        Task_Group_Def__mdt groupDef,
        Transaction__c deal
    ) {
        PendingGroup group = new PendingGroup();
        group.checklist = checklist;
        group.groupDef = groupDef;
        group.dealId = deal.Id;
        group.deal = deal;
        return group;
    }

    /**
     * @param groupDef The group definition to mirror.
     * @param dealId   Master-detail parent.
     * @return An unsaved `Checklist__c`.
     */
    private static Checklist__c buildChecklist(Task_Group_Def__mdt groupDef, Id dealId) {
        return new Checklist__c(
            Transaction__c = dealId,
            Group_Letter__c = groupDef.Letter__c,
            Group_Name__c = groupDef.Group_Name__c,
            Owner_Label__c = groupDef.Owner_Label__c,
            Sequence__c = groupDef.Sequence__c,
            Stage__c = groupDef.Stage__c,
            Is_Conditional__c = (groupDef.Conditional__c == true)
        );
    }

    /**
     * @param itemDef The item definition to mirror.
     * @param group   The pending group carrying the parent checklist and the deal.
     * @return An unsaved `Checklist_Item__c` with `Blocked_By__c` deliberately BLANK.
     */
    private static Checklist_Item__c buildItem(
        Transaction_Task_Def__mdt itemDef,
        PendingGroup group
    ) {
        Checklist_Item__c item = new Checklist_Item__c();
        item.Checklist__c = group.checklist.Id;
        item.Subject__c = itemDef.Subject__c;
        item.Sequence__c = itemDef.Sequence__c;
        item.Owner_Label__c = String.isNotBlank(itemDef.Owner_Label__c)
            ? itemDef.Owner_Label__c
            : group.groupDef.Owner_Label__c;
        item.Is_Conditional__c = (group.groupDef.Conditional__c == true);
        item.Is_Critical__c = (itemDef.Is_Critical__c == true);
        item.Is_Wire_Verification__c = (itemDef.Is_Wire_Verification__c == true);
        // 🔴 SEEDED FROM `Is_Critical__c`, NEVER FROM A SUBJECT REGEX. The Task model derived
        // CRITICAL from a parenthesised match on the Subject in TWO places (a service and an LWC),
        // neither of which threw when it stopped matching - and a naive bare-substring version of it
        // wrongly flags A4 and A5, which merely CONTAIN the word "critical".
        item.Flag__c = ChecklistItemDomain.openFlagFor(itemDef.Is_Critical__c);
        // Per-item override wins; otherwise inherit the group's phase; otherwise leave NULL and
        // count it (see `lastRunUnstagedItemCount`).
        item.Stage__c = String.isNotBlank(itemDef.Stage_Override__c)
            ? itemDef.Stage_Override__c
            : group.groupDef.Stage__c;
        if (group.deal.Contract_Executed_Date__c != null) {
            Integer offset = itemDef.Due_Day_Offset__c != null
                ? Integer.valueOf(itemDef.Due_Day_Offset__c)
                : 0;
            item.Due_Date__c = group.deal.Contract_Executed_Date__c.addDays(offset);
        }
        return item;
    }

    /**
     * The in-memory prerequisite index key. Note what it is NOT: it never touches a Subject, and it
     * does not cap the group letter at one character - so `H2`, the one two-character letter in the
     * set and the one inside which Phase 0's parser could not express a pair at all, works here with
     * no special case.
     *
     * @param dealId   The deal the item belongs to.
     * @param letter   Group letter; upper-cased and trimmed because Apex Map keys are case-sensitive.
     * @param sequence Item sequence.
     * @return A key of the form `<dealId>|<LETTER>|<sequence>`, or null when any part is absent.
     */
    private static String coordinateKey(Id dealId, String letter, Decimal sequence) {
        if (dealId == null || String.isBlank(letter) || sequence == null) {
            return null;
        }
        return String.valueOf(dealId) + '|' + letter.trim().toUpperCase()
            + '|' + String.valueOf(sequence.intValue());
    }

    /** @return The group definitions, ordered, honouring the test override. */
    private static List<Task_Group_Def__mdt> groupDefs() {
        return groupDefsOverride != null
            ? groupDefsOverride
            : TaskGroupDefProvider.getAllOrderedBySequence();
    }

    /** @return The item definitions, ordered, honouring the test override. */
    private static List<Transaction_Task_Def__mdt> itemDefs() {
        return taskDefsOverride != null
            ? taskDefsOverride
            : TransactionTaskDefProvider.getAllOrderedByGroupAndSequence();
    }

    /** A checklist that has been built but whose items are not created yet. */
    private class PendingGroup {
        Checklist__c checklist;
        Task_Group_Def__mdt groupDef;
        Id dealId;
        Transaction__c deal;
    }

    /** Per-deal counters accumulated while the items are built, so no re-read is needed. */
    private class DealTally {
        Integer total = 0;
        Integer overdue = 0;
        Integer wireOpen = 0;
    }
}
