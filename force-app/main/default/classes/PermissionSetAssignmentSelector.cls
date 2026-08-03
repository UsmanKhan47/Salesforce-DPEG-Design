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
 * `WITH SYSTEM_MODE` (changed from USER_MODE 2026-08-03).
 *
 * ✅ THIS CLASS'S OWN "VERIFY IN ORG" NOTE PREDICTED THE INCIDENT AND WAS RIGHT. It read: "every
 * user can read their OWN assignments — so USER_MODE is not expected to restrict this query.
 * ⚠ VERIFY IN ORG: if USER_MODE ever throws here for a non-admin, the gate fails CLOSED ... a
 * visible regression worth catching in UAT with a non-admin user." It threw, and the regression was
 * caught in UAT on 2026-08-03: a Minimum Access persona holding the qualifying permission sets
 * DIRECTLY was refused the Lead Convert action with "Unable to verify your permissions".
 *
 * ⚠ THE STANDING ASSUMPTION "every user can read their own assignments" IS FALSE UNDER USER_MODE.
 * Measured on DPEG-Acq-5 — the query is `WHERE AssigneeId = :UserInfo.getUserId()`, i.e. the user's
 * OWN rows, and it still throws:
 *
 *   | Principal                      | WITH USER_MODE               |
 *   | System Administrator           | OK — 8 rows                  |
 *   | Standard User                  | OK — 2 rows                  |
 *   | Minimum Access - Salesforce    | THROWS System.QueryException |
 *
 * Verbatim: `System.QueryException: sObject type 'PermissionSetAssignment' is not supported.`
 * Reading your own rows is not the question USER_MODE asks — it asks whether the PRINCIPAL may see
 * the setup ENTITY at all, and Minimum Access may not.
 *
 * ⚠ THIS SELECTOR, NOT THE GROUP ONE, IS WHAT ACTUALLY FAILED FIRST. LeadActionPermissionService
 * calls this before any group expansion, so fixing only PermissionSetGroupComponentSelector would
 * have left the incident fully intact. Standard User passing is why it was never caught: the repo's
 * runAs tests use Standard User, the real personas are on Minimum Access.
 *
 * WHY SYSTEM_MODE IS CORRECT HERE: this is a filtered read of the RUNNING USER'S OWN assignment
 * rows, used to answer "what am I allowed to do". It is scoped by `AssigneeId = current user` in the
 * WHERE clause, so system mode widens nothing — it cannot return another user's grants. Granting a
 * user the ability to discover their own permissions is not a privilege escalation; refusing it
 * merely breaks the features they were correctly provisioned for. Same reasoning as the sibling
 * PermissionSetGroupComponentSelector and the EAC guard's automation-path selectors: USER_MODE that
 * THROWS rather than degrades produces silent feature disablement, which secures nothing.
 *
 * The gates built on this still fail closed for GENUINE failures — no consumer swallows exceptions;
 * LeadActionPermissionController and the Opportunity equivalent convert anything propagating into a
 * denial.
 *
 * ── ⛔ PROHIBITION: NEVER PARAMETERIZE THE ASSIGNEE, AND NEVER ADD A BULK VARIANT ──────────────
 * DO NOT add a method that takes an assignee/user Id parameter, and DO NOT add a bulk variant that
 * accepts a Set<Id> of users. This is a SECURITY constraint, not a style or bulkification opinion.
 *
 * Since 2026-08-03 this class runs `WITH SYSTEM_MODE`, so the platform no longer checks anything
 * about the caller. THE HARD-CODED `WHERE AssigneeId = :UserInfo.getUserId()` IS NOW THE ONLY
 * CONTROL ON THIS CLASS. A parameterized or bulk variant would remove it, letting any authenticated
 * user enumerate ANY other user's permission set assignments — i.e. read the org's entire security
 * model, including who holds Modify All Data. Under the previous USER_MODE such a method would at
 * least have been checked by the platform; that backstop is gone, deliberately, and this
 * prohibition is what replaces it.
 *
 * If a genuine need to read another user's assignments ever arises, it belongs in a SEPARATE,
 * explicitly-named selector method with its own authorization gate and its own justification — not
 * as a parameter added to this one.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply: this selector performs
 * one query for one user (the running user) per transaction, with no loop and no per-record work.
 * It is the same per-transaction-singleton shape the rule already exempts. There is no
 * collection-shaped behavior at this layer to bulk-test — and per the prohibition above, there must
 * never be any.
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
            // SYSTEM_MODE, scoped to the running user's OWN rows by the WHERE clause above — see
            // the MODE section in the class header for the measured reason USER_MODE cannot be used.
            WITH SYSTEM_MODE
        ];
    }
}
