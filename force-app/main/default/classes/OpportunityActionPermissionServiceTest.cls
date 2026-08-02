/**
 * Tests OpportunityActionPermissionService — the permission gate behind the Opportunity stage quick
 * actions.
 *
 * This is a SECURITY class, so the suite is weighted toward the negative cases: the tests that
 * matter most prove a user is DENIED, and prove a grant is never produced by accident — in
 * particular that PERMISSION SET MEMBERSHIP ALONE DOES NOT GRANT. That last one is the assertion
 * that pins the deliberate design decision behind this class: the gate is two-factor
 * (FLS read on `User.Deal_Driver__c` AND the flag set to true), and swapping it for the Lead-style
 * membership check would widen live access. `membershipWithoutTheFlag_isStillDenied` is what turns
 * that decision into something a future change cannot quietly undo.
 *
 * Every scenario runs under System.runAs with a purpose-built user, because "the running user" is
 * the entire input to this class. The transaction cache is cleared before each impersonation —
 * without that, a user switch inside one transaction would silently inherit the previous user's
 * answer and every assertion after the first would be meaningless.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST ──────────────────────────────────────
 * Per .claude/rules/bulk-test-rule.md the 251-record mandate applies to triggers, batches and
 * service methods performing DML over a record collection. This service performs NO DML and asks a
 * per-transaction-singleton question about ONE user (the running user); there is no collection
 * parameter to scale. The property the rule actually protects — that cost does not grow with the
 * number of asks — is asserted directly via Limits.getQueries().
 *
 * ── SETUP-DML ISOLATION ───────────────────────────────────────────────────────
 * Every object touched here (User, PermissionSet, PermissionSetAssignment) is a SETUP object. No
 * test creates a non-setup record, which is what keeps MIXED_DML_OPERATION off the table.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls
 */
@isTest
private class OpportunityActionPermissionServiceTest {

