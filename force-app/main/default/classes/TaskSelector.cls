/**
 * Selector for the standard Task object. Encapsulates ALL SOQL against Task per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * ┌───────────────────────────────────────────────────────────────────────────┐
 * │ SHARED / CROSS-MODULE SELECTOR — THIS IS A CONTRACT, NOT A PRIVATE HELPER. │
 * └───────────────────────────────────────────────────────────────────────────┘
 * Task is the one genuinely cross-module object in the P4 selector rollout
 * (design §3 #18, §7, §10 flag 7). Two owners consume it:
 *
 *   • Transactions (owner, this module):
 *       - TransactionTaskController.getTaskGroups            -> selectChecklistByTransactionDealIds
 *       - TransactionTaskController.completeWireVerification -> selectRequiredById
 *   • Property Management (Module B, repoint is PM's job — NOT done here):
 *       - BrokerCheckInReminderSchedulable idempotency       -> selectOpenByWhatIdsAndSubjectPrefix
 *
 * The full public surface below is deliberately built NOW, in Transactions,
 * BEFORE PM repoints its Schedulable, so PM inherits a complete, stable
 * interface rather than having to grow this class later (design §7 sequencing:
 * "Transactions builds TaskSelector first; PM's repoint depends on it existing").
 * selectOpenByWhatIdsAndSubjectPrefix has no in-module consumer yet — that is
 * intentional; it is the pre-agreed PM contract, covered by its own test
 * (including the runAs USER_MODE proof), not dead code.
 *
 * MODE — every query uses `WITH USER_MODE` (API 67). Design §5 measured this
 * live: the only FLS-bearing standard Task fields in scope
 * (ActivityDate / Description / WhatId / WhoId) are all Standard User READ=true,
 * so USER_MODE returns rows for the internal personas here. Custom Task fields
 * (Task_Group__c, Task_Sequence__c, Task_Owner_Label__c, Verbal_Verification_*,
 * Verified_By__c/At__c, Verification_Phone__c) rely on the deployed permsets
 * (P3: custom-field FLS gap = 0). There is NO guest/automation path on Task, so
 * NO `SYSTEM_MODE` appears here.
 *
 * NOT-FOUND CONTRACT is per-caller (pilot WireSelector pattern):
 *   - list reads (checklist / open-reminders) : missing rows are normal ->
 *     return an EMPTY List, never null.
 *   - fetch-for-update (selectRequiredById)    : the caller passed a specific Id
 *     it expects to exist; a miss is an error -> single-row SOQL assignment lets
 *     the native System.QueryException fly (matches the old inline query).
 *
 * BULK SHAPE — the child-by-parent reads take a `Set<Id>` and return a `List`,
 * so both consumers work in bulk (TransactionTaskController passes a singleton
 * set; PM's Schedulable passes N overdue-assignment Ids). Getting this shape
 * right is the whole reason Transactions owns Task first.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (P4 pilot template)
 * @see agent-output/p4-selector-design.md (§3 #18, §4, §5, §7)
 */
