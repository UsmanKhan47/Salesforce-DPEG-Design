/**
 * Rolls the count of completed (closed) Tasks for a Transaction up to
 * Transaction__c.Tasks_Complete__c, which drives the "N / 82" highlights tile.
 * Invoked from TaskRollupTrigger.
 *
 * ⚠ 82 IS THE CEILING, NOT ALWAYS THE DENOMINATOR, and this header said "N / 75" until
 * 2026-08-31 — a number that was never right for either reading. There are 82
 * Transaction_Task_Def__mdt rows across 11 Task_Group_Def__mdt groups (verified against
 * usman-dpeg on 2026-08-31), and the tile renders Tasks_Display__c = TEXT(Tasks_Complete__c)
 * & " / " & TEXT(Tasks_Total__c). TaskFanoutService writes Tasks_Total__c = the count it
 * actually created for THAT Transaction, gated by that Transaction's own condition fields via
 * Task_Group_Def__mdt.Condition_Field__c — so a deal with no loan legitimately shows a
 * denominator below 82. Do not turn 82 into a constant anywhere; see the
 * `activeTransactionsList` header for the incident where a hardcoded denominator did exactly
 * that and reported on work that did not exist.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE DUAL-MODEL TIEBREAK (PHASE 4 M0, 2026-09-02). THIS CLASS NOW SKIPS DEALS THE
 *    CHECKLIST MODEL HAS CLAIMED. IT IS THE ONE SANCTIONED CHANGE TO THE LIVE TASK STACK.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `ChecklistRollupService` writes THE SAME FOUR Transaction__c counters from the
 * Checklist_Item__c model, and it already refuses to write them unless
 * Checklist_Fanned_Out__c is true. THAT GUARD WAS ONE-SIDED. Nothing stopped THIS class
 * recomputing all four from Task rows on any checklist-Task save, for ANY deal, INCLUDING one
 * already cut over. While no deal in the org carried the flag that was harmless; from Phase 4
 * step M1 both models are live on the same deal and it becomes LAST-WRITER-WINS, with the
 * loser being whichever model the UI happens to be rendering. The M2 reconciliation proves the
 * two AGREE at one instant; it is not a lock, and every subsequent Task edit re-runs the race.
 *
 * ✅ THE TIEBREAK: a deal whose Checklist_Fanned_Out__c is true is skipped here entirely.
 * Strictly narrowing — it can only ever cause FEWER writes, never a different value. No new
 * field, no report repoint, no LWC change. It inverts cleanly and completes the sentence the
 * other half of the guard started: THE TASK MODEL OWNS A DEAL UNTIL THE CHECKLIST MODEL CLAIMS
 * IT, AND Checklist_Fanned_Out__c IS THE CLAIM. That flag is written by exactly two callers
 * (ChecklistFanoutService and ChecklistMigrationService), so TestDataFactory and every seed
 * script are immune BY CONSTRUCTION rather than by a bypass flag.
 *
 * ⚠ WHAT IT COSTS, MEASURED RATHER THAN WAVED AT. This class had NO Transaction__c read at all
 * — it read only Task — so the guard is ONE EXTRA SOQL per recalc call. Two things make that a
 * wash or better:
 *   • THE GUARD READ GOES FIRST AND SHORT-CIRCUITS THE TASK READ. On a fully migrated deal
 *     recalc now costs 1 SOQL and 0 DML where it previously cost 1 SOQL and 1 DML. It is
 *     CHEAPER after cutover than before.
 *   • It reuses TransactionSelector.selectForChecklistFanout with an EMPTY condition set — the
 *     identical call ChecklistRollupService already makes for the identical purpose. No new
 *     selector method and no new field list.
 * Worst case is the dual-model window on a legacy deal: 2 SOQL instead of 1. The binding path
 * is the LEGACY DAY-0 FAN-OUT CASCADE, which is deliberately NOT suppressed on the Transaction
 * arm (TaskRollupTriggerHandler.recalcOnboardings gates only the Onboarding branch).
 * TaskFanoutQueueable.CHUNK_SIZE = 100 x 82 Tasks = 8,200 rows in ONE insert, fired
 * after-insert in ceil(8200/200) = 41 batches:
 *       today          41 SOQL / 41 DML statements
 *       with the guard 82 SOQL / 41 DML statements     (async limits: 200 SOQL / 150 DML)
 * 41% of the query budget: real, bounded, and TEMPORARY — it exists only while a deal is on
 * the Task model, and Phase 4 M3 stops creating such deals. Pinned by an IN-CONTEXT counter
 * assertion in TaskRollupDualModelGuardTest. ⚠ THAT PIN MEASURES ONE TRIGGER CHUNK (it asserts
 * the per-chunk cost is CONSTANT at 2 and does not grow with row or deal count); the 41-firing
 * cascade total above is ARITHMETIC ON TOP OF IT, not something any test executes. If it ever
 * became binding the
 * fix is to lower TaskFanoutQueueable.CHUNK_SIZE, a one-line change to a class M5 deletes.
 *
 * ⚠ KNOCK-ON, STATED SO IT IS NOT MET AS A BUG: scripts/seed-transaction-progress.apex calls
 * recalc directly and is now a no-op for any migrated deal. That is CORRECT (a migrated deal's
 * counters come from its items) and it is inert on a fresh demo org where nothing is migrated.
 * ⚠ ChecklistMigrationService.rollback must clear the flag BEFORE calling recalc, or this guard
 * skips the very recompute the rollback needs. Enforced by statement order in that one method.
 * 🔴 DELETE THIS GUARD WITH THE CLASS AT M5. Once nothing writes the counters from Tasks it is
 * a query on every recalc for a branch that can never be taken.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE `anti-fraud` SUBJECT PARSE AT `recalc` STAYS. IT IS NOT AN OVERSIGHT, AND REPOINTING
 *    IT TO `Is_Wire_Verification__c` WOULD NOT COMPILE — LET ALONE WORK.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * RISK 1 of the checklist rewrite (design §1) is that `Subject.toLowerCase().contains('anti-fraud')`
 * silently reads ZERO if the subject text is ever cleaned up, taking the Wire Sentinel dashboard
 * metric to "0 open wire risks" on every deal with no error anywhere. The fix is a real boolean
 * field — and the field is `Checklist_Item__c.Is_Wire_Verification__c`, on the NEW model.
 *
 * ⚠ THIS CLASS COUNTS `Task` ROWS, AND **`Task` HAS NO SUCH FIELD.** Verified 2026-09-01 against
 * `objects/Activity/fields/`: the Transaction-side custom fields there are `Task_Group__c`,
 * `Task_Sequence__c`, `Task_Owner_Label__c`, `Transaction_Deal__c`, `Conditional__c`,
 * `Blocked_By__c`, `Is_Prerequisite_Met__c`, `Verbal_Verification_Completed__c`,
 * `Verified_By__c`, `Verified_At__c`, `Verification_Phone__c`. There is no `Is_Wire_Verification__c`
 * and no `Is_Critical__c`. Adding them would mean adding two fields to the SHARED `Activity`
 * object (also owned by Property Management and Broker Protection), backfilling ~82 rows per live
 * deal, and granting FLS — all on a model that Phase 4/M5 retires. That work would be thrown away
 * by design.
 *
 * ✅ WHAT MAKES THAT SAFE — AND IT IS STRUCTURAL, NOT A PROMISE:
 *   1. A DEAL BORN ON THE NEW MODEL NEVER REACHES THIS CLASS. `recalc` is called only from
 *      `TaskRollupTrigger`, which fires on `Task`. `ChecklistFanoutService` creates zero `Task`
 *      rows, so such a deal has nothing that could fire it.
 *      🔴 AMENDED 2026-09-02 — THIS REASON WAS NEVER TRUE OF A **MIGRATED** DEAL, and saying so
 *      is the whole point of the tiebreak above. Phase 4 leaves the 82 `Task` rows in place by
 *      design, so a Task save on a migrated deal DOES reach this class. Reason 1 covers only
 *      deals created after M3; the tiebreak covers the rest.
 *   2. BOTH SERVICES WRITE THE SAME FOUR `Transaction__c` COUNTERS, so every downstream consumer
 *      (the Wire Sentinel tile, the eleven `reports/Transactions/**`, `transactionTaskCards`) is
 *      model-agnostic and needs no repoint.
 *   3. THE UI DISCRIMINATES ON `Transaction__c.Checklist_Fanned_Out__c`, the same flag that
 *      decides which model a deal is on, so the subject parse and the boolean read can never be
 *      applied to the wrong model's data.
 *
 * 🔴 THE ONE THING THAT WOULD BREAK THIS, STATED SO IT IS NOT REDISCOVERED THE HARD WAY:
 * cleaning the `(anti-fraud)` marker out of `Transaction_Task_Def__mdt.Subject__c` and re-running
 * `scripts/load-transaction-task-defs.apex` WHILE ANY DEAL IS STILL ON THE TASK MODEL. Existing
 * `Task` rows keep their frozen subjects and are unaffected, but any deal fanned out AFTER the
 * cleanup would get unmarked subjects and this line would count zero for it — silently, in the
 * safe-looking direction. DO NOT CLEAN THOSE SUBJECTS UNTIL M5 RETIRES THE TASK MODEL. On the new
 * model the markers are already cosmetic: `Is_Critical__c` / `Is_Wire_Verification__c` are seeded
 * from an explicit `{B2, F12, I7, J4}` / `{B2, I7}` key set in the loader, never from a parse.
 *
 * @see force-app/main/default/classes/ChecklistRollupService.cls (the new model's twin)
 * @see force-app/main/default/classes/ChecklistMigrationService.cls (Phase 4 M1)
 * @see agent-output/design-transaction-fsd-gaps.md §1 RISK 1, §6.1, §7
 * @see agent-output/phase4-migration-design.md §1
 */
