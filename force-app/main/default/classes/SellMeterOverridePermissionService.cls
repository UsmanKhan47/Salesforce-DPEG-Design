/**
 * SellMeterOverridePermissionService — the single source of truth for "may the running user
 * OVERRIDE the Sell Meter and start a disposition on a YELLOW (31-90 days to peak) asset?".
 *
 * Added 2026-08-31 (Disposition BA gap closure, Tranche 2, item 5a — stories 12 and 14). Shaped
 * after DispositionActionPermissionService, which is the nearest working precedent in this repo,
 * but it is a SEPARATE class reading a SEPARATE token. Both halves of that are load-bearing.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS IS NOT A METHOD ON `DispositionActionPermissionService`
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * That class's header opens with *"🔴 THE TWO CLASSES ARE ONE DESIGN ON TWO MODULES — CHANGE BOTH
 * OR NEITHER"*, its twin being `OpportunityActionPermissionService`. Adding a disposition-only
 * method there would be exactly the one-sided change it forbids, and there is no acquisitions
 * analogue of a sell meter to mirror it onto. So the shape is copied and the file is new.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE TOKEN IS **NOT** `Disposition_Deal_Actions`, AND REUSING IT WOULD INVERT THIS GATE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `Disposition_Deal_Actions` is granted by `DPEG_Disposition_Edit` — the ANALYST set — and its own
 * `customPermission-meta.xml` carries a red banner forbidding it on `DPEG_Disposition_View`:
 *   *"🔴 `DPEG_Disposition_View` DOES NOT AND MUST NOT CARRY THIS PERMISSION. Principals hold the
 *   View set and APPROVE dispositions; granting it there would put the submit and advance buttons
 *   in front of the approvers of those submissions."*
 * Gating the Override on that token would therefore show it to ANALYSTS and hide it from
 * PRINCIPALS — the exact inverse of what stories 12/14 ask for.
 *
 * `Disposition_Sell_Meter_Override` is the deliberate MIRROR IMAGE: it is granted by
 * `DPEG_Disposition_View` ONLY (the Principal persona, reaching the principals through
 * `DPEG_Principal_PSG`) and must NOT be added to `DPEG_Disposition_Edit`. The two tokens point in
 * opposite directions on purpose. Merging them, or "restoring symmetry" by granting both to both
 * sets, collapses this gate entirely.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * THE GATE IS ONE FACTOR: THE CUSTOM PERMISSION
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The running user passes when they hold `Disposition_Sell_Meter_Override`, or when they hold
 * "Modify All Data". That is the whole gate — there is no User flag, no FLS read and therefore no
 * `catch (QueryException)`; see DispositionActionPermissionService's header for the measured
 * reason that model was retired (a flexipage rule referencing a FIELD evaluates FALSE for anyone
 * lacking FLS on it, silently, and a Metadata-API-deployed field arrives with FLS for nobody).
 *
 * ⚠ ORDER IS A COST DECISION, NOT A CORRECTNESS ONE. `FeatureManagement.checkPermission` costs
 * ZERO SOQL, so a principal pays nothing and only a NON-principal pays the single
 * `PermissionSetAssignment` read behind the admin bypass. There is no statement here that can
 * throw an FLS denial, so nothing about the order can lock anyone out.
 *
 * ⚠ REJECTED: `@salesforce/customPermission/Disposition_Sell_Meter_Override` in the LWC, with no
 * Apex at all. Genuinely tempting — zero SOQL, zero classes. Rejected because (i) that import is
 * used NOWHERE in this repo, so its behaviour here is unproven, and (ii) it does not honour the
 * Modify-All-Data bypass every sibling gate in this codebase provides, which would lock a bare
 * System Administrator out of the button with no diagnosis path. It would also give the CLIENT a
 * gate the SERVER does not share, and the server is the real gate (see DispositionService).
 *
 * ── FAIL CLOSED, BUT DO NOT DISGUISE A SYSTEM FAULT AS A DENIAL ───────────────
 * `FeatureManagement.checkPermission` returns a Boolean and never throws — an unknown or
 * not-yet-deployed permission name simply returns `false`, so this gate fails CLOSED if the admin
 * half of the change is missing. A failure of the permission machinery itself (the
 * `PermissionSetAssignment` read) is NOT a denial signal — it is a fault, and it PROPAGATES. The
 * controller masks it behind a fixed message and the LWC guard treats a thrown check exactly like
 * `false`, so the gate still fails closed end to end.
 *
 * 🔴 A DEPLOY THAT SHIPS THIS CLASS WITHOUT THE PERMISSION-SET GRANT DENIES EVERY PRINCIPAL. That
 * is the correct direction to fail, but it is SILENT: the Override button simply renders disabled
 * for everyone and the server refuses every YELLOW create. The custom permission, the
 * `DPEG_Disposition_View` grant and this class belong in the same wave.
 *
 * ── ADMIN BYPASS (deliberate, RETAINED) ───────────────────────────────────────
 * ⚠ AN ADMIN SMOKE TEST PROVES NOTHING ABOUT THIS GATE. A System Administrator passes for a reason
 * unrelated to holding the token. Acceptance-test as a real principal persona AND as a real
 * junior-analyst persona — the analyst denial is the half stories 12/14 are actually about.
 *
 * Layer: Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). Zero SOQL and zero
 * DML of its own — the one query it causes belongs to `PermissionSetAssignmentSelector`.
 *
 * ── BULKIFICATION ─────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user) with no record collection,
 * no loop over records and no DML — the same shape the rule exempts for
 * `DispositionActionPermissionService` and `OpportunityActionPermissionService`. Cost is at most
 * ONE query per transaction however many times it is asked, and the test suite asserts that
 * directly via `Limits.getQueries()` rather than by volume.
 *
 * @see force-app/main/default/classes/DispositionActionPermissionService.cls (the shape this copies)
 * @see force-app/main/default/classes/SellMeterController.cls (hasOverrideAccess — the LWC read)
 * @see force-app/main/default/classes/DispositionService.cls (the YELLOW-branch server assert)
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls (admin bypass)
 */