    private static final String DEAL_DRIVER_PERM_SET = 'Acquisition_Deal_Driver';
    private static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    // ─────────────────────────────────────────────────────────────────────────
    // DENIED — the cases that make this class worth having
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * No permission set, so no FLS on Deal_Driver__c: factor (a) fails, the selector throws, and the
     * service must read that as a denial rather than let it escape as a fault.
     */
    @isTest
    static void hasDealActionAccess_bareStandardUser_returnsFalse() {
        User bareUser = buildStandardUser('oapsA');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'A Standard User with no deal-driver provisioning and no Modify All Data must be denied');
    }

    /**
     * THE ASSERTION THAT PINS THE DESIGN. This user HOLDS `Acquisition_Deal_Driver` — so they have
     * FLS read on Deal_Driver__c, factor (a) — but the flag itself is FALSE. Under the current
     * two-factor gate they are DENIED, which matches the deployed visibility rules exactly.
     *
     * If someone later "aligns with the Lead pattern" by replacing the flag read with
     * LeadActionPermissionService.hasAnyPermissionSet({'Acquisition_Deal_Driver'}), THIS TEST GOES
     * RED — which is the whole point. That refactor looks like tidying and is actually a live access
     * grant to every holder of the permission set whose flag is false.
     */
    @isTest
    static void hasDealActionAccess_membershipWithoutTheFlag_isStillDenied() {
        User permSetHolder = buildStandardUser('oapsB');
        permSetHolder.Deal_Driver__c = false;
        insert permSetHolder;
        assignPermissionSet(permSetHolder.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        Boolean fieldAccessible;
        OpportunityActionPermissionService.clearCache();
        System.runAs(permSetHolder) {
            fieldAccessible = Schema.SObjectType.User.fields.Deal_Driver__c.isAccessible();
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        // Precondition: this user really does hold the permission set's FLS, so a `false` result can
        // only come from the FLAG, not from a missing grant. Without this the test below would pass
        // for the wrong reason.
        Assert.isTrue(fieldAccessible,
            'PRECONDITION: Acquisition_Deal_Driver must grant FLS read on User.Deal_Driver__c — '
            + 'otherwise this test proves nothing about the flag');

        Assert.isFalse(allowed,
            'Holding Acquisition_Deal_Driver is NOT sufficient — the gate is two-factor and this '
            + 'user\'s Deal_Driver__c is false. A membership-only check would GRANT here and would '
            + 'silently widen who can drive deals');
    }

    /**
     * The mirror image: the flag is TRUE but the user has no FLS to read it. Factor (a) fails, so
     * they are denied. Proves the flag alone is not sufficient either — both factors are required,
     * in both directions.
     */
    @isTest
    static void hasDealActionAccess_flagSetButNoFieldAccess_isDenied() {
        User flaggedButUnprivileged = buildStandardUser('oapsC');
        flaggedButUnprivileged.Deal_Driver__c = true;
        insert flaggedButUnprivileged;   // deliberately NO permission set

        Test.startTest();
        Boolean allowed;
        OpportunityActionPermissionService.clearCache();
        System.runAs(flaggedButUnprivileged) {
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'Deal_Driver__c = true without FLS read on the field must be denied: the flag is only '
            + 'meaningful to a user the org has actually provisioned as a deal driver');
    }

    @isTest
    static void assertDealActionAccess_bareStandardUser_throwsWithTheUserFacingMessage() {
        User bareUser = buildStandardUser('oapsD');
        insert bareUser;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                OpportunityActionPermissionService.assertDealActionAccess();
                Assert.fail('assertDealActionAccess must throw for a user who is not a deal driver');
            } catch (OpportunityActionPermissionService.AccessDeniedException e) {
                Assert.areEqual(NO_PERMISSION_MESSAGE, e.getMessage(),
                    'The thrown message is shown verbatim to the user — it must be the agreed wording, '
                    + 'identical to the one the LWC shows for the client-side denial');
            }
        }
        Test.stopTest();
    }

    /**
     * A grant to a DIFFERENT user must not leak. This is the assertion that would catch a selector
     * regression dropping the running-user Id filter — the single worst failure this feature could
     * have.
     */
    @isTest
    static void hasDealActionAccess_anotherUserIsTheDealDriver_stillDeniesTheRunningUser() {
        User realDealDriver = buildStandardUser('oapsE');
        realDealDriver.Deal_Driver__c = true;
        User bareUser = buildStandardUser('oapsF');
        insert new List<User>{ realDealDriver, bareUser };
        assignPermissionSet(realDealDriver.Id, DEAL_DRIVER_PERM_SET);
        assignPermissionSet(bareUser.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'Another user being flagged as a deal driver must never grant access to the running user');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GRANTED
    // ─────────────────────────────────────────────────────────────────────────

    /** Both factors satisfied — the intended deal-driver persona. */
    @isTest
    static void hasDealActionAccess_provisionedDealDriver_returnsTrue() {
        User dealDriver = buildStandardUser('oapsG');
        dealDriver.Deal_Driver__c = true;
        insert dealDriver;
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        OpportunityActionPermissionService.clearCache();
        System.runAs(dealDriver) {
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isTrue(allowed,
            'FLS read on Deal_Driver__c (from Acquisition_Deal_Driver) plus the flag set to true is '
            + 'the exact condition the deployed visibility rules use — it must grant access');
    }

    @isTest
    static void assertDealActionAccess_provisionedDealDriver_doesNotThrow() {
        User dealDriver = buildStandardUser('oapsH');
        dealDriver.Deal_Driver__c = true;
        insert dealDriver;
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        System.runAs(dealDriver) {
            OpportunityActionPermissionService.assertDealActionAccess();   // must not throw
        }
        Test.stopTest();

        Assert.isTrue(true, 'assertDealActionAccess returns silently for a permitted user');
    }

    /**
     * The documented admin bypass — and the proof that it is LOAD-BEARING, not merely convenient.
     *
     * The user is on the System Administrator profile (which carries Modify All Data), is assigned NO
     * permission set, and has Deal_Driver__c left at its default FALSE, so a `true` result can ONLY
     * have come from the Modify All Data branch. Every precondition is asserted rather than assumed.
     *
     * ⚠ MEASURED IN THIS ORG (this test was written the other way round first and failed):
     * a System Administrator does NOT have FLS read on `User.Deal_Driver__c`. Custom fields deployed
     * by the Metadata API arrive with no field permissions for ANY profile — "Modify All Data" is an
     * object-level permission and does not confer FLS. So `UserSelector` THROWS for a bare admin, and
     * if `hasModifyAllData()` did not run BEFORE the field read, every administrator in the org would
     * be DENIED their own feature. The ordering inside computeDealActionAccess() is therefore a
     * correctness requirement, not an optimisation — `fieldAccessible` is asserted false below to pin
     * exactly that.
     *
     * The flag value is read with an ordinary system-mode test query (NOT through UserSelector) for
     * the same reason: the selector deliberately cannot read it as this user.
     *
     * (A fabricated PermissionSet with PermissionsModifyAllData = true is not an option: the platform
     * rejects it with FIELD_INTEGRITY_EXCEPTION listing ~35 dependent permissions. Using the profile
     * that already holds the permission is both simpler and closer to how a real admin is
     * provisioned — same finding as LeadActionPermissionServiceTest.)
     */
    @isTest
    static void hasDealActionAccess_administrator_isAllowedWithoutTheFlagOrThePermissionSet() {
        User adminUser = buildUserOnProfile('System Administrator', 'oapsI');
        insert adminUser;
        // System-mode read: proves the flag is false without needing the FLS this user lacks.
        Boolean flagValue =
            [SELECT Deal_Driver__c FROM User WHERE Id = :adminUser.Id].Deal_Driver__c;

        Test.startTest();
        Boolean allowed;
        Boolean fieldAccessible;
        Set<String> heldSetNames = new Set<String>();
        OpportunityActionPermissionService.clearCache();
        System.runAs(adminUser) {
            for (PermissionSetAssignment row : PermissionSetAssignmentSelector.selectForCurrentUser()) {
                heldSetNames.add(row.PermissionSet.Name);
            }
            fieldAccessible = Schema.SObjectType.User.fields.Deal_Driver__c.isAccessible();
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        // Preconditions — without these, a passing assertion below could be the ordinary two-factor
        // grant in disguise rather than the bypass.
        Assert.isFalse(heldSetNames.contains(DEAL_DRIVER_PERM_SET),
            'The admin must hold NO Acquisition_Deal_Driver set, otherwise this test would not isolate the bypass');
        Assert.isFalse(flagValue,
            'The admin\'s Deal_Driver__c must be false, otherwise this test would not isolate the bypass');
        Assert.isFalse(fieldAccessible,
            'MEASURED: a System Administrator has NO FLS read on User.Deal_Driver__c — Modify All Data is '
            + 'an OBJECT permission and confers no field access. This is why the Modify All Data check must '
            + 'run BEFORE the field read; reversing that order locks every admin out of the feature');

        Assert.isTrue(allowed,
            'A Modify All Data holder is allowed even without the flag AND without being able to read it — '
            + 'denying an admin a button whose effect they can already achieve by inline edit, the Path, or '
            + 'the API would be theatre, not security');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CACHING + FAILURE MODE
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void hasDealActionAccess_repeatedCalls_readTheUserOnlyOnce() {
        User dealDriver = buildStandardUser('oapsJ');
        dealDriver.Deal_Driver__c = true;
        insert dealDriver;
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        Integer queriesUsed;
        System.runAs(dealDriver) {
            Integer before = Limits.getQueries();
            // Several quick actions on one Opportunity page can each ask; the reads must not repeat.
            OpportunityActionPermissionService.hasDealActionAccess();
            OpportunityActionPermissionService.hasDealActionAccess();
            OpportunityActionPermissionService.hasDealActionAccess();
            OpportunityActionPermissionService.hasDealActionAccess();
            queriesUsed = Limits.getQueries() - before;
        }
        Test.stopTest();

        Assert.isTrue(queriesUsed <= 2,
            'Four permission asks must cost at most the two initial selector reads (assignments + the user '
            + 'row), not two per ask. Actual: ' + queriesUsed);
    }

    @isTest
    static void clearCache_afterAUserSwitch_recomputesForTheNewUser() {
        User dealDriver = buildStandardUser('oapsK');
        dealDriver.Deal_Driver__c = true;
        User bareUser = buildStandardUser('oapsL');
        insert new List<User>{ dealDriver, bareUser };
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Boolean driverResult;
        Boolean bareResult;
        OpportunityActionPermissionService.clearCache();
        System.runAs(dealDriver) {
            driverResult = OpportunityActionPermissionService.hasDealActionAccess();
        }
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            bareResult = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isTrue(driverResult, 'The provisioned deal driver is allowed');
        Assert.isFalse(bareResult,
            'After clearCache the second user is evaluated on their OWN grants — a stale cache here would '
            + 'hand one user another user\'s permissions');
    }

    /**
     * Reaches the load-failure path via the documented test seam. Its real-world trigger is a
     * setup-object access failure under WITH USER_MODE while reading PermissionSetAssignment, which
     * cannot be provoked deterministically (every user can read their own rows). What matters is that
     * the failure PROPAGATES instead of collapsing into a default answer — and that a propagated
     * fault is NOT memoized as if it were an answer.
     */
    @isTest
    static void hasDealActionAccess_whenTheLookupFails_propagatesAndCachesNothing() {
        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        OpportunityActionPermissionService.simulateLookupFailure = true;
        Boolean threw = false;
        try {
            OpportunityActionPermissionService.hasDealActionAccess();
        } catch (Exception e) {
            threw = true;
        }
        Boolean cacheStillEmpty =
            OpportunityActionPermissionService.cachedHasDealActionAccess == null;
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(threw,
            'A failed permission lookup must PROPAGATE (the controller then fails closed) — swallowing it '
            + 'into a default answer is how a security gate silently becomes a no-op');
        Assert.isTrue(cacheStillEmpty,
            'A thrown fault must not be cached: memoizing it would freeze the fault for the rest of the '
            + 'transaction instead of letting the next ask re-evaluate');
    }

    /**
     * assertDealActionAccess must let a system fault through as a fault — not convert it into
     * AccessDeniedException. A caller distinguishing "you may not" from "we could not tell" depends
     * on that, and so does the controller's masked-message branch.
     */
    @isTest
    static void assertDealActionAccess_whenTheLookupFails_propagatesTheFaultNotADenial() {
        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        OpportunityActionPermissionService.simulateLookupFailure = true;
        Boolean sawAccessDenied = false;
        Boolean sawFault = false;
        try {
            OpportunityActionPermissionService.assertDealActionAccess();
        } catch (OpportunityActionPermissionService.AccessDeniedException e) {
            sawAccessDenied = true;
        } catch (Exception e) {
            sawFault = true;
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(sawAccessDenied,
            'A broken lookup is not a denial — reporting it as AccessDeniedException would tell the user '
            + 'they lack permission when the truth is that the check itself failed');
        Assert.isTrue(sawFault, 'The underlying fault must propagate for the controller to mask and log');
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
     * LeadActionPermissionServiceTest — User is a setup object whose required-field shape
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
     *                    'System Administrator' for the Modify All Data bypass case)
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildUserOnProfile(String profileName, String tag) {
        Profile targetProfile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'DealPerm',
            Alias = 'dperm',
            Email = 'std.dealperm@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = targetProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
