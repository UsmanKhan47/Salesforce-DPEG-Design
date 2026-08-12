/**
 * @description Tests DispositionActionPermissionService — the gate behind the disposition stage
 * quick actions (decision D15/Q1). The sell-side twin of OpportunityActionPermissionServiceTest,
 * and deliberately shaped after it.
 *
 * ── 🔴 REWRITTEN 2026-08-12 FOR THE CUSTOM-PERMISSION MIGRATION ──────────────
 * The gate used to be two-factor: FLS read on `User.Disposition_Driver__c` (via `WITH USER_MODE`)
 * AND the flag itself set to true. It is now one factor: holding the `Disposition_Deal_Actions`
 * custom permission, granted by the SAME `Disposition_Deal_Driver` permission set that used to
 * carry the FLS grant. Positive-path fixtures are simpler as a direct consequence — see
 * agent-output/design-requirements-custom-permissions.md §7.2, and
 * OpportunityActionPermissionServiceTest's header for the Step 0 measurement (a throwaway probe
 * confirmed FeatureManagement.checkPermission sees a same-transaction PermissionSetAssignment
 * using the identical fixture shape this file already used) that applies here unchanged.
 *
 * ── 🔴 THE MOST IMPORTANT TEST IN THIS CLASS ─────────────────────────────────
 * anAcquisitionDealDriverIsDeniedTheDispositionGate. The whole reason D15/Q1 rejected reusing a
 * single shared authorization token is that it would merge two authorization boundaries — a sale
 * driver could then drive acquisitions and vice versa. That argument survived the token swap
 * unchanged (see the class header): every other test here would pass just as happily against an
 * implementation that read `Acquisition_Deal_Actions`; this one would not.
 *
 * ── ⚠ THIS CLASS HAS NO SEPARATE "CAPABILITY VS AUTHORIZATION" TEST, AND THAT IS DELIBERATE ──
 * OpportunityActionPermissionServiceTest carries
 * `capabilitySetWithoutTheAuthorizationSet_isStillDenied`, pinning that
 * `Opportunity_Stage_Actions_Access` (layer 4) does not imply `Acquisition_Deal_Driver` (layer 5).
 * There is no disposition-specific layer-4 capability set reachable independently of this gate to
 * build the same fixture against — `RecordStageAdvanceController` (the disposition entry point) sits
 * in the org-wide `DPEG_Apex_Access` catch-all, not a disposition-scoped capability set, so there is
 * no analogous "holds the capability set but not the authorization set" state to construct here.
 * `anAcquisitionDealDriverIsDeniedTheDispositionGate` below is this class's boundary-separation
 * proof instead: it pins that holding a DIFFERENT layer-5 authorization set (Acquisition_Deal_Driver)
 * does not grant this gate — the disposition-shaped version of "holding some other set does not
 * imply THIS one."
 *
 * ── ⚠ WHAT AN ADMIN RUN CANNOT PROVE ────────────────────────────────────────
 * "Modify All Data" bypasses this gate entirely and BEFORE the custom-permission check is even
 * consulted for cost reasons (see the class header), so the test-running user passes
 * unconditionally. Every meaningful assertion here therefore runs inside System.runAs against a
 * purpose-built user. The same caveat applies to UAT: an admin smoke test of the disposition
 * buttons proves nothing at all.
 *
 * ── ⚠ THE CACHE MUST BE CLEARED AROUND EVERY runAs ──────────────────────────
 * The service memoizes its answer per transaction, which is correct in production (one user per
 * transaction) and a trap in a test that switches users. clearCache() is called on both sides of
 * each runAs block.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * No 251-record scenario. This is a per-transaction-singleton question about ONE user (the
 * running user) with no record collection and no DML — the same shape
 * .claude/rules/bulk-test-rule.md exempts for OpportunityActionPermissionService and
 * LeadActionPermissionService. Cost is asserted directly via Limits.getQueries() instead.
 *
 * @see force-app/main/default/classes/DispositionActionPermissionService.cls
 * @see force-app/main/default/classes/OpportunityActionPermissionServiceTest.cls (the twin)
 * @author Unit Testing Agent
 */
@isTest
private class DispositionActionPermissionServiceTest {

