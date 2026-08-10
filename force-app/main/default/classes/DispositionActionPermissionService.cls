/**
 * DispositionActionPermissionService — the single source of truth for "may the running user drive
 * the DISPOSITION stage quick actions?".
 *
 * Added 2026-08-09 (Tranche 3A, decision D15/Q1). It is the sell-side twin of
 * OpportunityActionPermissionService and mirrors it deliberately, line for line where the
 * reasoning transfers. Consumed through RecordStageAdvanceService's per-record-type gate
 * dispatch: today the `Disposition_NDA` record type of `NDA__c`, and in tranches 3B/3C the
 * disposition record types of `LOI__c` and `Contract_Review__c`.
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It orchestrates two
 * selectors and holds zero SOQL and zero DML of its own.
 *
 * ── THE GATE IS TWO-FACTOR, AND THAT IS THE WHOLE POINT ───────────────────────
 *   (a) FLS READ on `User.Disposition_Driver__c`, granted only by the `Disposition_Deal_Driver`
 *       permission set. Enforced by `WITH USER_MODE` inside UserSelector: a user without that FLS
 *       makes the query THROW, which this class converts to `false`.
 *   (b) The FIELD VALUE `Disposition_Driver__c = true` on the running user's own User record.
 *
 * ── 🔴 WHY THIS IS A NEW FIELD AND A NEW SERVICE, NOT A REUSE ─────────────────
 * Three cheaper options were considered and all three are rejected in the decision record; the
 * reasons are worth carrying here because each of them looks like tidying:
 *
 *   1. GRANT `Deal_Driver__c` TO DISPOSITION USERS. Zero new metadata — and it also hands them
 *      the six OPPORTUNITY deal actions. It merges two authorization boundaries: a sale driver
 *      could then drive acquisitions.
 *   2. A PERMISSION-SET MEMBERSHIP CHECK (the Lead gate's shape). Membership and the flag are
 *      DIFFERENT QUESTIONS. A user holding `Disposition_Deal_Driver` with
 *      `Disposition_Driver__c = false` is denied here and would be GRANTED by a membership check
 *      — a one-factor gate wearing a two-factor gate's name. Adding a permission-set name to this
 *      class does not "also" grant access, it REPLACES the condition for every holder.
 *   3. NO GATE AT ALL on the disposition record types. `passesGate`'s `when else` fails closed, so
 *      an unwired enum value denies silently — which is exactly why the DISPOSITION_DRIVER value
 *      was deliberately NOT declared until this class and the field existed.
 *
 * A flexipage visibility rule also cannot call Apex, so a User field is the only thing the
 * declarative half of the gate can bind to. The two halves are complementary: App Builder HIDES
 * the button, this class REFUSES the call.
 *
 * ── 🔴 ADMIN BYPASS, AND ITS ORDER IS LOAD-BEARING ────────────────────────────
 * "Modify All Data" passes BEFORE the flag is read, and reversing those two statements locks
 * every administrator out of the feature they just deployed. That is MEASURED behaviour in this
 * org, not caution: a Metadata-API-deployed custom field arrives with NO field permissions for
 * ANY profile, and Modify All Data is an OBJECT permission that confers no FLS — so
 * `UserSelector` throws for a bare System Administrator exactly as it does for a bare Standard
 * User (pinned by UserSelectorTest.selectDealDriverFlagForCurrentUser_bareAdministrator_
 * alsoLacksFieldAccess on the acquisitions twin, and by this feature's own test below).
 *
 * ⚠ Consequently AN ADMIN SMOKE TEST PROVES NOTHING ABOUT THIS GATE. Acceptance-test as a real
 * disposition-driver persona; FLS truth lives in the org, not this repo (profiles are
 * `.forceignore`d).
 *
 * ── FAIL CLOSED, BUT DO NOT DISGUISE A SYSTEM FAULT AS A DENIAL ───────────────
 *   - An FLS failure reading `Disposition_Driver__c` is EXPECTED for an unprivileged user. It IS
 *     the denial signal for factor (a), so it is caught and converted to `false`.
 *   - A failure of the permission machinery itself (the PermissionSetAssignment read) is NOT a
 *     denial signal — it is a fault, and it PROPAGATES. The controller masks it behind a fixed
 *     message and the LWC guard treats a thrown check exactly like `false`, so the gate still
 *     fails CLOSED end to end; the difference is only that a fault reads as a fault.
 * Nothing here can return `true` by accident: every path to `true` requires positive evidence.
 * That asymmetry (the assignment read sits deliberately OUTSIDE the try/catch) is the same known,
 * accepted residual documented on the acquisitions twin — it is not copied by accident, and it
 * must not be "fixed" as a drive-by edit on either class alone.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user) with no record collection,
 * no loop over records and no DML — the same shape the rule exempts for
 * OpportunityActionPermissionService and LeadActionPermissionService. Cost is at most two queries
 * per transaction regardless of how many quick actions ask, which the test suite asserts directly
 * via Limits.getQueries() rather than by volume.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the acquisitions twin)
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (the gate dispatch)
 * @see force-app/main/default/classes/UserSelector.cls (factor (a) + (b))
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls (admin bypass)
 * @see force-app/main/default/permissionsets/Disposition_Deal_Driver.permissionset-meta.xml
 */
