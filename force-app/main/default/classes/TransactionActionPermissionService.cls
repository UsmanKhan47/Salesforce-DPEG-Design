/**
 * TransactionActionPermissionService — the single source of truth for "may the running user drive
 * the TRANSACTION stage quick action?".
 *
 * Added 2026-08-12 with the Transaction Advance Stage action. Consumed through
 * RecordStageAdvanceService's per-record-type gate dispatch
 * (StageActionGate.TRANSACTION_STAGE_ACTIONS), which is the only caller today.
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It holds zero SOQL and
 * zero DML of its own and orchestrates one selector.
 *
 * ── 🔴 REWRITTEN 2026-08-12 (SAME DAY IT SHIPPED): MEMBERSHIP → CUSTOM PERMISSION ──
 * The gate is now `FeatureManagement.checkPermission('Transaction_Stage_Actions')`, with the
 * "Modify All Data" bypass retained. It previously delegated to
 * `LeadActionPermissionService.hasAnyPermissionSet({'Transaction_Stage_Actions_Access'})`.
 *
 * ⚠ THIS IS A MECHANISM SWAP, NOT A POLICY CHANGE, AND THE DISTINCTION IS THE WHOLE POINT OF THIS
 * HEADER. The custom permission is carried by the SAME `Transaction_Stage_Actions_Access` permission
 * set that previously WAS the gate, so at the instant the deploy completes exactly the current
 * holders hold it. Nobody gains access, nobody loses it, and there is no in-org assignment step —
 * custom-permission GRANTS are deployable metadata even though `PermissionSetAssignment` is not.
 *
 * 🔴 WHAT THE SWAP BUYS, AND IT IS NOT SYMMETRY. A flexipage `<visibilityRule>` CANNOT test
 * permission set membership — there is no `$PermissionSet` global. `$Permission` is the only
 * mechanism available, so until now the Transaction Advance Stage button was the one stage action
 * in the application that could not be hidden declaratively for a user who may not use it
 * (`Transaction__c` appears in zero of the seven driver-gated flexipages, and that was a
 * CONSEQUENCE of the membership design, not an oversight). A custom permission makes that button
 * hideable for the first time. That is a new capability.
 *
 * ── 🔴 THE MEMBERSHIP *POLICY* SURVIVES INTACT — DO NOT READ THE SWAP AS FIXING IT ──
 * `Transaction_Stage_Actions_Access` is a MEMBER of the `DPEG_Transaction_Team` permission set
 * GROUP (verified 2026-08-12), and a group's membership is the unit of assignment. There is no
 * per-user unassignment of one member set: removing this capability from one user means removing
 * them from the group entirely and losing the other TEN sets with it — Base, Apex, Transaction Edit,
 * Task Edit, Opportunity View, Property View, Reports, the Transaction app, Account View and
 * Contact View. In practice that is not a revocation, it is a deprovisioning.
 *
 * ⇒ SO STATE IT PLAINLY, EXACTLY AS BEFORE: **THIS GATE IS TEAM-WIDE BY DESIGN.** It answers "is
 * this user on the Transactions team?", never "is this particular user allowed to advance a stage?".
 * PER-USER REVOCATION IS STILL NOT AVAILABLE. Changing the token from a set NAME to a custom
 * PERMISSION carried by that same set does not touch that, and anyone who reads the swap as having
 * granted per-user granularity will be wrong in a way no test can catch.
 *
 * ⇒ If Transactions ever needs to deny ONE user while keeping them on the team, the remedy is to
 * move `Transaction_Stage_Actions` onto its OWN, directly-assigned layer-5 set (the shape
 * `Acquisition_Deal_Driver` uses) — and it should be argued from that need when it appears, never
 * from symmetry with Opportunity.
 *
 * ── ⚠ THE PERMISSION SITS ON A LAYER-4 SET HERE. THAT IS A DELIBERATE DIVERGENCE ──
 * Both sibling services' headers state that the custom permission MUST NOT live in a layer-4
 * capability set, because everyone able to CALL the gate would then automatically PASS it, making
 * the gate a tautology. `Transaction_Stage_Actions` DOES live on the layer-4 set. Two reasons this
 * is correct here and is not a copy of the mistake those headers forbid:
 *
 *   1. IT PRESERVES THE EXISTING POPULATION EXACTLY. On Opportunity, moving the token to layer 4
 *      would be a WIDENING — `Opportunity_Stage_Actions_Access` sits inside
 *      `DPEG_Junior_Analyst_PSG` while `Acquisition_Deal_Driver` is assigned directly to a narrower
 *      population, so the move grants deal-driving to the whole group. Here the layer-4 set IS the
 *      current gate's population; anywhere else would be the change.
 *   2. IT IS NOT ACTUALLY A TAUTOLOGY, because `RecordStageAdvanceController` also sits in the
 *      broad `DPEG_Apex_Access` catch-all (ARCHITECTURE.md §2 explains why it must: it holds the
 *      cacheable `hasStageActionAccess` that c/recordStageGuard calls for ANY user who clicks, not
 *      only holders). So a non-Transaction user can still reach the gate and receive a clean
 *      `false` rather than a raw "You do not have access to the Apex class named …" toast.
 *
 * ⇒ If `RecordStageAdvanceController` is ever removed from `DPEG_Apex_Access`, reason (2) fails and
 * the divergence stops being safe. That coupling is the thing to check before narrowing class
 * access, and it fails LOUD (a bad message) rather than open, so no test will catch it.
 *
 * ── SOQL COST, QUANTIFIED ─────────────────────────────────────────────────────
 *   before: 0–2 queries — the membership read was free WHEN another gate had already populated
 *           LeadActionPermissionService's shared grant cache in the same transaction, and cost 2
 *           (PermissionSetAssignment + PermissionSetGroupComponent group expansion) when nothing
 *           had.
 *   after:  0 queries for a holder; 1 query (PermissionSetAssignment, for the bypass) otherwise.
 * ⚠ THE SHARED CACHE IS GONE AND THAT IS A REAL, IF SMALL, LOSS TO STATE HONESTLY. This class no
 * longer touches `LeadActionPermissionService`, so it no longer free-rides on a grant cache another
 * gate may have already paid for. The trade is worth it — a holder now pays ZERO unconditionally
 * instead of zero-or-two, and the group EXPANSION query disappears entirely because the platform
 * resolves custom permissions through groups itself — but a transaction that asks both this gate and
 * the Lead gate now pays each separately. Both are memoized per transaction in their own class.
 *
 * ── ADMIN BYPASS (RETAINED — AND RETAINING IT WAS NOT OPTIONAL) ───────────────
 * 🔴 THE BYPASS USED TO BE INHERITED FROM `hasAnyPermissionSet`, WHICH CHECKS "Modify All Data"
 * FROM THE SAME ROWS IT READS. A literal swap to `checkPermission` alone would have DROPPED it
 * silently, NARROWING access: every administrator who can drive a Transaction stage today would
 * have stopped being able to, with no error naming the cause. Custom permissions are NOT implied by
 * "Modify All Data" — it is an object permission and confers no custom permission of any kind. So
 * the bypass is re-implemented here explicitly, mirroring the two sibling services line for line.
 *
 * ⚠ Ordering here is a COST choice, not a correctness one (unlike the pre-migration siblings, where
 * an FLS read forced the bypass to run first): the permission check costs 0 SOQL, so a holder pays
 * nothing and only a non-holder pays the read. Note this class NEVER had the admin-lockout hazard —
 * it has no `User` field and never did, which was one of the concrete simplifications the membership
 * design bought and which the custom permission preserves.
 *
 * ── ⚠ TEST SEAMS NOW LIVE HERE, NOT ON `LeadActionPermissionService` ─────────
 * 🔴 THIS IS THE CHANGE MOST LIKELY TO BREAK AN EXISTING TEST. The previous header directed callers
 * to `LeadActionPermissionService.clearCache()` and `.simulateLoadFailure`, because this class held
 * no state of its own. It no longer touches that class at all, so those calls are now NO-OPS for
 * this gate. A test switching users with `System.runAs` must call
 * `TransactionActionPermissionService.clearCache()`, and the fault branch is reached through this
 * class's own `simulateLookupFailure`.
 *
 * ── FAIL CLOSED, BUT DO NOT DISGUISE A SYSTEM FAULT AS A DENIAL ───────────────
 * `FeatureManagement.checkPermission` returns a Boolean and does not throw — an unknown or
 * not-yet-deployed permission name simply returns `false`, so the gate fails CLOSED if the admin
 * half of this change is ever missing. Nothing here swallows an exception: a failure of the
 * permission machinery propagates to RecordStageAdvanceController, which masks it behind a fixed
 * message; `c/recordStageGuard` treats a thrown check exactly like `false`, so the gate still fails
 * CLOSED end to end — the difference is only that a fault reads as a fault rather than as "you lack
 * permission".
 *
 * ⚠ Nothing here can return `true` by accident: the only paths to `true` are holding the custom
 * permission or "Modify All Data".
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user) with no record collection,
 * no loop over records and no DML — the same shape the rule exempts for
 * LeadActionPermissionService, OpportunityActionPermissionService and
 * DispositionActionPermissionService.
 *
 * ── 🔴 2026-08-28: A SECOND, INDEPENDENT GATE LIVES HERE NOW (TASK) ──────────
 * This class answers TWO questions, not one:
 *   • hasTransactionActionAccess / assertTransactionActionAccess → `Transaction_Stage_Actions`
 *     (may the user drive the stage quick action?) — unchanged by the 2026-08-28 work.
 *   • hasTaskActionAccess / assertTaskActionAccess → `Transaction_Task_Actions`
 *     (may the user complete/update a checklist Task?) — NEW.
 *
 * They are SEPARATE PERMISSIONS BY USER DECISION: stage advancement and checklist completion
 * are to be independently grantable. They also have separate caches, so one gate can never
 * answer the other's question mid-transaction (see cachedHasTaskActionAccess).
 *
 * 🔴 THE TASK GATE CARRIES MORE WEIGHT THAN THE STAGE ONE. The stage gate sits in front of a
 * write the platform would also refuse on its own. The task gate does not: Task object Edit
 * cannot be granted by ANY permission set on this platform (ObjectPermissions.SobjectType is a
 * restricted picklist that excludes Task/Event/Activity), so TransactionTaskService writes in
 * SYSTEM_MODE and THIS CHECK IS THE ONLY AUTHORIZATION on that path. Read
 * TransactionTaskService's header before changing anything named *TaskAction* here.
 *
 * @see force-app/main/default/classes/TransactionTaskService.cls (the only task-gate consumer)
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (the gate dispatch)
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the acquisitions gate)
 * @see force-app/main/default/customPermissions/Transaction_Stage_Actions.customPermission-meta.xml
 * @see force-app/main/default/permissionsets/Transaction_Stage_Actions_Access.permissionset-meta.xml
 */
