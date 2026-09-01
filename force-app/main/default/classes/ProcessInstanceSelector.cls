/**
 * Selector for ProcessInstance. Encapsulates ALL SOQL against ProcessInstance per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers, and they ask DIFFERENT questions:
 *   1. `OpportunityApprovalController.submitForApproval` — the duplicate-submission guard
 *      (`selectPendingByTargetId`, Id only, one target).
 *   2. `DispositionApprovalHistoryService.getHistory` — the consolidated Approval History card on
 *      the Disposition record page (`selectHistoryByTargetIds`, MANY targets, full trail). Added
 *      2026-08-26; see that method's own Javadoc for why the target set spans three objects.
 *   3. `DispositionApprovalTrackerService.getTracker` — the five-approval CHECKLIST on the same
 *      page (`selectTrackerStatesByTargetIds`, MANY targets across FOUR objects, no trail, keyed on
 *      `ProcessDefinition.DeveloperName`). Added 2026-08-31.
 *      🔴 CONSUMERS 2 AND 3 LOOK ALIKE AND ASK DIFFERENT QUESTIONS. #2 asks "what happened, in
 *      order, in words a human recognises" and selects the process LABEL plus the full step trail.
 *      #3 asks "which of the five approval TYPES is where", and a label cannot answer it — four of
 *      the five processes were RELABELLED on 2026-08-26 with no API-name change, so a label-keyed
 *      checklist reclassifies itself the next time someone edits copy, silently. Do not merge the
 *      two methods to save a query: they are read by two different cards and only #3 is narrow
 *      enough to be safe without the subquery's extra USER_MODE gates.
 *
 * MODE — USER_MODE on BOTH methods (per P4 design §5, flagged as the one internal case worth a
 * manual smoke-test). ProcessInstance is a system object; its fields are
 * non-permissionable and record visibility follows access to the target deal,
 * which the submitting user already has. No SYSTEM_MODE.
 * 🔴 THE SECOND METHOD WIDENS WHAT `USER_MODE` IS BEING ASKED TO ENFORCE, AND THAT IS THE ONE
 * THING TO CHECK IF THE NEW CARD THROWS FOR A PERSONA. `selectPendingByTargetId` selects `Id` and
 * nothing else, so the only gate it can fail is OBJECT read on `ProcessInstance`. The history
 * method traverses to `ProcessDefinition` and to the polymorphic `Name` (User/Group) behind
 * `SubmittedBy` / `Actor`, and pulls a child subquery on `ProcessInstanceHistory` — every one of
 * those is an additional `USER_MODE` gate. They are all SETUP-ISH standard entities that the
 * platform's own Approval History related list reads for every user who can see the record, which
 * is why this is not treated as a provisioning risk; but if the card raises its read-failure
 * banner, THE FIX IS A PERMISSION SET AND NEVER `SYSTEM_MODE` HERE. Downgrading this method to
 * SYSTEM_MODE would show a user approval trails for records their sharing hides — the exact
 * inversion §2 of ARCHITECTURE.md warns about, on an audit surface.
 *
 * NOT-FOUND CONTRACT — read-for-existence: both callers only iterate or test `.isEmpty()`, so
 * both return a List and never throw on "no approvals".
 *
 * @see agent-output/p4-selector-design.md (§3 #20, §5)
 * @see force-app/main/default/classes/DispositionApprovalHistoryService.cls
 */