public with sharing class DispositionActionPermissionService {

    /**
     * Raised when the running user may not drive a Disposition stage action. Typed (rather than
     * AuraHandledException) so this service stays UI-agnostic — the controller owns the mapping to
     * the LWC boundary. Repo precedent: OpportunityActionPermissionService.AccessDeniedException.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * The user-facing denial message.
     *
     * ⚠ It is deliberately the SAME STRING as the Lead and Opportunity gates', reused from
     * OpportunityActionPermissionService rather than re-declared, so a future edit to the wording
     * cannot leave three features speaking with two voices. RecordStageAdvanceService throws its
     * own AccessDeniedException carrying this value regardless of which gate refused, which is why
     * a user can never tell the two gates apart from a toast — correct, since "which permission
     * you are missing" is not information a refused caller is owed.
     */
    public static final String NO_PERMISSION_MESSAGE =
        OpportunityActionPermissionService.NO_PERMISSION_MESSAGE;

    // Transaction-scoped cache of the composed answer. Neither the running user's FLS nor their
    // Disposition_Driver__c value can change mid-transaction, so the selector reads happen at most
    // once per execution context even when several quick actions on one page ask.
    // @TestVisible so tests can reset it between System.runAs blocks — the running user changes
    // there and the cache must not survive that.
    @TestVisible
    private static Boolean cachedHasDispositionActionAccess;

    /**
     * Test seam. The controller's AuraHandledException catch exists for a real failure mode (a
     * setup-object access failure under the PermissionSetAssignment read), but that mode cannot be
     * provoked deterministically — every user can read their OWN assignment rows. This flag is the
     * only deterministic way to reach that branch.
     *
     * It is `private` + `@TestVisible` (so no production class can set it) AND additionally gated
     * on Test.isRunningTest(), so production behaviour is provably unchanged. Repo precedent:
     * OpportunityActionPermissionService.simulateLookupFailure.
     */
    @TestVisible
    private static Boolean simulateLookupFailure = false;

    /**
     * Whether the running user may drive the Disposition stage quick actions.
     *
     * @return true when the user has "Modify All Data", or has FLS read on
     *         `User.Disposition_Driver__c` AND that flag is `true` on their own User record;
     *         false otherwise (including when the FLS read is denied).
     * @throws System.QueryException when the permission-set lookup behind the admin bypass fails
     *         unexpectedly. Deliberately NOT swallowed — see the fail-closed note in the class
     *         header.
     * @example
     * if (!DispositionActionPermissionService.hasDispositionActionAccess()) { return; }
     */
    public static Boolean hasDispositionActionAccess() {
        if (cachedHasDispositionActionAccess != null) {
            return cachedHasDispositionActionAccess;
        }
        // Assign only AFTER a successful computation: a thrown fault must leave the cache empty so
        // the next ask re-evaluates rather than memoizing a fault as an answer.
        Boolean allowed = computeDispositionActionAccess();
        cachedHasDispositionActionAccess = allowed;
        return allowed;
    }

    /**
     * Server-side guard for the Disposition stage actions.
     *
     * ⚠ In this tranche the disposition actions reach the server through
     * RecordStageAdvanceController, which asserts via
     * RecordStageAdvanceService.assertStageActionAccess (that method dispatches to the record's
     * gate and throws ITS OWN AccessDeniedException, so the controller's catch order is unchanged
     * by this feature). This method exists for a future disposition-specific entry point and for
     * symmetry with the acquisitions twin — call it at the top of any such method.
     *
     * @throws DispositionActionPermissionService.AccessDeniedException carrying
     *         NO_PERMISSION_MESSAGE when the running user lacks access.
     * @throws System.QueryException when the permission lookup itself fails unexpectedly.
     * @example
     * DispositionActionPermissionService.assertDispositionActionAccess();
     */
    public static void assertDispositionActionAccess() {
        if (hasDispositionActionAccess()) {
            return;
        }
        throw new AccessDeniedException(NO_PERMISSION_MESSAGE);
    }

    /**
     * Evaluates the two-factor gate. Ordered so the admin bypass runs FIRST and an administrator
     * never depends on Disposition_Driver__c FLS at all — see the class header; reversing these
     * two statements is a lockout, not a style preference.
     */
    private static Boolean computeDispositionActionAccess() {
        if (simulateLookupFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        if (hasModifyAllData()) {
            return true;
        }

        try {
            User runningUser = UserSelector.selectDispositionDriverFlagForCurrentUser();
            // `== true` rather than a bare truth test: Disposition_Driver__c is a nullable Boolean
            // in Apex and an explicit comparison cannot NPE.
            return runningUser != null && runningUser.Disposition_Driver__c == true;
        } catch (QueryException e) {
            // EXPECTED, not exceptional: WITH USER_MODE throws for a user without FLS read on
            // Disposition_Driver__c, which is precisely factor (a) of the gate being unmet. Not
            // logged — for the majority of users this is the normal path and logging it would be
            // noise, not signal.
            return false;
        }
    }

    /**
     * Whether the running user holds "Modify All Data" — through their profile or any assigned
     * permission set.
     *
     * A user's PROFILE surfaces in PermissionSetAssignment as an assignment to a PermissionSet
     * with `IsOwnedByProfile = true`, and a permission set GROUP assignment points at the group's
     * aggregate permission set, so this single pass covers profile-granted, set-granted and
     * group-granted "Modify All Data" without any group expansion.
     */
    private static Boolean hasModifyAllData() {
        for (PermissionSetAssignment assignment : PermissionSetAssignmentSelector.selectForCurrentUser()) {
            if (assignment.PermissionSet != null
                    && assignment.PermissionSet.PermissionsModifyAllData == true) {
                return true;
            }
        }
        return false;
    }

    /**
     * Clears the transaction-scoped cache. Test-only: production code runs in a single user
     * context per transaction, but a test switching users with System.runAs must not inherit the
     * previous user's answer.
     */
    @TestVisible
    private static void clearCache() {
        cachedHasDispositionActionAccess = null;
        simulateLookupFailure = false;
    }
}