public with sharing class TransactionActionPermissionService {

    /**
     * Raised when the running user may not drive a Transaction stage action. Typed (rather than
     * AuraHandledException) so this service stays UI-agnostic — the controller owns the mapping to
     * the LWC boundary. Repo precedent: DispositionActionPermissionService.AccessDeniedException.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * The user-facing denial message.
     *
     * ⚠ It is deliberately the SAME STRING as the Lead, Opportunity and Disposition gates', reused
     * from OpportunityActionPermissionService rather than re-declared, so a future edit to the
     * wording cannot leave four features speaking with two voices. RecordStageAdvanceService throws
     * its own AccessDeniedException carrying this value regardless of which gate refused, which is
     * why a user can never tell the gates apart from a toast — correct, since "which permission you
     * are missing" is not information a refused caller is owed.
     */
    public static final String NO_PERMISSION_MESSAGE =
        OpportunityActionPermissionService.NO_PERMISSION_MESSAGE;

    /**
     * The AUTHORIZATION token. Holding it IS the gate.
     *
     * 🔴 IT IS GRANTED BY `Transaction_Stage_Actions_Access`, AND THAT SET IS WHERE IT MUST STAY
     * UNLESS THE POLICY ITSELF IS BEING CHANGED. Granting it anywhere else changes WHO may advance a
     * Transaction stage — a real authorization change, not configuration. See the class header for
     * why a layer-4 set is the correct home here specifically, and why that reasoning does NOT
     * transfer to the two sibling gates.
     *
     * ⚠ A String, resolved at RUNTIME, so this class compiles and deploys whether or not the custom
     * permission exists yet. An absent permission returns `false` — the gate fails closed — which
     * means a deploy that ships this class without the permission set edit denies the whole
     * Transactions team rather than granting everyone. Correct direction, but SILENT: the two belong
     * in the SAME deploy.
     */
    private static final String TRANSACTION_ACTION_CUSTOM_PERMISSION = 'Transaction_Stage_Actions';

    /**
     * The AUTHORIZATION token for the Transaction CHECKLIST TASK write path (added 2026-08-28).
     *
     * 🔴 IT IS A SECOND, INDEPENDENT PERMISSION — NOT A REUSE OF THE STAGE ONE, AND THAT IS A
     * USER DECISION, NOT A STYLE CHOICE. Advancing a Transaction stage and completing a
     * checklist Task are to be independently grantable, so anyone tempted to collapse the two
     * tokens (they are carried by sets in the same group today, so the populations currently
     * coincide) would be removing a capability the user explicitly asked for.
     *
     * Granted by `DPEG_Task_Edit`, a member of the `DPEG_Transaction_Team` permission set group
     * (both verified live on usman-dpeg, 2026-08-28). Consumed by TransactionTaskService's three
     * write methods, which then run their DML in SYSTEM_MODE — because Task object Edit is
     * literally un-grantable by permission set on this platform (ObjectPermissions.SobjectType
     * is a restricted picklist that does not contain Task/Event/Activity). See that class's
     * header for the full proof.
     *
     * ⚠ Same runtime-resolution caveat as the stage token above: a String, so this class
     * compiles and deploys whether or not the permission exists yet, and an absent permission
     * returns `false` — denying the whole Transactions team rather than granting everyone.
     * Correct direction, but silent. The Apex and the permission belong in the SAME deploy.
     */
    private static final String TASK_ACTION_CUSTOM_PERMISSION = 'Transaction_Task_Actions';

    // Transaction-scoped cache of the composed answer. Neither the running user's custom-permission
    // grants nor their "Modify All Data" can change mid-transaction, so the bypass read happens at
    // most once per execution context.
    // ⚠ NEW IN THE 2026-08-12 REWRITE. This class previously held no state, borrowing
    // LeadActionPermissionService's shared cache; it now owns one, like both sibling gates.
    @TestVisible
    private static Boolean cachedHasTransactionActionAccess;

    /**
     * Transaction-scoped cache for the TASK gate.
     *
     * 🔴 A SEPARATE VARIABLE ON PURPOSE. The two permissions are independently grantable, so one
     * shared cache would let whichever gate ran first answer the other one's question — a user
     * holding only `Transaction_Stage_Actions` would silently pass the task gate (or vice
     * versa) for the rest of the transaction. That failure would be invisible in any test that
     * asks only one gate per transaction, which is most of them.
     */
    @TestVisible
    private static Boolean cachedHasTaskActionAccess;

    /**
     * Test seam for the permission-machinery fault branch — the only deterministic way to make this
     * gate throw, since every user can read their OWN PermissionSetAssignment rows and the selector
     * runs `WITH SYSTEM_MODE`.
     *
     * It is `private` + `@TestVisible` (so no production class can set it) AND additionally gated on
     * Test.isRunningTest(), so production behaviour is provably unchanged. Repo precedent:
     * OpportunityActionPermissionService.simulateLookupFailure.
     *
     * ⚠ IT IS EVALUATED BEFORE THE CUSTOM-PERMISSION CHECK ON PURPOSE. If it sat after, a test user
     * holding the permission would short-circuit past the seam and the fault branch would be
     * unreachable for exactly the personas most worth testing.
     */
    @TestVisible
    private static Boolean simulateLookupFailure = false;

    /**
     * Whether the running user may drive the Transaction stage quick action.
     *
     * @return true when the user holds the `Transaction_Stage_Actions` custom permission (granted
     *         through `Transaction_Stage_Actions_Access`, directly or via the
     *         `DPEG_Transaction_Team` permission set group), or has "Modify All Data"; false
     *         otherwise.
     * @throws System.QueryException when the permission-set lookup behind the admin bypass fails
     *         unexpectedly. Deliberately NOT swallowed — see the fail-closed note in the class
     *         header.
     * @example
     * if (!TransactionActionPermissionService.hasTransactionActionAccess()) { return; }
     */
    public static Boolean hasTransactionActionAccess() {
        if (cachedHasTransactionActionAccess != null) {
            return cachedHasTransactionActionAccess;
        }
        // Assign only AFTER a successful computation: a thrown fault must leave the cache empty so
        // the next ask re-evaluates rather than memoizing a fault as an answer.
        Boolean allowed = computeTransactionActionAccess();
        cachedHasTransactionActionAccess = allowed;
        return allowed;
    }

    /**
     * Server-side guard for the Transaction stage action.
     *
     * ⚠ Today the action reaches the server through RecordStageAdvanceController, which asserts via
     * RecordStageAdvanceService.assertStageActionAccess — that method dispatches to the record's
     * gate and throws ITS OWN AccessDeniedException, so the controller's catch order is unchanged by
     * this feature. This method exists for a future Transaction-specific entry point and for
     * symmetry with the three sibling gates; call it at the top of any such method.
     *
     * @throws TransactionActionPermissionService.AccessDeniedException carrying
     *         NO_PERMISSION_MESSAGE when the running user lacks access.
     * @throws System.QueryException when the permission lookup itself fails unexpectedly.
     * @example
     * TransactionActionPermissionService.assertTransactionActionAccess();
     */
    public static void assertTransactionActionAccess() {
        if (hasTransactionActionAccess()) {
            return;
        }
        throw new AccessDeniedException(NO_PERMISSION_MESSAGE);
    }

    /**
     * Whether the running user may complete/update a Transaction CHECKLIST TASK.
     *
     * Mirrors hasTransactionActionAccess() line for line, including the caching nuance: the
     * cache is assigned only AFTER a successful computation, so a thrown fault leaves it empty
     * and the next ask re-evaluates rather than memoizing a fault as an answer.
     *
     * @return true when the user holds the `Transaction_Task_Actions` custom permission
     *         (granted through `DPEG_Task_Edit`, directly or via the `DPEG_Transaction_Team`
     *         permission set group), or has "Modify All Data"; false otherwise.
     * @throws System.QueryException when the permission-set lookup behind the admin bypass fails
     *         unexpectedly. Deliberately NOT swallowed — see the fail-closed note in the class
     *         header.
     * @example
     * if (!TransactionActionPermissionService.hasTaskActionAccess()) { return; }
     */
    public static Boolean hasTaskActionAccess() {
        if (cachedHasTaskActionAccess != null) {
            return cachedHasTaskActionAccess;
        }
        // Assign only AFTER a successful computation: a thrown fault must leave the cache empty
        // so the next ask re-evaluates rather than memoizing a fault as an answer.
        Boolean allowed = computeTaskActionAccess();
        cachedHasTaskActionAccess = allowed;
        return allowed;
    }

    /**
     * Server-side guard for the Transaction checklist Task write path. Called at the top of all
     * three TransactionTaskService write methods, which then run their DML in SYSTEM_MODE.
     *
     * 🔴 UNLIKE assertTransactionActionAccess ABOVE, THIS ONE IS LOAD-BEARING TODAY. It is not
     * defence in depth over a platform CRUD check — it IS the only authorization on that write
     * path, because the platform's own Task Edit CRUD is un-grantable by permission set here
     * (see TransactionTaskService's header). Removing this call does not fall back to a
     * platform refusal; it opens the write to every user who can reach the controller.
     *
     * @throws TransactionActionPermissionService.AccessDeniedException carrying
     *         NO_PERMISSION_MESSAGE when the running user lacks access.
     * @throws System.QueryException when the permission lookup itself fails unexpectedly.
     * @example
     * TransactionActionPermissionService.assertTaskActionAccess();
     */
    public static void assertTaskActionAccess() {
        if (hasTaskActionAccess()) {
            return;
        }
        throw new AccessDeniedException(NO_PERMISSION_MESSAGE);
    }

    /**
     * Evaluates the gate.
     *
     * ⚠ ORDER: the custom permission is tested FIRST because it costs ZERO SOQL, so a Transactions
     * team member pays nothing and only a non-holder pays the bypass read. A cost ordering, not a
     * correctness one — this gate has never had a `User` field and so has never had the
     * admin-lockout hazard the two sibling gates carried until 2026-08-12.
     */
    private static Boolean computeTransactionActionAccess() {
        if (simulateLookupFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        // 0 SOQL. Returns false (never throws) for an unknown or unheld permission.
        if (FeatureManagement.checkPermission(TRANSACTION_ACTION_CUSTOM_PERMISSION)) {
            return true;
        }

        return hasModifyAllData();
    }

    /**
     * Evaluates the TASK gate. Structurally identical to computeTransactionActionAccess above,
     * differing only in the permission token it tests.
     *
     * ⚠ THE "Modify All Data" BYPASS IS RETAINED HERE DELIBERATELY, AND DROPPING IT WOULD BE A
     * REGRESSION, NOT A TIGHTENING. Administrators are the ONLY people who can complete a
     * checklist Task today — "Modify All Data" implies Task CRUD, which is precisely why the
     * defect reads as "works for me" to an admin. A task gate without the bypass would take
     * that away from every administrator who has not also been assigned `DPEG_Task_Edit`.
     *
     * ⚠ It shares the `simulateLookupFailure` test seam with the stage gate — one flag meaning
     * "the permission machinery itself failed", not one per gate. A test setting it affects
     * both, which is correct: the fault it simulates is not permission-specific.
     */
    private static Boolean computeTaskActionAccess() {
        if (simulateLookupFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        // 0 SOQL. Returns false (never throws) for an unknown or unheld permission.
        if (FeatureManagement.checkPermission(TASK_ACTION_CUSTOM_PERMISSION)) {
            return true;
        }

        return hasModifyAllData();
    }

    /**
     * Whether the running user holds "Modify All Data" — through their profile or any assigned
     * permission set.
     *
     * 🔴 RE-IMPLEMENTED HERE IN THE 2026-08-12 REWRITE RATHER THAN INHERITED. It used to come free
     * from `LeadActionPermissionService.hasAnyPermissionSet`, which checks the same permission from
     * the same rows. Dropping it would have narrowed access for every administrator — see the class
     * header. It is byte-for-byte the same logic as the two sibling services' private copies, which
     * is a deliberate triplication: three classes documented as one design, each self-contained, in
     * preference to a fourth class existing only to hold eight lines.
     *
     * A user's PROFILE surfaces in PermissionSetAssignment as an assignment to a PermissionSet with
     * `IsOwnedByProfile = true`, and a permission set GROUP assignment points at the group's
     * aggregate permission set, so this single pass covers profile-granted, set-granted and
     * group-granted "Modify All Data" without any group expansion.
     *
     * This is the ONLY query this service performs, and only a non-holder reaches it.
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
     *
     * ⚠ Before 2026-08-12 the equivalent call was `LeadActionPermissionService.clearCache()`. That
     * call no longer affects this gate at all.
     */
    @TestVisible
    private static void clearCache() {
        cachedHasTransactionActionAccess = null;
        // ⚠ BOTH caches. A user switch invalidates every memoized answer in this class, not just
        // the stage one; clearing only half would leave the previous user's task answer standing.
        cachedHasTaskActionAccess = null;
        simulateLookupFailure = false;
    }
}
