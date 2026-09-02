/**
 * Phase 4 M1 — migrates a live deal's legacy `Task` checklist onto the `Checklist__c` /
 * `Checklist_Item__c` model, and M1's reversal. Design §7, `agent-output/phase4-migration-design.md`.
 *
 * layer=service. All SOQL delegated to `TransactionSelector` / `TaskSelector` / `ChecklistSelector`;
 * CMDT through the two providers.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 ADDITIVE. THE `Task` ROWS ARE NEVER TOUCHED — NOT UPDATED, NOT DELETED, NOT READ FOR WRITE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The strategy is a dual-model window, not a conversion. `Task` rows cannot be reconstructed once
 * deleted, so they stay and are made read-only at M4 by a permission change, not by this class.
 * The single consequence worth stating: `rollback` is CHEAP and TOTAL **UNTIL THE OUTCOME BACKFILL
 * RUNS** — delete the checklists, clear the flag, and the Task model is authoritative again.
 *
 * 🔴 AND AFTER `scripts/backfill-checklist-outcomes.apex` HAS RUN, IT IS NEITHER. THAT SCRIPT IS
 * THE SANCTIONED POST-M1 STEP THIS CLASS DEFERS OUTCOMES TO, so the sequence both this header and
 * design §6 prescribe is exactly the sequence that makes rollback partial. Stated here because
 * this is the header somebody reads on rollback day.
 * `rollback` deletes the checklists and clears the flag. It does NOT undo what the backfill wrote
 * to the DEAL, and none of it existed on the Task model:
 *   • `Critical_Date__c` rows — PERMANENT. They are precisely the rows GATE-B3 is about, and
 *     nothing in Phase 4 deletes them. `CriticalDateService` is idempotent on
 *     (Transaction + Type), so a re-migration + re-backfill will not duplicate them - but it will
 *     not remove them either, and a deal that never had critical dates now has them forever.
 *   • `Earnest_Money_Sent__c = true` — stays true.
 *   • `Earnest_Money_Sent_Date__c` — stamped with the BACKFILL DAY, not the day the wire was sent.
 *     🔴 AND A RE-MIGRATION CANNOT CORRECT IT. `ChecklistOutcomeService` stamps that date ONLY
 *     WHEN IT IS BLANK, so the one residue that looks repairable by re-running is specifically
 *     protected against being repaired that way. Clearing it is a deliberate manual write.
 *   • `Is_Earnest_At_Risk__c` — flipped, and deliberately NOT covered by the outcome suppression
 *     seam (it derives from a date and nothing saves a deal the day feasibility expires), so it
 *     is not restored either.
 * ⇒ ROLLBACK IS TOTAL ONLY BEFORE THE BACKFILL RUNS. After it, rollback restores the CHECKLIST
 *   and leaves DEAL-LEVEL residue that must be unwound by hand, item by item, from the list above.
 *   If a rollback is even conceivable, run it BEFORE the backfill.
 *
 * ⚠ DELETING THE TRANSACTION IS **NOT** THE ROLLBACK, even though it is now possible.
 * Design §7 RISK 2 said "delete the deal and re-fan it" was unavailable because
 * `Critical_Date__c.Transaction__c` was `required=true` + `deleteConstraint=Restrict`. THAT
 * SENTENCE IS STALE: the field was relaxed to `SetNull` + optional on 2026-08-31 under GATE-B3
 * and its own description says the relaxation exists so "a botched migration stays reversible".
 * Availability is not suitability — deleting the deal destroys the very `Task` rows this whole
 * strategy exists to preserve, plus its `Wire__c` links, its field history and its Opportunity
 * gate flags. Use `rollback`.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 FOUR STATEMENTS, IN THIS ORDER, AND THE ORDER IS THE WIRE-GATE STRATEGY.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *   1. insert `Checklist__c`   — items are master-detail children and need parent Ids.
 *   2. insert `Checklist_Item__c` WITH `Blocked_By__c` BLANK, including rows migrated as
 *      already-`Completed`.
 *   3. update the gated items with their `Blocked_By__c` — THE SECOND PASS.
 *   4. update `Transaction__c` — the guard flag plus the four counters, which this code knows
 *      exactly because it just projected them.
 *
 * WHY STEP 2 CANNOT CARRY THE LINK, MEASURED AGAINST THE DEPLOYED GATE RATHER THAN ASSUMED:
 * `ChecklistItemPrerequisiteService.clampOnInsert` forces `Is_Prerequisite_Met__c = false` on
 * ANY item inserted with a `Blocked_By__c` — deliberately, with no sibling lookup, because a
 * query in before-insert would cost ~21 SOQL on the fan-out cascade. The validation rule
 * `Prerequisite_Must_Be_Met_To_Complete` then refuses that row through its `ISNEW()` arm,
 * WITHOUT CONSULTING THE PREREQUISITE'S REAL STATE. A migration that inserted a completed B3
 * with its key in one statement would therefore be refused for exactly the two most important
 * rows on the deal — and under `allOrNone = false` they would be SILENTLY DROPPED.
 *
 * ✅ WHY STEP 3 IS **NOT** REFUSED, WHICH IS THE OTHER HALF AND IS EASY TO GET WRONG. The Phase 4
 * brief warned that the gate "refuses any coordinate change on an open item for every principal
 * and every path including SYSTEM_MODE", and that M1 would need `Transaction_Prereq_Override`.
 * IT DOES NOT, AND THE OVERRIDE IS DELIBERATELY NOT USED HERE. Branch by branch:
 *   • (B) the disarm refusal — the ONLY branch with an override — is gated on
 *     `candidate.linkChanged`, which is `priorBlockedBy != null && ...`. Step 3 writes null -> X,
 *     so `linkChanged` is FALSE and (B) never evaluates. The gate's own comment says so:
 *     "GAINING a link for the first time is NOT a change — that is the fan-out's second pass AND
 *     THE MIGRATION, and refusing it would make the feature uninstallable."
 *   • (A) the primary control fires only on `entering`, an open -> done transition. Step 3 writes
 *     `Blocked_By__c` and `Is_Prerequisite_Met__c` and NOTHING ELSE — `Flag__c` is untouched, so
 *     `entering` is false on every row, including rows migrated already-complete.
 *   • (D) refuses a link that is self, unresolvable or cross-deal. Both ends are same-deal rows
 *     this transaction just inserted.
 *   • The validation rule is `AND(OR(ISNEW(), ISCHANGED(Flag__c)), ...)`, and step 3 is neither.
 * ⚠ THE CONSEQUENCE THAT MAKES THIS WORTH THE PARAGRAPH: a live deal where B3 was completed while
 * B2 is still open — entirely possible, since Phase 0's gate only shipped 2026-08-31 — MIGRATES
 * SUCCESSFULLY, keeps its history, and lands with `Is_Prerequisite_Met__c = false`: visible,
 * reportable, and refused only if somebody later re-touches its `Flag__c`. That is correct, and
 * it required no elevated permission. DO NOT GRANT `Transaction_Prereq_Override` TO THE RUNNER.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 SHARING IS THE MOST LIKELY WAY THIS FAILS, AND IT WOULD OTHERWISE FAIL SILENTLY.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Every DML below is `AccessLevel.SYSTEM_MODE`, which lifts CRUD/FLS and **never** sharing. Both
 * master-detail links carry `writeRequiresMasterRead=false`, which is the STRICTER setting — it
 * requires read AND WRITE on the master — so inserting a `Checklist__c` needs EDIT SHARING on the
 * `Transaction__c`. `Transaction__c` is OWD Private; `Transaction_Team_All_RW` grants Edit to the
 * `DPEG_Transactions_Team` public group for every deal whose `Stage__c` is non-blank.
 * ⇒ THE RUNNER MUST BE IN `DPEG_Transactions_Team` (or hold Modify All Data). Group membership is
 *   NOT deployable, so this cannot be verified from the repo and is a pre-M1 org check.
 * ⇒ A deal the runner cannot see returns NO ROW from the `with sharing` selector and would simply
 *   be skipped. So `migrate` DIFFS THE IDS IT WAS ASKED FOR AGAINST THE IDS IT GOT BACK and
 *   reports every difference as `NOT_VISIBLE`. A deal with a blank `Stage__c` — outside the
 *   sharing rule's criteria — surfaces there rather than vanishing.
 * ⚠ `ChecklistRollupService.RollupWrites` is `without sharing` and its header names "a future
 * migration batch or Schedulable" as the shape whose principal would lack Edit sharing. This IS
 * that shape, and it deliberately does not lean on that escalation: the rollup is SUPPRESSED
 * throughout and this class writes the counters itself. That header's re-pricing question is
 * still open and is not answered by side effect here.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 GOVERNOR ARITHMETIC — RE-DERIVED FOR THIS CLASS. CHUNK IS 25, NOT THE FAN-OUT'S 50.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ THE HEAP FIGURES BELOW ARE ESTIMATED FROM ROW COUNTS, NOT MEASURED. sObject heap cost varies
 * with the number of populated fields and the length of their values, and nothing here has been
 * run against an org. The DML-row and SOQL figures ARE exact arithmetic. Treat 25 as a
 * conservative choice justified by a shape argument (this class holds BOTH models plus the
 * coordinate maps, where the fan-out holds only the new side) rather than by a measurement.
 *
 * Rows per deal are the fan-out 96 (11 checklists + up to 82 items + a 2-row second pass + 1
 * deal update), so DML ROWS ARE NOT THE CONSTRAINT: 25 x 96 = 2,400 of 10,000. **HEAP IS.** The
 * fan-out holds only the new side; this holds the `Task` rows AND the projected items AND the
 * coordinate maps AND the findings simultaneously:
 *     chunk 50 -> ~8,750 sObjects — uncomfortable against the 12 MB async ceiling
 *     chunk 25 -> ~4,375 sObjects — chosen
 * Per chunk, suppression ON:
 *   SOQL 4  — 1 TransactionSelector.selectForChecklistFanout, 1 TaskSelector
 *             .selectForChecklistMigration, 1 ChecklistSelector.selectByTransactionIds
 *             (idempotency probe), and 1 fired BY step 3's own update:
 *             `ChecklistItemPrerequisiteService.enforceOnUpdate` spends one read per chunk.
 *             ⚠ `suppressTriggerRecalc` does NOT cover that one — that flag is the ROLLUP arm
 *             only, and suppressing the GATE on the very write it exists to police would be
 *             wrong. Same note as `ChecklistFanoutService`'s header.
 *   DML  4  — checklists, items, links, transactions. Limit 150.
 * SUPPRESSION IS NOT OPTIONAL. 25 x 82 = 2,050 items in one insert fires after-insert in
 * ceil(2050/200) = 11 batches, x 4 selector reads per `recalcForChecklistIds` = 44 SOQL, to
 * recompute counters this code then overwrites with values it already has.
 * ⚠ The step-4 `Transaction__c` update moves neither `Stage__c`, `Loan_Required__c`,
 * `Opportunity__c` nor the closed boundary, so every arm of `TransactionTriggerHandler` collects
 * zero ids and spends nothing. That is why the flag write is free.
 * ⚠ NEW FAILURE MODE, INHERITED FROM THE MODEL: a master-detail child insert LOCKS ITS MASTER, so
 * a concurrent user edit of a Transaction during migration can raise `UNABLE_TO_LOCK_ROW`. The
 * chunk fails, the Finalizer keeps the chain moving, and the affected deals stay un-migrated —
 * safe, because the whole thing is idempotent on `Checklist_Fanned_Out__c`.
 *
 * @see force-app/main/default/classes/ChecklistMigrationDomain.cls (the projection + gate)
 * @see force-app/main/default/classes/ChecklistMigrationQueueable.cls (the chunk chain)
 * @see force-app/main/default/classes/ChecklistMigrationAuditService.cls (M2)
 * @see agent-output/phase4-migration-design.md §0.1, §2, §5, §6, §7
 */
