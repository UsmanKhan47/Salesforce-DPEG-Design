/**
 * OpportunityActionPermissionService — the single source of truth for "may the running user drive
 * the Opportunity stage quick actions?".
 *
 * Backs the five headless Opportunity quick-action bundles (advanceDealStage,
 * dealSendToDevelopmentReview, dealSendToConstructionReview, dealMoveToAboutToClose,
 * submitForApproval) and their shared c/dealActionGuard util. It is consumed two ways, exactly as
 * LeadActionPermissionService is on the Lead side:
 *   - OpportunityActionPermissionController.hasDealActionAccess() — the cacheable read the LWCs call
 *     before doing anything (a UX gate).
 *   - StageAdvanceController.advance / .advanceTo and
 *     OpportunityApprovalController.submitForApproval — a server-side assertion, so a stage write
 *     cannot be driven by calling the @AuraEnabled method directly (real enforcement).
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It orchestrates two
 * selectors and holds zero SOQL and zero DML of its own.
 *
 * ── THE GATE IS TWO-FACTOR, AND THAT IS THE WHOLE POINT ───────────────────────
 * This class asks the IDENTICAL question the six deployed Dynamic Actions visibility rules on
 * Opportunity_Record_Page already ask — `{!$User.Deal_Driver__c} EQUAL true` — which requires BOTH:
 *
 *   (a) FLS READ on `User.Deal_Driver__c`, granted only by the `Acquisition_Deal_Driver` permission
 *       set. Enforced by `WITH USER_MODE` inside UserSelector: a user without that FLS makes the
 *       query THROW, which this class converts to `false`.
 *   (b) The FIELD VALUE `Deal_Driver__c = true` on the running user's own User record.
 *
 * Asking the same question is a deliberate design constraint, not an accident of implementation.
 * The alternative considered and REJECTED was to mirror the Lead gate's PERMISSION SET MEMBERSHIP
 * check (`LeadActionPermissionService.hasAnyPermissionSet`). Membership and the flag are DIFFERENT
 * QUESTIONS: a user holding `Acquisition_Deal_Driver` with `Deal_Driver__c = false` is denied today
 * and would be GRANTED by a membership check. That is a silent widening of a live authorization
 * boundary, so this class deliberately does not reuse that method — the reuse would have been
 * tidier and wrong. See the Opportunity design doc, findings F3 / Option B.
 *
 * Consequence to keep in mind when changing this class: adding a permission-set name here does not
 * "also" grant access, it REPLACES a two-factor condition with a one-factor one for every holder.
 *
 * ── ADMIN BYPASS (deliberate) ─────────────────────────────────────────────────
 * A user whose profile or permission sets grant "Modify All Data" always passes, before the flag is
 * even read. Administrators can already move any deal through inline edit, the Path, or the API, so
 * denying them the button would be theatre rather than security — and it would make the org's own
 * admins the only users unable to use the feature they just deployed. It also keeps the existing
 * StageAdvanceControllerTest / OpportunityApprovalControllerTest suites green without provisioning
 * permission sets to the test-running user. Same rationale and same mechanism as
 * LeadActionPermissionService.
 *
 * ⚠ This bypass is why an admin smoke test PROVES NOTHING about this feature. Acceptance-test as a
 * real deal-driver persona; FLS truth lives in the org, not this repo (profiles are
 * `.forceignore`d).
 *
 * ── FAIL CLOSED, BUT DO NOT DISGUISE A SYSTEM FAULT AS A DENIAL ───────────────
 * Two failure modes are handled differently ON PURPOSE:
 *   - An FLS failure reading `Deal_Driver__c` is EXPECTED for an unprivileged user. It IS the
 *     denial signal for factor (a), so it is caught and converted to `false`.
 *   - A failure of the permission machinery itself (the PermissionSetAssignment read) is NOT a
 *     denial signal — it is a fault. It PROPAGATES to the controller, which masks it behind a fixed
 *     "unable to verify your permissions" message and logs the stack. The LWC guard treats a thrown
 *     check exactly like `false`, so the gate still fails CLOSED end to end; the difference is only
 *     that a genuine fault reads as a fault instead of as "you lack permission".
 * Nothing here can return `true` by accident: every path to `true` requires positive evidence.
 *
 * ── ⚠ THIS SERVICE CARRIED THE 2026-08-03 PERMISSION-GATE BUG TOO (fixed, zero code change here) ──
 * The incident was reported against the LEAD quick actions ("Unable to verify your permissions" for
 * a Minimum Access persona), but the root cause was in PermissionSetAssignmentSelector, which THIS
 * service also consumes — so the Opportunity deal actions failed identically for the same users.
 * Measured on DPEG-Acq-5: `PermissionSetAssignment ... WITH USER_MODE` THROWS `System.QueryException`
 * for a Minimum Access user (System Administrator and Standard User both pass, which is why no test
 * caught it — every runAs proof in this repo used Standard User).
 *
 * ⚠ THE SELECTOR READ IN hasModifyAllData() SITS DELIBERATELY OUTSIDE THE try/catch. That catch, in
 * computeDealActionAccess(), wraps ONLY the UserSelector Deal_Driver__c read, where a QueryException
 * genuinely MEANS "factor (a) unmet" and converting it to `false` is the correct reading. The
 * assignment read is a different question and must not be silently swallowed the same way. Under the
 * old USER_MODE that placement meant a Minimum Access user made this gate THROW instead of DENY —
 * and a gate that throws is not a stricter gate, it is a broken one, because it takes the
 * administrator bypass down with it.
 *
 * Both selectors now run `WITH SYSTEM_MODE` (each justified in its own header), so this service is
 * fixed with NO code change — it inherits the fix. Pinned by
 * OpportunityActionPermissionServiceTest.hasDealActionAccess_minimumAccessUser_deniesWithoutThrowing,
 * which asserts DENY-not-THROW.
 *
 * ⛔ RESIDUAL, AND IT IS A TRACKED FOLLOW-UP — DO NOT "FIX" IT MID-INCIDENT. A genuine future
 * selector failure still propagates out of hasModifyAllData(), reaching
 * OpportunityActionPermissionController's catch and denying with the generic message — a different
 * posture from the Lead gate's. That asymmetry is now KNOWN and ACCEPTED, not accidental. Changing
 * it means re-opening the two-factor gate's failure semantics, which is a deliberate design decision
 * with its own review, not a drive-by edit attached to an unrelated change.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user) with no record collection,
 * no loop over records, and no DML — the same shape the rule exempts for the Broker Protection
 * async pipeline and for LeadActionPermissionService. Cost is at most two queries per transaction
 * regardless of how many quick actions ask, which the test suite asserts directly via
 * Limits.getQueries() rather than by volume.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionController.cls (LWC boundary)
 * @see force-app/main/default/classes/UserSelector.cls (factor (a) + (b))
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls (admin bypass)
 * @see force-app/main/default/classes/LeadActionPermissionService.cls (the Lead-side analogue)
 * @see force-app/main/default/lwc/dealActionGuard/dealActionGuard.js (sole LWC consumer)
 */
