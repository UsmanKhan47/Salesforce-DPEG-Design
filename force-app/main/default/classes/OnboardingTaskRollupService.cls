/**
 * Recomputes the twelve summary/rollup fields on `Onboarding__c` from its checklist
 * Tasks (counts per status, open / overdue / stalled / due-in-7-days, and
 * Completion_Pct__c). `Task` is a lookup child of `Onboarding__c`, not
 * master-detail, so no roll-up summary field is possible and no formula can
 * aggregate the children — this service is the only way these numbers move.
 *
 * ═══ 🔴 AMENDED 2026-08-22 — THE CALLER SET CHANGED, AND THAT MADE THE OLD DML
 * UNSAFE ═══
 * Until this change `recalc` had exactly one caller: `OnboardingService.completeTask`,
 * i.e. a property manager ticking a box on their own checklist in the Onboarding LWC.
 * Its last line was a bare `update upd.values();`, and that worked ONLY because of
 * who was running it.
 *
 * `TaskRollupTriggerHandler` now routes `Onboarding__c` on all four after-contexts,
 * so this method fires for **any** user who inserts, updates, deletes or undeletes
 * **any** Task carrying an `Onboarding__c` — including the fan-out job creating 4,500
 * checklist rows, and including a deal driver whose Closed Won save cascaded all the
 * way down here. Two independent things had to be fixed for that to be safe, and they
 * are separate decisions:
 *
 *   1. CRUD/FLS — `AccessLevel.SYSTEM_MODE`. `Onboarding__c`'s counter fields are
 *      Metadata-API-deployed custom fields, which arrive with NO FLS for any profile
 *      (System Administrator included) until a permission set grants them. A
 *      user-mode write throws `System.TypeException`, which inside a trigger escapes
 *      as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolls back the user's own save.
 *
 *   2. SHARING — the `RollupWrites` inner class. `SYSTEM_MODE` lifts CRUD and FLS and
 *      **NEVER** sharing. `Onboarding__c` is Private OWD
 *      (`Onboarding__c.object-meta.xml`), shared by ONE criteria rule to
 *      `DPEG_Property_Mgmt_Team` where `Status__c != ''`. Under `with sharing` a
 *      write by anyone outside that group — or against a row with a blank Status —
 *      simply does not apply. This project already has a live incident of exactly
 *      that shape: an approval's parent write failed silently for every approver who
 *      did not OWN the record, worked in every test because the test's approver WAS
 *      the owner, and was swallowed by `allOrNone = false`.
 *
 * `allOrNone = true` so this can never fail silently again. If the write is genuinely
 * impossible the caller's save fails loudly, which is the correct outcome for a
 * rollup that the dashboard, the KPIs and the risk alerts all read.
 *
 * ⚠ `OnboardingService.completeTask` no longer calls this method. With the trigger
 * routing in place its `update t` fires the after-update context on the same Task, so
 * an explicit call would recompute twice per click.
 *
 * All SOQL is delegated to `TaskSelector.selectByOnboardingIds` (already
 * `WITH SYSTEM_MODE`, for the same automation-path reason). This service holds none.
 *
 * BULK SHAPE: one selector call and one DML statement per invocation regardless of
 * how many Onboardings are passed. Never call it per record.
 *
 * @see force-app/main/default/classes/TaskRollupTriggerHandler.cls (the new caller)
 * @see force-app/main/default/classes/TaskSelector.cls (all SOQL)
 */