public with sharing class ChecklistMigrationService {

    /** Extra `Transaction__c` fields the projection's advisory drift check needs. */
    @TestVisible
    private static final Set<String> STORED_COUNTER_FIELDS = new Set<String>{
        'Tasks_Total__c', 'Tasks_Complete__c', 'Tasks_Overdue__c', 'Wire_Open_Risks__c'
    };

    /** Deals migrated by the last `migrate` call. In-context instrumentation; see below. */
    @TestVisible
    private static Integer lastRunMigratedCount = 0;

    /** Deals REFUSED by the reconciliation gate on the last call. */
    @TestVisible
    private static Integer lastRunRefusedCount = 0;

    /** Deals already claimed (idempotent re-run) on the last call. */
    @TestVisible
    private static Integer lastRunSkippedCount = 0;

    /** Deals asked for that the running user could not see on the last call. */
    @TestVisible
    private static Integer lastRunNotVisibleCount = 0;

    /**
     * SOQL consumed by the last `migrate` body.
     * 🔴 CAPTURED INSIDE THE ASYNC CONTEXT. `Test.stopTest()` restores the pre-test governor
     * counters, so a `Limits.getQueries()` assertion written after it measures nothing and passes
     * vacuously. Assert on this.
     */
    @TestVisible
    private static Integer lastRunQueryCount = 0;

    /** DML statements consumed by the last `migrate` body. Same in-context capture rule. */
    @TestVisible
    private static Integer lastRunDmlCount = 0;

    /** Test injection point — CMDT cannot be inserted, but can be built in memory. */
    @TestVisible
    static List<Task_Group_Def__mdt> groupDefsOverride;

    /** Test injection point. */
    @TestVisible
    static List<Transaction_Task_Def__mdt> taskDefsOverride;

    /** One deal's outcome, returned so a caller (or a script) can report on it. */
    public class MigrationResult {
        /** The deal. */
        public Id transactionId;
        /** MIGRATED, REFUSED, ALREADY_MIGRATED or NOT_VISIBLE. */
        public String outcome;
        /** Checklists created (0 unless MIGRATED). */
        public Integer checklistCount = 0;
        /** Items created (0 unless MIGRATED). */
        public Integer itemCount = 0;
        /** Every finding from the reconciliation, blocking and advisory. */
        public List<ChecklistMigrationDomain.Discrepancy> discrepancies =
            new List<ChecklistMigrationDomain.Discrepancy>();
    }

    /**
     * Migrates a chunk of deals. Callers keep the chunk at or below
     * `ChecklistMigrationQueueable.CHUNK_SIZE` — see the class header for why that is 25.
     *
     * @param transactionIds Deals to migrate. Null/empty-safe. Deals already carrying
     *                       `Checklist_Fanned_Out__c` are skipped, so this is idempotent and a
     *                       failed chunk can simply be re-run.
     * @return One result per deal asked for, in the order asked.
     * @throws System.DmlException on a platform save failure (`allOrNone = true`, deliberately:
     *         a half-migrated deal is worse than an un-migrated one, and the Queueable's
     *         Finalizer keeps the chain moving for the other chunks).
     * @example
     * List<ChecklistMigrationService.MigrationResult> results =
     *     ChecklistMigrationService.migrate(new List<Id>{ dealId });
     */
    public static List<MigrationResult> migrate(List<Id> transactionIds) {
        resetRunCounters();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            return migrateChunk(transactionIds);
        } finally {
            lastRunQueryCount = Limits.getQueries() - queriesBefore;
            lastRunDmlCount = Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * The migration itself, wrapped by `migrate` so the instrumentation covers every early return.
     *
     * @param transactionIds Deals to migrate.
     * @return One result per deal asked for.
     */
    private static List<MigrationResult> migrateChunk(List<Id> transactionIds) {
        List<MigrationResult> results = new List<MigrationResult>();
        if (transactionIds == null || transactionIds.isEmpty()) {
            return results;
        }
        Set<Id> dealIds = new Set<Id>(transactionIds);
        dealIds.remove(null);
        if (dealIds.isEmpty()) {
            return results;
        }

        Map<Id, Transaction__c> deals =
            TransactionSelector.selectForChecklistFanout(dealIds, STORED_COUNTER_FIELDS);
        List<Task> tasks = TaskSelector.selectForChecklistMigration(dealIds);
        Map<Id, List<Task>> tasksByDeal = groupTasksByDeal(tasks);
        Set<Id> alreadyHasChecklists = dealsWithChecklists(dealIds);

        List<Task_Group_Def__mdt> groupDefs = groupDefs();
        List<Transaction_Task_Def__mdt> itemDefs = itemDefs();
        Date today = Date.today();

        List<Checklist__c> checklistWrites = new List<Checklist__c>();
        List<ChecklistMigrationDomain.PendingItem> pendingItems =
            new List<ChecklistMigrationDomain.PendingItem>();
        Map<String, ChecklistMigrationDomain.PendingItem> itemByCoordinate =
            new Map<String, ChecklistMigrationDomain.PendingItem>();
        List<Transaction__c> dealWrites = new List<Transaction__c>();

        for (Id dealId : transactionIds) {
            if (dealId == null) {
                continue;
            }
            MigrationResult result = new MigrationResult();
            result.transactionId = dealId;
            results.add(result);

            Transaction__c deal = deals.get(dealId);
            if (deal == null) {
                // Sharing, not absence — see the sharing block in the class header. Reported
                // rather than skipped, because a silently skipped deal is the failure mode this
                // migration is most likely to hide.
                result.outcome = 'NOT_VISIBLE';
                result.discrepancies.add(new ChecklistMigrationDomain.Discrepancy(
                    ChecklistMigrationDomain.Severity.BLOCKING, 'NOT_VISIBLE', null,
                    'requested', 'no row returned - check DPEG_Transactions_Team membership'));
                lastRunNotVisibleCount++;
                continue;
            }
            if (deal.Checklist_Fanned_Out__c == true || alreadyHasChecklists.contains(dealId)) {
                // Idempotency. The flag alone is not enough: a Checklist__c created by hand on an
                // unclaimed deal is a documented coexistence case (`ChecklistRollupService`), and
                // migrating on top of it would duplicate the whole checklist.
                result.outcome = 'ALREADY_MIGRATED';
                lastRunSkippedCount++;
                continue;
            }

            ChecklistMigrationDomain.Projection projection = ChecklistMigrationDomain.project(
                dealId, storedCountersOf(deal), tasksByDeal.get(dealId), groupDefs, itemDefs, today);
            result.discrepancies = projection.discrepancies;
            if (projection.isReconciled != true) {
                // 🔴 THE GATE. Nothing is inserted for this deal, so it stays wholly on the Task
                // model and the audit service can explain it in PROJECTED mode.
                result.outcome = 'REFUSED';
                lastRunRefusedCount++;
                continue;
            }

            result.outcome = 'MIGRATED';
            result.checklistCount = projection.checklists.size();
            result.itemCount = projection.itemCount;
            lastRunMigratedCount++;
            for (ChecklistMigrationDomain.PendingChecklist pending : projection.checklists) {
                checklistWrites.add(pending.record);
                for (ChecklistMigrationDomain.PendingItem item : pending.items) {
                    pendingItems.add(item);
                    itemByCoordinate.put(indexKey(item.dealId, item.letter, item.sequence), item);
                }
            }
            dealWrites.add(new Transaction__c(
                Id = dealId,
                Checklist_Fanned_Out__c = true,
                Tasks_Total__c = projection.counters.total,
                Tasks_Complete__c = projection.counters.complete,
                Tasks_Overdue__c = projection.counters.overdue,
                Wire_Open_Risks__c = projection.counters.wireOpen
            ));
        }

        if (!checklistWrites.isEmpty()) {
            persist(checklistWrites, pendingItems, itemByCoordinate, dealWrites);
        }
        return results;
    }

    /**
     * The four write statements, in the order the class header fixes, with the rollup suppressed
     * across all of them.
     *
     * @param checklistWrites  Unsaved checklists.
     * @param pendingItems     Unsaved items, each still pointing at its parent's unsaved record.
     * @param itemByCoordinate Index for resolving the prerequisite links after insert.
     * @param dealWrites       The guard flag plus the four counters, one row per migrated deal.
     */
    private static void persist(
        List<Checklist__c> checklistWrites,
        List<ChecklistMigrationDomain.PendingItem> pendingItems,
        Map<String, ChecklistMigrationDomain.PendingItem> itemByCoordinate,
        List<Transaction__c> dealWrites
    ) {
        Boolean alreadySuppressed = ChecklistRollupService.isTriggerRecalcSuppressed();
        // 🔴 THE OUTCOME SEAM (Phase 5 built it to this spec; the argument is recorded at the flag).
        // `ChecklistOutcomeService.applyForCompletedItems` keys on `isDone(Flag__c)`, and step 2
        // below inserts items that are ALREADY DONE - real completion history carried over from the
        // Task model. Without this, migrating 25 deals re-applies every historical outcome in bulk,
        // including `CriticalDateService.ensureFor`, the exact call `TransactionTriggerHandler`
        // WITHHOLDS pending GATE-B2/B4 because it can throw inside a trigger and roll back the
        // caller's save. `suppressTriggerRecalc` is the ROLLUP arm only and does not cover it.
        // ⚠ THE FLAG, NOT A TRANSITION GATE, AND THAT IS NOT A PREFERENCE. A transition test needs
        // a prior state, and an INSERT has none: the gate would have to answer "is a row created
        // already-done a transition?" with one fixed answer, and both are wrong for somebody - NO
        // silently stops outcomes ever applying to a legitimate Data Loader insert, YES lets this
        // migration re-apply everything. A flag set by exactly ONE caller is the only thing that
        // tells "the migration inserted this" apart from "someone loaded a completed item".
        // ⚠ OUTCOMES ARE APPLIED DELIBERATELY AFTER M1 by `scripts/backfill-checklist-outcomes.apex`,
        // which runs WITHOUT this flag set. That script is the approved path and this suppression is
        // what keeps it the ONLY path - do not "helpfully" apply them inline here.
        Boolean outcomesAlreadySuppressed = ChecklistOutcomeService.isOutcomeApplicationSuppressed();
        try {
            // Restore-not-clear: `reconcile` and the fan-out can already have suppressed, and an
            // unconditional reset in this inner scope would re-arm the trigger halfway through an
            // outer one's DML.
            ChecklistRollupService.suppressTriggerRecalc(true);
            ChecklistOutcomeService.suppressOutcomeApplication(true);

            Database.insert(checklistWrites, true, AccessLevel.SYSTEM_MODE);

            List<Checklist_Item__c> itemWrites = new List<Checklist_Item__c>();
            for (ChecklistMigrationDomain.PendingItem pending : pendingItems) {
                itemWrites.add(pending.record);
            }
            if (!itemWrites.isEmpty()) {
                // STEP 2 — `Blocked_By__c` is blank on every one of these by construction:
                // `ChecklistMigrationDomain.buildItem` never sets it. See the class header for
                // what happens if that ever changes.
                Database.insert(itemWrites, true, AccessLevel.SYSTEM_MODE);
            }

            List<Checklist_Item__c> links = resolveLinks(pendingItems, itemByCoordinate);
            if (!links.isEmpty()) {
                Database.update(links, true, AccessLevel.SYSTEM_MODE);
            }

            if (!dealWrites.isEmpty()) {
                Database.update(dealWrites, true, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            ChecklistRollupService.suppressTriggerRecalc(alreadySuppressed);
            // Restore the PRIOR value, never blindly false - same discipline as the rollup flag
            // above, and for the same reason: a caller can already have suppressed.
            ChecklistOutcomeService.suppressOutcomeApplication(outcomesAlreadySuppressed);
        }
    }

    /**
     * STEP 3 — the prerequisite links, now that every item has an Id. ZERO SOQL: the index was
     * built as the rows were constructed and `Database.insert` populates `Id` on those very
     * instances. Only the gated rows are touched (B3, I8), never all 82.
     *
     * ⚠ FAILS OPEN, deliberately and narrowly, exactly as `ChecklistFanoutService.resolveLinks`
     * does: a lookup cannot point at nothing, so an unresolvable prerequisite leaves the dependent
     * UNGATED rather than bricking the deal. It cannot happen silently here — the reconciliation
     * already emitted a BLOCKING `PREREQ_UNRESOLVED` for that coordinate and the deal was refused
     * before reaching this method.
     *
     * @param pendingItems     Every item just inserted.
     * @param itemByCoordinate Index of those items by deal + letter + sequence.
     * @return Sparse update rows carrying Id, `Blocked_By__c` and `Is_Prerequisite_Met__c`.
     */
    private static List<Checklist_Item__c> resolveLinks(
        List<ChecklistMigrationDomain.PendingItem> pendingItems,
        Map<String, ChecklistMigrationDomain.PendingItem> itemByCoordinate
    ) {
        List<Checklist_Item__c> links = new List<Checklist_Item__c>();
        for (ChecklistMigrationDomain.PendingItem dependent : pendingItems) {
            if (dependent.blockedBySequence == null || dependent.record.Id == null) {
                continue;
            }
            // ⚠ `dependent.dealId`, NOT `dependent.record.Checklist__r.Transaction__c`. The index
            // is built at PROJECTION time, when the row is unsaved and has no populated parent
            // relationship — traversing it there is a null dereference, not a slow path.
            String key = indexKey(
                dependent.dealId, dependent.blockedByLetter, dependent.blockedBySequence);
            ChecklistMigrationDomain.PendingItem prerequisite = itemByCoordinate.get(key);
            if (prerequisite == null
                    || prerequisite.record.Id == null
                    || prerequisite.record.Id == dependent.record.Id) {
                continue;
            }
            links.add(new Checklist_Item__c(
                Id = dependent.record.Id,
                Blocked_By__c = prerequisite.record.Id,
                // Stated explicitly so the row is correct even if the trigger were ever
                // deactivated. `ChecklistItemPrerequisiteService.enforceOnUpdate` recomputes it
                // from the resolved prerequisite on this very save, so the two agree — and unlike
                // the fan-out, a MIGRATED prerequisite can already be done, so a hardcoded false
                // would be wrong here where it is right there.
                Is_Prerequisite_Met__c =
                    ChecklistItemDomain.isDone(prerequisite.record.Flag__c)
            ));
        }
        return links;
    }

    /**
     * Reverses M1 for the supplied deals. See the class header for why this, and not deleting the
     * Transaction, is the rollback.
     *
     * 🔴 ROLLBACK IS SAFE ONLY BEFORE M3. AFTER THE FLOW REPOINT IT UNDOES ITSELF.
     * Step 1 writes `Checklist_Fanned_Out__c` true -> false. M3 repoints
     * `flows/Transaction_Task_Fanout` to filter on THAT FIELD being false, and the flow declares
     * `doesRequireRecordChangedToMeetCriteria = true` - so the un-claim is a record CHANGING INTO
     * the criteria and the flow fires. It calls `ChecklistFanoutService`, whose only dedupe guard
     * is the same flag, now false. The deal is immediately re-fanned with a BRAND NEW checklist,
     * re-claimed, and `Tasks_Complete__c` overwritten with 0 - destroying the recompute step 3
     * had just performed and every completion the migration had carried over.
     * ⚠ Design §4 reasons about whether the repointed flow fires RETROACTIVELY for the
     * un-migrated backlog (it does not) and stops there. It never asks what ELSE writes the flag.
     * This method does, and it is the only thing that does.
     * ⇒ AFTER M3, ROLLING A DEAL BACK REQUIRES DEACTIVATING OR RE-FILTERING THE FLOW FIRST. That
     *   is a deploy, not a script argument, which is precisely why M3 is sequenced after M2 reads
     *   CUTOVER: CLEAR - by then rollback should not be needed. Anyone who needs it anyway must
     *   take the flow out of the path before running this, and put it back afterwards.
     *
     * 🔴 TOTAL ONLY BEFORE `scripts/backfill-checklist-outcomes.apex` HAS RUN. That script is the
     * sanctioned post-M1 step `persist` defers outcomes to, so the prescribed sequence is exactly
     * what makes this method partial. It restores the CHECKLIST; it does not undo what the backfill
     * wrote to the DEAL, and none of that existed on the Task model:
     * `Critical_Date__c` rows (PERMANENT - the GATE-B3 rows), `Earnest_Money_Sent__c = true`,
     * `Earnest_Money_Sent_Date__c` stamped with the BACKFILL DAY rather than the wire day, and
     * `Is_Earnest_At_Risk__c` flipped.
     * 🔴 THE DATE CANNOT BE REPAIRED BY RE-RUNNING. `ChecklistOutcomeService` stamps it ONLY WHEN
     * BLANK, so a re-migration + re-backfill leaves the wrong day in place. Unwinding is a manual,
     * per-field write. IF A ROLLBACK IS CONCEIVABLE AT ALL, RUN IT BEFORE THE BACKFILL.
     *
     * 🔴 THE ORDER IS LOAD-BEARING AND IS THE WHOLE METHOD:
     *   1. clear `Checklist_Fanned_Out__c` — FIRST, because the Phase 4 counter guard in
     *      `TaskRollupService.recalc` skips claimed deals, so a recompute run before this line
     *      would be a silent no-op and the deal would keep the checklist model's numbers with no
     *      checklist behind them.
     *   2. delete the `Checklist__c` rows (master-detail cascades the items), with the rollup
     *      suppressed — an after-delete recalc would try to write `Items_*` on rows being deleted,
     *      and `ChecklistRollupService.recalcForChecklistIds` cannot reach the deal from a child
     *      whose parent is already gone (that hole is documented on that method).
     *   3. recompute from the Tasks, which were never touched, so the legacy model is
     *      authoritative again.
     *
     * @param transactionIds Deals to roll back. Null/empty-safe.
     * @return The deals actually rolled back (those that had checklists).
     * @throws System.DmlException on a platform failure (`allOrNone = true`).
     * @example
     * ChecklistMigrationService.rollback(new Set<Id>{ dealId });
     */
    public static Set<Id> rollback(Set<Id> transactionIds) {
        Set<Id> rolledBack = new Set<Id>();
        if (transactionIds == null || transactionIds.isEmpty()) {
            return rolledBack;
        }
        Set<Id> dealIds = new Set<Id>(transactionIds);
        dealIds.remove(null);
        if (dealIds.isEmpty()) {
            return rolledBack;
        }

        List<Checklist__c> checklists = ChecklistSelector.selectByTransactionIds(dealIds);
        Map<Id, Transaction__c> deals =
            TransactionSelector.selectForChecklistFanout(dealIds, new Set<String>());

        List<Transaction__c> unclaim = new List<Transaction__c>();
        for (Id dealId : dealIds) {
            Transaction__c deal = deals.get(dealId);
            if (deal != null && deal.Checklist_Fanned_Out__c == true) {
                unclaim.add(new Transaction__c(Id = dealId, Checklist_Fanned_Out__c = false));
                rolledBack.add(dealId);
            }
        }
        for (Checklist__c checklist : checklists) {
            rolledBack.add(checklist.Transaction__c);
        }
        if (rolledBack.isEmpty()) {
            return rolledBack;
        }

        // STEP 1 — before anything else. See the numbered note above.
        if (!unclaim.isEmpty()) {
            Database.update(unclaim, true, AccessLevel.SYSTEM_MODE);
        }

        // STEP 2.
        Boolean alreadySuppressed = ChecklistRollupService.isTriggerRecalcSuppressed();
        try {
            ChecklistRollupService.suppressTriggerRecalc(true);
            if (!checklists.isEmpty()) {
                Database.delete(checklists, true, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            ChecklistRollupService.suppressTriggerRecalc(alreadySuppressed);
        }

        // STEP 3 — the legacy model recomputes its own counters from rows it still owns.
        TaskRollupService.recalc(rolledBack);
        return rolledBack;
    }

    /**
     * @param tasks Checklist Tasks across several deals.
     * @return Those Tasks grouped by `Transaction_Deal__c`; never null.
     */
    private static Map<Id, List<Task>> groupTasksByDeal(List<Task> tasks) {
        Map<Id, List<Task>> byDeal = new Map<Id, List<Task>>();
        for (Task legacyTask : tasks) {
            if (legacyTask.Transaction_Deal__c == null) {
                continue;
            }
            List<Task> forDeal = byDeal.get(legacyTask.Transaction_Deal__c);
            if (forDeal == null) {
                forDeal = new List<Task>();
                byDeal.put(legacyTask.Transaction_Deal__c, forDeal);
            }
            forDeal.add(legacyTask);
        }
        return byDeal;
    }

    /**
     * The idempotency probe. Separate from the `Checklist_Fanned_Out__c` flag on purpose: a
     * hand-created `Checklist__c` on an unclaimed deal is a documented coexistence case, and
     * migrating on top of one would duplicate the whole checklist with no error.
     *
     * @param dealIds Deals about to be migrated.
     * @return Those that already carry at least one checklist.
     */
    private static Set<Id> dealsWithChecklists(Set<Id> dealIds) {
        Set<Id> found = new Set<Id>();
        for (Checklist__c checklist : ChecklistSelector.selectByTransactionIds(dealIds)) {
            if (checklist.Transaction__c != null) {
                found.add(checklist.Transaction__c);
            }
        }
        return found;
    }

    /**
     * @param deal A Transaction loaded WITH `STORED_COUNTER_FIELDS`.
     * @return Its stored counters, for the domain's advisory drift check.
     */
    private static ChecklistMigrationDomain.Counters storedCountersOf(Transaction__c deal) {
        ChecklistMigrationDomain.Counters stored = new ChecklistMigrationDomain.Counters();
        stored.total = intOf(deal.Tasks_Total__c);
        stored.complete = intOf(deal.Tasks_Complete__c);
        stored.overdue = intOf(deal.Tasks_Overdue__c);
        stored.wireOpen = intOf(deal.Wire_Open_Risks__c);
        return stored;
    }

    /** @param value A stored counter. @return Its Integer value, or null when unset. */
    private static Integer intOf(Decimal value) {
        return value == null ? null : value.intValue();
    }

    /**
     * The in-memory prerequisite index key. Never touches a Subject, and does not cap the letter
     * at one character — so `H2` needs no special case.
     *
     * @param dealId   The deal.
     * @param letter   Group letter.
     * @param sequence Item sequence.
     * @return `<dealId>|<LETTER>|<sequence>`, or null when any part is absent.
     */
    private static String indexKey(Id dealId, String letter, Integer sequence) {
        if (dealId == null || String.isBlank(letter) || sequence == null) {
            return null;
        }
        return String.valueOf(dealId) + '|' + letter.trim().toUpperCase()
            + '|' + String.valueOf(sequence);
    }

    /** @return The group definitions, honouring the test override. */
    private static List<Task_Group_Def__mdt> groupDefs() {
        return groupDefsOverride != null
            ? groupDefsOverride
            : TaskGroupDefProvider.getAllOrderedBySequence();
    }

    /** @return The item definitions, honouring the test override. */
    private static List<Transaction_Task_Def__mdt> itemDefs() {
        return taskDefsOverride != null
            ? taskDefsOverride
            : TransactionTaskDefProvider.getAllOrderedByGroupAndSequence();
    }

    /**
     * Zeroes the instrumentation at the start of every run.
     * ⚠ NOT test-only - `migrate` calls it (this header said "production never calls it", which was
     * wrong and would have made a reader treat a stale counter as impossible). It is `@TestVisible`
     * so a test can reset between assertions, not because production skips it.
     */
    @TestVisible
    private static void resetRunCounters() {
        lastRunMigratedCount = 0;
        lastRunRefusedCount = 0;
        lastRunSkippedCount = 0;
        lastRunNotVisibleCount = 0;
        lastRunQueryCount = 0;
        lastRunDmlCount = 0;
    }
}
