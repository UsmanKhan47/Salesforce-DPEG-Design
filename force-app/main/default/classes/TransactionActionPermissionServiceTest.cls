/**
 * @description Tests TransactionActionPermissionService — the gate behind the Transaction Advance
 * Stage quick action.
 *
 * ── 🔴 FULLY REWRITTEN 2026-08-12, SAME DAY THE PRODUCTION CLASS WAS REWRITTEN ──
 * This class shipped once already on 2026-08-12 as a one-line delegation to
 * `LeadActionPermissionService.hasAnyPermissionSet(Set<String>)`, sharing that class's cache and
 * test seams. The custom-permission migration replaced the delegation with a direct
 * `FeatureManagement.checkPermission('Transaction_Stage_Actions')` call plus a re-implemented
 * Modify All Data bypass — the SAME SHAPE as `OpportunityActionPermissionService` and
 * `DispositionActionPermissionService` now use, each with its OWN cache and its OWN
 * `simulateLookupFailure` seam (see that class's header, "TEST SEAMS NOW LIVE HERE, NOT ON
 * LeadActionPermissionService"). This file is therefore a FULL REWRITE, not a fixture touch-up —
 * every test that used to clear or seed `LeadActionPermissionService`'s cache now does so on
 * `TransactionActionPermissionService` itself, and the whole "delegation properties" section of the
 * old suite (group expansion resolving through the shared engine, the shared-cache benefit) no
 * longer applies: there is no delegation left to prove.
 *
 * ── ⚠ THE MEMBERSHIP *POLICY* IS UNCHANGED — ONLY THE MECHANISM MOVED ────────
 * `Transaction_Stage_Actions` is granted by `Transaction_Stage_Actions_Access`, the SAME layer-4
 * set that was always the gate (see that class's own header for why the custom permission
 * deliberately lives on a layer-4 set here, unlike the two sibling gates). Every DPEG persona still
 * reaches it through `DPEG_Transaction_Team` membership, so
 * `hasTransactionActionAccess_grantedThroughAPermissionSetGroup_returnsTrue` is kept — group
 * expansion for a CUSTOM PERMISSION is a platform guarantee (the platform resolves
 * `FeatureManagement.checkPermission` through group membership itself; there is no group-expansion
 * SOQL left in this class to prove wired), so this test now proves the platform behaviour rather
 * than an Apex expansion step, and is kept for exactly the reason its old header gave: a
 * regression here would deny every real Transactions-team user while every direct-grant test stayed
 * green.
 *
 * ── 🔴 STEP 0 MEASURED (2026-08-12) ───────────────────────────────────────────
 * A throwaway probe (ProbeCustomPermissionTest, deployed and deleted in the same session) confirmed
 * FeatureManagement.checkPermission DOES reflect a PermissionSetAssignment inserted in the SAME
 * test transaction, using the exact fixture shape this suite already used pre-migration (assign
 * before Test.startTest(), check inside System.runAs). No fixture restructuring was required.
 *
 * ── BULK ─────────────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user), with no record collection
 * and no DML — the identical shape the rule exempts for LeadActionPermissionService,
 * OpportunityActionPermissionService and DispositionActionPermissionService. The cost-does-not-scale
 * property is asserted directly via Limits.getQueries().
 *
 * @see force-app/main/default/classes/TransactionActionPermissionService.cls
 * @see force-app/main/default/classes/OpportunityActionPermissionServiceTest.cls (the sibling shape)
 * @author Unit Testing Agent
 */
@isTest
private class TransactionActionPermissionServiceTest {