public with sharing class TaskRollupService {

    /**
     * Deals skipped by the dual-model guard on the last `recalc` call.
     *
     * 🔴 CAPTURED INSIDE THE CALL, NOT AFTER IT. `Test.stopTest()` restores the pre-test governor
     * counters, so an assertion written after it measures nothing and passes vacuously. The same
     * hazard applies to any did-the-guard-fire assertion taken from outside an async context —
     * assert on this instead.
     */
    @TestVisible
    private static Integer lastRunSkippedDealCount = 0;

    /** SOQL consumed by the last `recalc` body. Same in-context capture rule as above. */
    @TestVisible
    private static Integer lastRunQueryCount = 0;

    /** DML statements consumed by the last `recalc` body. Same in-context capture rule. */
    @TestVisible
    private static Integer lastRunDmlCount = 0;

    /**
     * Recomputes the four legacy Transaction counters from the deal's checklist Task rows.
     *
     * @param txnIds Deals to recompute. Null/empty-safe; nulls inside are dropped. Deals whose
     *               `Checklist_Fanned_Out__c` is true are skipped — see the class header.
     * @example
     * TaskRollupService.recalc(new Set<Id>{ dealId });
     */
    public static void recalc(Set<Id> txnIds) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        lastRunSkippedDealCount = 0;
        try {
            recalcOwnedDeals(txnIds);
        } finally {
            lastRunQueryCount = Limits.getQueries() - queriesBefore;
            lastRunDmlCount = Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * The recompute itself, wrapped by `recalc` purely so the instrumentation above covers every
     * early return.
     *
     * @param txnIds Deals to recompute.
     */
    private static void recalcOwnedDeals(Set<Id> txnIds) {
        if (txnIds == null || txnIds.isEmpty()) {
            return;
        }
        Set<Id> owned = new Set<Id>(txnIds);
        owned.remove(null);
        if (owned.isEmpty()) {
            return;
        }

        // ── THE DUAL-MODEL TIEBREAK ──────────────────────────────────────────────────────
        // FIRST, and before the Task read, so a fully migrated deal costs 1 SOQL and 0 DML
        // rather than 1 SOQL and 1 DML. The full argument is in the class header.
        // ⚠ A deal ABSENT from this map is one the running user cannot SEE (the selector is
        // `with sharing`). It is deliberately treated as STILL OWNED BY THIS MODEL rather than
        // as claimed: skipping an unreadable deal would silently stop maintaining counters that
        // nothing else maintains. The subsequent write then fails LOUDLY for that deal, which is
        // the correct direction for a guard whose false negative is a wrong dashboard number.
        Map<Id, Transaction__c> deals = TransactionSelector.selectForChecklistFanout(
            owned, new Set<String>());
        Set<Id> claimed = new Set<Id>();
        for (Id dealId : owned) {
            Transaction__c deal = deals.get(dealId);
            if (deal != null && deal.Checklist_Fanned_Out__c == true) {
                claimed.add(dealId);
            }
        }
        if (!claimed.isEmpty()) {
            lastRunSkippedDealCount = claimed.size();
            owned.removeAll(claimed);
        }
        if (owned.isEmpty()) {
            return;
        }

        Map<Id, Integer> complete = new Map<Id, Integer>();
        Map<Id, Integer> overdue = new Map<Id, Integer>();
        Map<Id, Integer> wireOpen = new Map<Id, Integer>();
        for (Id tid : owned) {
            complete.put(tid, 0);
            overdue.put(tid, 0);
            wireOpen.put(tid, 0);
        }

        // Checklist tasks relate to the deal via Transaction_Deal__c (not WhatId), so this only
        // sees fan-out tasks — not ad-hoc Activities. Computed counts: closed, past-due-open, and
        // open anti-fraud wire-verification tasks (those drive the dashboard's Wire Sentinel).
        Date today = Date.today();
        for (Task t : TaskSelector.selectByTransactionDealIds(owned)) {
            Id d = t.Transaction_Deal__c;
            if (!complete.containsKey(d)) {
                // A Task on a deal the guard removed. Unreachable today (the read is filtered on
                // `owned`), and skipped rather than trusted if it ever becomes reachable.
                continue;
            }
            if (t.IsClosed) {
                complete.put(d, complete.get(d) + 1);
            } else if (t.ActivityDate != null && t.ActivityDate < today) {
                overdue.put(d, overdue.get(d) + 1);
            }
            Boolean isWire = t.Subject != null && t.Subject.toLowerCase().contains('anti-fraud');
            if (isWire && t.Verbal_Verification_Completed__c != true) {
                wireOpen.put(d, wireOpen.get(d) + 1);
            }
        }

        List<Transaction__c> updates = new List<Transaction__c>();
        for (Id tid : owned) {
            updates.add(new Transaction__c(Id = tid,
                Tasks_Complete__c = complete.get(tid),
                Tasks_Overdue__c = overdue.get(tid),
                Wire_Open_Risks__c = wireOpen.get(tid)));
        }
        // 🔴 EXPLICIT SYSTEM MODE — fixes a MEASURED production failure (AsyncApexJob
        // 707iw000003HEdIAAW, 2026-08-28T09:56:23Z, Status Failed):
        //
        //   CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY, TaskRollupTrigger: execution of AfterInsert
        //   caused by: System.TypeException: DML operation UPDATE not allowed on Transaction__c
        //
        // The bare `update updates;` that stood here ran in the CALLING USER's context. The whole
        // Day-0 chain — Opportunity 'About to Close' -> ContractExecutionService inserts the
        // Transaction__c -> Transaction_Task_Fanout flow (declares no runInMode) -> TaskFanoutService
        // -> TaskFanoutQueueable (a Queueable runs as the user who enqueued it) -> 82 Task inserts
        // -> THIS TRIGGER — never leaves the deal driver's identity. That user has no Edit on
        // Transaction__c: measured live 2026-08-28, ONLY DPEG_Transaction_Edit and
        // DPEG_Transaction_Team grant it, and the failing user held neither. So this statement
        // threw, the throw escaped the after-insert trigger, and the ENTIRE 82-row Task insert
        // rolled back — Tasks_Fanned_Out__c stayed false and ZERO checklist Tasks existed
        // org-wide, with nothing surfacing the failure to anyone.
        //
        // This is a rollup performed ON A PRINCIPAL'S BEHALF, not a write they requested — the
        // automation-path case ARCHITECTURE.md §2 describes, justified here at its own
        // declaration as that section requires.
        //
        // 🔴 THE PRECEDENT IS IN THIS SAME CHAIN. TaskFanoutService.fanOutNow already fixed
        // EXACTLY this for its own two statements (its header records the same measurement, dated
        // 2026-08-05); the trigger it cascades into was simply missed, so the repair stopped one
        // statement short and the failure moved downstream. Read the two together — they are a
        // pair, and neither is correct alone. OnboardingTaskRollupService.RollupWrites is the
        // sibling rollup's version of the same repair.
        //
        // ⚠ SCOPE — SYSTEM_MODE ONLY, DELIBERATELY NOT `without sharing`. SYSTEM_MODE lifts
        // CRUD/FLS and NEVER sharing, and that is the correct stopping point here:
        //   • Transaction__c is OWD Private, but ContractExecutionService inserts it WITHOUT
        //     setting OwnerId, so the owner defaults to the deal driver running this very
        //     transaction (verified: TXN-0267 is owned by the user whose job failed). On the
        //     reported path the running user IS the owner, so sharing is already satisfied and
        //     SYSTEM_MODE alone is sufficient.
        //   • The read side (TaskSelector, `with sharing`, deliberately and documentedly so) IS
        //     sharing-filtered. Making this write `without sharing` while the read stays filtered
        //     would let a principal who cannot see every checklist Task publish authoritative
        //     counters computed from a partial view — trading a loud failure for a silently wrong
        //     "N / 82" on the dashboard. That is a separate decision needing its own analysis; it
        //     is NOT a free hardening of this one.
        // RESIDUAL, KNOWN, NOT ADDRESSED HERE: a user who is neither the Transaction owner nor in
        // DPEG_Transactions_Team (the Transaction_Team_All_RW criteria rule) can still be denied
        // by SHARING when they edit a reassigned checklist Task. That path is unmeasured; do not
        // "fix" it by widening this statement without first resolving the read-side asymmetry.
        Database.update(updates, true, AccessLevel.SYSTEM_MODE);
    }
}
