/**
 * Selector for ProcessInstance. Encapsulates ALL SOQL against ProcessInstance per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumer:
 * OpportunityApprovalController.submitForApproval — the duplicate-submission guard.
 *
 * MODE — USER_MODE (per P4 design §5, flagged as the one internal case worth a
 * manual smoke-test). ProcessInstance is a system object; its fields are
 * non-permissionable and record visibility follows access to the target deal,
 * which the submitting user already has. No SYSTEM_MODE.
 *
 * NOT-FOUND CONTRACT — read-for-existence: the caller only tests `.isEmpty()`, so
 * this returns a List and never throws on "no pending approval".
 *
 * @see agent-output/p4-selector-design.md (§3 #20, §5)
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
}
