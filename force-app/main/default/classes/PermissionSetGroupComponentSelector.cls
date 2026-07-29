/**
 * Selector for PermissionSetGroupComponent. Encapsulates ALL SOQL against
 * PermissionSetGroupComponent per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * Consumer: LeadActionPermissionService, which uses it to expand a Permission Set GROUP assignment
 * into the member permission sets that group grants.
 *
 * ── WHY THIS CLASS EXISTS ─────────────────────────────────────────────────────
 * Assigning a Permission Set Group creates a PermissionSetAssignment row that points at the GROUP,
 * not at each member set. A permission check written only as
 * `PermissionSet.Name = 'Lead_Stage_Actions_Access'` therefore returns FALSE for a user who holds
 * that set through a group — silently locking out a correctly-provisioned user. This org uses
 * permission set groups as its primary provisioning mechanism (DPEG_Junior_Analyst_PSG,
 * DPEG_Principal_PSG, DPEG_Property_Management_Team, DPEG_Transaction_Team), so group expansion is
 * a real requirement here, not a hypothetical one. Neither Lead_Stage_Actions_Access nor
 * Broker_Protection_Access is a member of a group TODAY — this class is what keeps the gate
 * correct on the day an admin adds one.
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector).
 *
 * `WITH USER_MODE` per ARCHITECTURE.md §2 / .claude/rules. Like PermissionSetAssignment, this is a
 * setup entity not governed by profile object permissions. ⚠ VERIFY IN ORG: an access failure here
 * propagates (it is deliberately NOT swallowed) and the gate fails CLOSED — the button is blocked,
 * never wrongly enabled. Confirm with a non-admin user during UAT.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The public method accepts a `Set<Id>` and issues ONE query for the whole set — no SOQL in a
 * loop. The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply to the volume:
 * the input is bounded by the number of groups assigned to a single user (typically 1-2), and this
 * runs once per transaction for the running user only.
 *
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls
 * @see force-app/main/default/classes/LeadActionPermissionService.cls (consumer)
 */
public with sharing class PermissionSetGroupComponentSelector {

    /**
     * The permission sets that make up the given permission set groups — i.e. what a user actually
     * receives when one of those groups is assigned to them.
     *
     * Bulk-safe: a single query over the whole Id set, regardless of how many groups are passed.
     *
     * NOT-FOUND CONTRACT — an empty List, never null, for null/empty input or no matching rows.
     *
     * @param permissionSetGroupIds The groups to expand; null/empty-safe.
     * @return The member components with Id, PermissionSetGroupId, PermissionSetId and
     *         PermissionSet.Name populated; empty when the input is null/empty or nothing matches.
     * @example
     * List<PermissionSetGroupComponent> members =
     *     PermissionSetGroupComponentSelector.selectByGroupIds(assignedGroupIds);
     */
    public static List<PermissionSetGroupComponent> selectByGroupIds(Set<Id> permissionSetGroupIds) {
        if (permissionSetGroupIds == null || permissionSetGroupIds.isEmpty()) {
            return new List<PermissionSetGroupComponent>();
        }
        return [
            SELECT Id,
                   PermissionSetGroupId,
                   PermissionSetId,
                   PermissionSet.Name
            FROM PermissionSetGroupComponent
            WHERE PermissionSetGroupId IN :permissionSetGroupIds
            WITH USER_MODE
        ];
    }
}
