/**
 * Tests OpportunityActionPermissionController — the thin @AuraEnabled boundary the Opportunity
 * quick-action bundles call through c/dealActionGuard.
 *
 * ⚠ NAME: `Ctrl`, not `Controller`. Apex identifiers are capped at 40 characters and
 * `OpportunityActionPermissionControllerTest` is 41 — the platform rejects it outright with
 * "Identifier name is too long", which is a DEPLOY-TIME failure, not a style warning. Do not
 * "restore" the conventional `<Class>Test` name; the class under test (37 chars) is fine, only its
 * test name overflows.
 *
 * The controller holds no logic, so this suite covers exactly the three things a boundary owes its
 * caller:
 *   1. it returns the service's answer unchanged (both true and false);
 *   2. an unexpected failure of the lookup becomes an AuraHandledException carrying a MASKED
 *      message — no platform text, no stack trace, nothing about the org's security model;
 *   3. an ordinary denial does NOT throw (it returns false), so callers are not forced into a catch
 *      block for the everyday "not allowed" case.
 *
 * Point 2 is reachable only through the service's documented `simulateLookupFailure` seam: the real
 * trigger is a setup-object access failure under WITH USER_MODE, which cannot be provoked
 * deterministically because every user can read their own PermissionSetAssignment rows. Without the
 * seam this class would sit near 50% on an uncoverable branch.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST ──────────────────────────────────────
 * Per .claude/rules/bulk-test-rule.md the mandate applies to record-collection DML. This method
 * takes no parameters, performs no DML, and answers a question about the single running user.
 *
 * ── SETUP-DML ISOLATION ───────────────────────────────────────────────────────
 * Only setup objects (User, PermissionSet, PermissionSetAssignment) are written, so
 * MIXED_DML_OPERATION cannot arise.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionController.cls
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (all logic)
 */
@isTest
private class OpportunityActionPermissionCtrlTest {

    private static final String DEAL_DRIVER_PERM_SET = 'Acquisition_Deal_Driver';
    private static final String CHECK_FAILURE_MESSAGE =
        'Unable to verify your permissions. Please try again or contact your administrator.';
    private static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    /**
     * The permitted path: a provisioned deal driver gets `true` straight through.
     *
     * ⚠ SIMPLIFIED 2026-08-12 (custom-permission migration): the fixture used to also set
     * `Deal_Driver__c = true` — that flag no longer governs access at all, so assigning the
     * permission set is now the whole grant. See OpportunityActionPermissionServiceTest's header.
     */
    @isTest
    static void hasDealActionAccess_provisionedDealDriver_returnsTrue() {
        User dealDriver = buildStandardUser('oapcA');
        insert dealDriver;
        assignPermissionSet(dealDriver.Id, DEAL_DRIVER_PERM_SET);

        Test.startTest();
        Boolean allowed;
        OpportunityActionPermissionService.clearCache();
        System.runAs(dealDriver) {
            allowed = OpportunityActionPermissionController.hasDealActionAccess();
        }
        Test.stopTest();

        Assert.isTrue(allowed, 'The controller must return the service answer unchanged for a deal driver');
    }

    /**
     * The denial path. The critical property is that it RETURNS rather than THROWS: the LWC renders
     * its own denial toast from a `false`, and turning the ordinary case into an exception would make
     * every caller wrap a routine answer in a try/catch.
     */
    @isTest
    static void hasDealActionAccess_bareStandardUser_returnsFalseWithoutThrowing() {
        User bareUser = buildStandardUser('oapcB');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        Boolean threw = false;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                allowed = OpportunityActionPermissionController.hasDealActionAccess();
            } catch (Exception e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isFalse(threw,
            'A plain denial must NOT throw — it is a question with a "no" answer, not an error. The '
            + 'throwing variant is assertDealActionAccess on the service');
        Assert.isFalse(allowed, 'A user who is not a deal driver must get false');
    }

    /**
     * The masked-failure branch. Asserts the exact message, because the point of the branch is that
     * the user sees THIS text and not the underlying platform error — and that the denial wording is
     * not reused, since a broken check is not the same thing as a refused one.
     */
    @isTest
    static void hasDealActionAccess_whenTheLookupFails_throwsAMaskedAuraHandledException() {
        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        OpportunityActionPermissionService.simulateLookupFailure = true;
        try {
            OpportunityActionPermissionController.hasDealActionAccess();
            Assert.fail('A failed permission lookup must surface as an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(CHECK_FAILURE_MESSAGE, e.getMessage(),
                'The user must see the fixed generic message — never raw platform/query text, which would '
                + 'leak implementation detail about the org\'s security model');
            Assert.areNotEqual(NO_PERMISSION_MESSAGE, e.getMessage(),
                'A broken check must not masquerade as a denial: telling the user they lack permission '
                + 'when the check itself failed sends them to the wrong administrator conversation');
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();
    }

    /**
     * The test-running admin (Modify All Data) passes, which is what keeps every existing
     * Opportunity quick-action test green now that the controllers assert this permission.
     */
    @isTest
    static void hasDealActionAccess_testRunningAdministrator_returnsTrue() {
        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        Boolean allowed = OpportunityActionPermissionController.hasDealActionAccess();
        Test.stopTest();

        Assert.isTrue(allowed,
            'The test-running administrator holds Modify All Data and must pass the gate — this is the '
            + 'documented bypass the existing StageAdvanceController tests rely on');
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
     * LeadActionPermissionServiceTest / OpportunityActionPermissionServiceTest.
     *
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildStandardUser(String tag) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'DealPermCtl',
            Alias = 'dpctl',
            Email = 'std.dealpermctl@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
