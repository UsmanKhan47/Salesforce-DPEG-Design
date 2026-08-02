/**
 * Tests UserSelector — the running user's `Deal_Driver__c` read behind the Opportunity stage
 * quick-action gate.
 *
 * The behaviour worth testing here is NOT "does a SELECT return a row". It is the FLS boundary:
 * `WITH USER_MODE` is half of a two-factor authorization gate, so the tests that matter are the ones
 * proving the query THROWS for a user without FLS read on `User.Deal_Driver__c` and SUCCEEDS for one
 * with it. If someone deletes `WITH USER_MODE` "because the query works fine without it", the
 * throwsForAUserWithoutFieldLevelAccess test is what fails.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST ──────────────────────────────────────
 * Per .claude/rules/bulk-test-rule.md the 251-record mandate applies to triggers, batches and
 * service methods performing DML across a record collection. This selector runs ONE query for ONE
 * user (the running user, by hard-filtered Id), performs no DML, and offers no collection-shaped
 * method to bulk-test — deliberately, since a `Set<Id>` variant would let a user read other users'
 * deal-driver status. It is the same per-transaction-singleton shape the rule exempts.
 *
 * ── SETUP-DML ISOLATION ───────────────────────────────────────────────────────
 * Only setup objects are touched (User, PermissionSet, PermissionSetAssignment), so
 * MIXED_DML_OPERATION cannot arise. Test setup writes `Deal_Driver__c` through ordinary system-mode
 * DML, which is unaffected by the FLS the tests then measure under System.runAs.
 *
 * @see force-app/main/default/classes/UserSelector.cls
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (consumer)
 */
@isTest
private class UserSelectorTest {

    private static final String DEAL_DRIVER_PERM_SET = 'Acquisition_Deal_Driver';

    /**
     * The grant path: FLS present (via Acquisition_Deal_Driver) and the flag set. Both factors of
     * the gate are satisfiable only if this read works.
     */
    @isTest
    static void selectDealDriverFlagForCurrentUser_withFieldAccessAndFlagSet_returnsTheFlag() {
        User dealDriver = buildStandardUser('usel1');
        dealDriver.Deal_Driver__c = true;
        insert dealDriver;
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        User result;
        System.runAs(dealDriver) {
            result = UserSelector.selectDealDriverFlagForCurrentUser();
        }
        Test.stopTest();

        Assert.isNotNull(result, 'The running user always has a User record, so a row must come back');
        Assert.areEqual(dealDriver.Id, result.Id,
            'The query is hard-filtered to the RUNNING user — any other Id would mean the filter was dropped');
        Assert.isTrue(result.Deal_Driver__c,
            'Deal_Driver__c must be readable and true for a provisioned deal driver');
    }

