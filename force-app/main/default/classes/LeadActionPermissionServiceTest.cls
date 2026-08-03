/**
 * Tests LeadActionPermissionService — the permission gate behind the four Lead stage quick actions.
 *
 * This is a SECURITY class, so the suite is weighted toward the negative cases: the tests that
 * matter most are the ones proving a user is DENIED, and proving that a denial is never produced by
 * accident (e.g. by a name that merely looks similar, or by another user's grant).
 *
 * Every scenario runs under System.runAs with a purpose-built user, because "the running user" is
 * the entire input to this class. The transaction cache is cleared before each impersonation —
 * without that, a user switch inside one transaction would silently inherit the previous user's
 * grants and every assertion after the first would be meaningless.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST ──────────────────────────────────────
 * Per .claude/rules/bulk-test-rule.md the 251-record mandate applies to triggers, batches and
 * service methods that perform DML over a record collection. This service performs NO DML and asks
 * a per-transaction-singleton question about ONE user (the running user); `hasAnyPermissionSet`
 * takes a Set of NAMES, not records, and its cost is two queries regardless of the Set's size. A
 * 251-name test would exercise no additional code path. The property the rule actually protects —
 * that cost does not scale with input — is asserted directly via Limits.getQueries().
 *
 * ── SETUP-DML ISOLATION ───────────────────────────────────────────────────────
 * Every object touched here (User, PermissionSet, PermissionSetGroup, PermissionSetGroupComponent,
 * PermissionSetAssignment) is a SETUP object. No test creates a non-setup record, which is what
 * keeps MIXED_DML_OPERATION off the table.
 *
 * @see force-app/main/default/classes/LeadActionPermissionService.cls
 */
@isTest
private class LeadActionPermissionServiceTest {

