/**
 * Selector for the standard Task object. Encapsulates ALL SOQL against Task per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * ┌───────────────────────────────────────────────────────────────────────────┐
 * │ SHARED / CROSS-MODULE SELECTOR — THIS IS A CONTRACT, NOT A PRIVATE HELPER. │
 * └───────────────────────────────────────────────────────────────────────────┘
 * Task is the one genuinely cross-module object in the P4 selector rollout
 * (design §3 #18, §7, §10 flag 7). Its consumers today:
 *
 *   • Property Management:
 *       - OnboardingController.getChecklist                  -> selectChecklistByOnboardingId
 *       - OnboardingController.completeTask                  -> selectForOnboardingCompletion
 *       - OnboardingTaskRollupService.recalc                 -> selectByOnboardingIds
 *       - BrokerCheckInReminderSchedulable idempotency       -> selectOpenByWhatIdsAndSubjectPrefix
 *   • Dispositions:
 *       - DispositionTaskController.getClosingTasks          -> selectByWhatIdAndSubjects
 *   • Broker Protection / EAC capture:
 *       - selectByInboundMessageId, selectLatestByThreadOrMessageIds,
 *         selectByIds, selectThreadAnchorsByAnchorValues
 *
 * 🔴 AMENDED 2026-09-03 — M5 LEGACY TASK RETIREMENT. TRANSACTIONS NO LONGER CONSUMES
 * THIS CLASS AT ALL, AND THAT IS THE HEADLINE, NOT A FOOTNOTE.
 * This class was built by and for Transactions ("Transactions builds TaskSelector first;
 * PM's repoint depends on it existing"). Five methods left with the legacy Task-based
 * Transaction checklist:
 *     selectChecklistByTransactionDealIds  (TransactionTaskController.getTaskGroups)
 *     selectRequiredById                   (TransactionTaskController.completeWireVerification)
 *     selectByTransactionDealIds + the `RollupReads` inner class   (TaskRollupService)
 *     selectChecklistByDealsAndSequences   (TaskPrerequisiteService)
 *     selectForChecklistMigration          (ChecklistMigrationService / AuditService)
 * The Transaction checklist now lives on `Checklist_Item__c` and is read by
 * `ChecklistItemSelector`. ⇒ THIS CLASS IS NOW OWNED BY PROPERTY MANAGEMENT IN PRACTICE
 * even though its git history is Transactions'. A change here that "cleans up" an
 * onboarding method has no Transaction fallback to catch it.
 *
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
 * personas driving those reads. The custom Task fields this class still selects
 * (Task_Owner_Label__c, Onboarding_*, Blocked_Reason__c, Source_System__c,
 * Thread_Key__c, Inbound_Message_Id__c) rely on the deployed permsets
 * (P3: custom-field FLS gap = 0).
 * ⚠ 2026-09-03 (M5): this list previously also named Task_Group__c, Task_Sequence__c,
 * Verbal_Verification_*, Verified_By__c/At__c and Verification_Phone__c. All but
 * Task_Sequence__c were DELETED from Activity at M5; Task_Sequence__c survives because
 * OnboardingFanoutService writes it, but nothing in THIS class reads it any more.
 *
 * THREE methods are `WITH SYSTEM_MODE` (SIX between 2026-09-02 and M5). Each carries its own
 * justification at its own declaration; all three sit on an AUTOMATION PATH, where
 * `USER_MODE` THROWS rather than degrades and so converts one missing FLS grant into a
 * broken write:
 *
 *   EAC capture pipeline (added 2026-08-02)
 *     • selectByIds                        <- EmailThreadGuardService
 *     • selectThreadAnchorsByAnchorValues  <- EmailThreadAnchorService (guard+adopter)
 *   Rollup recompute — PLATFORM-DRIVEN, NOT USER-REQUESTED (added 2026-08-05).
 *     • selectByOnboardingIds              <- OnboardingTaskRollupService.recalc,
 *       called DIRECTLY by OnboardingService.completeTask AND routed from
 *       TaskRollupTrigger's four after-contexts.
 *       ⚠ ITS SYSTEM_MODE JUSTIFICATION IS INHERITED, NOT MEASURED, AND THAT MATTERS MORE
 *       NOW THAN IT DID. It was moved to SYSTEM_MODE for CONSISTENCY with a sibling —
 *       `selectByTransactionDealIds` — whose USER_MODE FLS denial WAS a reproduced
 *       production failure (2026-08-05: a `No such column 'Transaction_Deal__c'` throw
 *       escaped TaskRollupTrigger as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolled back
 *       an entire 82-Task Day-0 fan-out). That sibling was retired at M5, so the evidence
 *       for this entry is now HISTORICAL rather than co-resident. It is retained
 *       deliberately: the mechanism (a Metadata-API-deployed custom field arrives with no
 *       FLS for anyone) is a platform property, not a property of the retired class.
 *       🔴 ALSO ESCAPES SHARING since 2026-09-02 (`OnboardingRollupReads`) — see the
 *       SHARING INVENTORY below. Mode and sharing are two decisions, not one.
 *
 * 🔴 AMENDED 2026-09-03 — M5. THREE SYSTEM_MODE ENTRIES LEFT THIS INVENTORY, AND THEY ARE
 * NAMED HERE RATHER THAN SILENTLY DROPPED BECAUSE ARCHITECTURE.md §2 MAKES THIS BLOCK THE
 * AUTHORITATIVE RECORD OF WHICH READS ESCAPE AND WHY:
 *     • selectByTransactionDealIds         (TaskRollupService — the reproduced failure above)
 *     • selectChecklistByDealsAndSequences (TaskPrerequisiteService, the Phase 0 gate)
 *     • selectForChecklistMigration        (ChecklistMigrationService / AuditService)
 * All three read Transaction-only `Activity` fields that no longer exist. Do not cite any of
 * them as precedent for a new escape; cite the mechanism instead.
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
 * the platform's wording for an FLS DENIAL, not a missing field (it existed then:
 * objects/Activity/fields/Transaction_Deal__c.field-meta.xml). The throw escaped the
 * trigger as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolled back all 82 inserts,
 * leaving the Day-0 checklist — the core of the Transaction module — UNBUILDABLE BY
 * ANY NON-ADMIN. Every DPEG persona is on `Minimum Access - Salesforce`, which grants
 * no FLS whatsoever; all access comes from permission sets, so ONE ungranted custom
 * field is enough to break an unrelated write. selectByOnboardingIds was moved in the
 * same change for CONSISTENCY AND FUTURE CALLERS ONLY — it is NOT a second instance
 * of this defect and could not have produced one (its live caller throws earlier); the
 * distinction is spelled out in that method's Javadoc so nobody cites it as evidence.
 * ⚠ 2026-09-03 (M5): the failing method and the field it named are BOTH GONE. This
 * paragraph is kept as the EVIDENCE for selectByOnboardingIds' mode, which is now the
 * only survivor of the pair and would otherwise look like an unjustified escape. The
 * incident is real and dated; it is simply no longer reproducible in this class.
 *
 * ⚠ SCOPE OF THE BYPASS. `SYSTEM_MODE` bypasses FLS and CRUD ONLY. It does NOT bypass
 * sharing — sharing is a SEPARATE question, asked separately, and answered in the block
 * immediately below rather than here.
 *
 * ┌───────────────────────────────────────────────────────────────────────────┐
 * │ 🔴 SHARING INVENTORY — ADDED 2026-09-02. THIS CLASS HAS ONE ESCAPE.        │
 * └───────────────────────────────────────────────────────────────────────────┘
 * 🔴 THIS BLOCK USED TO READ: "It does NOT bypass sharing: this class stays `with
 * sharing`, so EVERY SYSTEM_MODE method still returns only rows the running user can
 * already see." THAT SENTENCE IS NO LONGER TRUE, and it is quoted rather than deleted
 * because ARCHITECTURE.md §2 makes these headers the AUTHORITATIVE inventory of which
 * reads escape and why — a stale one tells the next security review that no exemption
 * exists here, which is worse than no header at all.
 *
 * The class itself STAYS `with sharing` and must: it backs the PM onboarding checklist UI
 * and the PM reminder Schedulable, whose whole job is to respect what the running user may
 * see. ONE read escapes, through its OWN narrow `private without sharing` inner class,
 * justified at its own declaration:
 *
 *   • selectByOnboardingIds       -> `OnboardingRollupReads` (OnboardingTaskRollupService)
 *
 * ⚠ AMENDED 2026-09-03 (M5) — THERE WERE TWO. The second was
 * `selectByTransactionDealIds -> RollupReads` (TaskRollupService), retired with the legacy
 * Task checklist along with the inner class itself. It is named here because this block is
 * the authoritative record; do not read its absence as a revocation.
 *
 * The surviving escape was opened on 2026-09-02 by a measured production failure
 * (`AsyncApexJob 707iw0000046Rh6AAE`, deal `a0Riw000000Ao3ZEAS`, user `005iw000000AJhJAAW`,
 * `UserRecordAccess` = HasReadAccess true / HasEditAccess FALSE / MaxAccessLevel 'Read'),
 * and for a reason that is the OPPOSITE of a convenience: its WRITE half
 * (`OnboardingTaskRollupService.RollupWrites`) escapes sharing, so a filtered read here
 * would not fail — it would SUCCEED WITH ZEROES and publish authoritative counters,
 * including `Completion_Pct__c`, computed from rows the principal cannot see. Read the
 * method declaration for the full argument; do not summarise it here.
 *
 * 🔴 THE PAIRING IS THE POINT. The read may not be reverted to `with sharing` while its
 * write half stays escalated, and the escape may not be extended to a second method — a
 * new read needing this treatment gets its OWN inner class and its OWN measurement.
 * 🔴 EVERY OTHER METHOD IN THIS CLASS IS STILL SHARING-FILTERED, INCLUDING THE TWO OTHER
 * SYSTEM_MODE ONES. That platform fact — `WITH SYSTEM_MODE` bypasses CRUD and FLS and
 * NEVER sharing — is pinned by
 * `TaskSelectorTest.selectByIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows`.
 * ⚠ THAT PIN HAS NOW MOVED TWICE AND MUST NOT BE ALLOWED TO LAPSE. It lived on
 * `selectByTransactionDealIds` until 2026-09-02, then on `selectForChecklistMigration`
 * until M5; both hosts were retired. If the current host is ever retired, MOVE THE PIN
 * to another SYSTEM_MODE + sharing-filtered method in the same change — do not delete it.
 *
 * Do not "harmonize" the two mode groups — they answer questions for different principals.
 *
 * NOT-FOUND CONTRACT is per-caller (pilot WireSelector pattern):
 *   - list reads (checklist / open-reminders)  : missing rows are normal ->
 *     return an EMPTY List, never null.
 *   - fetch-for-update (selectForOnboardingCompletion) : the caller passed a specific Id
 *     it expects to exist; a miss is an error -> single-row SOQL assignment lets
 *     the native System.QueryException fly (matches the old inline query).
 *
 * BULK SHAPE — the child-by-parent reads take a `Set<Id>` and return a `List`,
 * so consumers work in bulk (PM's Schedulable passes N overdue-assignment Ids).
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (P4 pilot template)
 * @see agent-output/p4-selector-design.md (§3 #18, §4, §5, §7)
 */
