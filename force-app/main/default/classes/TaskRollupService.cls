/**
 * Rolls the count of completed (closed) Tasks for a Transaction up to
 * Transaction__c.Tasks_Complete__c, which drives the "N / 75" highlights tile.
 * Invoked from TaskRollupTrigger.
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