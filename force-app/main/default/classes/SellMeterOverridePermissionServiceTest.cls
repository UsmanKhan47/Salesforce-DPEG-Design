/**
 * @description Tests SellMeterOverridePermissionService — the gate behind the Sell Meter's YELLOW
 * "Override" action (Tranche 2 item 5a, stories 12 and 14). Shaped after
 * DispositionActionPermissionServiceTest, which is the nearest working precedent, and deliberately
 * so: the fixture traps in that file are the same ones here.
 *
 * ── 🔴 THE TWO TESTS THAT CARRY THIS CLASS ──────────────────────────────────
 * 1. `anAnalystHoldingTheDealActionsTokenIsStillDenied` — the BOUNDARY-INVERSION proof. The design
 *    for this feature originally cited `Disposition_Deal_Actions` as the token to reuse, and that
 *    token is EXACTLY BACKWARDS: it lives on `DPEG_Disposition_Edit` (the ANALYST set) and its own
 *    XML forbids it on `DPEG_Disposition_View` (the PRINCIPAL set). Reusing it would have shown the
 *    Override to analysts and hidden it from principals — the precise inverse of the stories. Every
 *    other test in this class would pass unchanged against an implementation reading
 *    `Disposition_Deal_Actions`. This one is the only falsifier.
 * 2. `aPrincipalSetHolderIsAllowed` — the reachable-true-branch proof. If it ever fails, the gate
 *    has no true branch for any non-administrator and the Override button is dead for everyone,
 *    which fails CLOSED and therefore silently.
 *
 * ── ⚠ WHAT AN ADMIN RUN CANNOT PROVE ────────────────────────────────────────
 * "Modify All Data" bypasses this gate entirely, so the test-running user passes unconditionally.
 * Every meaningful assertion here therefore runs inside System.runAs against a purpose-built user.
 * The same caveat applies to UAT: an admin smoke test of the Override button proves nothing at all.
 *
 * ── ⚠ THE CACHE MUST BE CLEARED AROUND EVERY runAs ──────────────────────────
 * The service memoizes its answer per transaction — correct in production (one user per
 * transaction) and a trap in a test that switches users. clearCache() is called on both sides of
 * each runAs block.
 *
 * ── ⚠ WHY `Standard User` IS THE RIGHT BASE PROFILE HERE ────────────────────
 * This repo has a standing rule that a denial test must use `Minimum Access - Salesforce`, because
 * `Standard User` already grants read on STANDARD objects and a denial test built on it proves
 * nothing. That rule is about OBJECT access. This class asserts nothing about object access at all
 * — it asks only whether a CUSTOM PERMISSION is held, and no profile in this org grants
 * `Disposition_Sell_Meter_Override` (asserted directly, as a precondition, in the admin-bypass test
 * below rather than assumed). `Standard User` is used to match the sibling gate suites so a reader
 * comparing them sees one shape. The tests in DispositionServiceTest that need a persona who can
 * READ the asset are the ones where the profile choice matters, and they say so.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * No 251-record scenario. This is a per-transaction-singleton question about ONE user (the running
 * user) with no record collection, no loop and no DML — the same shape
 * .claude/rules/bulk-test-rule.md exempts for OpportunityActionPermissionService,
 * LeadActionPermissionService and DispositionActionPermissionService. Cost is asserted directly via
 * Limits.getQueries() instead of by volume.
 *
 * @see force-app/main/default/classes/SellMeterOverridePermissionService.cls
 * @see force-app/main/default/classes/DispositionActionPermissionServiceTest.cls (the template)
 * @author Salesforce Developer Agent
 */
@isTest
private class SellMeterOverridePermissionServiceTest {

    /** The ONLY set that grants `Disposition_Sell_Meter_Override` — the PRINCIPAL persona. */
    private static final String PRINCIPAL_PERM_SET = 'DPEG_Disposition_View';

    /**
     * The ANALYST persona set. It grants `Disposition_Deal_Actions` and must NEVER grant
     * `Disposition_Sell_Meter_Override` — the two tokens are deliberate mirror images.
     */
    private static final String ANALYST_PERM_SET = 'DPEG_Disposition_Edit';