public with sharing class TaskSelector {

    /**
     * Day-0 checklist Tasks for one or more Transactions, ordered by
     * Task_Sequence__c. Backs TransactionTaskController.getTaskGroups (which
     * passes a single Transaction Id as a singleton set and buckets the rows by
     * Task_Group__c). Checklist Tasks attach via the custom Transaction_Deal__c
     * lookup (not WhatId) and always carry a Task_Group__c, so the WHERE mirrors
     * the original inline query exactly (`Task_Group__c != null`).
     *
     * Static SOQL (not dynamic): the field set is fixed and has a single caller,
     * so the query is inlined and `WITH USER_MODE` sits after the WHERE and BEFORE
     * ORDER BY — the clause order the pilot flagged as a compile-breaker.
     *
     * @param transactionDealIds Transaction__c Ids whose checklist Tasks to load.
     * @return Matching Tasks ordered by Task_Sequence__c; an empty list when the
     *         input is null/empty or no checklist Tasks exist (never null).
     * @example
     * List<Task> rows = TaskSelector.selectChecklistByTransactionDealIds(new Set<Id>{ txnId });
     */
    public static List<Task> selectChecklistByTransactionDealIds(Set<Id> transactionDealIds) {
        if (transactionDealIds == null || transactionDealIds.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Id, Subject, Task_Group__c, Task_Owner_Label__c, Status, IsClosed,
                   ActivityDate, Task_Sequence__c, Verbal_Verification_Completed__c,
                   Verified_By__c, Verified_At__c, Verification_Phone__c, Description, LastModifiedDate
            FROM Task
            WHERE Transaction_Deal__c IN :transactionDealIds AND Task_Group__c != null
            WITH USER_MODE
            ORDER BY Task_Sequence__c
        ];
    }

    /**
     * Open Tasks whose WhatId is in the supplied set and whose Subject begins with
     * `subjectPrefix`. This is the idempotency probe for PM's
     * BrokerCheckInReminderSchedulable ("does this assignment already have an open
     * 'Check in with broker%' reminder?"). Selects Id + WhatId only — the caller
     * builds a Set of WhatIds from the result (design §4: selectors return
     * SObjects; the caller derives its own collection).
     *
     * The subject match is a bound LIKE (`subjectPrefix + '%'`), so it is
     * injection-safe even though the prefix is caller-supplied.
     *
     * @param whatIds       Parent (WhatId) record Ids to probe (e.g. Broker_Assignment__c Ids).
     * @param subjectPrefix Leading text the Task Subject must start with; the '%' is added here.
     * @return Open Tasks (IsClosed = false) matching both filters; an empty list
     *         when whatIds is null/empty or subjectPrefix is blank (never null).
     * @example
     * List<Task> open = TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(
     *     assignmentIds, 'Check in with broker');
     */
    public static List<Task> selectOpenByWhatIdsAndSubjectPrefix(Set<Id> whatIds, String subjectPrefix) {
        if (whatIds == null || whatIds.isEmpty() || String.isBlank(subjectPrefix)) {
            return new List<Task>();
        }
        String subjectPattern = subjectPrefix + '%';
        return [
            SELECT Id, WhatId
            FROM Task
            WHERE WhatId IN :whatIds
              AND IsClosed = false
              AND Subject LIKE :subjectPattern
            WITH USER_MODE
        ];
    }

    /**
     * Fetches exactly one Task by Id for the wire-verification update path
     * (backs TransactionTaskController.completeWireVerification). Uses a single-row
     * SOQL assignment with LIMIT 1: when the Id resolves to no row, Apex throws
     * System.QueryException ("List has no rows for assignment to SObject"),
     * preserving the caller contract that a missing target is an error.
     *
     * FIELD SET IS DELIBERATE: `Id, Description`. completeWireVerification reads
     * Description on the returned record to decide whether to append the standard
     * verification note; a `SELECT Id`-only query would reintroduce a
     * `System.SObjectException` on that access. Do not narrow this field list.
     *
     * @param taskId Task Id to load for update; must reference an existing row.
     * @return The Task with Id and Description populated.
     * @throws System.QueryException when no Task matches the Id.
     */
    public static Task selectRequiredById(Id taskId) {
        return [
            SELECT Id, Description
            FROM Task
            WHERE Id = :taskId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P4 Onboarding + Task-rollup cleanup wave — additional Task query surface.
    // These relocate inline SOQL out of OnboardingController,
    // OnboardingTaskRollupService, TaskRollupService, and DispositionTaskController.
    // None of the three methods above fit those callers (different field sets and
    // filters — see each method's doc), so each caller gets a purpose-built method
    // rather than an overload of an existing one.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Onboarding checklist Tasks for one Onboarding__c, grouped/ordered for the
     * PM checklist LWC. Backs OnboardingController.getChecklist, which buckets the
     * rows by Onboarding_Category__c. Single-parent child read (design §4
     * `selectByParentId(Id)` shape) — the checklist is always rendered for exactly
     * one Onboarding record page, so no `Set<Id>` overload is added (a dead bulk
     * method would violate the one-change-one-reason scope, per the WireSelector
     * pilot).
     *
     * ORDER BY Onboarding_Category__c, ActivityDate NULLS LAST mirrors the original
     * inline query so the caller's category bucketing and within-bucket ordering
     * are unchanged. `WITH USER_MODE` sits after the WHERE and before ORDER BY.
     *
     * @param onboardingId Onboarding__c Id whose checklist Tasks to load.
     * @return Matching Tasks ordered by category then due date; an empty list when
     *         onboardingId is null or the Onboarding has no checklist Tasks (never null).
     * @example
     * for (Task t : TaskSelector.selectChecklistByOnboardingId(onboardingId)) { ... }
     */
    public static List<Task> selectChecklistByOnboardingId(Id onboardingId) {
        if (onboardingId == null) {
            return new List<Task>();
        }
        return [
            SELECT Id, Subject, Onboarding_Category__c, Onboarding_Status__c, Source_System__c,
                   Task_Owner_Label__c, ActivityDate, Blocked_Reason__c, Description
            FROM Task
            WHERE Onboarding__c = :onboardingId
            WITH USER_MODE
            ORDER BY Onboarding_Category__c, ActivityDate NULLS LAST
        ];
    }

    /**
     * Fetches exactly one Task by Id for the onboarding-checklist completion path
     * (backs OnboardingController.completeTask, which mutates and updates the
     * returned record, then rolls the change up onto the parent Onboarding__c).
     * Single-row SOQL assignment with LIMIT 1: a missing Id raises
     * System.QueryException, preserving the caller contract that the checkbox click
     * targets a Task that exists.
     *
     * FIELD SET IS DELIBERATE and DISTINCT from selectRequiredById (which selects
     * only Id, Description for the wire path). completeTask additionally reads
     * Onboarding__c (to decide which parent to recalc), Onboarding_Status__c and
     * Status (to flip them), and Description (to append the note). Reusing
     * selectRequiredById here would throw System.SObjectException on the first of
     * those extra-field reads — which is why this is its own method, not a widening
     * of the shared wire-path method.
     *
     * @param taskId Task Id to load for update; must reference an existing row.
     * @return The Task with Id, Onboarding__c, Onboarding_Status__c, Status and
     *         Description populated.
     * @throws System.QueryException when no Task matches the Id.
     */
    public static Task selectForOnboardingCompletion(Id taskId) {
        return [
            SELECT Id, Onboarding__c, Onboarding_Status__c, Status, Description
            FROM Task
            WHERE Id = :taskId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Checklist Tasks for one or more Onboarding__c parents, for the summary/rollup
     * recompute. Backs OnboardingTaskRollupService.recalc, which aggregates the
     * rows in memory into the Tasks_* counters on each Onboarding__c. Bulk
     * `Set<Id>` in / `List` out so the service processes many parents in a single
     * query (no SOQL-in-loop), matching the original inline query's
     * `WHERE Onboarding__c IN :onboardingIds`.
     *
     * Narrow field set (Onboarding__c, Onboarding_Status__c, ActivityDate) — the
     * only fields the rollup arithmetic reads. `WITH USER_MODE`: the recompute runs
     * for internal PM personas; the sole FLS-bearing standard field here
     * (ActivityDate) is Standard User READ=true per design §5.
     *
     * @param onboardingIds Onboarding__c Ids whose checklist Tasks to load.
     * @return Matching Tasks; an empty list when the input is null/empty or no
     *         checklist Tasks exist (never null).
     * @example
     * List<Task> rows = TaskSelector.selectByOnboardingIds(onboardingIds);
     */
    public static List<Task> selectByOnboardingIds(Set<Id> onboardingIds) {
        if (onboardingIds == null || onboardingIds.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Onboarding__c, Onboarding_Status__c, ActivityDate
            FROM Task
            WHERE Onboarding__c IN :onboardingIds
            WITH USER_MODE
        ];
    }

    /**
     * ALL checklist Tasks for one or more Transactions (via the custom
     * Transaction_Deal__c lookup), for the transaction rollup recompute. Backs
     * TaskRollupService.recalc, which counts closed / past-due-open / open
     * anti-fraud wire-verification Tasks per deal.
     *
     * DISTINCT from selectChecklistByTransactionDealIds above: that method is for
     * the checklist UI and (a) adds `AND Task_Group__c != null`, (b) does NOT
     * select Transaction_Deal__c, and (c) orders by Task_Sequence__c. The rollup
     * needs Transaction_Deal__c (to key its per-deal maps) and must NOT impose the
     * Task_Group__c filter — the original rollup query had no such filter, and
     * introducing one would silently change the counts for any fan-out Task lacking
     * a group. So this is a separate, unfiltered, rollup-shaped read, not a reuse
     * of the checklist method.
     *
     * @param transactionDealIds Transaction__c Ids whose Tasks to load.
     * @return Matching Tasks (Transaction_Deal__c, IsClosed, ActivityDate, Subject,
     *         Verbal_Verification_Completed__c); an empty list when the input is
     *         null/empty or no Tasks exist (never null).
     * @example
     * List<Task> rows = TaskSelector.selectByTransactionDealIds(txnIds);
     */
    public static List<Task> selectByTransactionDealIds(Set<Id> transactionDealIds) {
        if (transactionDealIds == null || transactionDealIds.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Transaction_Deal__c, IsClosed, ActivityDate, Subject, Verbal_Verification_Completed__c
            FROM Task
            WHERE Transaction_Deal__c IN :transactionDealIds
            WITH USER_MODE
        ];
    }

    /**
     * Tasks under one WhatId whose Subject is in the supplied list. Backs BOTH
     * SOQL sites in DispositionTaskController.getClosingTasks — the pre-insert
     * existence probe (reads Subject only) and the post-insert map build (reads
     * Id / Subject / IsClosed / LastModifiedDate). One method serves both because
     * they are the same query shape at two points in the find-or-create lifecycle;
     * the two call sites remain two separate query executions (the second re-reads
     * rows created by the insert between them).
     *
     * FIELD SET IS DELIBERATE: `Id, Subject, IsClosed, LastModifiedDate`. The
     * map-build caller computes `completedDate = IsClosed ? LastModifiedDate : null`
     * (the guard that fixed the stale-completion-date defect where
     * Task.CompletedDateTime is auto-stamped on close but never cleared on reopen).
     * Dropping LastModifiedDate here would reintroduce a System.SObjectException on
     * that read; the `IsClosed ? :` guard itself stays in the controller. Do NOT
     * narrow this field list. The existence probe over-selects three harmless
     * fields (it reads only Subject) — an acceptable trade for a single shared
     * query shape.
     *
     * @param whatId   Parent (WhatId) record Id to scope Tasks to (e.g. Disposition__c Id).
     * @param subjects Task Subjects to match (the closing-checklist subject list).
     * @return Matching Tasks; an empty list when whatId is null or subjects is
     *         null/empty (never null).
     * @example
     * for (Task t : TaskSelector.selectByWhatIdAndSubjects(dispositionId, SUBJECTS)) { ... }
     */
    public static List<Task> selectByWhatIdAndSubjects(Id whatId, List<String> subjects) {
        if (whatId == null || subjects == null || subjects.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Id, Subject, IsClosed, LastModifiedDate
            FROM Task
            WHERE WhatId = :whatId AND Subject IN :subjects
            WITH USER_MODE
        ];
    }
}