public with sharing class ProcessInstanceSelector {

    private static final String STATUS_PENDING = 'Pending';

    /**
     * Pending approval process instances targeting a record — backs the
     * "already pending approval" guard on submit.
     *
     * @param targetObjectId The record the approval targets (the deal Id); null-safe.
     * @return ProcessInstance rows with Status = 'Pending' for the target; empty
     *         when the input is null or none are pending.
     */
    public static List<ProcessInstance> selectPendingByTargetId(Id targetObjectId) {
        if (targetObjectId == null) {
            return new List<ProcessInstance>();
        }
        return [
            SELECT Id
            FROM ProcessInstance
            WHERE TargetObjectId = :targetObjectId AND Status = :STATUS_PENDING
            WITH USER_MODE
        ];
    }

    /**
     * EVERY approval process instance — pending AND completed — whose `TargetObjectId` is one of a
     * SET of records, newest submission first, each carrying its full step/workitem trail.
     * Backs the consolidated "Approval History" card on the Disposition record page
     * (`DispositionApprovalHistoryService.getHistory` -> `c/dispositionApprovalHistory`).
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE PARAMETER IS A **SET OF IDS ACROSS THREE OBJECTS**, AND THAT IS THE WHOLE POINT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The defect this method exists to fix (user report, 2026-08-25: *"I sent the disposition for
     * approval on BOV Outreach but it is not appearing on the disposition record"*) is that the
     * disposition flow's approvals do NOT all target the Disposition:
     *   `Sale_Decision_Approval`     -> `Disposition__c`
     *   `Broker_Selection_Approval`  -> `Disposition__c`   (off-market only)
     *   `Closing_Approval`           -> `Disposition__c`
     *   `Broker_Finalize_Approval`   -> the SELECTED `BOV_Submission__c`
     *   `Offer_Selection_Approval`   -> the SELECTED `Disposition_Offer__c`
     * The standard Approval History related list matches `TargetObjectId` to the record it is
     * rendered on, so the last two are structurally invisible on the Disposition page. A method
     * keyed on ONE Id could not fix that, which is why this one is not a `...ByTargetId` twin of
     * the method above. ⚠ DO NOT NARROW IT BACK TO A SINGLE ID — the caller would have to loop,
     * and that is SOQL in a loop on a page render.
     *
     * 🔴 IT DELIBERATELY DOES **NOT** FILTER ON `Status`. A completed approval is the part of the
     * history a user most often needs (who approved the sale decision, and when), and a `Pending`
     * filter is exactly what the guard method above wants and this one must not copy.
     *
     * ── THE SUBQUERY: `StepsAndWorkitems`, NOT `Steps` ──────────────────────────────────────────
     * `Steps` (`ProcessInstanceStep`) holds only COMPLETED actions, so a PENDING approval — the
     * one state the reporting user was actually looking at — would come back with an empty trail
     * and the card could not say who is holding it. `StepsAndWorkitems` (`ProcessInstanceHistory`)
     * is the union of the completed steps and the outstanding workitems, which is the same set the
     * platform's own Approval History related list renders.
     * 🔴 AND IT CARRIES **NO `ORDER BY`**, WHICH IS DELIBERATE AND IS NOT AN OVERSIGHT.
     * `ProcessInstanceHistory` is a synthesised, read-only entity and its support for `ORDER BY`
     * inside a child subquery is not something this codebase has measured. The trail is therefore
     * ordered ONCE, in Apex, by `DispositionApprovalHistoryService` (`StepRow implements
     * Comparable`, newest first with a total-order tie-break). ⚠ IF YOU ADD AN `ORDER BY` HERE,
     * you create a SECOND copy of that ordering rule, and deleting either one leaves a query that
     * still compiles and a card that silently renders an arbitrary step order.
     *
     * ── ORDERING OF THE OUTER ROWS IS THIS METHOD'S, AND THE CONSUMER DOES NOT RE-SORT ─────────
     * `CreatedDate DESC` is "most recently submitted approval first". `Id DESC` is the tie-break
     * that makes it a TOTAL order: `CreatedDate` is second-granular, and three approvals submitted
     * from one screen in one minute are a real shape here (see
     * `DispositionApprovalHistoryServiceTest`, which submits three in a single transaction).
     * Without it the card's row order would be arbitrary between runs.
     *
     * @param targetObjectIds The records the approvals target — the Disposition plus its
     *                        `BOV_Submission__c` and `Disposition_Offer__c` children. Null/empty
     *                        safe and issues NO query when the set is empty.
     * @return ProcessInstance rows for those targets, newest submission first, each with its
     *         `StepsAndWorkitems` child rows in UNSPECIFIED order (see above). An empty list when
     *         the input is null/empty or nothing has ever been submitted; never null.
     * @example
     * List&lt;ProcessInstance&gt; instances =
     *     ProcessInstanceSelector.selectHistoryByTargetIds(targetIds);
     */
    public static List<ProcessInstance> selectHistoryByTargetIds(Set<Id> targetObjectIds) {
        if (targetObjectIds == null || targetObjectIds.isEmpty()) {
            return new List<ProcessInstance>();
        }
        return [
            SELECT Id, Status, TargetObjectId, CreatedDate, CompletedDate,
                   SubmittedById, SubmittedBy.Name,
                   ProcessDefinitionId, ProcessDefinition.Name,
                   (
                       SELECT Id, StepStatus, Comments, CreatedDate, ActorId, Actor.Name
                       FROM StepsAndWorkitems
                   )
            FROM ProcessInstance
            WHERE TargetObjectId IN :targetObjectIds
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }

    /**
     * The STATE of every approval ever raised against a set of records, newest submission first,
     * each row carrying the approval process's **API NAME**. Backs the five-approval tracker
     * (`DispositionApprovalTrackerService.getTracker` -> `c/dispositionApprovalTracker`,
     * 2026-08-31, Tranche 3 item 3).
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IT SELECTS `ProcessDefinition.DeveloperName`. THE METHOD ABOVE SELECTS
     *    `ProcessDefinition.Name`. THAT IS THE ENTIRE REASON THIS METHOD EXISTS.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `Name` is the process's LABEL — display copy, and copy that has already moved inside this
     * programme. On 2026-08-26 FOUR of the five disposition approval processes were relabelled in
     * one change ("Sale Decision Approval" -> "Decide to Sell Approval"; "Broker Finalize Approval"
     * -> "Broker Selection Approval (BOV)"; "Broker Selection Approval" -> "Broker Selection
     * Approval (Off-Market)"), and NOT ONE of the `<fullName>` API names changed. A card that
     * IDENTIFIES which approval type a row belongs to by matching that string is keyed on copy: the
     * next relabel silently reclassifies every row, and nothing throws — the tracker would simply
     * report five "Not started" rows on a sale that had passed four approvals. `DeveloperName` is
     * the stable key and is what this method is for.
     *
     * ⚠ THE OTHER METHOD IS DELIBERATELY LEFT ALONE, AND NOT ONLY OUT OF CAUTION. `Name` is exactly
     * right for what it feeds — the consolidated Approval History card HEADLINES each row with the
     * label a human recognises, and `DispositionApprovalHistoryServiceTest` asserts on those labels
     * as a signal that `Name` is not returning an API name in this org. Adding `DeveloperName`
     * there would widen a query whose consumer does not need it; and widening it would not have
     * given this caller what it needs anyway, because it also drags a `ProcessInstanceHistory`
     * subquery this one has no use for. TWO CALLERS, TWO QUESTIONS, TWO METHODS — the same
     * per-caller split `NdaSelector` and `DispositionSelector` both make.
     *
     * ── ⚠ NO `StepsAndWorkitems` SUBQUERY, AND THAT IS THE OTHER HALF OF THE SPLIT ─────────────
     * A checklist needs an OUTCOME per approval, not a trail. Omitting the subquery drops the three
     * extra `USER_MODE` gates it carries (the child entity itself, and the polymorphic `Name`
     * behind `Actor`), so this read is materially NARROWER than the one above rather than merely
     * different — which matters because the tracker fails HARD on a `QueryException`.
     * ⚠ `SubmittedBy.Name` IS ALSO OMITTED for the same reason: the tracker shows WHETHER each
     * approval happened, not who moved it. The card beside it shows that.
     *
     * ── ORDER IS LOAD-BEARING, NOT COSMETIC ───────────────────────────────────────────────────
     * `CreatedDate DESC, Id DESC` — NEWEST FIRST — and the caller relies on it: it takes the FIRST
     * row it sees per (target, process) pair and ignores the rest, so "newest" is what makes a
     * RESUBMITTED approval report its CURRENT state rather than its first. `Id DESC` is the
     * tie-break that makes the order total; `CreatedDate` is second-granular and three approvals
     * submitted from one screen in one minute is a real shape here.
     * 🔴 IF YOU EVER CHANGE THIS ORDER, `DispositionApprovalTrackerService` SILENTLY REPORTS STALE
     * OUTCOMES. It does not throw and no row count changes — a recalled-then-resubmitted approval
     * would read "Recalled" forever. There is no second copy of this rule to disagree with; the
     * service documents its dependence on it at the point of use.
     *
     * ── MODE: `WITH USER_MODE` ─────────────────────────────────────────────────────────────────
     * Same argument as both methods above, and it is the class-header argument: a human opened a
     * record page. `ProcessInstance` and `ProcessDefinition` are system entities whose fields are
     * non-permissionable and whose row visibility follows access to the TARGET record — which is
     * why `DPEG_Apex_Access` records that they *"need no objectPermissions block anywhere"*.
     * 🔴 IF THIS EVER THROWS FOR A PERSONA, THE FIX IS A PERMISSION SET AND NEVER `SYSTEM_MODE`
     * HERE. A system-mode read would show a user the approval outcomes of records their sharing
     * hides — the inversion ARCHITECTURE.md §2 warns about, on an audit surface.
     *
     * @param targetObjectIds The records the approvals target — the Disposition plus its
     *                        `BOV_Submission__c`, `Disposition_Offer__c` and `NDA__c` children.
     *                        Null/empty safe and issues NO query when the set is empty.
     * @return ProcessInstance rows for those targets, NEWEST SUBMISSION FIRST, each carrying its
     *         status, its target, its timestamps and its process's API name. An empty list when the
     *         input is null/empty or nothing has ever been submitted; never null.
     * @example
     * List&lt;ProcessInstance&gt; states =
     *     ProcessInstanceSelector.selectTrackerStatesByTargetIds(targetIds);
     */
    public static List<ProcessInstance> selectTrackerStatesByTargetIds(Set<Id> targetObjectIds) {
        if (targetObjectIds == null || targetObjectIds.isEmpty()) {
            return new List<ProcessInstance>();
        }
        return [
            SELECT Id, Status, TargetObjectId, CreatedDate, CompletedDate,
                   ProcessDefinitionId, ProcessDefinition.DeveloperName
            FROM ProcessInstance
            WHERE TargetObjectId IN :targetObjectIds
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }
}
