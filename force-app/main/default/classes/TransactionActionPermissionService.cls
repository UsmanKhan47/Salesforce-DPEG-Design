/**
 * TransactionActionPermissionService — the single source of truth for "may the running user drive
 * the TRANSACTION stage quick action?".
 *
 * Added 2026-08-12 with the Transaction Advance Stage action. Consumed through
 * RecordStageAdvanceService's per-record-type gate dispatch
 * (StageActionGate.TRANSACTION_STAGE_ACTIONS), which is the only caller today.
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It orchestrates one
 * other service and holds zero SOQL and zero DML of its own.
 *
 * ── 🔴 THIS GATE IS MEMBERSHIP-ONLY. IT IS **NOT** A TWO-FACTOR DRIVER GATE, AND THAT IS A
 *    DELIBERATE, ARGUED DECISION — DO NOT "HARMONIZE" IT WITH ITS TWO SIBLINGS ─────────────────
 *
 * `OpportunityActionPermissionService` and `DispositionActionPermissionService` are TWO-FACTOR:
 * FLS read on a `User.*_Driver__c` checkbox (granted by exactly one permission set) AND that
 * checkbox `true` on the running user. This class is one-factor: membership of the
 * `Transaction_Stage_Actions_Access` permission set, with a "Modify All Data" bypass. It follows
 * `LeadActionPermissionService`, not the two `*_Driver` services.
 *
 * 🔴 WHY THE SIBLINGS' ARGUMENT DOES NOT TRANSFER — the reason is HISTORICAL, and missing it is
 * how a future reader "fixes" this back into a second `User` checkbox nobody needs:
 *
 *   - On `Opportunity`, `User.Deal_Driver__c` ALREADY EXISTED and ALREADY DROVE the six Dynamic
 *     Actions visibility rules on `Opportunity_Record_Page` before any Apex gate was written. A
 *     membership check there would therefore have WIDENED a LIVE authorization boundary: every
 *     holder of the permission set with the flag `false` is denied today and would have been
 *     granted. `OpportunityActionPermissionServiceTest
 *     .hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` exists to keep that true, and
 *     `DispositionActionPermissionService` mirrors it so a sale driver and a purchase driver stay
 *     separable.
 *   - `Transaction__c` HAS NO SUCH FLAG AND NO SUCH POPULATION. There is no
 *     `User.Transaction_Driver__c`, no visibility rule bound to one, and therefore nobody whose
 *     access a membership check could widen. Inventing the flag would create the two-factor
 *     condition purely so this class could check it — and would buy two UNDEPLOYABLE org steps
 *     (assign the set AND tick the box per user) whose omission is silent: the action simply
 *     refuses, with no error anywhere naming the missing tick.
 *
 * ⇒ The two-factor pattern protects an EXISTING boundary. Where there is none, it is a second
 *   moving part with a silent failure mode. USER DECISION 2026-08-12, overriding the design
 *   document's `TRANSACTION_DRIVER` recommendation: "why do we need driver? When we can assign a
 *   permission set to show quick actions to transaction user."
 *
 * ⚠ THE COST IS STATED, NOT HIDDEN — AND IT IS LARGER THAN AN EARLIER DRAFT OF THIS HEADER
 * CLAIMED. That draft said "revoking one user means unassigning the set rather than unticking a
 * box". **That option does not exist.** `Transaction_Stage_Actions_Access` is a MEMBER of the
 * `DPEG_Transaction_Team` permission set GROUP (verified 2026-08-12), and a group's membership is
 * the unit of assignment, so there is no per-user unassignment of one member set: removing this
 * capability from one user means removing them from the group entirely and losing the other TEN
 * sets with it — Base, Apex, Transaction Edit, Task Edit, Opportunity View, Property View, Reports,
 * the Transaction app, Account View and Contact View. In practice that is not a revocation, it is a
 * deprovisioning.
 *
 * ⇒ SO STATE IT PLAINLY: **THIS GATE IS TEAM-WIDE BY DESIGN.** It is granted by membership of
 * `DPEG_Transaction_Team`, and it answers "is this user on the Transactions team?", never "is this
 * particular user allowed to advance a stage?". PER-USER REVOCATION IS NOT AVAILABLE without
 * removing the user from the team.
 *
 * ⚠ THE PLACEMENT IS PRECEDENTED AND IS NOT THE DEFECT. `Opportunity_Stage_Actions_Access` sits
 * inside `DPEG_Junior_Analyst_PSG` in exactly the same way, and a layer-4 capability set belonging
 * to its persona group is the documented shape (ARCHITECTURE.md §2, "Permission Set Architecture").
 * The difference is that Opportunity pairs its capability set with a layer-5 authorization FLAG
 * (`Acquisition_Deal_Driver` / `User.Deal_Driver__c`), assigned DIRECTLY rather than through the
 * group — and that flag is where its per-user granularity actually comes from, not from the
 * capability set's placement. This gate has no such partner, by decision, so it has no such
 * granularity. Only the earlier CLAIM was wrong; the design is unchanged.
 *
 * ⇒ If Transactions ever needs to deny ONE user while keeping them on the team, no edit to this
 * class or to any permission set achieves it — that need is the trigger to add a layer-5 flag, and
 * it should be argued from that need when it appears, never from symmetry with Opportunity.
 *
 * ── WHY IT DELEGATES RATHER THAN COPYING THE MEMBERSHIP LOGIC ─────────────────
 * `LeadActionPermissionService.hasAnyPermissionSet(Set<String>)` is PUBLIC and its own Javadoc
 * states it is "generic on purpose … reusable by any future feature that needs a permission set
 * gate". Reusing it buys three things a copy would lose:
 *   1. GROUP EXPANSION. A user provisioned through a `PermissionSetGroup` (which is how every DPEG
 *      persona is provisioned) holds no direct assignment row, so a naive name check misses them
 *      entirely. That expansion is already written and already tested there.
 *   2. THE TRANSACTION-SCOPED CACHE IS SHARED. It holds EVERY permission set name the running user
 *      effectively holds, so this gate costs ZERO extra queries when anything else has already
 *      asked in the same transaction — and at most two when nothing has.
 *   3. THE "Modify All Data" BYPASS IS COMPUTED ONCE, in one place, from the same rows.
 * A copy would be a second cache that can disagree with the first about the same user.
 *
 * ⚠ TEST SEAMS LIVE ON `LeadActionPermissionService`, NOT HERE. A test switching users with
 * `System.runAs` must call `LeadActionPermissionService.clearCache()` (the running user changes and
 * the cache must not survive that), and `LeadActionPermissionService.simulateLoadFailure` is how
 * the controller's fault branch is reached. They are deliberately NOT re-declared here: a second
 * seam onto the same cache is a way for a test to leave it half-cleared.
 *
 * ── FAIL CLOSED, BUT DO NOT DISGUISE A SYSTEM FAULT AS A DENIAL ───────────────
 * Nothing here swallows an exception. A failure of the permission machinery propagates to
 * RecordStageAdvanceController, which masks it behind a fixed message; `c/recordStageGuard` treats
 * a thrown check exactly like `false`, so the gate still fails CLOSED end to end — the difference
 * is only that a fault reads as a fault rather than as "you lack permission".
 *
 * ⚠ Nothing here can return `true` by accident: the only paths to `true` are a positive membership
 * match or "Modify All Data".
 *
 * ── ADMIN BYPASS ──────────────────────────────────────────────────────────────
 * Inherited from `hasAnyPermissionSet`. It is checked from the SAME assignment rows this gate reads
 * and needs no ordering care, unlike the two `*_Driver` services — there is no `User` field here,
 * so there is no FLS read that could lock out the administrator who just deployed the feature.
 * That absence is one of the concrete simplifications the membership design buys.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user) with no record collection,
 * no loop over records and no DML — the same shape the rule exempts for
 * LeadActionPermissionService, OpportunityActionPermissionService and
 * DispositionActionPermissionService.
 *
 * @see force-app/main/default/classes/LeadActionPermissionService.cls (the membership engine)
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls (the gate dispatch)
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the two-factor twin)
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
     * Holding this permission set grants the Transaction stage action.
     *
     * 🔴 A SET, NOT A SINGLE STRING, because `hasAnyPermissionSet` takes a collection and because
     * the Lead gate's precedent shows a second name is a routine future need (it accepts
     * `Broker_Protection_Access` alongside its own set). Adding a name here GRANTS the action to
     * that set's whole population — it is a real authorization change, not configuration.
     *
     * ⚠ `Transaction_Stage_Actions_Access` is a LAYER-4 CAPABILITY set (ARCHITECTURE.md §2,
     * "Permission Set Architecture"): it carries the Apex class access this feature needs and
     * nothing else. It is deliberately NOT `DPEG_Transaction_Edit` — that set already grants
     * `Transaction__c.Stage__c` editable to its whole population, so gating on it would make the
     * gate a no-op for everyone who can edit a Transaction at all, i.e. exactly no gate.
     */
    private static final Set<String> TRANSACTION_ACTION_PERMISSION_SETS = new Set<String>{
        'Transaction_Stage_Actions_Access'
    };

    /**
     * Whether the running user may drive the Transaction stage quick action.
     *
     * @return true when the user holds Transaction_Stage_Actions_Access (directly or through a
     *         permission set group), or has "Modify All Data"; false otherwise.
     * @throws System.QueryException when the permission-set lookup itself fails unexpectedly.
     *         Deliberately NOT swallowed — see the fail-closed note in the class header.
     * @example
     * if (!TransactionActionPermissionService.hasTransactionActionAccess()) { return; }
     */
    public static Boolean hasTransactionActionAccess() {
        return LeadActionPermissionService.hasAnyPermissionSet(TRANSACTION_ACTION_PERMISSION_SETS);
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
}