public with sharing class SellMeterOverridePermissionService {

    /**
     * Raised when the running user may not override the sell meter. Typed (rather than
     * AuraHandledException) so this service stays UI-agnostic — the controller owns the mapping to
     * the LWC boundary. Repo precedent: DispositionActionPermissionService.AccessDeniedException.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * The user-facing denial message.
     *
     * ⚠ IT IS DELIBERATELY **NOT** THE SHARED `NO_PERMISSION_MESSAGE` THE FOUR STAGE-ACTION GATES
     * REUSE, AND THAT IS A DEPARTURE FROM THIS FILE'S TEMPLATE. Those four all answer the same
     * question ("may you drive this record's stage?") from four buttons that are HIDDEN when the
     * answer is no, so a generic refusal is all a user ever sees and telling them which token they
     * lack is not information they are owed.
     *
     * This gate is different in exactly the way that matters: the Override button is VISIBLE and
     * DISABLED for a non-principal (design decision D-11), so the user can already see the action
     * exists and the only useful thing left to tell them is WHO to ask. A bare "You don't have
     * permission to perform this action." on a button they can see, next to an Initiate button
     * that works on the row above, reads as a fault rather than as a rule.
     *
     * Authored, plain-ASCII and user-safe by construction: no platform text, no field API names,
     * no exception detail, no permission-set or token name. Safe to surface verbatim.
     */
    public static final String NO_OVERRIDE_PERMISSION_MESSAGE =
        'Only a principal can override the sell meter. This property is not at peak yet, '
        + 'so starting a disposition on it needs a principal to approve the override.';

    /**
     * The AUTHORIZATION token. Holding it IS the gate.
     *
     * 🔴 GRANTED BY `DPEG_Disposition_View` (the PRINCIPAL persona) AND BY NOTHING ELSE. It must
     * NOT be added to `DPEG_Disposition_Edit` — see the class header. This is the deliberate
     * mirror image of `Disposition_Deal_Actions`, which lives on `_Edit` and is forbidden on
     * `_View`, and the two must not be merged or made symmetric.
     *
     * ⚠ A String, resolved at RUNTIME, so this class compiles and deploys whether or not the
     * custom permission exists in the target org yet. An absent permission returns `false` — the
     * gate fails closed.
     */
    private static final String SELL_METER_OVERRIDE_CUSTOM_PERMISSION =
        'Disposition_Sell_Meter_Override';

    /**
     * Transaction-scoped cache of the composed answer. Neither the running user's custom-permission
     * grants nor their "Modify All Data" can change mid-transaction, so the bypass read happens at
     * most once per execution context however many callers ask.
     *
     * @TestVisible so tests can reset it between System.runAs blocks — the running user changes
     * there and the cache must not survive that.
     */
    @TestVisible
    private static Boolean cachedHasOverrideAccess;

    /**
     * Test seam. The controller's failure catch exists for a real mode (a failure of the
     * PermissionSetAssignment read behind the admin bypass), but that mode cannot be provoked
     * deterministically — every user can read their OWN assignment rows. This flag is the only
     * deterministic way to reach that branch.
     *
     * `private` + `@TestVisible` (so no production class can set it) AND additionally gated on
     * `Test.isRunningTest()`, so production behaviour is provably unchanged. Repo precedent:
     * DispositionActionPermissionService.simulateLookupFailure.
     *
     * ⚠ EVALUATED BEFORE THE CUSTOM-PERMISSION CHECK ON PURPOSE. If it sat after, a test user
     * holding the permission would short-circuit past the seam and the fault branch would be
     * unreachable for exactly the personas most worth testing.
     */
    @TestVisible
    private static Boolean simulateLookupFailure = false;

    /**
     * Whether the running user may override the sell meter on a YELLOW asset.
     *
     * @return true when the user holds the `Disposition_Sell_Meter_Override` custom permission, or
     *         has "Modify All Data"; false otherwise.
     * @throws System.QueryException when the permission-set lookup behind the admin bypass fails
     *         unexpectedly. Deliberately NOT swallowed — see the fail-closed note in the header.
     * @example
     * if (!SellMeterOverridePermissionService.hasSellMeterOverrideAccess()) { return; }
     */
    public static Boolean hasSellMeterOverrideAccess() {
        if (cachedHasOverrideAccess != null) {
            return cachedHasOverrideAccess;
        }
        // Assign only AFTER a successful computation: a thrown fault must leave the cache empty so
        // the next ask re-evaluates rather than memoizing a fault as an answer.
        Boolean allowed = computeSellMeterOverrideAccess();
        cachedHasOverrideAccess = allowed;
        return allowed;
    }

    /**
     * Server-side guard for the sell-meter override.
     *
     * 🔴 CALL THIS ONLY ON THE YELLOW BRANCH. An unscoped assert at the top of a create path closes
     * GREEN Initiate to every junior analyst, which no story asks for and which
     * `DispositionService`'s header refuses in terms. Both of its create paths compute the band
     * already and call this immediately after, only when the band is YELLOW.
     *
     * @throws SellMeterOverridePermissionService.AccessDeniedException carrying
     *         NO_OVERRIDE_PERMISSION_MESSAGE when the running user lacks access.
     * @throws System.QueryException when the permission lookup itself fails unexpectedly.
     * @example
     * SellMeterOverridePermissionService.assertSellMeterOverrideAccess();
     */
    public static void assertSellMeterOverrideAccess() {
        if (hasSellMeterOverrideAccess()) {
            return;
        }
        throw new AccessDeniedException(NO_OVERRIDE_PERMISSION_MESSAGE);
    }

    /**
     * Evaluates the gate.
     *
     * ⚠ ORDER: the custom permission is tested FIRST because it costs ZERO SOQL, so a principal
     * pays nothing and only a non-principal pays the bypass read.
     */
    private static Boolean computeSellMeterOverrideAccess() {
        if (simulateLookupFailure == true && Test.isRunningTest()) {
            throw new QueryException('Simulated permission-lookup failure (test seam).');
        }

        // 0 SOQL. Returns false (never throws) for an unknown or unheld permission.
        if (FeatureManagement.checkPermission(SELL_METER_OVERRIDE_CUSTOM_PERMISSION)) {
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
     * This is the ONLY query this service causes, and only a non-principal reaches it.
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
        cachedHasOverrideAccess = null;
        simulateLookupFailure = false;
    }
}