public with sharing class OpportunityActionPermissionService {

    /**
     * Raised when the running user may not drive an Opportunity stage action. Typed (rather than
     * AuraHandledException) so this service stays UI-agnostic — the controller owns the mapping to
     * the LWC boundary. Repo precedent: LeadActionPermissionService.AccessDeniedException.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * The user-facing denial message. Deliberately identical for every quick action and for both the
     * client-side gate and the server-side assertion, so the user never sees two different
     * phrasings for the same condition. Also identical to the Lead wording, so the two features
     * speak with one voice.
     */
    public static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    // Transaction-scoped cache of the composed answer. Neither the running user's FLS nor their
    // Deal_Driver__c value can change mid-transaction, so the selector reads happen at most once per
    // execution context even when several quick actions on one page ask.
    // @TestVisible so tests can reset it between System.runAs blocks — the running user changes
    // there and the cache must not survive that.
    @TestVisible
    private static Boolean cachedHasDealActionAccess;

    /**
     * Test seam. The controller's AuraHandledException catch exists for a real failure mode (a
     * setup-object access failure under WITH USER_MODE while reading PermissionSetAssignment), but
     * that mode cannot be provoked deterministically — every user can read their OWN assignment
     * rows, so even a bare Standard User does not make the selector throw. This flag is the only
     * deterministic way to reach that catch; without it the controller would sit far below the 90%
     * bar on an uncoverable branch.
     *
     * It is `private` + `@TestVisible` (so no production class can set it) AND additionally gated on
     * Test.isRunningTest(), so production behaviour is provably unchanged. Repo precedent:
     * LeadActionPermissionService.simulateLoadFailure.
     */
    @TestVisible
    private static Boolean simulateLookupFailure = false;

    /**
     * Whether the running user may drive the Opportunity stage quick actions.
     *
     * @return true when the user has "Modify All Data", or has FLS read on `User.Deal_Driver__c`
     *         AND that flag is `true` on their own User record; false otherwise (including when the
     *         FLS read is denied).
     * @throws System.QueryException when the permission-set lookup behind the admin bypass fails
     *         unexpectedly. Deliberately NOT swallowed — see the fail-closed note in the class
     *         header. The controller masks and logs it; the LWC treats it as denied.
     * @example
     * if (!OpportunityActionPermissionService.hasDealActionAccess()) { return; }
     */
    public static Boolean hasDealActionAccess() {
        if (cachedHasDealActionAccess != null) {
            return cachedHasDealActionAccess;
        }
        // Assign only AFTER a successful computation: a thrown fault must leave the cache empty so
        // the next ask re-evaluates rather than memoizing a fault as an answer.
        Boolean allowed = computeDealActionAccess();
        cachedHasDealActionAccess = allowed;
        return allowed;
    }

    /**
     * Server-side guard for the Opportunity stage actions. Call this at the top of any Apex entry
     * point that performs a stage write or an approval submission, so the declarative visibility
     * rule — which is a UX affordance only — cannot be bypassed by invoking the @AuraEnabled method
     * directly.
     *
     * @throws OpportunityActionPermissionService.AccessDeniedException carrying
     *         NO_PERMISSION_MESSAGE when the running user lacks access.
     * @throws System.QueryException when the permission lookup itself fails unexpectedly (see
     *         hasDealActionAccess).
     * @example
     * OpportunityActionPermissionService.assertDealActionAccess();
     */
    public static void assertDealActionAccess() {
        if (hasDealActionAccess()) {
            return;
        }
        throw new AccessDeniedException(NO_PERMISSION_MESSAGE);
    }

    /**
     * Evaluates the two-factor gate. Ordered so the cheap, already-cached-by-the-platform admin
     * bypass runs first and an administrator never depends on Deal_Driver__c FLS at all.
     */
    private static Boolean computeDealActionAccess() {
        if (simulateLookupFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        if (hasModifyAllData()) {
            return true;
        }

        try {
            User runningUser = UserSelector.selectDealDriverFlagForCurrentUser();
            // `== true` rather than a bare truth test: Deal_Driver__c is a nullable Boolean in Apex
            // and an explicit comparison cannot NPE.
            return runningUser != null && runningUser.Deal_Driver__c == true;
        } catch (QueryException e) {
            // EXPECTED, not exceptional: WITH USER_MODE throws for a user without FLS read on
            // Deal_Driver__c, which is precisely factor (a) of the gate being unmet. Converting it
            // to a denial is the correct reading — see the class header. Not logged, because for
            // the majority of users (everyone who is not a deal driver) this is the normal path and
            // logging it would be noise, not signal.
            return false;
        }
    }

    /**
     * Whether the running user holds "Modify All Data" — through their profile or any assigned
     * permission set.
     *
     * A user's PROFILE surfaces in PermissionSetAssignment as an assignment to a PermissionSet with
     * `IsOwnedByProfile = true`, and a permission set GROUP assignment points at the group's
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
     * Clears the transaction-scoped cache. Test-only: production code runs in a single user context
     * per transaction, but a test switching users with System.runAs must not inherit the previous
     * user's answer.
     */
    @TestVisible
    private static void clearCache() {
        cachedHasDealActionAccess = null;
        simulateLookupFailure = false;
    }
}
