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
 * `WITH SYSTEM_MODE` (changed from USER_MODE 2026-08-03 — see below).
 *
 * ✅ THE "VERIFY IN ORG" NOTE THAT USED TO SIT HERE IS NOW ANSWERED, AND THE ANSWER WAS "IT BREAKS".
 * It read: "⚠ VERIFY IN ORG: an access failure here propagates and the gate fails CLOSED — the
 * button is blocked, never wrongly enabled. Confirm with a non-admin user during UAT." That UAT
 * happened on 2026-08-03: a non-admin persona (Minimum Access profile, holding the qualifying
 * permission sets DIRECTLY) clicked Convert and got "Unable to verify your permissions" — the
 * controller's catch-all. Measured on DPEG-Acq-5, all with the identical query:
 *
 *   | Principal                      | WITH USER_MODE                                  |
 *   | System Administrator           | OK — rows returned                              |
 *   | Standard User                  | OK — rows returned                              |
 *   | Minimum Access - Salesforce    | THROWS System.QueryException                    |
 *   | Minimum Access, SYSTEM_MODE    | OK — rows returned                              |
 *
 * Verbatim: `System.QueryException: sObject type 'PermissionSetGroupComponent' is not supported.`
 * Note the message is the misleading "not supported" flavour, NOT an FLS message — which is why the
 * failure was not recognised as a mode problem. Note also that STANDARD USER PASSES: that is
 * precisely why this went undetected, because the repo's runAs tests use Standard User while the
 * real personas are provisioned on Minimum Access.
 *
 * WHY SYSTEM_MODE IS CORRECT HERE, NOT A WEAKENING:
 *   • This reads GROUP COMPOSITION — org configuration, not user data. "Which permission sets does
 *     this group contain" is the same class of fact as a picklist's values; it exposes nothing
 *     about any record and nothing about any other user.
 *   • MEMBERSHIP STILL COMES FROM THE USER'S OWN ASSIGNMENT ROWS. This selector only expands groups
 *     the caller already proved are assigned to the running user. Reading composition in system
 *     mode cannot grant access to a group the user does not hold.
 *   • USER_MODE here defeated the selector's entire purpose. Its own header says it exists to "keep
 *     the gate correct on the day an admin adds one" — but under USER_MODE that day would instead
 *     BREAK the gate for every group-provisioned non-admin. A guard that fails exactly when it is
 *     first needed is not a guard.
 *   • "Fails closed" is the right direction for a security decision but the wrong outcome for a
 *     CONFIGURATION read: it denied correctly-provisioned users a feature they were granted, while
 *     protecting nothing. Same reasoning the EAC guard selectors already carry for automation paths
 *     (EmailMessageSelector / EmailMessageRelationSelector / TaskSelector's guard methods): when
 *     USER_MODE throws rather than degrades, the result is silent feature disablement, which
 *     secures nothing.
 *
 * The gate itself still fails closed for GENUINE failures — LeadActionPermissionService swallows
 * nothing, and the controller still converts any propagating exception into a denial.
 *
 * ── ⛔ CALLER OBLIGATION: PASS ONLY THE RUNNING USER'S OWN GROUP IDs ───────────────────────────
 * CALLERS MUST pass only permission set group Ids derived from the RUNNING USER'S OWN assignment
 * rows (i.e. the PermissionSetGroupId values returned by
 * PermissionSetAssignmentSelector.selectForCurrentUser()). Never pass a group Id from any other
 * source — user input, a hard-coded Id, another user's assignments, or a query over all groups.
 *
 * ⚠ THIS SELECTOR IS SCOPED BY CONVENTION, NOT BY CONSTRUCTION. Unlike its sibling
 * PermissionSetAssignmentSelector — whose WHERE clause pins AssigneeId to the running user and so
 * enforces its own scope — this class takes an ARBITRARY Set<Id> and will faithfully expand any
 * group it is handed. Since 2026-08-03 it runs `WITH SYSTEM_MODE`, so the platform checks nothing
 * either. CALLER DISCIPLINE IS THEREFORE THE ONLY CONTROL. Handing it a group the running user does
 * not hold turns a permission CHECK into a permission ORACLE: the result would report what that
 * group grants, and a gate built on it would grant access the user was never provisioned.
 *
 * This is the same kind of caller-guarantee obligation as EmailToLeadService.deleteLead's "SAFETY —
 * the caller must invoke this ONLY on the explicit ClaimOutcome.DUPLICATE_RACE" note: an invariant
 * the class cannot enforce for itself, recorded here so it is upheld deliberately rather than by
 * luck. The sole consumer today (LeadActionPermissionService.loadRunningUserGrants) satisfies it —
 * it passes exactly the group Ids it read from the running user's own assignment rows.
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
            WITH SYSTEM_MODE
        ];
    }
}