    private static final String TRANSACTION_ACTION_PERM_SET = 'Transaction_Stage_Actions_Access';
    private static final String LEAD_ACTION_PERM_SET = 'Lead_Stage_Actions_Access';
    private static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    // ─────────────────────────────────────────────────────────────────────────
    // DENIED
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void hasTransactionActionAccess_bareStandardUser_returnsFalse() {
        User bareUser = buildStandardUser('tapsA');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        TransactionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'A user holding neither Transaction_Stage_Actions_Access nor Modify All Data must be denied');
    }

    @isTest
    static void assertTransactionActionAccess_bareStandardUser_throwsWithTheSharedMessage() {
        User bareUser = buildStandardUser('tapsB');
        insert bareUser;

        Test.startTest();
        TransactionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                TransactionActionPermissionService.assertTransactionActionAccess();
                Assert.fail('assertTransactionActionAccess must throw for an unprovisioned user');
            } catch (TransactionActionPermissionService.AccessDeniedException e) {
                Assert.areEqual(NO_PERMISSION_MESSAGE, e.getMessage(),
                    'The thrown message must be the shared wording — NO_PERMISSION_MESSAGE is '
                    + 'REUSED from OpportunityActionPermissionService rather than re-declared, so '
                    + 'a user can never see two phrasings for one condition across the Lead, '
                    + 'Opportunity, Disposition and Transaction gates');
            }
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();
    }

    /**
     * A grant to a DIFFERENT user must not leak — the same regression this pattern guards against
     * in the sibling gates.
     */
    @isTest
    static void hasTransactionActionAccess_anotherUserHoldsTheGrant_stillDeniesTheRunningUser() {
        User grantedUser = buildStandardUser('tapsC');
        User bareUser = buildStandardUser('tapsD');
        insert new List<User>{ grantedUser, bareUser };
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);

        Test.startTest();
        Boolean allowed;
        TransactionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Another user holding Transaction_Stage_Actions_Access must not grant access to the '
            + 'running user');
    }

    /**
     * 🔴 A DIFFERENT PERMISSION SET NAME MUST NOT GRANT — the boundary-separation test for this
     * gate. `Lead_Stage_Actions_Access` is a real, deployed capability set in this org; holding it
     * proves nothing about Transaction access, because the custom permission this gate checks is
     * carried by `Transaction_Stage_Actions_Access` alone.
     */
    @isTest
    static void hasTransactionActionAccess_holderOfADifferentPermissionSet_isStillDenied() {
        User leadHolder = buildStandardUser('tapsE');
        insert leadHolder;
        assignPermissionSet(leadHolder.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        Boolean allowed;
        TransactionActionPermissionService.clearCache();
        System.runAs(leadHolder) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Holding Lead_Stage_Actions_Access must not grant the Transaction stage action — the '
            + 'two gates are backed by different permission sets and different custom permissions '
            + 'and must not cross-grant');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GRANTED
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void hasTransactionActionAccess_directGrant_returnsTrue() {
        User grantedUser = buildStandardUser('tapsF');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);

        Test.startTest();
        Boolean allowed;
        TransactionActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(allowed,
            'A user holding Transaction_Stage_Actions_Access DIRECTLY — which now carries the '
            + 'Transaction_Stage_Actions custom permission — must be granted access');
    }

    @isTest
    static void assertTransactionActionAccess_directGrant_doesNotThrow() {
        User grantedUser = buildStandardUser('tapsG');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);

        Test.startTest();
        TransactionActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            TransactionActionPermissionService.assertTransactionActionAccess(); // must not throw
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(true, 'assertTransactionActionAccess returns silently for a permitted user');
    }

    /**
     * 🔴 THE MOST IMPORTANT TEST IN THIS CLASS, UNCHANGED IN INTENT ACROSS THE REWRITE. Every DPEG
     * persona is provisioned through a PermissionSetGroup — `Transaction_Stage_Actions_Access` is a
     * member of `DPEG_Transaction_Team`, not a direct assignment on any user. A user's own
     * PermissionSetAssignment row therefore names the GROUP, never the member set.
     *
     * ⚠ WHAT CHANGED IS WHAT THIS TEST PROVES, NOT WHETHER IT IS NEEDED. Pre-migration it proved
     * that `LeadActionPermissionService`'s own group-expansion SOQL (via
     * PermissionSetGroupComponentSelector) resolved a group-carried grant. There is no Apex group
     * expansion left to exercise: FeatureManagement.checkPermission resolves group membership
     * itself, as a platform guarantee. This test is kept because that guarantee is exactly what a
     * regression to a naive "does the assignment row literally name this set" check would violate —
     * it would deny every real Transactions-team user while every direct-grant test above stayed
     * green.
     */
    @isTest
    static void hasTransactionActionAccess_grantedThroughAPermissionSetGroup_returnsTrue() {
        // Arrange — a group whose only member is the Transaction set, assigned to a bare user.
        User groupUser = buildStandardUser('tapsH');
        insert groupUser;
        Id transactionPermSetId =
            [SELECT Id FROM PermissionSet WHERE Name = :TRANSACTION_ACTION_PERM_SET LIMIT 1].Id;
        PermissionSetGroup psGroup = new PermissionSetGroup(
            DeveloperName = 'TapsGroup' + String.valueOf(Datetime.now().getTime()),
            MasterLabel = 'TAPS Test Group'
        );
        insert psGroup;
        insert new PermissionSetGroupComponent(
            PermissionSetGroupId = psGroup.Id,
            PermissionSetId = transactionPermSetId
        );
        // A freshly built group sits in an "Updating" status; assignment requires a recalculation,
        // which Test.calculatePermissionSetGroup performs synchronously in a test context.
        Test.calculatePermissionSetGroup(psGroup.Id);
        insert new PermissionSetAssignment(
            AssigneeId = groupUser.Id,
            PermissionSetGroupId = psGroup.Id
        );

        // Act
        Test.startTest();
        Boolean allowed;
        TransactionActionPermissionService.clearCache();
        System.runAs(groupUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        // Assert
        Assert.isTrue(allowed,
            'A user granted Transaction_Stage_Actions_Access through a PERMISSION SET GROUP must be '
            + 'allowed — this is the exact production shape: DPEG_Transaction_Team composes '
            + 'Transaction_Stage_Actions_Access as a member, so a check that only recognised a '
            + 'direct assignment would deny every real Transactions-team user while every other '
            + 'test in this class stayed silent about it.');
    }

    /**
     * The admin bypass. The user is on the System Administrator profile (which carries Modify All
     * Data) and is deliberately assigned NO permission set at all, so a `true` result can ONLY have
     * come from the Modify All Data branch — asserted as a precondition rather than assumed.
     * (A fabricated PermissionsModifyAllData=true PermissionSet is rejected by the platform —
     * FIELD_INTEGRITY_EXCEPTION, ~35 dependent permissions — so the real profile is used instead,
     * same technique as the sibling gates.)
     */
    @isTest
    static void hasTransactionActionAccess_administrator_isAllowedWithoutThePermissionSet() {
        User adminUser = buildUserOnProfile('System Administrator', 'tapsI');
        insert adminUser;

        Test.startTest();
        Boolean allowed;
        Set<String> heldSetNames = new Set<String>();
        TransactionActionPermissionService.clearCache();
        System.runAs(adminUser) {
            for (PermissionSetAssignment row : PermissionSetAssignmentSelector.selectForCurrentUser()) {
                if (row.PermissionSet != null) {
                    heldSetNames.add(row.PermissionSet.Name);
                }
            }
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        // Precondition — without this, a passing assertion below could be a name match in disguise.
        Assert.isFalse(heldSetNames.contains(TRANSACTION_ACTION_PERM_SET),
            'The admin must hold NO Transaction_Stage_Actions_Access, otherwise this test would not '
            + 'isolate the Modify All Data bypass');

        Assert.isTrue(allowed,
            'A Modify All Data holder is allowed even with no Transaction permission set — denying '
            + 'an admin a button they can already action through the standard UI would be theatre, '
            + 'not security');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CACHING + FAILURE MODE (new in the rewrite — this class now owns both, mirroring the siblings)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 A holder pays ZERO queries. FeatureManagement.checkPermission costs 0 SOQL, and this gate
     * never had the admin-lockout hazard that forced the two sibling gates' bypass to run first
     * pre-migration (there was never a `User` field in its path) — so, unlike the siblings, its
     * check-first order was never a correctness change, only a cost one. The measurable result is
     * identical: a holder never reaches the bypass read.
     */
    @isTest
    static void hasTransactionActionAccess_repeatedCallsByAHolder_costZeroQueries() {
        User grantedUser = buildStandardUser('tapsJ');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);

        Test.startTest();
        Integer used;
        TransactionActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            Integer before = Limits.getQueries();
            TransactionActionPermissionService.hasTransactionActionAccess();
            TransactionActionPermissionService.hasTransactionActionAccess();
            TransactionActionPermissionService.hasTransactionActionAccess();
            used = Limits.getQueries() - before;
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.areEqual(0, used,
            'A Transaction_Stage_Actions holder must pay ZERO queries across repeated asks in one '
            + 'transaction. Actual: ' + used);
    }

    /** A non-holder still pays at most one query (the bypass read), memoized across repeated asks. */
    @isTest
    static void hasTransactionActionAccess_repeatedCallsByANonHolder_costAtMostOneQuery() {
        User bareUser = buildStandardUser('tapsK');
        insert bareUser;

        Test.startTest();
        Integer used;
        TransactionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            Integer before = Limits.getQueries();
            TransactionActionPermissionService.hasTransactionActionAccess();
            TransactionActionPermissionService.hasTransactionActionAccess();
            used = Limits.getQueries() - before;
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(used <= 1,
            'A non-holder must pay at most ONE query (the Modify All Data bypass read), memoized for '
            + 'every subsequent ask. Actual: ' + used);
    }

    @isTest
    static void clearCache_afterAUserSwitch_recomputesForTheNewUser() {
        User bareUser = buildStandardUser('tapsL');
        insert bareUser;
        User grantedUser = buildStandardUser('tapsM');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);

        Test.startTest();
        Boolean bareResult;
        Boolean grantedResult;
        TransactionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            bareResult = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            grantedResult = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(bareResult, 'The unprovisioned user is denied');
        Assert.isTrue(grantedResult,
            'After clearCache the second user must be re-evaluated on their OWN grants. A cache '
            + 'that survived the switch would answer the first user\'s question for the second.');
    }

    /**
     * 🔴 THE NEW TEST SEAM. Pre-migration this class held no state of its own and reached the fault
     * branch through `LeadActionPermissionService.simulateLoadFailure`. It now owns
     * `simulateLookupFailure` directly, exactly like the two sibling gates — this is the only
     * deterministic way to reach the permission-machinery fault branch, since every user can read
     * their own PermissionSetAssignment rows.
     */
    @isTest
    static void aLookupFaultPropagatesAndCachesNothing() {
        Test.startTest();
        TransactionActionPermissionService.clearCache();
        TransactionActionPermissionService.simulateLookupFailure = true;
        Boolean threw = false;
        try {
            TransactionActionPermissionService.hasTransactionActionAccess();
            Assert.fail('A permission-machinery fault must PROPAGATE, not be swallowed as a denial');
        } catch (QueryException e) {
            threw = true;
        }
        Assert.isNull(TransactionActionPermissionService.cachedHasTransactionActionAccess,
            'A thrown fault must leave the cache EMPTY so the next ask re-evaluates');

        Boolean assertThrew = false;
        try {
            TransactionActionPermissionService.assertTransactionActionAccess();
            Assert.fail('The assert must propagate the fault too');
        } catch (QueryException e) {
            assertThrew = true;
        }
        TransactionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(threw, 'hasTransactionActionAccess propagates a machinery fault');
        Assert.isTrue(assertThrew,
            'assertTransactionActionAccess propagates it as a FAULT, not as an AccessDeniedException '
            + '— a system failure must never be reported to the user as a permissions problem');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WORDING
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * NO_PERMISSION_MESSAGE is REUSED from OpportunityActionPermissionService, not re-declared —
     * the class header states this explicitly. This test pins the reuse itself: if a future edit
     * re-declares the constant with even a punctuation difference, this is the test that catches it,
     * independent of what any single denial test's literal string happens to say.
     */
    @isTest
    static void noPermissionMessage_isTheSameConstantAsTheOpportunityGate() {
        Assert.areEqual(
            OpportunityActionPermissionService.NO_PERMISSION_MESSAGE,
            TransactionActionPermissionService.NO_PERMISSION_MESSAGE,
            'TransactionActionPermissionService.NO_PERMISSION_MESSAGE must be the identical string '
            + 'as OpportunityActionPermissionService.NO_PERMISSION_MESSAGE (reused, not '
            + 're-declared) so the Lead, Opportunity, Disposition and Transaction gates can never '
            + 'diverge in wording for the same condition');
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
     * Builds (but does not insert) a bare Standard User.
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildStandardUser(String tag) {
        return buildUserOnProfile('Standard User', tag);
    }

    /**
     * @param profileName the profile to place the user on ('Standard User' for a bare user,
     *                    'System Administrator' for the Modify All Data bypass case)
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildUserOnProfile(String profileName, String tag) {
        Profile targetProfile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'TxnPerm',
            Alias = 'tperm',
            Email = 'std.txnperm@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = targetProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