    /**
     * FLS present, flag NOT set. Proves the selector reports the field's real value rather than
     * conflating "readable" with "true" — the distinction the whole two-factor gate rests on.
     */
    @isTest
    static void selectDealDriverFlagForCurrentUser_withFieldAccessAndFlagUnset_returnsFalse() {
        User nonDriver = buildStandardUser('usel2');
        nonDriver.Deal_Driver__c = false;
        insert nonDriver;
        assignPermissionSet(nonDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        User result;
        System.runAs(nonDriver) {
            result = UserSelector.selectDealDriverFlagForCurrentUser();
        }
        Test.stopTest();

        Assert.isNotNull(result, 'A readable field still returns a row');
        Assert.isFalse(result.Deal_Driver__c,
            'Holding the permission set is NOT the same as being flagged a deal driver — the value must survive intact');
    }

    /**
     * THE FLS TEST. A bare Standard User has no read on `User.Deal_Driver__c`, so `WITH USER_MODE`
     * must make the query throw rather than hand back the row with a null field. This is factor (a)
     * of the gate, and it is the assertion that fails if USER_MODE is ever removed.
     *
     * The flag is set to TRUE on this user on purpose: if USER_MODE stopped enforcing FLS, the query
     * would succeed and return `true`, which is precisely the silent privilege escalation this test
     * exists to prevent.
     */
    @isTest
    static void selectDealDriverFlagForCurrentUser_withoutFieldAccess_throwsInsteadOfLeakingTheFlag() {
        User bareUser = buildStandardUser('usel3');
        bareUser.Deal_Driver__c = true;   // set, but must be unreadable to this user
        insert bareUser;

        Test.startTest();
        Boolean threw = false;
        Boolean fieldAccessible;
        System.runAs(bareUser) {
            fieldAccessible = Schema.SObjectType.User.fields.Deal_Driver__c.isAccessible();
            try {
                UserSelector.selectDealDriverFlagForCurrentUser();
            } catch (Exception e) {
                threw = true;
            }
        }
        Test.stopTest();

        // Precondition, asserted rather than assumed. If this fails, someone has granted
        // Deal_Driver__c read to the Standard User profile in this org, which by itself weakens the
        // quick-action gate to a single factor for every Standard User — a real finding, not a test bug.
        Assert.isFalse(fieldAccessible,
            'PRECONDITION: a bare Standard User must NOT have FLS read on User.Deal_Driver__c. '
            + 'If this fails, the field has been granted outside Acquisition_Deal_Driver and factor (a) '
            + 'of the Opportunity action gate is no longer enforced for those users');

        Assert.isTrue(threw,
            'WITH USER_MODE must make the read FAIL for a user without FLS on Deal_Driver__c. If this '
            + 'query ever succeeds for a bare user it would return Deal_Driver__c = true and grant the '
            + 'deal actions to someone holding no permission set at all');
    }

    /**
     * ⚠ MEASURED IN THIS ORG, and counter-intuitive enough to be worth its own test: even a SYSTEM
     * ADMINISTRATOR cannot read `User.Deal_Driver__c` without the permission set. Custom fields
     * deployed by the Metadata API arrive with NO field permissions for any profile, and "Modify All
     * Data" is an OBJECT-level permission that confers no FLS — so this selector throws for a bare
     * admin exactly as it does for a bare Standard User.
     *
     * That is the reason OpportunityActionPermissionService checks Modify All Data BEFORE calling
     * this selector. If the order were reversed, every administrator in the org would be denied the
     * very quick actions they just deployed. This test is the tripwire for that ordering.
     */
    @isTest
    static void selectDealDriverFlagForCurrentUser_bareAdministrator_alsoLacksFieldAccess() {
        User bareAdmin = buildUserOnProfile('System Administrator', 'usel4');
        insert bareAdmin;   // deliberately NO permission set

        Test.startTest();
        Boolean threw = false;
        Boolean fieldAccessible;
        System.runAs(bareAdmin) {
            fieldAccessible = Schema.SObjectType.User.fields.Deal_Driver__c.isAccessible();
            try {
                UserSelector.selectDealDriverFlagForCurrentUser();
            } catch (Exception e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isFalse(fieldAccessible,
            'PRECONDITION: a System Administrator holding no permission set must NOT have FLS read on '
            + 'User.Deal_Driver__c. Modify All Data is an object permission, not field access. If this '
            + 'fails, the field has been granted to the admin profile in this org');
        Assert.isTrue(threw,
            'The selector must throw for a bare administrator too — which is precisely why the service '
            + 'tests Modify All Data BEFORE it reads the flag');
    }

    /**
     * Cost is one query, and it does not scale with anything. Asserted directly, because the
     * property the bulk rule protects (cost independent of input) is what matters here — there is no
     * record volume to vary.
     *
     * Runs as a PROVISIONED deal driver rather than as the test-running user: whether the running
     * user can read Deal_Driver__c depends on org FLS state, which is not in source control
     * (profiles are `.forceignore`d), so measuring the query cost as "whoever runs the tests" would
     * make this assertion depend on org configuration instead of on the selector.
     */
    @isTest
    static void selectDealDriverFlagForCurrentUser_costsExactlyOneQuery() {
        User dealDriver = buildStandardUser('usel5');
        dealDriver.Deal_Driver__c = true;
        insert dealDriver;
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Integer used;
        System.runAs(dealDriver) {
            Integer before = Limits.getQueries();
            UserSelector.selectDealDriverFlagForCurrentUser();
            used = Limits.getQueries() - before;
        }
        Test.stopTest();

        Assert.areEqual(1, used, 'The selector must issue exactly one query per call');
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
     * Builds (but does not insert) a bare Standard User. Mirrors the helper in
     * LeadActionPermissionServiceTest — User is a setup object with a required-field shape that
     * TestDataFactory deliberately does not cover, and the repo's existing permission tests build it
     * locally for the same reason.
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
     *                    'System Administrator' for the no-FLS-even-for-admins case)
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildUserOnProfile(String profileName, String tag) {
        Profile targetProfile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'UserSel',
            Alias = 'usel',
            Email = 'std.usersel@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = targetProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