    private static final String OVERRIDE_TOKEN = 'Disposition_Sell_Meter_Override';
    private static final String DEAL_ACTIONS_TOKEN = 'Disposition_Deal_Actions';

    // ═════════════════════════════════════════════════════════════════════════
    // DENIALS
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void bareStandardUserIsDenied() {
        User bareUser = buildStandardUser('smo1');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'A user with neither Modify All Data nor DPEG_Disposition_View (the only grantor of '
            + 'Disposition_Sell_Meter_Override) must be denied the sell-meter override');
    }

    /**
     * 🔴 THE BOUNDARY-INVERSION TEST — the single most important assertion in this class.
     *
     * A fully provisioned DISPOSITION ANALYST (`DPEG_Disposition_Edit`, carrying
     * `Disposition_Deal_Actions`) must be DENIED the override. The design for this feature cited
     * `Disposition_Deal_Actions` as the token to reuse; that token lives on the analyst set and is
     * FORBIDDEN on the principal set by its own XML, so reusing it would have inverted the gate
     * exactly. Every other test here would pass against that wrong implementation. This one would
     * not.
     *
     * The precondition assertion is what keeps it honest: if the analyst set ever stops granting
     * `Disposition_Deal_Actions`, this stops being an inversion test and becomes a second
     * bare-user test, green and meaningless.
     */
    @isTest
    static void anAnalystHoldingTheDealActionsTokenIsStillDenied() {
        User analyst = buildStandardUser('smo2');
        insert analyst;
        assignPermissionSet(analyst.Id, ANALYST_PERM_SET);

        Test.startTest();
        Boolean holdsDealActions;
        Boolean overrideAllowed;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(analyst) {
            holdsDealActions = FeatureManagement.checkPermission(DEAL_ACTIONS_TOKEN);
            overrideAllowed = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(holdsDealActions,
            'PRECONDITION: this user IS a provisioned disposition analyst holding '
            + 'Disposition_Deal_Actions. If this fails the fixture is wrong and the assertion below '
            + 'proves nothing — it degenerates into a second bare-user test.');
        Assert.isFalse(overrideAllowed,
            '🔴 An ANALYST must NOT be able to override the sell meter. Disposition_Deal_Actions '
            + 'lives on DPEG_Disposition_Edit and is FORBIDDEN on DPEG_Disposition_View by its own '
            + 'XML; Disposition_Sell_Meter_Override is its deliberate mirror image and lives on '
            + 'DPEG_Disposition_View only. Reading the wrong token here inverts stories 12/14 — it '
            + 'shows the Override to analysts and hides it from the principals it is for.');
    }

    /**
     * A grant to a DIFFERENT user must not leak. Worth keeping even though
     * FeatureManagement.checkPermission resolves against the running context: the admin-bypass path
     * still reads through PermissionSetAssignmentSelector's hard-filtered query, and this pins that
     * a second user's grant in the same transaction cannot bleed across.
     */
    @isTest
    static void anotherUserHoldsTheGrant_stillDeniesTheRunningUser() {
        User principal = buildStandardUser('smo3');
        User bareUser = buildStandardUser('smo3b');
        insert new List<User>{ principal, bareUser };
        assignPermissionSet(principal.Id, PRINCIPAL_PERM_SET);

        Test.startTest();
        Boolean allowed;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Another user holding DPEG_Disposition_View must never grant access to the running user');
    }

    /**
     * The assert's message is AUTHORED TO BE SHOWN and is deliberately NOT the shared
     * `NO_PERMISSION_MESSAGE` the four stage-action gates reuse — see the constant's own header.
     * This pins both halves: the authored wording is present, and the generic wording is absent.
     * Asserting only "an AccessDeniedException was thrown" would pass against a copy-paste of the
     * shared string, which is the change most likely to be made by someone tidying.
     */
    @isTest
    static void assertThrowsTheAuthoredOverrideWording() {
        User bareUser = buildStandardUser('smo4');
        insert bareUser;

        Test.startTest();
        Boolean refused = false;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                SellMeterOverridePermissionService.assertSellMeterOverrideAccess();
                Assert.fail('assertSellMeterOverrideAccess must REFUSE an unprovisioned user. '
                    + 'Returning normally means the gate did not run at all.');
            } catch (SellMeterOverridePermissionService.AccessDeniedException e) {
                refused = true;
                Assert.areEqual(
                    SellMeterOverridePermissionService.NO_OVERRIDE_PERMISSION_MESSAGE,
                    e.getMessage(),
                    'The denial must carry the authored override wording verbatim');
                Assert.isTrue(e.getMessage().contains('principal'),
                    'The message must name WHO can do this. The Override button is VISIBLE and '
                    + 'disabled for a non-principal (D-11), so "you don\'t have permission" on a '
                    + 'button they can see reads as a fault rather than as a rule: ' + e.getMessage());
                Assert.isFalse(
                    e.getMessage().contains('perform this action'),
                    'It must NOT have been collapsed into the shared stage-action wording — those '
                    + 'four gates hide their buttons, this one does not. See '
                    + 'NO_OVERRIDE_PERMISSION_MESSAGE\'s header: ' + e.getMessage());
            }
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The server-side assert must refuse an unprovisioned user');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // GRANTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE REACHABLE-TRUE-BRANCH PROOF. The gate fails CLOSED, so a missing or misspelled token —
     * or a permission-set grant that never deployed — denies EVERYONE silently: the Override button
     * simply renders disabled for the whole population and the server refuses every YELLOW create.
     * Nothing else in this suite would notice. This test is what notices.
     */
    @isTest
    static void aPrincipalSetHolderIsAllowed() {
        User principal = buildStandardUser('smo5');
        insert principal;
        assignPermissionSet(principal.Id, PRINCIPAL_PERM_SET);

        Test.startTest();
        Boolean allowed;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(principal) {
            allowed = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
            // Must not throw.
            SellMeterOverridePermissionService.assertSellMeterOverrideAccess();
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(allowed,
            'Holding DPEG_Disposition_View — the ONLY grantor of Disposition_Sell_Meter_Override — '
            + 'must grant. If this fails, the gate has no reachable true branch for any '
            + 'non-administrator: the Override button is dead for every principal and the failure '
            + 'is silent, because the gate fails closed.');
    }

    /**
     * The admin bypass. A System Administrator holding NEITHER the custom permission NOR the
     * permission set must still pass, via Modify All Data — an administrator can already create a
     * Disposition through the API or the New button, so denying them the Override would be theatre.
     *
     * 🔴 THE TOKEN IS ASSERTED DIRECTLY AS THE PRECONDITION, NOT JUST THE SET NAME. The set check
     * excludes ONE grantor; the premise is about the TOKEN. If any future route ever grants a bare
     * administrator `Disposition_Sell_Meter_Override`, this fails HERE, loudly, instead of turning
     * the bypass assertion below into a tautology that re-proves the token.
     */
    @isTest
    static void administratorPassesWithoutTheCustomPermissionOrThePermissionSet() {
        User bareAdmin = buildUserOnProfile('System Administrator', 'smo6');
        insert bareAdmin;   // no permission set

        Test.startTest();
        Boolean allowed;
        Boolean adminHoldsTheToken;
        Set<String> heldSetNames = new Set<String>();
        SellMeterOverridePermissionService.clearCache();
        System.runAs(bareAdmin) {
            for (PermissionSetAssignment row : PermissionSetAssignmentSelector.selectForCurrentUser()) {
                if (row.PermissionSet != null) {
                    heldSetNames.add(row.PermissionSet.Name);
                }
            }
            adminHoldsTheToken = FeatureManagement.checkPermission(OVERRIDE_TOKEN);
            allowed = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(adminHoldsTheToken,
            'PRECONDITION (the real one): a bare System Administrator must NOT hold '
            + 'Disposition_Sell_Meter_Override by ANY route. If they do, the assertion below stops '
            + 'isolating the Modify All Data bypass and starts re-proving the token — green, and '
            + 'meaningless.');
        Assert.isFalse(heldSetNames.contains(PRINCIPAL_PERM_SET),
            'PRECONDITION: the admin must hold no DPEG_Disposition_View assignment, or this test '
            + 'would not isolate the Modify All Data bypass.');
        Assert.isTrue(allowed,
            'Modify All Data must grant the override even without the custom permission.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // CACHING AND FAULTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * A principal must pay ZERO queries however many times the gate is asked:
     * FeatureManagement.checkPermission costs 0 SOQL and a holder never reaches the Modify All Data
     * bypass read. This is the cost ordering the service's header argues for, asserted rather than
     * described.
     */
    @isTest
    static void repeatedCallsByAPrincipalCostZeroQueries() {
        User principal = buildStandardUser('smo7');
        insert principal;
        assignPermissionSet(principal.Id, PRINCIPAL_PERM_SET);

        Test.startTest();
        Integer used;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(principal) {
            Integer before = Limits.getQueries();
            SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
            SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
            SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
            used = Limits.getQueries() - before;
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.areEqual(0, used,
            'A principal must pay ZERO queries for the gate. Actual: ' + used);
    }

    /** A non-principal pays at most one query (the bypass read), memoized across repeated asks. */
    @isTest
    static void repeatedCallsByANonPrincipalCostAtMostOneQuery() {
        User bareUser = buildStandardUser('smo8');
        insert bareUser;

        Test.startTest();
        Integer used;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(bareUser) {
            Integer before = Limits.getQueries();
            SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
            SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
            used = Limits.getQueries() - before;
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(used <= 1,
            'A non-principal must pay at most ONE query (the Modify All Data bypass read), memoized '
            + 'for every subsequent ask. Actual: ' + used);
    }

    @isTest
    static void clearCacheAfterAUserSwitchRecomputes() {
        User denied = buildStandardUser('smo9');
        insert denied;
        User granted = buildStandardUser('smo10');
        insert granted;
        assignPermissionSet(granted.Id, PRINCIPAL_PERM_SET);

        Test.startTest();
        Boolean first;
        Boolean second;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(denied) {
            first = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        }
        SellMeterOverridePermissionService.clearCache();
        System.runAs(granted) {
            second = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(first, 'The unprovisioned user is denied');
        Assert.isTrue(second,
            'After clearCache the provisioned user must be re-evaluated. A cache that survived the '
            + 'switch would answer the FIRST user\'s question for the second.');
    }

    /**
     * A failure of the permission MACHINERY is a fault, not a denial, and must PROPAGATE — the
     * controller masks it behind a fixed message and the LWC guard treats a thrown check exactly
     * like `false`, so the gate still fails closed end to end. The difference is only that a fault
     * reads as a fault instead of as "you lack permission".
     *
     * It must also cache NOTHING: memoizing a fault as an answer would make one transient failure
     * deny for the rest of the transaction.
     */
    @isTest
    static void aLookupFaultPropagatesAndCachesNothing() {
        Test.startTest();
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;
        Boolean threw = false;
        try {
            SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
            Assert.fail('A permission-machinery fault must PROPAGATE, not be swallowed as a denial');
        } catch (QueryException e) {
            threw = true;
        }
        Assert.isNull(SellMeterOverridePermissionService.cachedHasOverrideAccess,
            'A thrown fault must leave the cache EMPTY so the next ask re-evaluates');

        Boolean assertThrew = false;
        try {
            SellMeterOverridePermissionService.assertSellMeterOverrideAccess();
            Assert.fail('The assert must propagate the fault too');
        } catch (QueryException e) {
            assertThrew = true;
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(threw, 'hasSellMeterOverrideAccess propagates a machinery fault');
        Assert.isTrue(assertThrew,
            'assertSellMeterOverrideAccess propagates it as a FAULT, not as an '
            + 'AccessDeniedException — a system failure must never be reported to the user as a '
            + 'permissions problem');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────

    /** Assigns a deployed permission set, by API Name, to a user. */
    private static void assignPermissionSet(Id assigneeId, String permissionSetName) {
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = assigneeId, PermissionSetId = permSetId);
    }

    /**
     * Builds (but does not insert) a bare Standard User. User is a setup object whose
     * required-field shape TestDataFactory deliberately does not cover, so this mirrors the helper
     * in DispositionActionPermissionServiceTest.
     *
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildStandardUser(String tag) {
        return buildUserOnProfile('Standard User', tag);
    }

    /**
     * @param profileName the profile to place the user on
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildUserOnProfile(String profileName, String tag) {
        Profile targetProfile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'SellMeterOverride',
            Alias = 'smoperm',
            Email = 'std.smoperm@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = targetProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
