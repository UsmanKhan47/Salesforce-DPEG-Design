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
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It holds zero SOQL and
 * zero DML of its own, and since 2026-08-12 it orchestrates ONE selector rather than two.
 *
 * ── 🔴 THE GATE IS ONE FACTOR: THE CUSTOM PERMISSION (REWRITTEN 2026-08-12) ───
 * The running user passes when they hold the `Acquisition_Deal_Actions` CUSTOM PERMISSION, granted
 * by the layer-5 `Acquisition_Deal_Driver` permission set. That is the whole gate.
 *
 * ⚠ THIS SECTION USED TO READ "THE GATE IS TWO-FACTOR, AND THAT IS THE WHOLE POINT" AND IT IS NOW
 * WRONG IN EVERY PARTICULAR — it is rewritten rather than deleted so a reader who remembers the old
 * shape can see what replaced it and why. The retired model was:
 *   (a) FLS READ on `User.Deal_Driver__c`, enforced by `WITH USER_MODE` inside UserSelector, where
 *       a THROW was the denial signal; AND
 *   (b) the FIELD VALUE `Deal_Driver__c = true` on the running user's own record.
 * Both factors are gone. `UserSelector` is no longer called from this class at all.
 *
 * ── 🔴 WHY THE FLAG MODEL WAS RETIRED — MEASURED, NOT PREFERRED ───────────────
 * A flexipage visibility rule that references a FIELD evaluates FALSE for any user who lacks FLS
 * READ on that field. The rule does not error, does not log and does not warn — the button simply
 * is not there, which is indistinguishable from "this feature is not for me".
 *
 * That is a defect this repo has already paid for TWICE:
 *   1. It is recorded on `NDA__c.Is_Decline_Allowed__c`, whose own XML comment names the mechanism
 *      that made `{!$User.Deal_Driver__c}` unreachable for the disposition persona (code review C1).
 *   2. It was RE-DEMONSTRATED LIVE on 2026-08-12: removing a single permission-set assignment cost
 *      a System Administrator the ability even to QUERY `Deal_Driver__c` — `System.QueryException:
 *      No such column 'Deal_Driver__c' on entity 'User'` is the FLS-DENIAL signature on this
 *      platform, not a schema error, and it is what a bare admin sees on a field they just deployed.
 *
 * A custom permission has NO FLS of any kind. The entire failure class is REMOVED, not mitigated.
 * That — not the query saving below — is the justification for this change.
 *
 * ── 🔴 THE ADMIN-LOCKOUT ORDERING CONSTRAINT IS GONE. DO NOT RE-INTRODUCE IT ──
 * This class used to carry, in capitals, the rule that `hasModifyAllData()` MUST run BEFORE the flag
 * read or every administrator is locked out. That rule was correct and load-bearing while a `User`
 * field was in the path: a Metadata-API-deployed custom field arrives with NO field permissions for
 * ANY profile, System Administrator included, and "Modify All Data" is an OBJECT permission that
 * confers no FLS — so the selector threw for a bare admin exactly as it did for a bare Standard User,
 * before the bypass was ever reached.
 *
 * With the field read gone there is no statement that can throw an FLS denial, so THE ORDER IS NO
 * LONGER A CORRECTNESS CONSTRAINT. The two statements are now ordered on COST instead, and the
 * inversion is deliberate:
 *   - `FeatureManagement.checkPermission` costs ZERO SOQL, so a deal driver — the common case on
 *     these pages — now pays NOTHING at all;
 *   - only a NON-driver pays the single PermissionSetAssignment read behind the admin bypass.
 * A future reader who "restores" the old order will not break anything, but they will make every
 * deal driver pay a query for no reason. A future reader who re-adds a field read will re-open the
 * lockout, and must restore the ordering rule with it.
 *
 * ── SOQL COST, QUANTIFIED ─────────────────────────────────────────────────────
 *   before: 2 queries (PermissionSetAssignment for the bypass + User for the flag)
 *   after:  0 queries for a deal driver; 1 query for everyone else
 * Per transaction, not per call — the answer is memoized below, and
 * OpportunityActionPermissionController is `cacheable=true` so Lightning also caches it client-side.
 * This runs on EVERY Opportunity record view via c/dealActionGuard, which is what makes the driver's
 * zero-query path worth having. It is still a secondary benefit: lead with the FLS argument.
 *
 * ── CAPABILITY AND AUTHORIZATION ARE STILL TWO SEPARATE THINGS ────────────────
 * The token changed; the seven-layer model did not (ARCHITECTURE.md §2).
 *   layer 4 — `Opportunity_Stage_Actions_Access` — "can this code be reached at all" (Apex class
 *             access). A non-driver MUST be able to reach this method so it can honestly answer
 *             `false`; see OpportunityActionPermissionController's CLASS ACCESS note.
 *   layer 5 — `Acquisition_Deal_Driver` — "is this specific user allowed" (now carries the custom
 *             permission instead of the FLS grant).
 * 🔴 THEY MUST NEVER BE MERGED, AND THE REASON IS MEASURED: `Opportunity_Stage_Actions_Access` is a
 * MEMBER of `DPEG_Junior_Analyst_PSG`, while `Acquisition_Deal_Driver` is assigned DIRECTLY because
 * its population is narrower than any group's. Moving `Acquisition_Deal_Actions` into the layer-4
 * set would therefore grant deal-driving to that ENTIRE GROUP in one deploy — and would make this
 * gate a tautology, since everyone able to CALL it would automatically PASS it.
 * `OpportunityActionPermissionServiceTest` carries the falsifier for that; do not delete it.
 *
 * ⚠ Note the argument that changed and the one that did not. The old header rejected a permission-set
 * MEMBERSHIP check because membership and the flag were DIFFERENT QUESTIONS, so a membership check
 * would have widened a live boundary. That specific argument is now MOOT — there is no flag left to
 * disagree with membership. What survives is the layer-4/layer-5 separation above, which is a
 * statement about WHICH set carries the token, not about what kind of token it is.
 *
 * ── ADMIN BYPASS (deliberate, RETAINED) ───────────────────────────────────────
 * A user whose profile or permission sets grant "Modify All Data" always passes. Administrators can
 * already move any deal through inline edit, the Path, or the API, so denying them the button would
 * be theatre rather than security. It also keeps StageAdvanceControllerTest /
 * OpportunityApprovalControllerTest green without provisioning permission sets to the test-running
 * user. Same rationale and same mechanism as LeadActionPermissionService.
 *
 * ⚠ THE BYPASS IS WHY AN ADMIN SMOKE TEST STILL PROVES NOTHING ABOUT THIS FEATURE. That has not
 * changed and is not fixed by removing the FLS factor — an administrator passes this gate for a
 * reason unrelated to holding the custom permission, so acceptance-test as a real deal-driver
 * persona. What HAS changed is that a bare admin is no longer LOCKED OUT; they are bypassed.
 *
 * ── FAIL CLOSED, BUT DO NOT DISGUISE A SYSTEM FAULT AS A DENIAL ───────────────
 * `FeatureManagement.checkPermission` returns a Boolean and does not throw — an unknown or
 * not-yet-deployed permission name simply returns `false`, so the gate fails CLOSED if the admin
 * half of this change is ever missing. A failure of the permission machinery itself (the
 * PermissionSetAssignment read behind the bypass) is NOT a denial signal — it is a fault, and it
 * PROPAGATES to the controller, which masks it behind a fixed "unable to verify your permissions"
 * message and logs the stack. The LWC guard treats a thrown check exactly like `false`, so the gate
 * still fails CLOSED end to end; the difference is only that a fault reads as a fault.
 *
 * ⚠ THERE IS NO LONGER A `catch (QueryException)` IN THIS CLASS, AND ITS ABSENCE IS THE POINT. That
 * catch existed to convert an FLS denial into `false`. With no field read there is no expected
 * exception left to swallow, so every remaining exception is a genuine fault and every one of them
 * propagates. Re-adding a broad catch here would silently convert a broken permission check into
 * "you lack permission" — the exact disguise the section above forbids.
 *
 * Nothing here can return `true` by accident: every path to `true` requires positive evidence.
 *
 * ── ⚠ THE 2026-08-03 PERMISSION-GATE BUG STILL APPLIES TO THE ONE REMAINING READ ──
 * The incident was reported against the LEAD quick actions ("Unable to verify your permissions" for
 * a Minimum Access persona) but the root cause was in PermissionSetAssignmentSelector, which this
 * service still consumes for the bypass. Measured on DPEG-Acq-5: that read under `WITH USER_MODE`
 * THREW for a Minimum Access user (System Administrator and Standard User both passed, which is why
 * no test caught it — every runAs proof in this repo used Standard User). The selector now runs
 * `WITH SYSTEM_MODE`, justified in its own header, so this service inherits the fix.
 * `hasDealActionAccess_minimumAccessUser_deniesWithoutThrowing` asserts DENY-not-THROW and is now
 * MORE valuable than before, because the bypass read is the ONLY query left in this class.
 *
 * ⛔ RESIDUAL, UNCHANGED AND STILL ACCEPTED. A genuine future selector failure propagates out of
 * hasModifyAllData(), reaching OpportunityActionPermissionController's catch and denying with the
 * generic message — a different posture from the Lead gate's. That asymmetry is KNOWN, not
 * accidental, and re-opening it is a deliberate design decision with its own review, not a drive-by
 * edit attached to an unrelated change.
 *
 * ── ⚠ THE `User.Deal_Driver__c` FIELD STILL EXISTS, AND NOTHING READS IT ──────
 * The field and its FLS grant survive this phase deliberately (they are the rollback lever) and are
 * deleted in a later one. Until then it is dead-but-live metadata: someone reading the schema will
 * reasonably believe it still governs access. It does not. No Apex in this repo reads either
 * `*_Driver__c` field as of 2026-08-12 — that is the precondition the deletion phase needs.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user) with no record collection,
 * no loop over records, and no DML — the same shape the rule exempts for the Broker Protection
 * async pipeline and for LeadActionPermissionService. Cost is at most ONE query per transaction
 * regardless of how many quick actions ask, which the test suite asserts directly via
 * Limits.getQueries() rather than by volume.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionController.cls (LWC boundary)
 * @see force-app/main/default/customPermissions/Acquisition_Deal_Actions.customPermission-meta.xml
 * @see force-app/main/default/permissionsets/Acquisition_Deal_Driver.permissionset-meta.xml
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls (admin bypass)
 * @see force-app/main/default/classes/DispositionActionPermissionService.cls (the sell-side twin)
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
     *
     * ⚠ Wording is byte-identical to the pre-2026-08-12 value. DispositionActionPermissionService
     * and TransactionActionPermissionService both REUSE this constant rather than re-declaring it,
     * so editing the string here changes all four gates at once — which is the intent.
     */
    public static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    /**
     * The layer-5 AUTHORIZATION token. Holding it IS the gate.
     *
     * 🔴 It is granted by `Acquisition_Deal_Driver` and MUST NOT be added to a layer-4 capability
     * set — see the class header for the measured reason (`Opportunity_Stage_Actions_Access` is a
     * member of `DPEG_Junior_Analyst_PSG`, so that move grants deal-driving to the whole group).
     *
     * ⚠ A String, resolved at RUNTIME, so this class compiles and deploys whether or not the
     * custom permission exists yet. An absent permission returns `false` — the gate fails closed —
     * which means a deploy that ships this class without the admin half denies everyone rather than
     * granting everyone. That is the correct direction to fail, but it is silent, so the permission
     * set edit and this class belong in the SAME deploy.
     */
    private static final String DEAL_ACTION_CUSTOM_PERMISSION = 'Acquisition_Deal_Actions';

    // Transaction-scoped cache of the composed answer. Neither the running user's custom-permission
    // grants nor their "Modify All Data" can change mid-transaction, so the bypass read happens at
    // most once per execution context even when several quick actions on one page ask.
    // @TestVisible so tests can reset it between System.runAs blocks — the running user changes
    // there and the cache must not survive that.
    @TestVisible
    private static Boolean cachedHasDealActionAccess;

    /**
     * Test seam. The controller's AuraHandledException catch exists for a real failure mode (a
     * failure of the PermissionSetAssignment read behind the admin bypass), but that mode cannot be
     * provoked deterministically — every user can read their OWN assignment rows, so even a bare
     * Standard User does not make the selector throw. This flag is the only deterministic way to
     * reach that catch; without it the controller would sit far below the 90% bar on an uncoverable
     * branch.
     *
     * It is `private` + `@TestVisible` (so no production class can set it) AND additionally gated on
     * Test.isRunningTest(), so production behaviour is provably unchanged. Repo precedent:
     * LeadActionPermissionService.simulateLoadFailure.
     *
     * ⚠ IT IS EVALUATED BEFORE THE CUSTOM-PERMISSION CHECK ON PURPOSE. If it sat after, a test user
     * holding the permission would short-circuit past the seam and the fault branch would be
     * unreachable for exactly the personas most worth testing.
     */
    @TestVisible
    private static Boolean simulateLookupFailure = false;

    /**
     * Whether the running user may drive the Opportunity stage quick actions.
     *
     * @return true when the user holds the `Acquisition_Deal_Actions` custom permission, or has
     *         "Modify All Data"; false otherwise.
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
     * Evaluates the gate.
     *
     * ⚠ ORDER: the custom permission is tested FIRST because it costs ZERO SOQL, so a deal driver
     * pays nothing and only a non-driver pays the bypass read. This is a COST ordering, not a
     * correctness one — see the class header. It is the deliberate INVERSE of the pre-2026-08-12
     * order, which was a correctness constraint imposed by an FLS read that no longer exists.
     */
    private static Boolean computeDealActionAccess() {
        if (simulateLookupFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        // 0 SOQL. Returns false (never throws) for an unknown or unheld permission.
        if (FeatureManagement.checkPermission(DEAL_ACTION_CUSTOM_PERMISSION)) {
            return true;
        }

        return hasModifyAllData();
    }

    /**
     * Whether the running user holds "Modify All Data" — through their profile or any assigned
     * permission set.
     *
     * A user's PROFILE surfaces in PermissionSetAssignment as an assignment to a PermissionSet with
     * `IsOwnedByProfile = true`, and a permission set GROUP assignment points at the group's
     * aggregate permission set, so this single pass covers profile-granted, set-granted and
     * group-granted "Modify All Data" without any group expansion.
     *
     * This is the ONLY query this service performs, and only a non-driver reaches it.
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