    private static final String DISPOSITION_DRIVER_PERM_SET = 'Disposition_Deal_Driver';
    private static final String DEAL_DRIVER_PERM_SET = 'Acquisition_Deal_Driver';
    private static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    // ═════════════════════════════════════════════════════════════════════════
    // DENIALS
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void bareStandardUserIsDenied() {
        User bareUser = buildStandardUser('dap1');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'A user with neither Modify All Data nor Disposition_Deal_Driver must be denied');
    }

    /**
     * A grant to a DIFFERENT user must not leak — the disposition mirror of the acquisitions
     * regression pin. Worth keeping even though FeatureManagement.checkPermission resolves against
     * the running context (there is no explicit user Id filter in this class to regress): the
     * admin-bypass path still reads through PermissionSetAssignmentSelector's hard-filtered query,
     * and this pins that a second user's grant in the same transaction cannot bleed across.
     */
    @isTest
    static void anotherUserHoldsTheGrant_stillDeniesTheRunningUser() {
        User realDispositionDriver = buildStandardUser('dap2');
        User bareUser = buildStandardUser('dap2b');
        insert new List<User>{ realDispositionDriver, bareUser };
        assignPermissionSet(realDispositionDriver.Id, DISPOSITION_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            allowed = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Another user holding Disposition_Deal_Driver must never grant access to the running user');
    }

    /**
     * 🔴 THE BOUNDARY-SEPARATION TEST — the reason D15/Q1 rejected a single shared authorization
     * token, and the reason the two modules still carry SEPARATE custom permissions after the
     * token swap.
     *
     * A fully provisioned ACQUISITIONS deal driver (Acquisition_Deal_Driver, carrying
     * Acquisition_Deal_Actions) must be DENIED the disposition actions. Every other test in this
     * class would pass unchanged against an implementation that read Acquisition_Deal_Actions
     * instead of Disposition_Deal_Actions; this one is the falsifier.
     */
    @isTest
    static void anAcquisitionDealDriverIsDeniedTheDispositionGate() {
        User acquisitionDriver = buildStandardUser('dap4');
        insert acquisitionDriver;
        assignPermissionSet(acquisitionDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Boolean dispositionAllowed;
        Boolean acquisitionAllowed;
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.clearCache();
        System.runAs(acquisitionDriver) {
            dispositionAllowed = DispositionActionPermissionService.hasDispositionActionAccess();
            acquisitionAllowed = OpportunityActionPermissionService.hasDealActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(acquisitionAllowed,
            'PRECONDITION: this user IS a provisioned acquisitions deal driver. If this fails the '
            + 'fixture is wrong and the real assertion below proves nothing.');
        Assert.isFalse(dispositionAllowed,
            'An acquisitions deal driver must NOT be able to drive a SALE. The two gates read '
            + 'different custom permissions granted by different permission sets on purpose — '
            + 'merging them (or granting Acquisition_Deal_Actions to disposition users) would let a '
            + 'sale driver drive acquisitions and vice versa.');
    }

    @isTest
    static void assertThrowsTheSharedUserFacingMessage() {
        User bareUser = buildStandardUser('dap5');
        insert bareUser;

        Test.startTest();
        Boolean refused = false;
        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                DispositionActionPermissionService.assertDispositionActionAccess();
                Assert.fail('assertDispositionActionAccess must REFUSE an unprovisioned user. '
                    + 'Returning normally means the gate did not run at all.');
            } catch (DispositionActionPermissionService.AccessDeniedException e) {
                refused = true;
                Assert.areEqual(NO_PERMISSION_MESSAGE, e.getMessage(),
                    'The denial must use the SHARED wording, so one condition never produces two '
                    + 'phrasings across the Lead, Opportunity and disposition features. This is '
                    + 'also why NO_PERMISSION_MESSAGE is REUSED from '
                    + 'OpportunityActionPermissionService rather than re-declared here.');
            }
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The server-side assert must refuse an unprovisioned user');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // GRANTS
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void provisionedDispositionDriverIsAllowed() {
        User dispositionDriver = buildStandardUser('dap6');
        insert dispositionDriver;
        assignPermissionSet(dispositionDriver.Id, DISPOSITION_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        DispositionActionPermissionService.clearCache();
        System.runAs(dispositionDriver) {
            allowed = DispositionActionPermissionService.hasDispositionActionAccess();
            // Must not throw.
            DispositionActionPermissionService.assertDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(allowed,
            'Holding Disposition_Deal_Driver — which now carries the Disposition_Deal_Actions '
            + 'custom permission — must grant. If this fails, the gate has no reachable true branch '
            + 'for anyone and the feature is dead for every non-administrator.');
    }

    /**
     * The admin bypass. A System Administrator holding NEITHER the custom permission NOR the
     * permission set must still pass, via Modify All Data.
     *
     * ⚠ THE OLD FLS-LOCKOUT PRECONDITION IS GONE, AND DELIBERATELY NOT REPLACED. Pre-migration this
     * test had to prove a bare admin lacks FLS read on User.Disposition_Driver__c — the reason the
     * bypass had to run BEFORE the field read. There is no field read left in this class, so there
     * is nothing left to lock an admin out of; the ordering is now a cost choice (see the class
     * header), not a correctness one.
     */
    @isTest
    static void administratorPassesWithoutTheCustomPermissionOrThePermissionSet() {
        User bareAdmin = buildUserOnProfile('System Administrator', 'dap7');
        insert bareAdmin;   // no permission set

        Test.startTest();
        Boolean allowed;
        Set<String> heldSetNames = new Set<String>();
        DispositionActionPermissionService.clearCache();
        System.runAs(bareAdmin) {
            for (PermissionSetAssignment row : PermissionSetAssignmentSelector.selectForCurrentUser()) {
                if (row.PermissionSet != null) {
                    heldSetNames.add(row.PermissionSet.Name);
                }
            }
            allowed = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(heldSetNames.contains(DISPOSITION_DRIVER_PERM_SET),
            'PRECONDITION: the admin must hold NO Disposition_Deal_Driver set, otherwise this test '
            + 'would not isolate the Modify All Data bypass.');
        Assert.isTrue(allowed,
            'Modify All Data must grant access even without the custom permission. An administrator '
            + 'can already change any stage through inline edit, the Path or the API, so denying '
            + 'them the button would be theatre, not security.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // CACHING AND FAULTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE ASSERTION TIGHTENS UNDER THE NEW ORDER, mirroring the acquisitions twin. The
     * custom-permission check now runs FIRST and costs ZERO SOQL, and a disposition driver never
     * falls through to the Modify All Data bypass — so repeated asks by a driver must cost EXACTLY
     * ZERO queries.
     */
    @isTest
    static void repeatedCallsByADriverCostZeroQueries() {
        User dispositionDriver = buildStandardUser('dap8');
        insert dispositionDriver;
        assignPermissionSet(dispositionDriver.Id, DISPOSITION_DRIVER_PERM_SET);

        Test.startTest();
        Integer used;
        DispositionActionPermissionService.clearCache();
        System.runAs(dispositionDriver) {
            Integer before = Limits.getQueries();
            DispositionActionPermissionService.hasDispositionActionAccess();
            DispositionActionPermissionService.hasDispositionActionAccess();
            DispositionActionPermissionService.hasDispositionActionAccess();
            used = Limits.getQueries() - before;
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.areEqual(0, used,
            'A disposition driver must pay ZERO queries: FeatureManagement.checkPermission costs 0 '
            + 'SOQL and a driver never reaches the Modify All Data bypass read. Actual: ' + used);
    }

    /** A non-driver still pays at most one query (the bypass read), memoized across repeated asks. */
    @isTest
    static void repeatedCallsByANonDriverCostAtMostOneQuery() {
        User bareUser = buildStandardUser('dap8b');
        insert bareUser;

        Test.startTest();
        Integer used;
        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            Integer before = Limits.getQueries();
            DispositionActionPermissionService.hasDispositionActionAccess();
            DispositionActionPermissionService.hasDispositionActionAccess();
            used = Limits.getQueries() - before;
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(used <= 1,
            'A non-driver must pay at most ONE query (the Modify All Data bypass read), memoized for '
            + 'every subsequent ask. Actual: ' + used);
    }

    @isTest
    static void clearCacheAfterAUserSwitchRecomputes() {
        User denied = buildStandardUser('dap9');
        insert denied;
        User granted = buildStandardUser('dap10');
        insert granted;
        assignPermissionSet(granted.Id, DISPOSITION_DRIVER_PERM_SET);

        Test.startTest();
        Boolean first;
        Boolean second;
        DispositionActionPermissionService.clearCache();
        System.runAs(denied) {
            first = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        System.runAs(granted) {
            second = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(first, 'The unprovisioned user is denied');
        Assert.isTrue(second,
            'After clearCache the provisioned user must be re-evaluated. A cache that survived '
            + 'the switch would answer the FIRST user\'s question for the second.');
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
        DispositionActionPermissionService.clearCache();
        DispositionActionPermissionService.simulateLookupFailure = true;
        Boolean threw = false;
        try {
            DispositionActionPermissionService.hasDispositionActionAccess();
            Assert.fail('A permission-machinery fault must PROPAGATE, not be swallowed as a denial');
        } catch (QueryException e) {
            threw = true;
        }
        Assert.isNull(DispositionActionPermissionService.cachedHasDispositionActionAccess,
            'A thrown fault must leave the cache EMPTY so the next ask re-evaluates');

        Boolean assertThrew = false;
        try {
            DispositionActionPermissionService.assertDispositionActionAccess();
            Assert.fail('The assert must propagate the fault too');
        } catch (QueryException e) {
            assertThrew = true;
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(threw, 'hasDispositionActionAccess propagates a machinery fault');
        Assert.isTrue(assertThrew,
            'assertDispositionActionAccess propagates it as a FAULT, not as an AccessDeniedException '
            + '— a system failure must never be reported to the user as a permissions problem');
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
     * in OpportunityActionPermissionServiceTest.
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
            LastName = 'DispPerm',
            Alias = 'dperm',
            Email = 'std.dispperm@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = targetProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
