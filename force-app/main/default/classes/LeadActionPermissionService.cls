/**
 * LeadActionPermissionService — the single source of truth for "may the running user drive the
 * Lead stage quick actions?".
 *
 * Backs the four headless Lead quick actions (leadConvertAction, leadMarkUnderReview,
 * leadMarkQualified, leadDisqualify) and their shared c/leadStatusChange util. It is consumed two
 * ways:
 *   - LeadActionPermissionController.hasLeadActionAccess() — the cacheable read the LWCs call to
 *     decide whether to run the action at all (a UX gate).
 *   - LeadConvertActionController.convertLead(...) — a server-side assertion, so the irreversible
 *     Convert cannot be driven by calling the Apex directly (real enforcement).
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It orchestrates two
 * selectors and holds zero SOQL and zero DML of its own.
 *
 * ── WHAT "PERMISSION" MEANS HERE, AND WHAT IT DOES NOT ────────────────────────
 * This class answers a PERMISSION SET MEMBERSHIP question. That is an authorization gate layered
 * ON TOP OF the platform's own enforcement — it does not replace it:
 *   - Convert is ultimately enforced by the "Convert Leads" user permission plus Create access on
 *     Account/Contact/Opportunity; Database.convertLead throws a DmlException without them.
 *   - The three status transitions are written by the LWC through LDS updateRecord, so they are
 *     ultimately enforced by CRUD/FLS on Lead.Status. Apex is NOT in that call path at all, which
 *     means the check this class performs is, for those three buttons, an affordance only. A user
 *     with Lead edit rights but without the permission set can still change Status by other means
 *     (inline edit, the Path, the standard Change Status action, the API). Removing Lead edit
 *     access is the only way to actually prevent that.
 * Both facts are stated plainly so nobody mistakes this gate for the whole control.
 *
 * ── ADMIN BYPASS (deliberate) ─────────────────────────────────────────────────
 * A user whose profile or permission sets grant "Modify All Data" always passes. Administrators
 * can already edit and convert any Lead through the standard UI, so denying them the button would
 * be theatre rather than security — and it would make the org's own admins the only users unable
 * to use the feature they just deployed. This also keeps the existing
 * LeadConvertActionControllerTest green without assigning permission sets to the test-running user.
 *
 * ── FAIL-CLOSED ───────────────────────────────────────────────────────────────
 * Nothing here swallows an exception. If a selector throws (e.g. a setup-object access failure
 * under WITH USER_MODE), it propagates to the controller, which converts it to an
 * AuraHandledException; the LWC then treats a failed check exactly like a denied one. The action is
 * blocked, never wrongly permitted.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * `hasAnyPermissionSet` accepts a COLLECTION of permission set names, and the underlying reads are
 * two queries total regardless of how many names are passed — no SOQL in a loop. The 251-record
 * mandate in .claude/rules/bulk-test-rule.md does not apply: this is a per-transaction-singleton
 * question about ONE user (the running user), the same shape the rule exempts for the Broker
 * Protection async pipeline. There is no record collection at this layer to bulk-test.
 *
 * @see force-app/main/default/classes/LeadActionPermissionController.cls (LWC boundary)
 * @see force-app/main/default/classes/LeadConvertActionController.cls (server-side assertion)
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls
 * @see force-app/main/default/classes/PermissionSetGroupComponentSelector.cls
 */