public with sharing class OnboardingTaskRollupService {

    // ═════════════════════════════════════════════════════════════════════════════
    // 🔴 THE FAN-OUT RE-ENTRANCY SWITCH — ADDED 2026-08-22
    //
    // Suppresses the TRIGGER-driven recalc only. `recalc` itself is never gated: a
    // caller that asks for a recompute always gets one.
    //
    // WHY IT EXISTS. `OnboardingFanoutService.fanOutNow` inserts CHUNK_SIZE x 45 =
    // 4,500 checklist Tasks in ONE `Database.insert`. Salesforce fires after-insert
    // in 200-row batches, so that single statement fires `TaskRollupTriggerHandler`
    // ceil(4500/200) = 23 times, and each firing spends one SOQL
    // (`TaskSelector.selectByOnboardingIds`) and one DML — 23 SOQL + 23 DML against
    // limits of 100 and 150, to compute counters for rows that are all being created
    // by the same statement. Twenty-two of those twenty-three results are thrown away
    // by the next batch.
    //
    // ⚠ SUPPRESSING IS ONLY HALF THE FIX, AND THE OTHER HALF IS NOT OPTIONAL.
    // `fanOutNow` writes `Tasks_Total__c` itself but NONE of the other eleven
    // counters. Suppressing the cascade without a replacement would leave a freshly
    // fanned-out Onboarding reading "45 total, 0 open, 0 not started, 0% complete" on
    // the PM dashboard (`OnboardingController` reads Tasks_Open__c,
    // Tasks_Not_Started__c, Tasks_Due_7d__c and Completion_Pct__c) until somebody
    // happened to edit a Task. So `fanOutNow` calls `recalc` ONCE per chunk, itself,
    // after the insert — 1 SOQL + 1 DML, constant, instead of 23 + 23.
    //
    // SCOPE: onboarding rollups only. `TaskRollupService` (Transaction__c) is NOT
    // gated by this flag, and fan-out Tasks carry a null `Transaction_Deal__c`
    // anyway. The flag is transaction-scoped static state, set and restored in a
    // `finally` by the one production caller, and defaults false so every other path
    // — standard UI edit, API, Data Loader, delete, undelete — is untouched.
    // ═════════════════════════════════════════════════════════════════════════════

    /** False except inside `OnboardingFanoutService.fanOutNow`'s DML window. */
    @TestVisible
    private static Boolean triggerRecalcSuppressed = false;

    /**
     * Whether the TRIGGER should skip its onboarding recalc right now. Read by
     * `TaskRollupTriggerHandler.recalcOnboardings` and by nothing else.
     *
     * @return true while a fan-out owns the recompute for this transaction.
     */
    public static Boolean isTriggerRecalcSuppressed() {
        return triggerRecalcSuppressed;
    }

    /**
     * Sets the trigger-recalc suppression flag.
     *
     * ⚠ A caller that sets this to true TAKES OWNERSHIP of recomputing the affected
     * Onboardings and MUST restore the previous value in a `finally`. Leaving it set
     * silently disables every onboarding rollup for the rest of the transaction.
     *
     * @param suppressed true to suppress; null is treated as false.
     */
    public static void suppressTriggerRecalc(Boolean suppressed) {
        triggerRecalcSuppressed = (suppressed == true);
    }

    /**
     * Recomputes the summary/rollup fields on each `Onboarding__c` from its
     * checklist Tasks.
     *
     * ⚠ NEVER gated by `triggerRecalcSuppressed` — that flag stops the TRIGGER from
     * calling this method, not this method from doing its job. `fanOutNow` sets the
     * flag and then calls straight in here.
     *
     * @param onboardingIds Onboarding__c ids to recompute; null/empty-safe.
     */
    public static void recalc(Set<Id> onboardingIds) {
        if (onboardingIds == null || onboardingIds.isEmpty()) return;
        Date today = Date.today();
        Date stalledCutoff = today.addDays(-7);
        Date due7dEnd = today.addDays(7);

        Map<Id, Onboarding__c> upd = new Map<Id, Onboarding__c>();
        for (Id oid : onboardingIds) {
            upd.put(oid, new Onboarding__c(Id=oid,
                Tasks_Total__c=0, Tasks_Complete__c=0, Tasks_In_Progress__c=0, Tasks_Not_Started__c=0,
                Tasks_Blocked__c=0, Tasks_NA__c=0, Tasks_Open__c=0, Tasks_Overdue__c=0,
                Tasks_Blocked_Now__c=0, Tasks_Stalled__c=0, Tasks_Due_7d__c=0, Completion_Pct__c=0));
        }

        for (Task t : TaskSelector.selectByOnboardingIds(onboardingIds)) {
            Onboarding__c o = upd.get(t.Onboarding__c);
            if (o == null) continue;
            String st = t.Onboarding_Status__c;
            o.Tasks_Total__c += 1;
            Boolean isComplete = (st == 'Complete');
            Boolean isNA = (st == 'Not Applicable');
            if (isComplete) o.Tasks_Complete__c += 1;
            else if (st == 'In Progress') o.Tasks_In_Progress__c += 1;
            else if (st == 'Not Started') o.Tasks_Not_Started__c += 1;
            else if (st == 'Blocked') { o.Tasks_Blocked__c += 1; o.Tasks_Blocked_Now__c += 1; }
            if (isNA) o.Tasks_NA__c += 1;
            Boolean isOpen = (!isComplete && !isNA);
            if (isOpen) o.Tasks_Open__c += 1;
            if (isOpen && t.ActivityDate != null && t.ActivityDate < today) o.Tasks_Overdue__c += 1;
            if (st == 'In Progress' && t.ActivityDate != null && t.ActivityDate < stalledCutoff) o.Tasks_Stalled__c += 1;
            if (isOpen && t.ActivityDate != null && t.ActivityDate >= today && t.ActivityDate <= due7dEnd) o.Tasks_Due_7d__c += 1;
        }

        for (Onboarding__c o : upd.values()) {
            Decimal tot = (o.Tasks_Total__c == null) ? 0 : o.Tasks_Total__c;
            Decimal comp = (o.Tasks_Complete__c == null) ? 0 : o.Tasks_Complete__c;
            o.Completion_Pct__c = (tot > 0) ? (Integer) Math.round(100 * comp / tot) : 0;
        }
        // 🔴 SYSTEM_MODE **and** without sharing — two separate reasons, both in the
        // class header. Do not collapse them: SYSTEM_MODE alone leaves this write
        // silently inapplicable for every user outside DPEG_Property_Mgmt_Team.
        new RollupWrites().commitRollups(upd.values());
    }

    /**
     * 🔴 THE ROLLUP WRITE, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * Scoped as narrowly as Apex allows: `private`, one method, one statement, reached
     * only from `recalc` above. Inner classes do NOT inherit the outer class's sharing,
     * so this is declared explicitly and `OnboardingTaskRollupService` itself STAYS
     * `with sharing`. It writes ONLY derived counters onto `Onboarding__c` — no field a
     * user supplied, nothing read back, nothing returned to a caller — so it cannot
     * leak a row the running user could not otherwise see.
     *
     * PRECEDENT: `PropertyAssetSelector.AssetCreationReads`,
     * `OnboardingSelector.IdempotencyReads`.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new RollupWrites()` at the call site.
     */
    private without sharing class RollupWrites {

        /**
         * Persists the recomputed counters.
         *
         * @param records Onboarding__c records carrying Id + the twelve counters.
         * @throws System.DmlException on a platform save failure (allOrNone = true, by design).
         */
        private void commitRollups(List<Onboarding__c> records) {
            if (records == null || records.isEmpty()) {
                return;
            }
            Database.update(records, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
