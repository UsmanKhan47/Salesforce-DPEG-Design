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
}
