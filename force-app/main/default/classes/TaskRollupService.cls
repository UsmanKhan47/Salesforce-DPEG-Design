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
 *   1. THE NEW MODEL NEVER REACHES THIS CLASS. `recalc` is called only from `TaskRollupTrigger`,
 *      which fires on `Task`. `ChecklistFanoutService` creates zero `Task` rows, so a deal on the
 *      new model has nothing that could fire it. Its counters come from `ChecklistRollupService`,
 *      which already keys on `Is_Wire_Verification__c` and never looks at a subject.
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
 * @see agent-output/design-transaction-fsd-gaps.md §1 RISK 1, §6.1, §7
 */
public with sharing class TaskRollupService {

    public static void recalc(Set<Id> txnIds) {
        if (txnIds == null || txnIds.isEmpty()) {
            return;
        }
        txnIds.remove(null);
        if (txnIds.isEmpty()) {
            return;
        }

        Map<Id, Integer> complete = new Map<Id, Integer>();
        Map<Id, Integer> overdue = new Map<Id, Integer>();
        Map<Id, Integer> wireOpen = new Map<Id, Integer>();
        for (Id tid : txnIds) {
            complete.put(tid, 0);
            overdue.put(tid, 0);
            wireOpen.put(tid, 0);
        }

        // Checklist tasks relate to the deal via Transaction_Deal__c (not WhatId), so this only
        // sees fan-out tasks — not ad-hoc Activities. Computed counts: closed, past-due-open, and
        // open anti-fraud wire-verification tasks (those drive the dashboard's Wire Sentinel).
        Date today = Date.today();
        for (Task t : TaskSelector.selectByTransactionDealIds(txnIds)) {
            Id d = t.Transaction_Deal__c;
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
        for (Id tid : txnIds) {
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