    private static final String LEAD_ACTION_PERM_SET = 'Lead_Stage_Actions_Access';
    private static final String BROKER_PERM_SET = 'Broker_Protection_Access';
    private static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    // ─────────────────────────────────────────────────────────────────────────
    // DENIED — the cases that make this class worth having
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void hasLeadActionAccess_bareStandardUser_returnsFalse() {
        User bareUser = buildStandardUser('lapsA');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = LeadActionPermissionService.hasLeadActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'A Standard User holding neither Lead permission set and no Modify All Data must be denied');
    }

    @isTest
    static void assertLeadActionAccess_bareStandardUser_throwsWithTheUserFacingMessage() {
        User bareUser = buildStandardUser('lapsB');
        insert bareUser;

        Test.startTest();
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                LeadActionPermissionService.assertLeadActionAccess();
                Assert.fail('assertLeadActionAccess must throw for a user without the permission sets');
            } catch (LeadActionPermissionService.AccessDeniedException e) {
                Assert.areEqual(NO_PERMISSION_MESSAGE, e.getMessage(),
                    'The thrown message is shown verbatim to the user — it must be the agreed wording, '
                    + 'identical to the one the LWC shows for the client-side denial');
            }
        }
        Test.stopTest();
    }

    /**
     * A grant to a DIFFERENT user must not leak. This is the assertion that would catch a selector
     * regression dropping the AssigneeId filter — the single worst failure this feature could have.
     */
    @isTest
    static void hasLeadActionAccess_anotherUserHoldsTheGrant_stillDeniesTheRunningUser() {
        User grantedUser = buildStandardUser('lapsC');
        User bareUser = buildStandardUser('lapsD');
        insert new List<User>{ grantedUser, bareUser };
        assignPermissionSet(grantedUser.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = LeadActionPermissionService.hasLeadActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'Another user holding Lead_Stage_Actions_Access must not grant access to the running user');
    }

    @isTest
    static void hasAnyPermissionSet_unrelatedName_returnsFalseForANonAdmin() {
        User bareUser = buildStandardUser('lapsE');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = LeadActionPermissionService.hasAnyPermissionSet(
                new Set<String>{ 'A_Permission_Set_That_Does_Not_Exist' }
            );
        }
        Test.stopTest();

        Assert.isFalse(allowed, 'An unmatched permission set name must never grant access');
    }

    @isTest
    static void hasAnyPermissionSet_nullOrEmptyNames_returnsFalse() {
        Test.startTest();
        Boolean nullResult = LeadActionPermissionService.hasAnyPermissionSet(null);
        Boolean emptyResult = LeadActionPermissionService.hasAnyPermissionSet(new Set<String>());
        Test.stopTest();

        Assert.isFalse(nullResult,
            'A null requirement is not a grant — an empty ask must never resolve to "allowed", even for an admin');
        Assert.isFalse(emptyResult, 'An empty requirement is not a grant');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GRANTED
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void hasLeadActionAccess_standardUserWithLeadSet_returnsTrue() {
        User grantedUser = buildStandardUser('lapsF');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            allowed = LeadActionPermissionService.hasLeadActionAccess();
        }
        Test.stopTest();

        Assert.isTrue(allowed, 'Lead_Stage_Actions_Access is the primary gate and must grant access');
    }

    @isTest
    static void hasLeadActionAccess_standardUserWithBrokerProtectionSet_returnsTrue() {
        User grantedUser = buildStandardUser('lapsG');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, BROKER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            allowed = LeadActionPermissionService.hasLeadActionAccess();
        }
        Test.stopTest();

        Assert.isTrue(allowed,
            'Broker_Protection_Access is the second accepted set — its operators triage the Leads this pipeline creates');
    }

    @isTest
    static void assertLeadActionAccess_permittedUser_doesNotThrow() {
        User grantedUser = buildStandardUser('lapsH');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            LeadActionPermissionService.assertLeadActionAccess();   // must not throw
        }
        Test.stopTest();

        Assert.isTrue(true, 'assertLeadActionAccess returns silently for a permitted user');
    }

    /**
     * The group path. This is the scenario a name-only check would silently get WRONG: the user's
     * assignment row names the GROUP, not the member set, so without PermissionSetGroupComponent
     * expansion a correctly-provisioned user would be locked out. The org provisions its personas
     * through groups, so this is the realistic production shape.
     */
    @isTest
    static void hasLeadActionAccess_setGrantedThroughAPermissionSetGroup_returnsTrue() {
        // Arrange — a group whose only member is the Lead set, assigned to a bare Standard User.
        User groupUser = buildStandardUser('lapsI');
        insert groupUser;
        Id leadPermSetId = [SELECT Id FROM PermissionSet WHERE Name = :LEAD_ACTION_PERM_SET LIMIT 1].Id;
        PermissionSetGroup psGroup = new PermissionSetGroup(
            DeveloperName = 'LapsGroup' + String.valueOf(Datetime.now().getTime()),
            MasterLabel = 'LAPS Test Group'
        );
        insert psGroup;
        insert new PermissionSetGroupComponent(
            PermissionSetGroupId = psGroup.Id,
            PermissionSetId = leadPermSetId
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
            allowed = LeadActionPermissionService.hasLeadActionAccess();
        }
        Test.stopTest();

        // Assert
        Assert.isTrue(allowed,
            'A user granted Lead_Stage_Actions_Access through a PERMISSION SET GROUP must be allowed — '
            + 'their assignment row names the group, so this only passes if group expansion runs');
    }

    /**
     * The documented admin bypass. The user is on the System Administrator profile (which carries
     * Modify All Data) and is deliberately assigned NO permission set at all, so a `true` result can
     * ONLY have come from the Modify All Data branch — the test asserts that precondition rather
     * than assuming it.
     *
     * A fabricated PermissionSet with PermissionsModifyAllData = true was tried first and rejected
     * by the platform: FIELD_INTEGRITY_EXCEPTION, "Permission ModifyAllData depends on
     * permission(s): AssignTopics, ConvertLeads, ..." — roughly 35 dependencies that would have to
     * be enumerated and kept in step with the org's edition. Using the profile that already holds
     * the permission is both simpler and closer to how a real administrator is provisioned.
     */
    @isTest
    static void hasLeadActionAccess_administrator_isAllowedWithoutAnyLeadPermissionSet() {
        User adminUser = buildUserOnProfile('System Administrator', 'lapsJ');
        insert adminUser;

        Test.startTest();
        Boolean allowed;
        Set<String> heldSetNames = new Set<String>();
        LeadActionPermissionService.clearCache();
        System.runAs(adminUser) {
            for (PermissionSetAssignment row : PermissionSetAssignmentSelector.selectForCurrentUser()) {
                heldSetNames.add(row.PermissionSet.Name);
            }
            allowed = LeadActionPermissionService.hasLeadActionAccess();
        }
        Test.stopTest();

        // Precondition — without this, a passing assertion below could be a name match in disguise.
        Assert.isFalse(heldSetNames.contains(LEAD_ACTION_PERM_SET),
            'The admin must hold NO Lead permission set, otherwise this test would not isolate the bypass');
        Assert.isFalse(heldSetNames.contains(BROKER_PERM_SET),
            'The admin must hold NO Broker permission set, otherwise this test would not isolate the bypass');

        Assert.isTrue(allowed,
            'A Modify All Data holder is allowed even with no Lead permission set — denying an admin a button '
            + 'they can already action through the standard UI would be theatre, not security');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CACHING + FAILURE MODE
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void hasAnyPermissionSet_repeatedCalls_readsTheAssignmentsOnlyOnce() {
        User grantedUser = buildStandardUser('lapsK');
        insert grantedUser;
        assignPermissionSet(grantedUser.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        LeadActionPermissionService.clearCache();
        Integer queriesUsed;
        System.runAs(grantedUser) {
            Integer before = Limits.getQueries();
            // Four buttons on one Lead page can each ask; the reads must not be repeated per ask.
            LeadActionPermissionService.hasLeadActionAccess();
            LeadActionPermissionService.hasLeadActionAccess();
            LeadActionPermissionService.hasLeadActionAccess();
            LeadActionPermissionService.hasLeadActionAccess();
            queriesUsed = Limits.getQueries() - before;
        }
        Test.stopTest();

        Assert.isTrue(queriesUsed <= 2,
            'Four permission asks must cost at most the two initial selector reads (assignments + group expansion), '
            + 'not two per ask. Actual: ' + queriesUsed);
    }

    @isTest
    static void clearCache_afterAUserSwitch_recomputesForTheNewUser() {
        User grantedUser = buildStandardUser('lapsL');
        User bareUser = buildStandardUser('lapsM');
        insert new List<User>{ grantedUser, bareUser };
        assignPermissionSet(grantedUser.Id, LEAD_ACTION_PERM_SET);

        Test.startTest();
        Boolean grantedResult;
        Boolean bareResult;
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            grantedResult = LeadActionPermissionService.hasLeadActionAccess();
        }
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            bareResult = LeadActionPermissionService.hasLeadActionAccess();
        }
        Test.stopTest();

        Assert.isTrue(grantedResult, 'The granted user is allowed');
        Assert.isFalse(bareResult,
            'After clearCache the second user is evaluated on their OWN grants — a stale cache here would '
            + 'hand one user another user\'s permissions');
    }

    /**
     * Reaches the load failure path via the documented test seam. Its real-world trigger is a
     * setup-object access failure under WITH USER_MODE, which cannot be provoked deterministically
     * (PermissionSetAssignment is readable by every user for their own rows). What matters is that
     * the failure PROPAGATES rather than being swallowed into a false "allowed".
     */
    @isTest
    static void hasLeadActionAccess_whenTheLookupFails_propagatesInsteadOfSilentlyAllowing() {
        Test.startTest();
        LeadActionPermissionService.clearCache();
        LeadActionPermissionService.simulateLoadFailure = true;
        Boolean threw = false;
        try {
            LeadActionPermissionService.hasLeadActionAccess();
        } catch (Exception e) {
            threw = true;
        }
        LeadActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(threw,
            'A failed permission lookup must PROPAGATE (the controller then fails closed) — swallowing it '
            + 'into a default answer is how a security gate silently becomes a no-op');
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
     * Builds (but does not insert) a bare Standard User. Mirrors the repo's existing helper in
     * ContactSelectorTest / OpportunitySelectorTest.
     *
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildStandardUser(String tag) {
        return buildUserOnProfile('Standard User', tag);
    }

    /**
     * Builds (but does not insert) a user on a named profile.
     *
     * @param profileName the profile to place the user on ('Standard User' for a bare user,
     *                    'System Administrator' for the Modify All Data bypass case)
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    /**
     * ⚠ REGRESSION PIN FOR THE 2026-08-03 PRODUCTION INCIDENT. This is the exact live shape that
     * broke: a non-admin on the MINIMUM ACCESS profile, holding a qualifying permission set
     * DIRECTLY, who is ALSO assigned an unrelated permission set GROUP. Clicking Convert produced
     * "Unable to verify your permissions" — the controller's catch-all — because BOTH selectors ran
     * `WITH USER_MODE` and BOTH throw for that profile (measured: the assignment read throws too,
     * even though it reads only the user's own rows).
     *
     * ⚠ THE PROFILE IS THE WHOLE POINT — DO NOT "SIMPLIFY" THIS TO buildStandardUser. Standard User
     * can read both setup entities and passes under either mode, so a Standard-User version of this
     * test is GREEN EVEN WITH THE BUG PRESENT. That false assurance is precisely why the defect
     * reached production: every existing runAs proof in this class uses Standard User.
     *
     * The group is deliberately unrelated to the qualifying sets, mirroring production (neither
     * qualifying set is a group member today) — so this proves the fix, not a lucky group expansion.
     */
    @isTest
    static void hasLeadActionAccess_minimumAccessUserWithDirectSetAndAGroup_returnsTrueWithoutThrowing() {
        // Arrange — Junior's shape.
        User juniorLike = buildUserOnProfile('Minimum Access - Salesforce', 'lapsMin');
        insert juniorLike;

        Id leadPermSetId = [SELECT Id FROM PermissionSet WHERE Name = :LEAD_ACTION_PERM_SET LIMIT 1].Id;

        // An unrelated group, exactly as DPEG_Junior_Analyst_PSG is unrelated to the qualifying sets.
        PermissionSet unrelated = new PermissionSet(
            Name = 'Laps_Unrelated_' + String.valueOf(Math.abs(Crypto.getRandomInteger())),
            Label = 'LAPS Unrelated Set'
        );
        insert unrelated;
        PermissionSetGroup psGroup = new PermissionSetGroup(
            DeveloperName = 'LapsMinGroup' + String.valueOf(Datetime.now().getTime()).right(9),
            MasterLabel = 'LAPS Min Access Group'
        );
        insert psGroup;
        insert new PermissionSetGroupComponent(
            PermissionSetGroupId = psGroup.Id,
            PermissionSetId = unrelated.Id
        );
        Test.calculatePermissionSetGroup(psGroup.Id);

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = juniorLike.Id, PermissionSetId = leadPermSetId),
            new PermissionSetAssignment(AssigneeId = juniorLike.Id, PermissionSetGroupId = psGroup.Id)
        };

        // Act
        Test.startTest();
        Boolean allowed;
        String thrown = null;
        LeadActionPermissionService.clearCache();
        System.runAs(juniorLike) {
            try {
                allowed = LeadActionPermissionService.hasLeadActionAccess();
            } catch (Exception e) {
                thrown = e.getTypeName() + ': ' + e.getMessage();
            }
        }
        Test.stopTest();

        // Assert — no throw is half the contract; the RIGHT ANSWER is the other half.
        Assert.isNull(thrown,
            'The permission check must not THROW for a Minimum Access user. A throw here reproduces the '
            + '2026-08-03 incident, where it surfaced as "Unable to verify your permissions". Observed: ' + thrown);
        Assert.isTrue(allowed,
            'A Minimum Access user holding ' + LEAD_ACTION_PERM_SET + ' DIRECTLY must be granted access, '
            + 'even while also assigned an unrelated permission set group');
    }

    private static User buildUserOnProfile(String profileName, String tag) {
        Profile targetProfile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'LeadPerm',
            Alias = 'lperm',
            Email = 'std.leadperm@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = targetProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
