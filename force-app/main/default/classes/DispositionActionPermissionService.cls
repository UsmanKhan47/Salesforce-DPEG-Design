/**
 * DispositionActionPermissionService — the single source of truth for "may the running user drive
 * the DISPOSITION stage quick actions?".
 *
 * Added 2026-08-09 (Tranche 3A, decision D15/Q1). It is the sell-side twin of
 * OpportunityActionPermissionService and mirrors it deliberately, line for line where the
 * reasoning transfers. Consumed through RecordStageAdvanceService's per-record-type gate
 * dispatch: the disposition record types of `NDA__c`, `LOI__c` and `Contract_Review__c`.
 *
 * 🔴 THE TWO CLASSES ARE ONE DESIGN ON TWO MODULES — CHANGE BOTH OR NEITHER. They were rewritten
 * together on 2026-08-12 for the custom-permission migration and differ in nothing but the module's
 * names. The acquisitions twin's header carries the full argument for every decision below; this
 * one states the same decisions without re-deriving them, and any divergence between the two files
 * is a defect rather than a variation.
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It holds zero SOQL and
 * zero DML of its own, and since 2026-08-12 it orchestrates ONE selector rather than two.
 *
 * ── 🔴 THE GATE IS ONE FACTOR: THE CUSTOM PERMISSION (REWRITTEN 2026-08-12) ───
 * The running user passes when they hold the `Disposition_Deal_Actions` CUSTOM PERMISSION, granted
 * by the layer-5 `Disposition_Deal_Driver` permission set. That is the whole gate.
 *
 * ⚠ THIS SECTION USED TO READ "THE GATE IS TWO-FACTOR, AND THAT IS THE WHOLE POINT" AND IT IS NOW
 * WRONG IN EVERY PARTICULAR — it is rewritten rather than deleted so a reader who remembers the old
 * shape can see what replaced it and why. The retired model was:
 *   (a) FLS READ on `User.Disposition_Driver__c`, enforced by `WITH USER_MODE` inside UserSelector,
 *       where a THROW was the denial signal; AND
 *   (b) the FIELD VALUE `Disposition_Driver__c = true` on the running user's own record.
 * Both factors are gone. `UserSelector` is no longer called from this class at all.
 *
 * ── 🔴 WHY THE FLAG MODEL WAS RETIRED — AND WHY THIS MODULE PAID FOR IT FIRST ─
 * A flexipage visibility rule that references a FIELD evaluates FALSE for any user who lacks FLS
 * READ on that field. It does not error, does not log and does not warn — the button simply is not
 * there, which is indistinguishable from "this feature is not for me".
 *
 * 🔴 THE DISPOSITION PERSONA IS WHERE THAT DEFECT ACTUALLY LANDED. `NDA__c.Is_Decline_Allowed__c`'s
 * XML comment records the mechanism by name: a disposition driver holds FLS on
 * `Disposition_Driver__c` and NOT on `Deal_Driver__c`, so `{!$User.Deal_Driver__c}` could never
 * evaluate true for them — which is precisely why this class and its field had to be invented in
 * Tranche 3A (code review C1). It was RE-DEMONSTRATED LIVE on 2026-08-12: removing one
 * permission-set assignment cost a System Administrator the ability even to QUERY the flag field —
 * `System.QueryException: No such column ... on entity 'User'` is the FLS-DENIAL signature on this
 * platform, not a schema error.
 *
 * A custom permission has NO FLS of any kind. The entire failure class is REMOVED, not mitigated.
 * That — not the query saving below — is the justification for this change.
 *
 * ⚠ WHAT DID **NOT** CHANGE: the two modules are still SEPARATE AUTHORIZATION BOUNDARIES. An
 * acquisitions deal driver must not be able to drive a SALE's NDA and vice versa. The old header
 * recorded three rejected shortcuts; two of them are still live traps under the new token and are
 * restated here because each still looks like tidying:
 *   1. GRANT THE ACQUISITIONS TOKEN TO DISPOSITION USERS. Zero new metadata — and it also hands
 *      them the Opportunity deal actions. It merges two boundaries into one.
 *   2. ONE SHARED `Deal_Actions` PERMISSION FOR BOTH MODULES. The new-token version of (1), and
 *      the same defect: `RecordStageAdvanceService` dispatches NDA__c, LOI__c and
 *      Contract_Review__c to DIFFERENT gates per RECORD TYPE precisely so one table can serve two
 *      modules without merging their personas. A shared permission would make that dispatch
 *      decorative.
 *   3. NO GATE AT ALL on the disposition record types. `passesGate`'s `when else` fails closed, so
 *      an unwired enum value denies silently — which is why DISPOSITION_DRIVER was not declared
 *      until this class existed.
 * The third rejected option in the old header — a permission-set MEMBERSHIP check — is now MOOT
 * rather than rejected: there is no flag left for membership to disagree with. See the acquisitions
 * twin's header for the argument that survived (layer-4 vs layer-5), which is not the same one.
 *
 * ── 🔴 THE ADMIN-LOCKOUT ORDERING CONSTRAINT IS GONE. DO NOT RE-INTRODUCE IT ──
 * This class used to state that "Modify All Data" MUST pass BEFORE the flag is read and that
 * "reversing these two statements is a lockout, not a style preference". That was correct and
 * load-bearing while a `User` field was in the path: a Metadata-API-deployed custom field arrives
 * with NO field permissions for ANY profile, System Administrator included, and Modify All Data is
 * an OBJECT permission that confers no FLS — so `UserSelector` threw for a bare System Administrator
 * exactly as it did for a bare Standard User, before the bypass was ever reached.
 *
 * With the field read gone there is no statement that can throw an FLS denial, so THE ORDER IS NO
 * LONGER A CORRECTNESS CONSTRAINT. The two statements are now ordered on COST, and inverted
 * deliberately: `FeatureManagement.checkPermission` costs ZERO SOQL, so a disposition driver pays
 * nothing and only a NON-driver pays the single PermissionSetAssignment read.
 *
 * ── SOQL COST, QUANTIFIED ─────────────────────────────────────────────────────
 *   before: 2 queries (PermissionSetAssignment for the bypass + User for the flag)
 *   after:  0 queries for a disposition driver; 1 query for everyone else
 * Per transaction, not per call — the answer is memoized below. This is reached from
 * `RecordStageAdvanceService.hasStageActionAccess`, a `cacheable=true` path invoked once per record
 * view, where it sits ALONGSIDE that service's own row load (which resolves the record type and
 * survives this change untouched). So a disposition driver's per-view cost on NDA__c / LOI__c /
 * Contract_Review__c goes 3 → 1, and a non-driver's 3 → 2.
 *
 * ── CAPABILITY AND AUTHORIZATION ARE STILL TWO SEPARATE THINGS ────────────────
 * The token changed; the seven-layer model did not (ARCHITECTURE.md §2). `Disposition_Deal_Driver`
 * is the layer-5 AUTHORIZATION set and now carries the custom permission in place of the FLS grant.
 * 🔴 The permission MUST NOT be moved into a layer-4 capability set: that would make the gate a
 * tautology (everyone able to CALL it would automatically PASS it) and would grant deal-driving to
 * that set's whole population in one deploy. Identical to the acquisitions twin; read its header for
 * the measured `DPEG_Junior_Analyst_PSG` case.
 *
 * A flexipage visibility rule also cannot call Apex, so the declarative half of the gate binds to
 * `{!$Permission.CustomPermission.Disposition_Deal_Actions}` where it used to bind to the User
 * field. The two halves remain complementary: App Builder HIDES the button, this class REFUSES the
 * call.
 *
 * ⚠ THE TOKEN HAS THREE SEGMENTS — only `{!$Permission.CustomPermission.<Name>}` is accepted. The
 * two-segment `{!$Permission.<Name>}` and the alternative `{!$CustomPermission.<Name>}` were BOTH
 * rejected by the Metadata API at deploy on 2026-08-12, so copying a shortened form into a flexipage
 * fails the deploy; see RecordStageAdvanceService.StageActionGate.
 *
 * ── ADMIN BYPASS (deliberate, RETAINED) ───────────────────────────────────────
 * A user granted "Modify All Data" always passes, for the same reason as on the acquisitions twin.
 *
 * ⚠ AN ADMIN SMOKE TEST STILL PROVES NOTHING ABOUT THIS GATE. That has not changed and is not fixed
 * by removing the FLS factor — an administrator passes for a reason unrelated to holding the custom
 * permission. Acceptance-test as a real disposition-driver persona. What HAS changed is that a bare
 * administrator is no longer LOCKED OUT; they are bypassed.
 *
 * ── FAIL CLOSED, BUT DO NOT DISGUISE A SYSTEM FAULT AS A DENIAL ───────────────
 * `FeatureManagement.checkPermission` returns a Boolean and does not throw — an unknown or
 * not-yet-deployed permission name simply returns `false`, so the gate fails CLOSED if the admin
 * half of this change is ever missing. A failure of the permission machinery itself (the
 * PermissionSetAssignment read behind the bypass) is NOT a denial signal — it is a fault, and it
 * PROPAGATES. The controller masks it behind a fixed message and the LWC guard treats a thrown
 * check exactly like `false`, so the gate still fails CLOSED end to end.
 *
 * ⚠ THERE IS NO LONGER A `catch (QueryException)` IN THIS CLASS, AND ITS ABSENCE IS THE POINT. That
 * catch existed to convert an FLS denial into `false`. With no field read there is no expected
 * exception left to swallow, so every remaining exception is a genuine fault and propagates.
 * Re-adding a broad catch would silently convert a broken permission check into "you lack
 * permission".
 *
 * Nothing here can return `true` by accident: every path to `true` requires positive evidence. The
 * asymmetry noted on the acquisitions twin (the bypass read sits deliberately OUTSIDE any catch) is
 * the same known, accepted residual and must not be "fixed" on either class alone.
 *
 * ── ⚠ THE `User.Disposition_Driver__c` FIELD STILL EXISTS, AND NOTHING READS IT ──
 * The field and its FLS grant survive this phase deliberately (they are the rollback lever) and are
 * deleted in a later one. Until then it is dead-but-live metadata: someone reading the schema will
 * reasonably believe it still governs access. It does not.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user) with no record collection,
 * no loop over records and no DML — the same shape the rule exempts for
 * OpportunityActionPermissionService and LeadActionPermissionService. Cost is at most ONE query per
 * transaction regardless of how many quick actions ask, which the test suite asserts directly via
 * Limits.getQueries() rather than by volume.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the acquisitions twin)
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (the gate dispatch)
 * @see force-app/main/default/customPermissions/Disposition_Deal_Actions.customPermission-meta.xml
 * @see force-app/main/default/permissionsets/Disposition_Deal_Driver.permissionset-meta.xml
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls (admin bypass)
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
     * a user can never tell the gates apart from a toast — correct, since "which permission you are
     * missing" is not information a refused caller is owed.
     */
    public static final String NO_PERMISSION_MESSAGE =
        OpportunityActionPermissionService.NO_PERMISSION_MESSAGE;

    /**
     * The layer-5 AUTHORIZATION token. Holding it IS the gate.
     *
     * 🔴 It is granted by `Disposition_Deal_Driver` and MUST NOT be added to a layer-4 capability
     * set, nor merged with `Acquisition_Deal_Actions` — see the class header. Two permissions for
     * two modules is what keeps a sale driver and a purchase driver separable, and that separation
     * is the reason this class exists at all.
     *
     * ⚠ A String, resolved at RUNTIME, so this class compiles and deploys whether or not the custom
     * permission exists yet. An absent permission returns `false` — the gate fails closed — which
     * means a deploy that ships this class without the admin half denies everyone rather than
     * granting everyone. Correct direction, but silent: the permission set edit and this class
     * belong in the SAME deploy.
     */
    private static final String DISPOSITION_ACTION_CUSTOM_PERMISSION = 'Disposition_Deal_Actions';

    // Transaction-scoped cache of the composed answer. Neither the running user's custom-permission
    // grants nor their "Modify All Data" can change mid-transaction, so the bypass read happens at
    // most once per execution context even when several quick actions on one page ask.
    // @TestVisible so tests can reset it between System.runAs blocks — the running user changes
    // there and the cache must not survive that.
    @TestVisible
    private static Boolean cachedHasDispositionActionAccess;

    /**
     * Test seam. The controller's AuraHandledException catch exists for a real failure mode (a
     * failure of the PermissionSetAssignment read behind the admin bypass), but that mode cannot be
     * provoked deterministically — every user can read their OWN assignment rows. This flag is the
     * only deterministic way to reach that branch.
     *
     * It is `private` + `@TestVisible` (so no production class can set it) AND additionally gated
     * on Test.isRunningTest(), so production behaviour is provably unchanged. Repo precedent:
     * OpportunityActionPermissionService.simulateLookupFailure.
     *
     * ⚠ IT IS EVALUATED BEFORE THE CUSTOM-PERMISSION CHECK ON PURPOSE. If it sat after, a test user
     * holding the permission would short-circuit past the seam and the fault branch would be
     * unreachable for exactly the personas most worth testing.
     */
    @TestVisible
    private static Boolean simulateLookupFailure = false;

    /**
     * Whether the running user may drive the Disposition stage quick actions.
     *
     * @return true when the user holds the `Disposition_Deal_Actions` custom permission, or has
     *         "Modify All Data"; false otherwise.
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
     * ⚠ Today the disposition actions reach the server through RecordStageAdvanceController, which
     * asserts via RecordStageAdvanceService.assertStageActionAccess (that method dispatches to the
     * record's gate and throws ITS OWN AccessDeniedException, so the controller's catch order is
     * unchanged by this feature). This method exists for a future disposition-specific entry point
     * and for symmetry with the sibling gates — call it at the top of any such method.
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
     * Evaluates the gate.
     *
     * ⚠ ORDER: the custom permission is tested FIRST because it costs ZERO SOQL, so a disposition
     * driver pays nothing and only a non-driver pays the bypass read. This is a COST ordering, not
     * a correctness one — see the class header. It is the deliberate INVERSE of the pre-2026-08-12
     * order, which was a correctness constraint imposed by an FLS read that no longer exists.
     */
    private static Boolean computeDispositionActionAccess() {
        if (simulateLookupFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        // 0 SOQL. Returns false (never throws) for an unknown or unheld permission.
        if (FeatureManagement.checkPermission(DISPOSITION_ACTION_CUSTOM_PERMISSION)) {
            return true;
        }

        return hasModifyAllData();
    }

    /**
     * Whether the running user holds "Modify All Data" — through their profile or any assigned
     * permission set.
     *
     * A user's PROFILE surfaces in PermissionSetAssignment as an assignment to a PermissionSet
     * with `IsOwnedByProfile = true`, and a permission set GROUP assignment points at the group's
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
