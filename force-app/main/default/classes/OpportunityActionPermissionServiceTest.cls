/**
 * Tests OpportunityActionPermissionService — the permission gate behind the Opportunity stage quick
 * actions.
 *
 * ── 🔴 REWRITTEN 2026-08-12 FOR THE CUSTOM-PERMISSION MIGRATION ──────────────
 * The gate used to be two-factor: FLS read on `User.Deal_Driver__c` (via `WITH USER_MODE`) AND the
 * flag itself set to true. It is now one factor: holding the `Acquisition_Deal_Actions` custom
 * permission, granted by the SAME `Acquisition_Deal_Driver` permission set that used to carry the
 * FLS grant. Every positive-path fixture below is SIMPLER as a direct consequence — "assign the set
 * AND set the flag" is now just "assign the set" — per
 * agent-output/design-requirements-custom-permissions.md §7.2.
 *
 * ── 🔴 STEP 0 MEASURED (2026-08-12), BEFORE ANY OF THIS WAS WRITTEN ──────────
 * A throwaway probe (ProbeCustomPermissionTest, deployed and deleted in the same session) confirmed
 * FeatureManagement.checkPermission('Acquisition_Deal_Actions') DOES reflect a
 * PermissionSetAssignment inserted in the SAME test transaction, using the exact fixture shape this
 * suite already used pre-migration: assign the permission set BEFORE Test.startTest(), then check
 * inside a System.runAs block. No fixture restructuring was required — this file keeps that shape.
 *
 * ── WHAT SURVIVED THE REWRITE, AND WHY ────────────────────────────────────────
 * `hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` used to pin "permission-set MEMBERSHIP
 * alone is not the gate" against the retired flag. The FLAG is gone, but the PRINCIPLE it protected —
 * CAPABILITY (layer 4, "can this code be reached at all") is not AUTHORIZATION (layer 5, "is this
 * user allowed") — is still load-bearing (ARCHITECTURE.md §2, "Permission Set Architecture"). It is
 * rewritten below as `capabilitySetWithoutTheAuthorizationSet_isStillDenied`: a user holding
 * `Opportunity_Stage_Actions_Access` (layer 4) but NOT `Acquisition_Deal_Driver` (layer 5) must still
 * be denied. If someone ever moves `Acquisition_Deal_Actions` onto the layer-4 set — the exact move
 * both class headers forbid, because `Opportunity_Stage_Actions_Access` is a member of
 * `DPEG_Junior_Analyst_PSG` — this test goes red.
 *
 * ── WHAT DID NOT SURVIVE ───────────────────────────────────────────────────────
 * `hasDealActionAccess_flagSetButNoFieldAccess_isDenied` is DELETED, not rewritten. It proved "the
 * flag alone, without FLS to read it, is not sufficient" — there is no FLS surface left on a custom
 * permission, so there is no analogous state to construct. Inventing a fixture for it would be
 * testing nothing.
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
    private static final String CAPABILITY_PERM_SET = 'Opportunity_Stage_Actions_Access';
    private static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    // ─────────────────────────────────────────────────────────────────────────
    // DENIED — the cases that make this class worth having
    // ─────────────────────────────────────────────────────────────────────────

    /** No permission set, so no custom permission and no Modify All Data: denied. */
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
     * 🔴 THE ASSERTION THAT REPLACES THE OLD FLAG PIN. This user holds `Opportunity_Stage_Actions_Access`
     * — the layer-4 CAPABILITY set that lets a quick action reach this class at all — but NOT
     * `Acquisition_Deal_Driver`, the layer-5 AUTHORIZATION set that carries `Acquisition_Deal_Actions`.
     * Capability must not imply authorization.
     *
     * If someone later "simplifies" by moving `Acquisition_Deal_Actions` onto the capability set (or
     * grants deal-driving to everyone who can call the gate), THIS TEST GOES RED — which is the whole
     * point. That move looks like tidying and is actually a live access grant to the entire
     * `DPEG_Junior_Analyst_PSG` group, which `Opportunity_Stage_Actions_Access` is a member of.
     */
    @isTest
    static void capabilitySetWithoutTheAuthorizationSet_isStillDenied() {
        User capabilityHolder = buildStandardUser('oapsB');
        insert capabilityHolder;
        assignPermissionSet(capabilityHolder.Id, CAPABILITY_PERM_SET);

        Test.startTest();
        Boolean allowed;
        OpportunityActionPermissionService.clearCache();
        System.runAs(capabilityHolder) {
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'Holding Opportunity_Stage_Actions_Access (capability) is NOT sufficient — the running '
            + 'user must ALSO hold Acquisition_Deal_Driver (authorization). If this ever passes, '
            + 'the custom permission has been moved onto — or duplicated onto — the capability set, '
            + 'silently widening deal-driving to the whole DPEG_Junior_Analyst_PSG group.');
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
     * A grant to a DIFFERENT user must not leak to the running user. Worth keeping even though
     * FeatureManagement.checkPermission resolves against the running context (there is no explicit
     * running-user Id filter in this class to regress) — the admin-bypass path still reads through
     * PermissionSetAssignmentSelector's hard-filtered query, and this pins that a second user's grant
     * in the same transaction cannot bleed across via a stale cache or a broken filter either way.
     */
    @isTest
    static void hasDealActionAccess_anotherUserHoldsTheGrant_stillDeniesTheRunningUser() {
        User realDealDriver = buildStandardUser('oapsE');
        User bareUser = buildStandardUser('oapsF');
        insert new List<User>{ realDealDriver, bareUser };
        assignPermissionSet(realDealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'Another user holding Acquisition_Deal_Driver must never grant access to the running user');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GRANTED
    // ─────────────────────────────────────────────────────────────────────────

    /** The intended deal-driver persona: holding the permission set is now the whole grant. */
    @isTest
    static void hasDealActionAccess_provisionedDealDriver_returnsTrue() {
        User dealDriver = buildStandardUser('oapsG');
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
            'Holding Acquisition_Deal_Driver — which now carries the Acquisition_Deal_Actions custom '
            + 'permission — is the exact condition the deployed FlexiPage visibility rules use; it '
            + 'must grant access');
    }

    @isTest
    static void assertDealActionAccess_provisionedDealDriver_doesNotThrow() {
        User dealDriver = buildStandardUser('oapsH');
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
     * The documented admin bypass. The user is on the System Administrator profile (which carries
     * Modify All Data) and is assigned NO permission set, so a `true` result can ONLY have come from
     * the Modify All Data branch.
     *
     * ⚠ THE OLD FLS-LOCKOUT PRECONDITION IS GONE, AND DELIBERATELY NOT REPLACED. Pre-migration this
     * test had to prove a System Administrator lacks FLS read on `User.Deal_Driver__c` — the reason
     * the bypass had to run BEFORE the field read. There is no field read left in this class at all,
     * so there is nothing left to lock an admin out; the ordering is now a COST choice, not a
     * correctness one (see the class header). This test now only isolates the bypass itself.
     *
     * (A fabricated PermissionSet with PermissionsModifyAllData = true is not an option: the platform
     * rejects it with FIELD_INTEGRITY_EXCEPTION listing ~35 dependent permissions. Using the profile
     * that already holds the permission is both simpler and closer to how a real admin is
     * provisioned — same finding as LeadActionPermissionServiceTest.)
     */
    @isTest
    static void hasDealActionAccess_administrator_isAllowedWithoutThePermissionSet() {
        User adminUser = buildUserOnProfile('System Administrator', 'oapsI');
        insert adminUser;

        Test.startTest();
        Boolean allowed;
        Set<String> heldSetNames = new Set<String>();
        OpportunityActionPermissionService.clearCache();
        System.runAs(adminUser) {
            for (PermissionSetAssignment row : PermissionSetAssignmentSelector.selectForCurrentUser()) {
                if (row.PermissionSet != null) {
                    heldSetNames.add(row.PermissionSet.Name);
                }
            }
            allowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(heldSetNames.contains(DEAL_DRIVER_PERM_SET),
            'PRECONDITION: the admin must hold NO Acquisition_Deal_Driver set, otherwise this test '
            + 'would not isolate the Modify All Data bypass');

        Assert.isTrue(allowed,
            'A Modify All Data holder is allowed even without the custom permission — denying an '
            + 'admin a button whose effect they can already achieve by inline edit, the Path, or the '
            + 'API would be theatre, not security');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CACHING + FAILURE MODE
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE ASSERTION TIGHTENS UNDER THE NEW ORDER. Pre-migration a deal driver still paid the
     * admin-bypass query first (the FLS read had to run before it, for correctness — see the class
     * header), so repeated asks cost "at most two" total. The custom-permission check now runs
     * FIRST and costs ZERO SOQL, and a driver never falls through to the bypass at all — so four
     * asks by a driver must cost EXACTLY ZERO queries, not merely "not-more-than-two".
     */
    @isTest
    static void hasDealActionAccess_repeatedCallsByADriver_costZeroQueries() {
        User dealDriver = buildStandardUser('oapsJ');
        insert dealDriver;
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        Integer queriesUsed;
        System.runAs(dealDriver) {
            Integer before = Limits.getQueries();
            // Several quick actions on one Opportunity page can each ask; none may cost a query.
            OpportunityActionPermissionService.hasDealActionAccess();
            OpportunityActionPermissionService.hasDealActionAccess();
            OpportunityActionPermissionService.hasDealActionAccess();
            OpportunityActionPermissionService.hasDealActionAccess();
            queriesUsed = Limits.getQueries() - before;
        }
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A deal driver must pay ZERO queries: FeatureManagement.checkPermission costs 0 SOQL and '
            + 'a driver never reaches the Modify All Data bypass read. A nonzero count here means '
            + 'either the cache regressed or the check order was reverted. Actual: ' + queriesUsed);
    }

    /** A non-driver still pays at most one query (the bypass read), memoized across repeated asks. */
    @isTest
    static void hasDealActionAccess_repeatedCallsByANonDriver_costAtMostOneQuery() {
        User bareUser = buildStandardUser('oapsNonDriver');
        insert bareUser;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        Integer queriesUsed;
        System.runAs(bareUser) {
            Integer before = Limits.getQueries();
            OpportunityActionPermissionService.hasDealActionAccess();
            OpportunityActionPermissionService.hasDealActionAccess();
            queriesUsed = Limits.getQueries() - before;
        }
        Test.stopTest();

        Assert.isTrue(queriesUsed <= 1,
            'A non-driver must pay at most ONE query (the Modify All Data bypass read), memoized for '
            + 'every subsequent ask in the same transaction. Actual: ' + queriesUsed);
    }

    @isTest
    static void clearCache_afterAUserSwitch_recomputesForTheNewUser() {
        User dealDriver = buildStandardUser('oapsK');
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
     * setup-object access failure under WITH SYSTEM_MODE while reading PermissionSetAssignment for
     * the admin bypass — the only remaining query in this class — which cannot be provoked
     * deterministically (every user can read their own rows). What matters is that the failure
     * PROPAGATES instead of collapsing into a default answer, and that a propagated fault is NOT
     * memoized as if it were an answer.
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

    /**
     * ⚠ COMPANION REGRESSION PIN to the 2026-08-03 Lead-action incident. That incident was reported
     * against the Lead quick actions, but the root cause sat in PermissionSetAssignmentSelector,
     * which THIS service still consumes for the admin bypass — the ONLY query it performs. Under the
     * old `WITH USER_MODE` a Minimum Access user made this gate THROW rather than deny; the selector
     * now runs `WITH SYSTEM_MODE`, and this service inherits the fix unchanged by the migration.
     *
     * The expected answer here is FALSE, not true: a bare Minimum Access user legitimately holds
     * neither the custom permission nor Modify All Data. The regression being pinned is
     * THROW-vs-DENY, not the flag model this class no longer has.
     *
     * ⚠ DO NOT downgrade this to buildStandardUser: Standard User can read the setup entity and so
     * passes under either mode, which is exactly the blind spot that let this reach production —
     * every other runAs test in this class uses Standard User.
     */
    @isTest
    static void hasDealActionAccess_minimumAccessUser_deniesWithoutThrowing() {
        User minimumAccessUser = buildUserOnProfile('Minimum Access - Salesforce', 'oapsMin');
        insert minimumAccessUser;

        Test.startTest();
        Boolean allowed;
        String thrown = null;
        OpportunityActionPermissionService.clearCache();
        System.runAs(minimumAccessUser) {
            try {
                allowed = OpportunityActionPermissionService.hasDealActionAccess();
            } catch (Exception e) {
                thrown = e.getTypeName() + ': ' + e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isNull(thrown,
            'The deal-action gate must DENY a Minimum Access user, not THROW. A throw reproduces the '
            + '2026-08-03 root cause reaching this service too. Observed: ' + thrown);
        Assert.isFalse(allowed,
            'A bare Minimum Access user holds neither the custom permission nor Modify All Data, so '
            + 'the gate must return false');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────

    /** Assigns a deployed permission set, by API Name, to a user. */
    private static void assignPermissionSet(Id assigneeId, String permissionSetName) {
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = assigneeId, PermissionSetId = permSetId);
    }

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
