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
}