public with sharing class LeadActionPermissionService {

    /**
     * Raised when the running user may not drive a Lead stage action. Typed (rather than
     * AuraHandledException) so this service stays UI-agnostic — the controller owns the mapping to
     * the LWC boundary. Repo precedent: TransactionTaskService.WireVerificationException.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * The user-facing denial message. Deliberately identical for every one of the four buttons and
     * for both the client-side gate and the server-side assertion, so the user never sees two
     * different phrasings for the same condition.
     */
    public static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    /**
     * Holding EITHER of these permission sets grants the Lead stage actions.
     *
     * Lead_Stage_Actions_Access is the Lead-specific set (it already carries the "Convert Leads"
     * user permission and class access to LeadConvertActionController, so it is the correct
     * primary gate). Broker_Protection_Access is accepted as well because the inbound
     * broker-email pipeline creates these Leads and its operators need to triage them.
     */
    private static final Set<String> LEAD_ACTION_PERMISSION_SETS = new Set<String>{
        'Lead_Stage_Actions_Access',
        'Broker_Protection_Access'
    };

    // Transaction-scoped cache. The assignment set cannot change mid-transaction, so the two
    // selector reads happen at most once per execution context even when several quick actions ask.
    // @TestVisible so tests can reset it between System.runAs blocks (the running user changes, the
    // cache must not survive that).
    @TestVisible
    private static Set<String> cachedPermissionSetNames;

    @TestVisible
    private static Boolean cachedHasModifyAllData;

    /**
     * Test seam. The controller's AuraHandledException catch exists for a real failure mode (a
     * setup-object access failure under WITH USER_MODE), but that mode cannot be provoked
     * deterministically from a test — PermissionSetAssignment is readable by every user for their
     * own rows, so even a bare Standard User does not make the selector throw. This flag is the only
     * deterministic way to reach that catch, and without it the controller would sit far below the
     * 90% bar on an uncoverable branch.
     *
     * It is `private` + `@TestVisible` (so no production class can set it) AND additionally gated on
     * Test.isRunningTest(), so production behavior is provably unchanged. Repo precedent:
     * BrokerPortalService's @TestVisible static-cache manipulation for its "queue not found" branch.
     */
    @TestVisible
    private static Boolean simulateLoadFailure = false;

    /**
     * Whether the running user may drive the Lead stage quick actions.
     *
     * @return true when the user holds Lead_Stage_Actions_Access or Broker_Protection_Access
     *         (directly or through a permission set group), or has "Modify All Data".
     * @example
     * if (!LeadActionPermissionService.hasLeadActionAccess()) { return; }
     */
    public static Boolean hasLeadActionAccess() {
        return hasAnyPermissionSet(LEAD_ACTION_PERMISSION_SETS);
    }

    /**
     * Server-side guard for the Lead stage actions. Use this on any Apex entry point that performs
     * the action, so the gate cannot be bypassed by calling the controller directly.
     *
     * @throws LeadActionPermissionService.AccessDeniedException carrying NO_PERMISSION_MESSAGE when
     *         the running user lacks access.
     * @example
     * LeadActionPermissionService.assertLeadActionAccess();
     */
    public static void assertLeadActionAccess() {
        if (hasLeadActionAccess()) {
            return;
        }
        throw new AccessDeniedException(NO_PERMISSION_MESSAGE);
    }

    /**
     * Whether the running user holds ANY of the named permission sets — directly, through a
     * permission set group, or implicitly via "Modify All Data".
     *
     * Generic on purpose: the Lead-specific names live in this class's own constant, but the
     * membership logic is reusable by any future feature that needs a permission set gate.
     *
     * @param permissionSetNames Permission set API Names (not labels) to test for; null/empty
     *                           returns false (an empty requirement is not a grant).
     * @return true when at least one name matches, or the user has "Modify All Data".
     * @example
     * Boolean allowed = LeadActionPermissionService.hasAnyPermissionSet(
     *     new Set<String>{ 'Lead_Stage_Actions_Access' });
     */
    public static Boolean hasAnyPermissionSet(Set<String> permissionSetNames) {
        if (permissionSetNames == null || permissionSetNames.isEmpty()) {
            return false;
        }
        loadRunningUserGrants();
        // `== true` rather than a bare truth test: the field is a nullable Boolean, and an explicit
        // comparison cannot NPE if a test seeds the cache partially.
        if (cachedHasModifyAllData == true) {
            return true;
        }
        Set<String> matches = permissionSetNames.clone();
        matches.retainAll(cachedPermissionSetNames);
        return !matches.isEmpty();
    }

    /**
     * Loads (once per transaction) every permission set API Name the running user effectively
     * holds, plus whether any of them grants "Modify All Data".
     *
     * Two queries at most: the user's assignments, then — only when the user actually has group
     * assignments — the member sets of those groups.
     */
    private static void loadRunningUserGrants() {
        if (cachedPermissionSetNames != null) {
            return;
        }
        if (simulateLoadFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        Set<String> names = new Set<String>();
        Set<Id> assignedGroupIds = new Set<Id>();
        Boolean isSuperUser = false;

        for (PermissionSetAssignment assignment : PermissionSetAssignmentSelector.selectForCurrentUser()) {
            if (assignment.PermissionSet != null) {
                // The profile surfaces here as an IsOwnedByProfile permission set, so this one flag
                // covers both profile-granted and permission-set-granted "Modify All Data".
                if (assignment.PermissionSet.PermissionsModifyAllData == true) {
                    isSuperUser = true;
                }
                if (String.isNotBlank(assignment.PermissionSet.Name)) {
                    names.add(assignment.PermissionSet.Name);
                }
            }
            if (assignment.PermissionSetGroupId != null) {
                assignedGroupIds.add(assignment.PermissionSetGroupId);
            }
        }

        // Expand group assignments into their member sets — see PermissionSetGroupComponentSelector
        // for why a name-only check would otherwise miss a group-provisioned user.
        for (PermissionSetGroupComponent member
                : PermissionSetGroupComponentSelector.selectByGroupIds(assignedGroupIds)) {
            if (member.PermissionSet != null && String.isNotBlank(member.PermissionSet.Name)) {
                names.add(member.PermissionSet.Name);
            }
        }

        cachedPermissionSetNames = names;
        cachedHasModifyAllData = isSuperUser;
    }

    /**
     * Clears the transaction-scoped cache. Test-only: production code runs in a single user context
     * per transaction, but a test switching users with System.runAs must not inherit the previous
     * user's grants.
     */
    @TestVisible
    private static void clearCache() {
        cachedPermissionSetNames = null;
        cachedHasModifyAllData = null;
        simulateLoadFailure = false;
    }
}
