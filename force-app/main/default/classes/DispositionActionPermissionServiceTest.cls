/**
 * @description Tests DispositionActionPermissionService — the TWO-FACTOR gate behind the
 * disposition stage quick actions (decision D15/Q1). The sell-side twin of
 * OpportunityActionPermissionServiceTest, and deliberately shaped after it.
 *
 * ── 🔴 THE MOST IMPORTANT TEST IN THIS CLASS ─────────────────────────────────
 * anAcquisitionDealDriverIsDeniedTheDispositionGate. The whole reason D15/Q1 rejected reusing
 * `Deal_Driver__c` is that it would merge two authorization boundaries — a sale driver could then
 * drive acquisitions and vice versa. Every other test here would pass just as happily against an
 * implementation that read `Deal_Driver__c`; that one would not.
 *
 * ── THE SECOND MOST IMPORTANT ───────────────────────────────────────────────
 * membershipWithoutTheFlagIsStillDenied. A user holding `Disposition_Deal_Driver` with
 * `Disposition_Driver__c = false` must be DENIED. A permission-set MEMBERSHIP check — the tidier
 * implementation, and the Lead gate's actual shape — would GRANT them, silently converting a
 * two-factor gate into a one-factor one for every holder.
 *
 * ── ⚠ WHAT AN ADMIN RUN CANNOT PROVE ────────────────────────────────────────
 * "Modify All Data" bypasses this gate entirely and BEFORE the flag is read, so the test-running
 * user passes unconditionally. Every meaningful assertion here therefore runs inside
 * System.runAs against a purpose-built user. The same caveat applies to UAT: an admin smoke test
 * of the disposition buttons proves nothing at all.
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
 * @author Salesforce Developer
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
            'A user with neither Modify All Data, nor the permission set, nor the flag must be '
            + 'denied. Both factors are unmet and the FLS read THROWS — which the service must '
            + 'convert to a denial, not propagate.');
    }

    /**
     * 🔴 MEMBERSHIP IS NOT THE FLAG. This user holds Disposition_Deal_Driver (so factor (a), the
     * FLS, is satisfied) and has Disposition_Driver__c = false. A membership-based gate would
     * grant them. This one must not.
     */
    @isTest
    static void membershipWithoutTheFlagIsStillDenied() {
        User holder = buildStandardUser('dap2');
        holder.Disposition_Driver__c = false;
        insertFixtureUser(holder);
        assignPermissionSet(holder.Id, DISPOSITION_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        DispositionActionPermissionService.clearCache();
        System.runAs(holder) {
            allowed = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Holding Disposition_Deal_Driver is NOT the same as being flagged a disposition '
            + 'driver. If this ever passes, someone replaced the two-factor condition with a '
            + 'permission-set membership check and silently widened a live authorization '
            + 'boundary for every holder of that set.');
    }

    /**
     * The mirror: the FLAG is set but the FLS is absent, so `WITH USER_MODE` makes the read throw
     * and factor (a) is unmet. Setting the flag true is the point — if USER_MODE ever stopped
     * enforcing FLS the read would succeed and return `true`, granting the actions to a user
     * holding no permission set at all.
     */
    @isTest
    static void flagSetWithoutFieldAccessIsDenied() {
        User flaggedButUnprovisioned = buildStandardUser('dap3');
        flaggedButUnprovisioned.Disposition_Driver__c = true;
        insertFixtureUser(flaggedButUnprovisioned);   // deliberately NO permission set

        Test.startTest();
        Boolean allowed;
        DispositionActionPermissionService.clearCache();
        System.runAs(flaggedButUnprovisioned) {
            allowed = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(allowed,
            'Without FLS read on User.Disposition_Driver__c the gate must deny even though the '
            + 'flag is TRUE — that is factor (a), enforced by WITH USER_MODE inside UserSelector');
    }

    /**
     * 🔴 THE BOUNDARY-SEPARATION TEST — the reason D15/Q1 rejected reusing Deal_Driver__c.
     *
     * A fully provisioned ACQUISITIONS deal driver (flag + permission set) must be DENIED the
     * disposition actions. Every other test in this class would pass unchanged against an
     * implementation that read `Deal_Driver__c`; this one is the falsifier.
     */
    @isTest
    static void anAcquisitionDealDriverIsDeniedTheDispositionGate() {
        User acquisitionDriver = buildStandardUser('dap4');
        acquisitionDriver.Deal_Driver__c = true;
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
            + 'different fields and different permission sets on purpose — merging them (or '
            + 'granting Deal_Driver__c to disposition users) would let a sale driver drive '
            + 'acquisitions and vice versa.');
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
        dispositionDriver.Disposition_Driver__c = true;
        insertFixtureUser(dispositionDriver);
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
            'BOTH factors satisfied — FLS via Disposition_Deal_Driver and the flag true — must '
            + 'grant. If this fails, the gate has no reachable true branch for anyone and the '
            + 'feature is dead for every non-administrator.');
    }

    /**
     * 🔴 THE ADMIN BYPASS, AND ITS ORDER. A System Administrator holding NEITHER the flag NOR the
     * permission set must still pass — because a Metadata-API-deployed custom field arrives with
     * no field permissions for ANY profile, and Modify All Data is an OBJECT permission that
     * confers no FLS. Reversing the two statements in computeDispositionActionAccess() would lock
     * every administrator out of the feature they just deployed. This test is the tripwire for
     * that ordering.
     */
    @isTest
    static void administratorPassesWithoutTheFlagOrThePermissionSet() {
        User bareAdmin = buildUserOnProfile('System Administrator', 'dap7');
        insert bareAdmin;   // no flag, no permission set

        Test.startTest();
        Boolean allowed;
        Boolean fieldAccessible;
        DispositionActionPermissionService.clearCache();
        System.runAs(bareAdmin) {
            fieldAccessible = Schema.SObjectType.User.fields.Disposition_Driver__c.isAccessible();
            allowed = DispositionActionPermissionService.hasDispositionActionAccess();
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isFalse(fieldAccessible,
            'PRECONDITION, and the whole reason the bypass must run FIRST: a System Administrator '
            + 'holding no permission set must NOT have FLS read on User.Disposition_Driver__c. If '
            + 'this fails, the field has been granted outside Disposition_Deal_Driver in this org '
            + '— which by itself weakens the gate to a single factor for those users.');
        Assert.isTrue(allowed,
            'Modify All Data must pass BEFORE the flag is read. An administrator can already '
            + 'change any stage through inline edit, the Path or the API, so denying them the '
            + 'button would be theatre — and here it would be a lockout, because the FLS read '
            + 'throws for them too.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // CACHING AND FAULTS
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void repeatedCallsReadTheUserOnlyOnce() {
        User dispositionDriver = buildStandardUser('dap8');
        dispositionDriver.Disposition_Driver__c = true;
        insertFixtureUser(dispositionDriver);
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

        Assert.areEqual(2, used,
            'At most TWO queries per transaction no matter how many quick actions ask — the '
            + 'PermissionSetAssignment read for the admin bypass and the UserSelector flag read. '
            + 'Neither the running user\'s FLS nor their flag can change mid-transaction, so the '
            + 'second and third calls must be served from the cache.');
    }

    @isTest
    static void clearCacheAfterAUserSwitchRecomputes() {
        User denied = buildStandardUser('dap9');
        insert denied;
        User granted = buildStandardUser('dap10');
        granted.Disposition_Driver__c = true;
        insertFixtureUser(granted);
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

    /**
     * Inserts a fixture User in EXPLICIT system mode.
     *
     * 🔴 MEASURED 2026-08-09 in check-only validation 0Afiw000000HEo9CAG, and it is not what a
     * reader expects: a bare `insert user` that SETS `User.Disposition_Driver__c` fails with
     * `System.DmlException: Operation failed due to fields being inaccessible on Sobject User`
     * when the running principal has no FLS on that field — even though ordinary Apex DML is
     * normally described as system mode. `User` is a setup object and a custom field deployed by
     * the Metadata API arrives carrying NO field permissions for ANY profile, System Administrator
     * included, so the deploying admin is exactly that principal on day one.
     *
     * The acquisitions twin (UserSelectorTest, Deal_Driver__c) does NOT hit this only because an
     * org-side grant on that field already exists — an asymmetry that lives in the org and not in
     * this repo, since profiles are `.forceignore`d.
     *
     * Declaring AccessLevel.SYSTEM_MODE states the intent the fixture actually has: these tests
     * are about the GATE, not about who may edit the flag. Whether an ADMIN can tick the checkbox
     * on a real User record is a separate, real question and is a deploy gate, not a test concern.
     */
    private static void insertFixtureUser(User fixture) {
        Database.insert(fixture, true, AccessLevel.SYSTEM_MODE);
    }

    /** Assigns a deployed permission set, by API Name, to a user. */
    private static void assignPermissionSet(Id assigneeId, String permissionSetName) {
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = assigneeId, PermissionSetId = permSetId);
    }

    /**
     * Builds (but does not insert) a bare Standard User. User is a setup object whose
     * required-field shape TestDataFactory deliberately does not cover, so this mirrors the helper
     * in OpportunityActionPermissionServiceTest / UserSelectorTest.
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
