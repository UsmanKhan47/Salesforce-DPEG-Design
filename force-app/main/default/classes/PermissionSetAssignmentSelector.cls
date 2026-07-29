/**
 * Selector for PermissionSetAssignment. Encapsulates ALL SOQL against PermissionSetAssignment per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector
 * classes. Nothing else queries that object.").
 *
 * Consumer: LeadActionPermissionService — the permission gate behind the Lead stage quick actions
 * (leadConvertAction / leadMarkUnderReview / leadMarkQualified / leadDisqualify). It answers
 * "which permission sets does the RUNNING user hold?".
 *
 * ── SCOPE: THE RUNNING USER ONLY ──────────────────────────────────────────────
 * Every method here is hard-filtered to `AssigneeId = UserInfo.getUserId()` and takes no assignee
 * parameter. This is deliberate and is the reason the class is safe to expose (indirectly) to an
 * `@AuraEnabled` boundary: a user can never use it to enumerate ANOTHER user's permissions, which
 * would leak the org's security model. Reading other users' assignments requires "View Setup and
 * Configuration"; this class never attempts it.
 *
 * Because the filter is a single fixed Id there is no collection-shaped ("bulk") variant to
 * provide — see the bulkification note below.
 *
 * ── WHY PermissionSet.PermissionsModifyAllData IS SELECTED ────────────────────
 * A user's PROFILE surfaces in this object as an assignment to a PermissionSet with
 * `IsOwnedByProfile = true`. Selecting `PermissionsModifyAllData` therefore lets one query answer
 * both questions the service needs — "which named sets?" and "is this an administrator?" — without
 * a second describe or query. The service uses the latter as its documented admin bypass.
 *
 * ── WHY PermissionSetGroupId IS SELECTED ──────────────────────────────────────
 * When a permission set is granted through a Permission Set GROUP, the assignment row points at
 * the GROUP, not at the member set — so `PermissionSet.Name` is the group's name and a name-only
 * check would silently miss the grant. This org actively uses permission set groups (4 are
 * deployed under force-app/main/default/permissionsetgroups/), so the group Ids are selected here
 * and expanded by PermissionSetGroupComponentSelector.
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector).
 *
 * `WITH USER_MODE` per ARCHITECTURE.md §2 / .claude/rules. PermissionSetAssignment is a setup
 * entity whose access is not granted through profile object permissions — every user can read
 * their OWN assignments — so USER_MODE is not expected to restrict this query. ⚠ VERIFY IN ORG:
 * if USER_MODE ever throws here for a non-admin, the gate fails CLOSED (the action is blocked,
 * never silently allowed), which is the correct direction for a security check but would be a
 * visible regression worth catching in UAT with a non-admin user.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply: this selector performs
 * one query for one user (the running user) per transaction, with no loop and no per-record work.
 * It is the same per-transaction-singleton shape the rule already exempts. There is no
 * collection-shaped behavior at this layer to bulk-test.
 *
 * @see force-app/main/default/classes/PermissionSetGroupComponentSelector.cls (group expansion)
 * @see force-app/main/default/classes/LeadActionPermissionService.cls (consumer)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class PermissionSetAssignmentSelector {

    /**
     * Every permission set assignment held by the RUNNING user — both direct permission set
     * assignments and permission set GROUP assignments.
     *
     * Rows where `PermissionSetGroupId` is populated represent a group assignment; the caller must
     * expand those through PermissionSetGroupComponentSelector to learn the member set names.
     * Rows where it is null are direct assignments (including the user's own profile, which
     * appears as an assignment to a PermissionSet with `IsOwnedByProfile = true`).
     *
     * NOT-FOUND CONTRACT — always a List, never null. In practice it is never empty, because every
     * user is assigned their profile's implicit permission set.
     *
     * @return The running user's assignments with Id, AssigneeId, PermissionSetId,
     *         PermissionSet.Name, PermissionSet.IsOwnedByProfile,
     *         PermissionSet.PermissionsModifyAllData and PermissionSetGroupId populated.
     *         AssigneeId is selected so a row is self-describing — it makes the "this really is the
     *         running user's row" guarantee assertable rather than implicit.
     * @example
     * for (PermissionSetAssignment psa : PermissionSetAssignmentSelector.selectForCurrentUser()) {
     *     String name = psa.PermissionSet.Name;
     * }
     */
    public static List<PermissionSetAssignment> selectForCurrentUser() {
        Id runningUserId = UserInfo.getUserId();
        return [
            SELECT Id,
                   AssigneeId,
                   PermissionSetId,
                   PermissionSet.Name,
                   PermissionSet.IsOwnedByProfile,
                   PermissionSet.PermissionsModifyAllData,
                   PermissionSetGroupId
            FROM PermissionSetAssignment
            WHERE AssigneeId = :runningUserId
            WITH USER_MODE
        ];
    }
}
