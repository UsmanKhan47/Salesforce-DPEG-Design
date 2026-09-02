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
 * ┌───────────────────────────────────────────────────────────────────────────┐
 * │ MODE INVENTORY — THIS CLASS DELIBERATELY MIXES USER_MODE AND SYSTEM_MODE.  │
 * └───────────────────────────────────────────────────────────────────────────┘
 * DEFAULT IS `WITH USER_MODE` (API 67) — every method NOT named below uses it, and
 * that is the reads a human asked for. Design §5 measured this live: the only
 * FLS-bearing standard Task fields in scope (ActivityDate / Description / WhatId /
 * WhoId) are all Standard User READ=true, so USER_MODE returns rows for the internal
 * personas driving those reads. Custom Task fields (Task_Group__c, Task_Sequence__c,
 * Task_Owner_Label__c, Verbal_Verification_*, Verified_By__c/At__c,
 * Verification_Phone__c) rely on the deployed permsets (P3: custom-field FLS gap = 0).
 *
 * SIX methods are `WITH SYSTEM_MODE` (FOUR until 2026-08-31, FIVE until 2026-09-02). Each carries its own
 * justification at its own declaration; all six sit on an AUTOMATION PATH, where
 * `USER_MODE` THROWS rather than degrades and so converts one missing FLS grant into a
 * broken write:
 *
 *   EAC capture pipeline (added 2026-08-02)
 *     • selectByIds                        <- EmailThreadGuardService
 *     • selectThreadAnchorsByAnchorValues  <- EmailThreadAnchorService (guard+adopter)
 *   Rollup recomputes — PLATFORM-DRIVEN, NOT USER-REQUESTED (added 2026-08-05).
 *   ⚠ The two entries below rest on DIFFERENT evidence; do not read the second as
 *   inheriting the first's. Only ONE of them fixes an observed failure:
 *     • selectByTransactionDealIds         <- TaskRollupService, fired by
 *       TaskRollupTrigger (after-insert). REPRODUCED PRODUCTION FAILURE — a USER_MODE
 *       FLS denial here rolled back an entire 82-Task Day-0 fan-out.
 *     • selectByOnboardingIds              <- OnboardingTaskRollupService.recalc,
 *       called DIRECTLY by OnboardingService.completeTask (no trigger involved).
 *       PROSPECTIVE ONLY — inert on today's live path, because an earlier USER_MODE
 *       read in that same method throws first. See the method's own Javadoc.
 *   Wire-fraud prerequisite gate — BEFORE-TRIGGER, USER-SAVE-ROLLING-BACK (added 2026-08-31).
 *     • selectChecklistByDealsAndSequences <- TaskPrerequisiteService, fired by
 *       TaskRollupTrigger (before-update). Same class of failure as
 *       selectByTransactionDealIds above, one context earlier: a USER_MODE FLS denial on
 *       the brand-new `Blocked_By__c` field would abort the SAVING USER'S OWN update of a
 *       checklist item. Not an observed failure — a structurally identical one, on a field
 *       that by construction has zero FieldPermissions on the day it deploys.
 *   Phase 4 checklist migration — QUEUEABLE CHAIN + READ-ONLY AUDIT (added 2026-09-02).
 *     • selectForChecklistMigration        <- ChecklistMigrationService (a Queueable chunk) and
 *       ChecklistMigrationAuditService (the M2 reconciliation, driven from a script). Reads
 *       NINE custom Activity fields at once (plus eight standard ones) - exactly the nine that design
 *       §8 lists as Transaction-only - so it is the widest FLS surface in this class and
 *       the one most certain to throw under USER_MODE. PROSPECTIVE in the sense that it has no
 *       live caller until the migration is run, but structurally identical to
 *       selectByTransactionDealIds, whose failure WAS reproduced. 🔴 RETIRED AT M5 — remove this
 *       entry in the same change.
 *
 * ⚠ AMENDED 2026-08-02 — the statement "There is NO guest/automation path on Task,
 * so NO `SYSTEM_MODE` appears here" was true when written and is NO LONGER TRUE.
 * Enabling Einstein Activity Capture introduced exactly such a path: EAC inserts an
 * EmailMessage, EmailMessageTrigger enqueues EmailCaptureQueueable, and
 * EmailThreadGuardService / EmailThreadAdopterService read Task as whichever
 * principal EAC committed under
 * (the connected-mailbox user, or Automated Process) — a principal this repo's
 * permission sets never provision.
 *
 * ⚠ AMENDED 2026-08-05 — the two ROLLUP reads joined the SYSTEM_MODE group for the
 * SAME automation-path reason, established by a production failure rather than by
 * analogy. A Transaction__c created with Contract_Executed_Date__c set ran the Day-0
 * fan-out, which inserted its 82 checklist Tasks; TaskRollupTrigger fired
 * after-insert; TaskRollupService called selectByTransactionDealIds; and its
 * USER_MODE query threw `No such column 'Transaction_Deal__c' on entity 'Task'` —
 * the platform's wording for an FLS DENIAL, not a missing field (it exists:
 * objects/Activity/fields/Transaction_Deal__c.field-meta.xml). The throw escaped the
 * trigger as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolled back all 82 inserts,
 * leaving the Day-0 checklist — the core of the Transaction module — UNBUILDABLE BY
 * ANY NON-ADMIN. Every DPEG persona is on `Minimum Access - Salesforce`, which grants
 * no FLS whatsoever; all access comes from permission sets, so ONE ungranted custom
 * field is enough to break an unrelated write. selectByOnboardingIds was moved in the
 * same change for CONSISTENCY AND FUTURE CALLERS ONLY — it is NOT a second instance
 * of this defect and could not have produced one (its live caller throws earlier); the
 * distinction is spelled out in that method's Javadoc so nobody cites it as evidence.
 *
 * ⚠ SCOPE OF THE BYPASS — THIS IS WHAT MAKES IT SAFE. `SYSTEM_MODE` bypasses FLS and
 * CRUD ONLY. It does NOT bypass sharing: this class stays `with sharing`, so every
 * SYSTEM_MODE method still returns only rows the running user can already see. The
 * change removes a field-level failure mode without widening record visibility by a
 * single row.
 *
 * Do not "harmonize" the two groups — they answer questions for different principals.
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
     * SPANNING READ — `LastModifiedById, LastModifiedBy.Name` (added 2026-08-28).
     * The checklist row's completion line used to render Task_Owner_Label__c (the STATIC
     * ROLE seeded from Transaction_Task_Def__mdt: 'Danish', 'CFO', 'Legal'...) next to the
     * completion date, which read as "completed by <role>" and was FALSE for everyone
     * except the one person that role names. The row now names the actual last modifier.
     * ⚠ Task has NO dedicated completed-by field; LastModifiedBy is "who last touched the
     * record", so a later edit to a closed task reassigns the name. See
     * TransactionTaskController.getTaskGroups for the trade-off note at the assignment site.
     *
     * WHY THIS IS SAFE UNDER `WITH USER_MODE` (MEASURED in usman-dpeg 2026-08-28, not
     * assumed — USER_MODE THROWS "No such column" on an FLS denial, it does not degrade):
     *   - `Task.LastModifiedById.getDescribe().isPermissionable()` = FALSE, and
     *     `SELECT COUNT() FROM FieldPermissions WHERE Field = 'Task.LastModifiedById'` = 0.
     *     No permission set can grant OR deny it — it is readable whenever Task is.
     *   - `User.Name.getDescribe().isPermissionable()` = FALSE — same story.
     *   - `EntityDefinition.InternalSharingModel` for User = 'Read' (Public Read Only), so
     *     the traversal resolves for every internal persona on this page (DPEG_Transaction_Edit
     *     / DPEG_Transaction_View holders and the read-only acquisitions PSGs).
     * A tightened User OWD, or an Experience Cloud (external) reader, would return a null
     * `LastModifiedBy` — which the controller tolerates: the name drops off the row rather
     * than throwing. Re-measure the three facts above if User OWD is ever tightened.
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
                   Verified_By__c, Verified_At__c, Verification_Phone__c, Description,
                   LastModifiedDate, LastModifiedById, LastModifiedBy.Name
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
     * only fields the rollup arithmetic reads.
     *
     * ⚠ `WITH SYSTEM_MODE` — CHANGED 2026-08-05, and the rationale it replaced was
     * WRONG, not merely outdated. That rationale read: "`WITH USER_MODE`: the
     * recompute runs for internal PM personas; the sole FLS-bearing standard field
     * here (ActivityDate) is Standard User READ=true per design §5." Both halves
     * fail. It accounted only for STANDARD fields, but Onboarding__c and
     * Onboarding_Status__c are CUSTOM fields that need FLS of their own; and it
     * assumed a Standard User profile, whereas every DPEG persona is on
     * `Minimum Access - Salesforce`, which grants no FLS at all — all access comes
     * from permission sets. Taken IN ISOLATION, a persona missing either custom
     * grant would make this query throw `No such column ... on entity 'Task'` — the
     * platform's wording for an FLS DENIAL rather than a missing field. In practice
     * that throw is pre-empted upstream; see the next paragraph, which is the part
     * that matters.
     *
     * ⚠ THIS CHANGE IS PROSPECTIVE — IT FIXES NOTHING ON TODAY'S LIVE PATH, AND
     * SAYING OTHERWISE WOULD MISLEAD THE NEXT READER. Unlike
     * selectByTransactionDealIds below (a REPRODUCED production failure), the
     * Onboarding rollup CANNOT reach that failure today, because its only production
     * caller reads the same custom fields under USER_MODE first and throws there:
     *
     *   OnboardingService.completeTask
     *     -> TaskSelector.selectForOnboardingCompletion  // USER_MODE; SELECTs
     *                                                    // Onboarding__c + Onboarding_Status__c
     *     -> update t
     *     -> OnboardingTaskRollupService.recalc -> THIS METHOD
     *
     * A persona lacking FLS on those two custom fields throws at the FIRST read and
     * never reaches the recompute. Same story upstream: selectChecklistByOnboardingId
     * (also USER_MODE) both SELECTs and FILTERS on them, so a user who cannot render
     * the checklist cannot click the checkbox that starts this chain either.
     *
     * ⚠ COROLLARY — DO NOT READ THIS AS "ONBOARDING IS NOW NON-ADMIN-SAFE." IT IS
     * NOT. selectForOnboardingCompletion and selectChecklistByOnboardingId remain the
     * real Onboarding FLS gate, and they remain USER_MODE — correctly so, since both
     * back reads a human explicitly asked for. Making this method SYSTEM_MODE moves
     * that gate not one inch.
     *
     * WHY DO IT AT ALL, THEN: (a) the recompute is genuinely not a user-requested
     * read — nobody asked for these rows; the user completed one Task and the service
     * recomputes the Tasks_* counters on their behalf — so it belongs on the same
     * footing as the Transaction rollup; and (b) it is safe PROSPECTIVELY, for the
     * first caller that arrives without a USER_MODE read in front of it (a nightly
     * batch recompute, a Yardi sync, a trigger). Such a caller would otherwise
     * rediscover the Transaction defect from scratch, because `USER_MODE` THROWS (it
     * does not degrade) the moment one selected field is inaccessible. Same
     * automation-path reasoning as the EAC methods at the bottom of this class and as
     * `LeadSelector.GuestReads` / `GroupMemberSelector` (ARCHITECTURE.md §2).
     *
     * SCOPE OF THE BYPASS: `SYSTEM_MODE` bypasses FLS and CRUD ONLY — it does NOT
     * bypass sharing. This class remains `with sharing`, so the recompute still sees
     * only the Tasks the running user can already see; it cannot read a Task under an
     * Onboarding__c the user has no access to. That distinction is what makes this
     * safe.
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
            WITH SYSTEM_MODE
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
     * ⚠ `WITH SYSTEM_MODE` — CHANGED 2026-08-05 to fix a CONFIRMED PRODUCTION
     * FAILURE, reproduced in `usman-dpeg`. A Transaction__c was created with
     * Contract_Executed_Date__c set; the Transaction_Task_Fanout flow ran
     * TaskFanoutService, which enqueued TaskFanoutQueueable; the job inserted its 82
     * checklist Tasks; TaskRollupTrigger fired after-insert; TaskRollupService called
     * THIS method; and the `WITH USER_MODE` query threw:
     *
     *   CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY, TaskRollupTrigger: execution of
     *   AfterInsert caused by: System.QueryException: No such column
     *   'Transaction_Deal__c' on entity 'Task'
     *
     * `Transaction_Deal__c` DOES exist
     * (objects/Activity/fields/Transaction_Deal__c.field-meta.xml) — "No such column"
     * is how Salesforce reports an FLS DENIAL under `WITH USER_MODE`. The throw
     * escaped the trigger and rolled back all 82 inserts, so the Day-0 checklist —
     * the core of the Transaction module — was UNBUILDABLE BY ANY NON-ADMIN. Every
     * DPEG persona is on `Minimum Access - Salesforce`, which grants no FLS at all;
     * access comes only from permission sets, so one ungranted custom field on this
     * SELECT is enough to take down the whole fan-out.
     *
     * WHY SYSTEM_MODE RATHER THAN A PERMISSION-SET GRANT: this is a TRIGGER-DRIVEN
     * ROLLUP RECOMPUTE, not a user-initiated read. Nobody asked for these rows — a
     * trigger recomputes the "N / 82" counters on the acting user's behalf, and
     * `USER_MODE` THROWS (it does not degrade) the moment one selected field is
     * inaccessible. Making an automatic recompute depend on the acting user's FLS
     * means any persona missing any one custom field silently breaks an unrelated
     * write. That is the documented precedent in ARCHITECTURE.md §2 for the EAC
     * capture pipeline, and it applies verbatim here. Granting FLS instead would fix
     * today's persona and leave the class fragile for the next one — the failure mode
     * is structural, not a provisioning oversight.
     *
     * SCOPE OF THE BYPASS: `SYSTEM_MODE` bypasses FLS and CRUD ONLY — NOT sharing.
     * This class remains `with sharing`, so the recompute still counts only the Tasks
     * the running user can already see. That distinction is what makes the change
     * safe: it removes a field-level failure mode without widening record visibility
     * by a single row.
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
            WITH SYSTEM_MODE
        ];
    }

    /**
     * Every checklist Task on the supplied Transactions, with the FULL field set the Phase 4
     * migration and its reconciliation report need. Backs `ChecklistMigrationService` and
     * `ChecklistMigrationAuditService`.
     *
     * 🔴 `WITH SYSTEM_MODE` — AUTOMATION PATH, AND THE SIXTH ENTRY IN THIS CLASS'S MODE
     * INVENTORY. The caller is a Queueable chain (and a read-only audit driven from a script),
     * neither of which is a read a human asked for. It reads NINE custom `Activity` fields (plus eight
     * standard ones),
     * every one of them Metadata-API-deployed and therefore carrying FieldPermissions for
     * whoever the permission pass granted and nobody else — so under `USER_MODE` one missing
     * grant raises `System.QueryException: No such column`, an FLS denial wearing a schema
     * error, and the migration chunk dies with 25 deals half-considered. This class has already
     * paid for exactly that once: on 2026-08-05 a `USER_MODE` read of `Transaction_Deal__c`
     * rolled back an entire 82-row Day-0 fan-out.
     * ⚠ SYSTEM_MODE lifts CRUD/FLS and NEVER sharing. This class stays `with sharing`, so a deal
     * the runner cannot see returns NO ROWS. That is deliberate and is why
     * `ChecklistMigrationService` diffs the ids it ASKED for against the ids it got back and
     * reports the difference as `NOT_VISIBLE` — a silently skipped deal is the failure mode this
     * migration is most likely to hide, so it is surfaced rather than tolerated.
     *
     * 🔴 THE FIELD SET IS THE MIGRATION MAPPING AND IT IS NOT DECORATIVE. `Task_Group__c` +
     * `Task_Sequence__c` are the COORDINATE the whole migration keys on — never the Subject,
     * which a bare-substring match would use to wrongly flag A4 and A5. `Subject` is selected
     * anyway because the legacy `anti-fraud` parse is one half of the reconciliation's RISK 1
     * canary; nothing MAPS on it. Do not narrow this list without reading
     * `ChecklistMigrationDomain.project`, which reads every column returned here.
     *
     * ⚠ ORDERED BY deal, then group, then sequence, so a migration chunk and an audit run walk
     * the rows in the same order and two runs can be diffed line for line.
     *
     * 🔴 RETIRED AT M5 WITH THE REST OF THE TASK MODEL, and this entry must leave the inventory
     * block above at the same time. ARCHITECTURE §2 makes that block the authoritative record of
     * which reads escape and why; a stale one tells the next review an exemption exists that
     * does not.
     *
     * NOT-FOUND CONTRACT: a list read. An empty list is MEANINGFUL — a deal that was never
     * fanned out on the Task model has no checklist Tasks, and the migration must treat that as
     * nothing to migrate rather than as an error.
     *
     * @param transactionDealIds Parent `Transaction__c` ids; null/empty-safe.
     * @return Checklist Tasks on those deals (Task_Group__c populated), ordered; never null.
     * @example
     * List<Task> rows = TaskSelector.selectForChecklistMigration(dealIds);
     */
    public static List<Task> selectForChecklistMigration(Set<Id> transactionDealIds) {
        if (transactionDealIds == null || transactionDealIds.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Id, Transaction_Deal__c, Task_Group__c, Task_Sequence__c, Task_Owner_Label__c,
                   Subject, Status, IsClosed, ActivityDate, Description, Conditional__c,
                   Verbal_Verification_Completed__c, Verified_By__c, Verified_At__c,
                   Verification_Phone__c, LastModifiedDate, LastModifiedById
            FROM Task
            WHERE Transaction_Deal__c IN :transactionDealIds AND Task_Group__c != null
            WITH SYSTEM_MODE
            ORDER BY Transaction_Deal__c, Task_Group__c, Task_Sequence__c NULLS FIRST
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

    // ─────────────────────────────────────────────────────────────────────────
    // Broker Protection (inbound-email staging model) — RFC threading queries.
    // Both read the two External Id text fields Task.Inbound_Message_Id__c and
    // Task.Thread_Key__c, which exist ONLY for this pipeline: the first is one
    // email's RFC Message-ID (unique -> idempotency), the second is the
    // conversation root shared by every message in a thread (-> reply matching).
    // Consumers: InboundEmailActivityService.isAlreadyLogged and
    // PropertyMatchingService.findRecordByReplyHeaders.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The Task, if any, already logged for one inbound RFC Message-ID. Backs the
     * IDEMPOTENCY probe at the top of ExtractAddressQueueable: a non-empty result
     * means the platform is redelivering a message the pipeline already routed, and
     * the whole routing tree must be skipped rather than producing a second Lead.
     *
     * Existence probe only — `SELECT Id` with `LIMIT 1` is all the caller needs
     * (InboundEmailActivityService.isAlreadyLogged tests `.isEmpty()`). Do not widen
     * the field set here; the reply-matching read below is the one that needs
     * WhatId / WhoId.
     *
     * @param messageId RFC Message-ID to probe; null/blank returns an empty list.
     * @return At most one Task carrying that Message-ID; an empty list when the
     *         message has not been logged (never null).
     * @example
     * Boolean seen = !TaskSelector.selectByInboundMessageId(messageId).isEmpty();
     */
    public static List<Task> selectByInboundMessageId(String messageId) {
        if (String.isBlank(messageId)) {
            return new List<Task>();
        }
        return [
            SELECT Id
            FROM Task
            WHERE Inbound_Message_Id__c = :messageId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * The most recent Task belonging to any of the supplied RFC Message-IDs, matched
     * on EITHER threading key. Backs PropertyMatchingService.findRecordByReplyHeaders,
     * which passes the whole ancestry cited by a reply's In-Reply-To + References
     * headers and uses the returned Task's WhatId/WhoId as the record to thread onto.
     *
     * The OR across both fields is deliberate and neither half is redundant:
     * `Thread_Key__c IN` catches any message in the same conversation (the root id is
     * shared by every message in the thread), while `Inbound_Message_Id__c IN` catches
     * the case where the reply cites a specific earlier message directly and that
     * message happens to BE the thread root — whose own Thread_Key__c is itself, but
     * whose ancestry the citing reply may express only as a Message-ID.
     *
     * ORDER BY CreatedDate DESC, Id DESC + LIMIT 1: a thread accumulates one Task per
     * message, and they all resolve to the same routed record, so the newest is both
     * correct and cheapest.
     *
     * ⚠ THE `, Id DESC` TIE-BREAK IS NOT COSMETIC (added 2026-07-31 with multi-property
     * routing, design C-3). One inbound email can now route to SEVERAL records, and
     * InboundEmailActivityService inserts those N Tasks in ONE bulk DML — so they share a
     * CreatedDate to the millisecond and `CreatedDate DESC` alone leaves the winner
     * UNDEFINED. The caller inserts them in ASCENDING PRIORITY (no-property &lt; repeat &lt;
     * competing &lt; winner), so the highest-priority record gets the highest Id, and this
     * tie-break lands a later reply on the deal DPEG actually owns rather than on an
     * arbitrary row. Removing either half — the ordering here or the insert order there —
     * silently reintroduces the ambiguity.
     *
     * FIELD SET IS DELIBERATE: WhatId and WhoId are what the caller returns; dropping
     * either would raise System.SObjectException on that read.
     *
     * @param messageIds RFC Message-IDs cited by the reply (angle brackets already
     *                   stripped by the caller); null/empty returns an empty list.
     * @return At most one Task (Id, WhatId, WhoId, Thread_Key__c,
     *         Inbound_Message_Id__c), newest first; an empty list when nothing in the
     *         thread has been logged (never null).
     * @example
     * List<Task> prior = TaskSelector.selectLatestByThreadOrMessageIds(citedIds);
     */
    public static List<Task> selectLatestByThreadOrMessageIds(Set<String> messageIds) {
        if (messageIds == null || messageIds.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Id, WhatId, WhoId, Thread_Key__c, Inbound_Message_Id__c
            FROM Task
            WHERE Thread_Key__c IN :messageIds OR Inbound_Message_Id__c IN :messageIds
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // EAC CAPTURE PIPELINE (added 2026-08-02) — WITH SYSTEM_MODE.
    //
    // Both methods below back the EAC capture pipeline — EmailThreadGuardService
    // (deletes) and, since the adopter landed, EmailThreadAnchorService /
    // EmailThreadAdopterService (RelatedToId writes) — which runs in a wholly
    // automated context: an Einstein Activity Capture write inserts an
    // EmailMessage, EmailMessageTrigger enqueues EmailCaptureQueueable, and
    // the queueable executes as the principal EAC committed under. That principal
    // holds none of this repo's permission sets.
    //
    // `WITH USER_MODE` DOES NOT DEGRADE GRACEFULLY HERE — it THROWS the moment a
    // selected field is inaccessible, killing the queueable. The guard would then
    // be silently disabled: no error surfaces anywhere a human looks, while EAC
    // keeps stapling unrelated conversations onto deal Leads. That is why these
    // two reads are SYSTEM_MODE.
    //
    // ⚠ AMENDED 2026-08-05 — this block used to end "...and the rest of this class
    // is not." That is no longer true and would mislead: the two ROLLUP reads
    // (selectByTransactionDealIds, selectByOnboardingIds) are now SYSTEM_MODE too,
    // for the same automation-path reason stated above — a USER_MODE FLS denial in
    // the Transaction rollup rolled back a whole Day-0 fan-out in production, and the
    // Onboarding rollup followed for consistency and future callers rather than as a
    // second observed failure. See the class header for the full four-method
    // inventory and for which entry rests on which evidence.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The companion Tasks EAC auto-creates alongside its captured EmailMessages,
     * loaded by the Ids the platform stamped on `EmailMessage.ActivityId`. Backs the
     * EAC FINGERPRINT test in EmailThreadGuardService: a companion created by the
     * Automated Process user is an EAC materialization; one created by a real user is
     * a deliberate composer/Agentforce send and is never touched.
     *
     * `CreatedBy.UserType` is the whole point of this method and is why SYSTEM_MODE is
     * mandatory rather than merely convenient: it is a cross-object read into User, and
     * User.UserType is not readable by every principal. Under USER_MODE this query is
     * one FLS gap away from throwing — see the block comment above.
     *
     * ⚠ SCOPE NOTE FOR REVIEWERS. This method is the ONLY way the guard can reach a
     * Task, and it can only be handed Ids harvested from `EmailMessage.ActivityId`.
     * Broker Protection's own pipeline Tasks are created by
     * InboundEmailActivityService and are linked to no EmailMessage at all, so no
     * EmailMessage.ActivityId can ever point at one. The thread anchors this feature
     * depends on are therefore structurally out of the guard's reach — proven by
     * EmailThreadGuardServiceTest.pipelineAnchorTaskIsStructurallyUnreachable.
     *
     * @param taskIds Companion Task Ids (from EmailMessage.ActivityId); null/empty-safe.
     * @return Matching Tasks with Id and CreatedBy.UserType populated; an empty list
     *         when the input is null/empty or the rows are already gone (never null).
     * @example
     * Map<Id, Task> companions = new Map<Id, Task>(TaskSelector.selectByIds(taskIds));
     */
    public static List<Task> selectByIds(Set<Id> taskIds) {
        if (taskIds == null || taskIds.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Id, CreatedBy.UserType
            FROM Task
            WHERE Id IN :taskIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * The Broker-Protection thread anchors matching any of the supplied identifiers,
     * **found BY ANCHOR VALUE rather than by record** (replaced selectThreadAnchorsByWhoIds
     * 2026-08-02). Backs the SHARED index in EmailThreadAnchorService, which both the
     * adopter and the guard consume.
     *
     * ⚠ WHY BY VALUE, NOT BY RECORD. The guard only ever asked "is this capture anchored on
     * a Lead it is related to?", so scoping by `WhoId IN :leadIds` was sufficient. The
     * adopter asks the opposite question — "which record does this thread belong to?" — and
     * has no record set to scope by; the anchor is what NAMES the record. One query must
     * serve both, so the scope is the identifier set. It stays selective because BOTH anchor
     * fields are indexed External Ids.
     *
     * ⚠ BOTH BRACKET FORMS ARE BOUND, and this is the fix for a live defect (P4/E3). The
     * pipeline stores `Thread_Key__c` UNBRACKETED and `Inbound_Message_Id__c` BRACKETED
     * (measured on both live anchor rows in `usman-dpeg` 2026-08-02), while EAC supplies
     * bracketed identifiers. Binding only one form silently halves the match surface — which
     * is exactly what the deployed guard was doing. Callers pass NORMALIZED (unbracketed)
     * values; this method re-brackets them itself so the caller never handles brackets.
     *
     * WhatId is now selected as well as WhoId: post-conversion anchors carry the Opportunity
     * there (verified by experiment E1 — conversion stamps `WhatId` on the existing anchor
     * Task), and that is the adopter's entire resolution chain.
     *
     * Both halves of the OR are load-bearing, for the same reason they are in
     * selectLatestByThreadOrMessageIds above: `Thread_Key__c` matches any message in
     * the conversation (every message shares the root id), while
     * `Inbound_Message_Id__c` matches the case where the capture cites the thread ROOT
     * directly — a root whose own Thread_Key__c is itself, but which a capture may
     * express only as a Message-ID.
     *
     * ⚠ SYSTEM_MODE IS A CORRECTNESS REQUIREMENT, NOT A CONVENIENCE. Thread_Key__c and
     * Inbound_Message_Id__c are custom fields whose FLS is granted by permission sets
     * the automated EAC principal does not hold. A USER_MODE failure here does not
     * merely narrow the result — it aborts the queueable, and every subsequent capture
     * stays on the Lead unexamined. (The inverse failure mode is worse still and is
     * why this must never be "softened" to a filtered read: a query that returned ZERO
     * anchors instead of throwing would make every genuine reply look unanchored and
     * DELETE it.)
     *
     * ORDER BY CreatedDate DESC, Id DESC is load-bearing, not cosmetic: one Message-ID can
     * carry N anchor Tasks across N records (multi-property routing), but `RelatedToId`
     * holds ONE Id. The caller takes FIRST-WINS, which reuses the pipeline's own tie-break
     * from selectLatestByThreadOrMessageIds — the epilogue inserts in ASCENDING priority, so
     * the deal DPEG actually owns carries the highest Id and wins here.
     *
     * @param anchorValues NORMALIZED (unbracketed) RFC identifiers carried by the captures
     *                     under examination; null/empty-safe.
     * @return Anchor Tasks with Id, WhoId, WhatId, Thread_Key__c and Inbound_Message_Id__c
     *         populated, newest/highest-priority first; an empty list when the input is
     *         null/empty or nothing anchors these identifiers (never null).
     * @example
     * List<Task> anchors = TaskSelector.selectThreadAnchorsByAnchorValues(normalizedIds);
     */
    public static List<Task> selectThreadAnchorsByAnchorValues(Set<String> anchorValues) {
        if (anchorValues == null || anchorValues.isEmpty()) {
            return new List<Task>();
        }
        // Bind BOTH bracket forms so a stored value in either shape matches (P4/E3).
        Set<String> bothForms = new Set<String>();
        for (String value : anchorValues) {
            if (String.isBlank(value)) {
                continue;
            }
            bothForms.add(value);
            bothForms.add('<' + value + '>');
        }
        if (bothForms.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Id, WhoId, WhatId, Thread_Key__c, Inbound_Message_Id__c
            FROM Task
            WHERE Thread_Key__c IN :bothForms OR Inbound_Message_Id__c IN :bothForms
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }

    /**
     * Completion state of the Tasks named as prerequisites by `Task.Blocked_By__c`. THE SINGLE READ
     * behind the Phase 0 wire-fraud prerequisite gate (`TaskPrerequisiteService`, design
     * `agent-output/design-transaction-fsd-gaps.md` §5.1 / §10) — B3 cannot complete while B2 is
     * open, I8 cannot complete while I7 is open.
     *
     * Called ONCE PER TRIGGER CHUNK from a BEFORE UPDATE context, and only when at least one Task in
     * that chunk carries a non-blank `Blocked_By__c` — which is at most two Tasks per Transaction.
     * The field set is deliberately minimal: `IsClosed` is the decision, `Task_Group__c` and
     * `Task_Sequence__c` are the KEY the caller matches on, and `Subject` NAMES the blocking step in
     * the refusal message and is read for DISPLAY ONLY (no branch reads it — that is the whole point
     * of the feature; see `TaskPrerequisiteService`'s header on RISK 1).
     *
     * 🔴 WHY THE SIGNATURE IS (deals, sequences) AND NOT A SET OF PREREQUISITE IDs. `Blocked_By__c`
     * IS NOT A LOOKUP AND CANNOT BE — measured on `usman-dpeg` 2026-08-31: a `CustomField` with
     * `referenceTo` = `Task` fails deploy with *"referenceTo value of 'Task' does not resolve to a
     * valid sObject type"*. Task/Event are not valid custom-relationship TARGETS on this platform. So
     * the field is `Text(20)` carrying the prerequisite's `<GroupLetter>|<Sequence>` key (`B|2`,
     * `I|7`) and the prerequisite is found as a SIBLING under the same `Transaction_Deal__c`. The
     * caller does the letter matching in memory — see the row-count note below for why that is not a
     * cop-out.
     *
     * ⚠ ROW COUNT, DERIVED RATHER THAN HOPED. The WHERE cannot filter on the group letter (it lives
     * inside `Task_Group__c` as `"<Letter>. <Group Name>"`, and SOQL has no `IN`-of-`LIKE`), so this
     * returns every checklist Task on the named deals whose sequence is in the set — roughly
     * `groups x sequences` rows per deal, i.e. ~11 x 2 = ~22 for the real B3/I8 pair. A full 200-row
     * before-update chunk of blocked items is 100 deals (two blocked items each), so ~2,200 rows
     * against the 50,000 query-row limit. Building a dynamic `OR`-of-`LIKE` to trim that would trade a
     * comfortable margin for an injection surface. Do not.
     *
     * 🔴 `WITH SYSTEM_MODE` — FIFTH MEMBER OF THE MODE INVENTORY IN THIS CLASS HEADER, AND IT IS A
     * CORRECTNESS REQUIREMENT, NOT A CONVENIENCE. This is an AUTOMATION-PATH read: performed on the
     * saving user's behalf, never at their request. `USER_MODE` THROWS rather than degrades, and
     * a `USER_MODE` FLS denial here would raise `System.QueryException: No such column` — an FLS
     * denial wearing a schema error — inside a BEFORE trigger, which escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back THE USER'S OWN SAVE of a checklist item
     * that has nothing to do with the missing grant. That is not hypothetical in this org: the
     * identical failure on `Transaction_Deal__c` rolled back a whole 82-Task Day-0 fan-out (see this
     * class's header, 2026-08-05).
     * Concretely and not by analogy: this SELECT reads `Transaction_Deal__c`, `Task_Group__c` and
     * `Task_Sequence__c`, all THREE of which are permission-set-granted custom fields, and
     * `Transaction_Deal__c` is the very field whose USER_MODE denial produced the 2026-08-05
     * rollback. `Blocked_By__c` itself is not read here — it comes from `Trigger.new`, where FLS does
     * not apply — but it is brand new and carries zero FieldPermissions on the day it deploys, so
     * anyone who later adds it (or `Verbal_Verification_Completed__c`, the obvious next refinement)
     * to this SELECT would recreate that failure exactly. Do not "tighten" this to USER_MODE.
     *
     * ⚠ SCOPE OF THE BYPASS IS UNCHANGED AND THE CLASS STAYS `with sharing`. SYSTEM_MODE lifts
     * CRUD/FLS and never sharing, so this still returns only rows the running user can see.
     * `TaskFanoutService` stamps every checklist Task with the Transaction's `OwnerId`, so a
     * prerequisite and the item it blocks always share an owner and the read is satisfied by
     * ownership on every path the model builds. A Task individually REASSIGNED away from that owner
     * can hide its prerequisite; the caller treats an absent row as UNRESOLVED and refuses the
     * completion (fails closed), which is the correct direction for an anti-fraud control and is
     * asserted by `TaskPrerequisiteServiceTest`.
     *
     * NOT-FOUND CONTRACT: a list read — missing rows are meaningful, not exceptional. Returns an
     * EMPTY list, never null. The caller distinguishes "absent" from "open" and refuses both.
     *
     * @param dealIds   `Transaction_Deal__c` ids of the blocked Tasks; null/empty-safe.
     * @param sequences `Task_Sequence__c` values named by the blocked Tasks' `Blocked_By__c` keys;
     *                  null/empty-safe.
     * @return Checklist Tasks on those deals at those sequences, with Id, Transaction_Deal__c,
     *         Task_Group__c, Task_Sequence__c, Subject and IsClosed populated; an empty list when
     *         either input is null/empty or nothing matches (never null).
     * @example
     * List<Task> candidates = TaskSelector.selectChecklistByDealsAndSequences(dealIds, sequences);
     */
    public static List<Task> selectChecklistByDealsAndSequences(Set<Id> dealIds, Set<Decimal> sequences) {
        if (dealIds == null || dealIds.isEmpty() || sequences == null || sequences.isEmpty()) {
            return new List<Task>();
        }
        return [
            SELECT Id, Transaction_Deal__c, Task_Group__c, Task_Sequence__c, Subject, Status, IsClosed
            FROM Task
            WHERE Transaction_Deal__c IN :dealIds
              AND Task_Sequence__c IN :sequences
              AND Task_Group__c != null
            WITH SYSTEM_MODE
        ];
    }
}
