/**
 * @description Tests TransactionActionPermissionService — the MEMBERSHIP-ONLY gate behind the
 * Transaction Advance Stage quick action (added 2026-08-12, live UI testing fix set).
 *
 * ── 🔴 THIS CLASS IS NOT SHAPED LIKE OpportunityActionPermissionServiceTest /
 *    DispositionActionPermissionServiceTest, AND THAT IS DELIBERATE ────────────
 * Those two gate TWO factors (permission-set-granted FLS on a `User.*_Driver__c` checkbox, AND the
 * checkbox itself). TransactionActionPermissionService gates exactly ONE factor: membership of
 * `Transaction_Stage_Actions_Access`, mirroring `LeadActionPermissionService.hasLeadActionAccess()`.
 * It is implemented as a one-line delegation to
 * `LeadActionPermissionService.hasAnyPermissionSet(Set<String>)`, so the properties worth pinning
 * here are the DELEGATION properties, not a re-proof of membership logic that
 * `LeadActionPermissionServiceTest` already covers exhaustively:
 *   1. GROUP EXPANSION resolves — every DPEG persona is provisioned through a
 *      PermissionSetGroup (`Transaction_Stage_Actions_Access` was added to `DPEG_Transaction_Team`),
 *      so a bare direct-assignment-only check would deny every real Transactions-team user.
 *   2. "Modify All Data" bypasses, inherited from the shared engine.
 *   3. A user with NEITHER is denied, and a grant to a DIFFERENT user or a DIFFERENT permission set
 *      name never leaks across.
 *   4. The shared transaction-scoped cache in LeadActionPermissionService means this gate costs NO
 *      additional queries once another feature (or this one) has already asked in the same
 *      transaction — the whole point of reusing hasAnyPermissionSet rather than copying it.
 *
 * ── ⚠ TEST SEAMS LIVE ON LeadActionPermissionService, NOT HERE ──────────────────
 * `clearCache()` and `simulateLoadFailure` are declared on LeadActionPermissionService (this class
 * re-declares neither, per its own class header) — every runAs block below clears THAT class's
 * cache, never a (nonexistent) cache on TransactionActionPermissionService itself.
 *
 * ── BULK ─────────────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. This is a
 * per-transaction-singleton question about ONE user (the running user), with no record collection
 * and no DML — the identical shape the rule exempts for LeadActionPermissionService,
 * OpportunityActionPermissionService and DispositionActionPermissionService. There is no record
 * collection at this layer to bulk-test; the cost-does-not-scale property is asserted directly via
 * Limits.getQueries() in delegatesToLeadActionPermissionService_cacheIsSharedAcrossFeatures.
 *
 * @see force-app/main/default/classes/TransactionActionPermissionService.cls
 * @see force-app/main/default/classes/LeadActionPermissionService.cls (the shared engine)
 * @see force-app/main/default/classes/LeadActionPermissionServiceTest.cls (the membership-logic proof)
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
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'A user holding neither Transaction_Stage_Actions_Access nor Modify All Data must be denied');
    }

    @isTest
    static void assertTransactionActionAccess_bareStandardUser_throwsWithTheSharedMessage() {
        User bareUser = buildStandardUser('tapsB');
        insert bareUser;

        Test.startTest();
        LeadActionPermissionService.clearCache();
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
        LeadActionPermissionService.clearCache();
        Test.stopTest();
    }

    /**
     * A grant to a DIFFERENT user must not leak — the same regression this pattern guards against
     * in LeadActionPermissionServiceTest, worth re-proving here because
     * TRANSACTION_ACTION_PERMISSION_SETS is this class's own constant, not a shared one.
     */
    @isTest
    static void hasTransactionActionAccess_anotherUserHoldsTheGrant_stillDeniesTheRunningUser() {
        User grantedUser = buildStandardUser('tapsC');
        User bareUser = buildStandardUser('tapsD');
        insert new List<User>{ grantedUser, bareUser };
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Another user holding Transaction_Stage_Actions_Access must not grant access to the '
            + 'running user');
    }

    /**
     * 🔴 A DIFFERENT PERMISSION SET NAME MUST NOT GRANT — the boundary-separation test for this
     * gate. `Lead_Stage_Actions_Access` is a real, deployed capability set in this org; holding it
     * proves nothing about Transaction access, because TRANSACTION_ACTION_PERMISSION_SETS names
     * exactly one set and hasAnyPermissionSet only matches on that exact collection.
     */
    @isTest
    static void hasTransactionActionAccess_holderOfADifferentPermissionSet_isStillDenied() {
        User leadHolder = buildStandardUser('tapsE');
        insert leadHolder;
        assignPermissionSet(leadHolder.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(leadHolder) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Holding Lead_Stage_Actions_Access must not grant the Transaction stage action — the '
            + 'two gates name different permission sets and must not cross-grant');
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
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(allowed,
            'A user holding Transaction_Stage_Actions_Access DIRECTLY must be granted access');
    }

    @isTest
    static void assertTransactionActionAccess_directGrant_doesNotThrow() {
        User grantedUser = buildStandardUser('tapsG');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);

        Test.startTest();
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            TransactionActionPermissionService.assertTransactionActionAccess(); // must not throw
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(true, 'assertTransactionActionAccess returns silently for a permitted user');
    }

    /**
     * 🔴 THE MOST IMPORTANT TEST IN THIS CLASS. Every DPEG persona is provisioned through a
     * PermissionSetGroup — `Transaction_Stage_Actions_Access` was added to `DPEG_Transaction_Team`
     * as a GROUP MEMBER, not as a direct assignment on any user. A user's own
     * PermissionSetAssignment row therefore names the GROUP, never the member set, so a
     * direct-assignment-only check would deny every real Transactions-team user in production while
     * every test using a direct grant (the tests above) stayed green. This is the scenario that
     * would catch that regression.
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
        LeadActionPermissionService.clearCache();
        System.runAs(groupUser) {
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        // Assert
        Assert.isTrue(allowed,
            'A user granted Transaction_Stage_Actions_Access through a PERMISSION SET GROUP must be '
            + 'allowed — their assignment row names the group, so this only passes if group '
            + 'expansion runs. This is the exact production shape: DPEG_Transaction_Team composes '
            + 'Transaction_Stage_Actions_Access as a member, so a bare direct-assignment check would '
            + 'deny every real Transactions-team user while this test alone stayed silent about it.');
    }

    /**
     * The documented admin bypass. The user is on the System Administrator profile (which carries
     * Modify All Data) and is deliberately assigned NO permission set at all, so a `true` result can
     * ONLY have come from the Modify All Data branch — the test asserts that precondition rather
     * than assuming it. Same technique as LeadActionPermissionServiceTest
     * .hasLeadActionAccess_administrator_isAllowedWithoutAnyLeadPermissionSet, and for the identical
     * reason: fabricating a PermissionsModifyAllData=true PermissionSet is rejected by the platform
     * (FIELD_INTEGRITY_EXCEPTION, ~35 dependent permissions), so the real profile is used instead.
     */
    @isTest
    static void hasTransactionActionAccess_administrator_isAllowedWithoutThePermissionSet() {
        User adminUser = buildUserOnProfile('System Administrator', 'tapsI');
        insert adminUser;

        Test.startTest();
        Boolean allowed;
        Set<String> heldSetNames = new Set<String>();
        LeadActionPermissionService.clearCache();
        System.runAs(adminUser) {
            for (PermissionSetAssignment row : PermissionSetAssignmentSelector.selectForCurrentUser()) {
                if (row.PermissionSet != null) {
                    heldSetNames.add(row.PermissionSet.Name);
                }
            }
            allowed = TransactionActionPermissionService.hasTransactionActionAccess();
        }
        LeadActionPermissionService.clearCache();
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
    // DELEGATION PROPERTIES
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * NO_PERMISSION_MESSAGE is REUSED from OpportunityActionPermissionService, not re-declared —
     * the class header states this explicitly ("so a future edit to the wording cannot leave four
     * features speaking with two voices"). This test pins the reuse itself: if a future edit
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

    /**
     * 🔴 THE CACHE-SHARING BENEFIT OF DELEGATING RATHER THAN COPYING. Because
     * TransactionActionPermissionService calls the SAME LeadActionPermissionService cache as the
     * Lead gate, asking both questions in one transaction must cost the assignment-read queries only
     * ONCE — not once per feature. A hand-rolled copy of the membership logic here would create a
     * SECOND cache that could disagree with the first about the very same user, which is exactly the
     * defect this class's header calls out under "why it delegates rather than copying".
     */
    @isTest
    static void delegatesToLeadActionPermissionService_cacheIsSharedAcrossFeatures() {
        User grantedUser = buildStandardUser('tapsJ');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, TRANSACTION_ACTION_PERM_SET);
        assignPermissionSet(grantedUser.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        Integer queriesUsed;
        Boolean transactionAllowed;
        Boolean leadAllowed;
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            Integer before = Limits.getQueries();
            // The Lead gate asks first, populating the shared cache; the Transaction gate must be
            // served from it rather than re-querying.
            leadAllowed = LeadActionPermissionService.hasLeadActionAccess();
            transactionAllowed = TransactionActionPermissionService.hasTransactionActionAccess();
            queriesUsed = Limits.getQueries() - before;
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(leadAllowed, 'PRECONDITION: the user must hold the Lead permission set');
        Assert.isTrue(transactionAllowed, 'PRECONDITION: the user must hold the Transaction permission set');
        Assert.isTrue(queriesUsed <= 2,
            'Two features asking a permission question in one transaction must cost at most the two '
            + 'initial LeadActionPermissionService selector reads (assignments + group expansion), '
            + 'not two per feature. Actual: ' + queriesUsed);
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