public with sharing class TaskSelector {

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

    // ─────────────────────────────────────────────────────────────────────────
    // P4 Onboarding + Task-rollup cleanup wave — additional Task query surface.
    // These relocate inline SOQL out of OnboardingController,
    // OnboardingTaskRollupService and DispositionTaskController. (TaskRollupService was
    // a fourth beneficiary until M5, 2026-09-03, when it and its read were retired.)
    // The method above does not fit those callers (different field sets and filters —
    // see each method's doc), so each caller gets a purpose-built method rather than an
    // overload of an existing one.
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
     * FIELD SET IS DELIBERATE. completeTask reads Onboarding__c (to decide which
     * parent to recalc), Onboarding_Status__c and Status (to flip them), and
     * Description (to append the note); a narrower list would throw
     * System.SObjectException on the first unselected read.
     * ⚠ Until M5 (2026-09-03) this paragraph explained why the method was NOT a
     * widening of a shared `selectRequiredById` that also served the legacy wire
     * path. That sibling is gone with the Task checklist, so this is now simply the
     * onboarding completion read — do not "consolidate" it with anything.
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
     * ═══════════════════════════════════════════════════════════════════════════
     * 🔴 SHARING — CORRECTED 2026-09-02. THIS READ ESCAPES SHARING, VIA
     *    `OnboardingRollupReads`. THE PARAGRAPH BELOW IS THE ONE IT REPLACES.
     * ═══════════════════════════════════════════════════════════════════════════
     * 🔴 THIS SAID: "SCOPE OF THE BYPASS: `SYSTEM_MODE` bypasses FLS and CRUD ONLY — it
     * does NOT bypass sharing. This class remains `with sharing`, so the recompute still
     * sees only the Tasks the running user can already see… That distinction is what
     * makes this safe." The first two sentences remain true of the PLATFORM. The
     * conclusion — that the filter made this method safe — was exactly backwards, and it
     * is quoted rather than deleted so nobody re-derives it.
     *
     * WHY IT WAS BACKWARDS. This method's WRITE half,
     * `OnboardingTaskRollupService.RollupWrites`, has been `private without sharing`
     * since 2026-08-22, correctly and for its own measured reason (`Onboarding__c` is
     * Private OWD, shared to `DPEG_Property_Mgmt_Team` by one criteria rule; a filtered
     * write simply does not apply). A write that ALWAYS succeeds paired with a read that
     * is FILTERED does not fail — it produces SILENTLY WRONG COUNTERS. All twelve of
     * them, including `Completion_Pct__c`, read by `OnboardingController` and the PM
     * dashboards. That is strictly the worse of the two failure states, and it has been
     * shipped since 2026-08-22.
     *
     * 🔴 IT IS REACHABLE, and the reachability is structural rather than exotic.
     * `TaskRollupTriggerHandler` routes `Onboarding__c` on all four after-contexts (the
     * same 2026-08-22 change), so ANY principal who can edit ONE onboarding Task while
     * not owning the rest recomputes all twelve counters from a partial view and writes
     * them successfully. A PM-group member holds Edit on EVERY `Onboarding__c` (via
     * `Onboarding_PM_All_RW`) while seeing only their OWN Tasks — `Activity` is
     * `sharingModel Private` and no `sharingRules/Activity*` or `sharingRules/Task*`
     * file exists anywhere in this repo (verified across all 198 files in
     * `sharingRules/`). An individually reassigned Task, an admin-created Task, or an
     * ownership change on the parent puts them in that state.
     *
     * ⚠ WHY IT HAS NOT BEEN NOTICED, AND WHY THAT PROTECTION IS NOT A GUARANTEE.
     * `OnboardingFanoutService` sets `tk.OwnerId = o.OwnerId` (`cls:287`) and suppresses
     * the trigger recalc in favour of one explicit call, so on the fan-out path owner ==
     * runner and the read is complete. There is NO `resolveTransactionOwnerId` equivalent
     * on the PM side — nothing reassigns `Onboarding__c.OwnerId` away from its creator.
     * That is an accident of the current feature set, not a control. It is PRECISELY the
     * property that changed on the Transaction side on 2026-08-28
     * (`ContractExecutionService.cls:359`) and produced `AsyncApexJob 707iw0000046Rh6AAE`
     * on 2026-09-02. This method was closed in the same change so the PM side cannot
     * repeat it.
     *
     * ⇒ THE FIX HERE IS THE MIRROR IMAGE of the Transaction rollup's: there the WRITE was
     *   filtered and moved; here the WRITE was already escaped and the READ moved to meet
     *   it. `OnboardingTaskRollupService.RollupWrites` is DELIBERATELY UNCHANGED.
     * 🔴 THE PAIR ONLY MAKES SENSE TOGETHER. Reverting this read to `with sharing` while
     *   that write stays `without sharing` restores the silent-zero state — it will not
     *   throw, and no test that only asserts "no exception" will catch it.
     *
     * @param onboardingIds Onboarding__c Ids whose checklist Tasks to load.
     * @return Matching Tasks; an empty list when the input is null/empty or no
     *         checklist Tasks exist (never null). Rows are returned WITHOUT sharing —
     *         every Task under the supplied Onboardings, not just the caller's own.
     * @example
     * List<Task> rows = TaskSelector.selectByOnboardingIds(onboardingIds);
     */
    public static List<Task> selectByOnboardingIds(Set<Id> onboardingIds) {
        if (onboardingIds == null || onboardingIds.isEmpty()) {
            return new List<Task>();
        }
        return new OnboardingRollupReads().byOnboardingIds(onboardingIds);
    }

    /**
     * 🔴 THE SHARING ESCAPE FOR THE ONBOARDING ROLLUP READ, AND NOTHING ELSE.
     *
     * `without sharing` is confined to this inner class so it applies to ONE query. The
     * enclosing `TaskSelector` stays `with sharing` and must — it also backs the checklist
     * UI and PM's reminder Schedulable, whose job is to respect what the running user may
     * see. This is the shape ARCHITECTURE.md §2 prescribes, and the live in-repo
     * precedents are `TransactionSelector.DealCloseGateReads`,
     * `OpportunitySelector.NdaGateReads` and `OnboardingTaskRollupService.RollupWrites`.
     *
     * ⚠ Inner classes do NOT inherit the outer class's sharing keyword, so the mode is
     * declared explicitly rather than left to the caller. Apex forbids static methods on
     * inner classes, hence the instance method and the `new OnboardingRollupReads()` at
     * the call site — the `RollupWrites` shape already used in this codebase.
     *
     * The full justification is at `selectByOnboardingIds`'s own declaration. Read it
     * before touching this.
     *
     * 🔴 DO NOT ADD A SECOND METHOD HERE. A query that lands in an existing escape class
     * silently inherits an argument made for a different question; a new read needing this
     * treatment gets its OWN inner class and its OWN measurement.
     * ⚠ 2026-09-03 (M5): this note used to say "SEPARATE FROM `RollupReads` BELOW ON
     * PURPOSE — DO NOT MERGE THEM", because a sibling escape existed for the Transaction
     * rollup (different caller, different principal, different evidence). That sibling was
     * retired with the legacy Task checklist, so this is now the class's only escape. The
     * one-class-per-question rule stands regardless — it is not a consequence of there
     * having been two.
     */
    private without sharing class OnboardingRollupReads {

        /**
         * The onboarding rollup's Task read, unfiltered by sharing so the twelve counters
         * are computed from EVERY Task under the Onboarding rather than from the running
         * principal's subset.
         *
         * @param onboardingIds Onboarding__c Ids; never null/empty (the wrapper guards).
         * @return Every checklist Task under those Onboardings.
         */
        private List<Task> byOnboardingIds(Set<Id> onboardingIds) {
            return [
                SELECT Onboarding__c, Onboarding_Status__c, ActivityDate
                FROM Task
                WHERE Onboarding__c IN :onboardingIds
                WITH SYSTEM_MODE
            ];
        }
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
    // second observed failure. See the class header for the full six-method
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

}
