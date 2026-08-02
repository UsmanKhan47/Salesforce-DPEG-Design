/**
 * Tests LeadActionPermissionController — the thin @AuraEnabled boundary the Lead quick actions call
 * to decide whether to run at all.
 *
 * The controller has three lines of its own (delegate / log / wrap) plus the shared `ahe` helper,
 * so this suite proves exactly three things:
 *   1. it returns the service's answer unchanged for a permitted user,
 *   2. it returns FALSE rather than throwing for an ordinary denial — the "not allowed" case must
 *      not force every caller into a catch block,
 *   3. an unexpected failure becomes an AuraHandledException carrying the fixed generic message,
 *      never raw platform text (ARCHITECTURE.md §5).
 *
 * (3) is reached through the service's documented test seam. Its real trigger is a setup-object
 * access failure under WITH USER_MODE, which cannot be provoked deterministically because
 * PermissionSetAssignment is readable by every user for their own rows — so, unlike the bare-user
 * recipe that covers most read catches in this repo, no user context makes this selector throw.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST ──────────────────────────────────────
 * The .claude/rules/bulk-test-rule.md 251-record mandate has nothing to act on here: the method
 * takes no parameters, performs no DML, and asks a single question about the running user. There is
 * no collection-shaped behavior at this layer. Same documented exemption as
 * LeadConvertActionControllerTest.
 *
 * @see force-app/main/default/classes/LeadActionPermissionController.cls
 * @see force-app/main/default/classes/LeadActionPermissionServiceTest.cls (the permission matrix)
 */
@isTest
private class LeadActionPermissionControllerTest {

    private static final String LEAD_ACTION_PERM_SET = 'Lead_Stage_Actions_Access';
    private static final String CHECK_FAILURE_MESSAGE =
        'Unable to verify your permissions. Please try again or contact your administrator.';

    @isTest
    static void hasLeadActionAccess_permittedUser_returnsTrue() {
        User grantedUser = buildStandardUser('lapcA');
        insert grantedUser;
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = :LEAD_ACTION_PERM_SET LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = grantedUser.Id, PermissionSetId = permSetId);

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(grantedUser) {
            allowed = LeadActionPermissionController.hasLeadActionAccess();
        }
        Test.stopTest();

        Assert.isTrue(allowed, 'The controller returns the service answer unchanged for a permitted user');
    }

    @isTest
    static void hasLeadActionAccess_deniedUser_returnsFalseInsteadOfThrowing() {
        User bareUser = buildStandardUser('lapcB');
        insert bareUser;

        Test.startTest();
        Boolean allowed;
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            // An ordinary denial is an ANSWER, not an error — it must not throw.
            allowed = LeadActionPermissionController.hasLeadActionAccess();
        }
        Test.stopTest();

        Assert.isFalse(allowed,
            'A denial is returned as false, not raised — throwing here would force every LWC caller to '
            + 'treat the normal "not allowed" case as an exception');
    }

    /**
     * Covers the generic catch tier: the failure is masked behind a fixed message and the real text
     * is only logged, so no platform internals reach the user (ARCHITECTURE.md §5).
     */
    @isTest
    static void hasLeadActionAccess_lookupFails_throwsAuraHandledExceptionWithTheMaskedMessage() {
        Test.startTest();
        LeadActionPermissionService.clearCache();
        LeadActionPermissionService.simulateLoadFailure = true;
        try {
            LeadActionPermissionController.hasLeadActionAccess();
            Assert.fail('Expected an AuraHandledException when the permission lookup fails');
        } catch (AuraHandledException e) {
            // ahe() explicitly calls setMessage(), so getMessage() must return the real masked
            // message here — NOT the generic "Script-thrown exception" fallback that occurs when
            // setMessage() is omitted.
            Assert.areEqual(CHECK_FAILURE_MESSAGE, e.getMessage(),
                'The user-visible message must be the fixed generic one, with no platform text interpolated');
        } finally {
            LeadActionPermissionService.clearCache();
        }
        Test.stopTest();
    }

    /**
     * Builds (but does not insert) a bare Standard User. Mirrors the repo's existing helper in
     * ContactSelectorTest / OpportunitySelectorTest.
     *
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildStandardUser(String tag) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'LeadPermCtl',
            Alias = 'lpctl',
            Email = 'std.leadpermctl@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
