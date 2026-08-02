/**
 * Tests LeadConvertActionController — the thin @AuraEnabled boundary for the
 * Lead record page's "Convert" button (leadStageActions LWC). Both scenarios
 * drive a REAL Database.convertLead through LeadConvertActionService (no
 * mocking — Database.convertLead cannot be mocked; see
 * LeadConvertActionServiceTest for the service-level collection/edge-case
 * coverage). This class only needs to prove the controller's own two lines:
 * the happy-path unwrap of index [0], and the catch -> ahe() ->
 * AuraHandledException mapping.
 *
 * Three-tier catch coverage. convertLead_userWithoutPermission_throwsAuraHandledExceptionWithDenial
 * exercises the `catch (LeadActionPermissionService.AccessDeniedException e)` tier — the server-side
 * authorization gate added so the irreversible Convert cannot be driven by calling the Apex
 * directly, bypassing the LWC's client-side check.
 * convertLead_alreadyConvertedLead_throwsAuraHandledExceptionWithRealMessage
 * exercises the `catch (DmlException e)` tier — Database.convertLead throws a System.DmlException on
 * an already-converted Lead, whose verbatim message the controller surfaces. The generic
 * `catch (Exception e)` tier (masked CONVERT_FAILURE_MESSAGE + logged stack) is an accepted
 * defensive branch: it is only reachable by a non-DmlException thrown deep in the trigger-driven
 * LeadConvertService, which cannot be provoked deterministically from a test without breaking the
 * trigger — so it is documented here rather than covered by a contrived, unreachable test (repo
 * precedent: StageAdvanceControllerTest reaches its generic tier via a deleted-Id QueryException;
 * this controller has no selector read to make throw that way).
 *
 * setDoNotCreateOpportunity(true) is never used here — see
 * LeadConvertActionServiceTest for why.
 *
 * The bulk-test-rule.md 251-record mandate does not apply to this controller:
 * its @AuraEnabled signature accepts a single Id (one user click converts one
 * Lead at a time — there is no way to invoke it 251 times in one transaction
 * from the UI), and LeadConvertActionServiceTest already documents why the
 * underlying service cannot be driven with 251 Ids in a single call. There is
 * no collection-shaped behavior at this layer to bulk-test.
 *
 * @see force-app/main/default/classes/LeadConvertActionController.cls
 * @see force-app/main/default/classes/LeadConvertActionServiceTest.cls
 */
@isTest
private class LeadConvertActionControllerTest {

    /** See LeadConvertActionServiceTest for why no TestDataFactory changes were needed. */
    private static Lead buildConvertibleLead(String dealType, String company) {
        Lead l = TestDataFactory.createLead(false);
        l.Company = company;
        l.Deal_Type__c = dealType;
        return l;
    }

    @isTest
    static void convertLead_validLead_returnsOpportunityId() {
        // Arrange
        Lead l = buildConvertibleLead('Commercial', 'Controller Convert LLC');
        insert l;

        // Act
        Test.startTest();
        Id opportunityId = LeadConvertActionController.convertLead(l.Id);
        Test.stopTest();

        // Assert — the controller returns the same Id the conversion actually produced
        Assert.isNotNull(opportunityId, 'convertLead should return the new Opportunity Id');
        Lead converted = [SELECT IsConverted, ConvertedOpportunityId FROM Lead WHERE Id = :l.Id];
        Assert.isTrue(converted.IsConverted, 'The Lead should be converted');
        Assert.areEqual(opportunityId, converted.ConvertedOpportunityId,
            'The returned Id should match the Lead\'s ConvertedOpportunityId');

        // Assert — the downstream cascade ran through the controller path too
        Opportunity opp = [SELECT Property__c, Deal_Type__c FROM Opportunity WHERE Id = :opportunityId];
        Assert.isNotNull(opp.Property__c, 'The conversion cascade should create and link a Property');
        Assert.areEqual('Commercial', opp.Deal_Type__c, 'Deal Type should carry to the Opportunity');
    }

    // Covers the `catch (DmlException e)` tier: a second convert of an already-converted Lead makes
    // Database.convertLead throw a System.DmlException, which the controller surfaces verbatim.
    @isTest
    static void convertLead_alreadyConvertedLead_throwsAuraHandledExceptionWithRealMessage() {
        // Arrange — convert once so the second attempt is guaranteed to fail.
        Lead l = buildConvertibleLead('Land', 'Double Convert LLC');
        insert l;
        LeadConvertActionController.convertLead(l.Id);

        // Act & Assert
        Test.startTest();
        try {
            LeadConvertActionController.convertLead(l.Id);
            Assert.fail('Expected an AuraHandledException when converting an already-converted Lead');
        } catch (AuraHandledException e) {
            // ahe() explicitly calls setMessage(), so getMessage() must return the real
            // underlying failure text here — NOT the generic "Script-thrown exception"
            // fallback that occurs elsewhere in this codebase when setMessage() is omitted.
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'The AuraHandledException should carry a message');
            Assert.areNotEqual('Script-thrown exception', e.getMessage(),
                'ahe() must call setMessage() so getMessage() returns the real error, not the generic fallback');
        }
        Test.stopTest();
    }

    /**
     * Covers the `catch (LeadActionPermissionService.AccessDeniedException e)` tier: a user without
     * either Lead permission set is refused BEFORE Database.convertLead runs, and the Lead is left
     * untouched.
     *
     * This is the test that proves the gate is real enforcement rather than UI decoration — it calls
     * the Apex directly, exactly as a caller bypassing the LWC would.
     *
     * MIXED_DML: the Lead (non-setup) is inserted first, then the User (setup) inside its own
     * System.runAs block — the repo's standard isolation (see ContactSelectorTest).
     */
    @isTest
    static void convertLead_userWithoutPermission_throwsAuraHandledExceptionWithDenial() {
        // Arrange — a convertible Lead, and a Standard User holding neither Lead permission set.
        Lead l = buildConvertibleLead('Commercial', 'Denied Convert LLC');
        insert l;

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'lcacden' + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User bareUser = new User(
            FirstName = 'Std',
            LastName = 'ConvertDenied',
            Alias = 'cvden',
            Email = 'std.convertdenied@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bareUser;
        }

        // Act & Assert
        Test.startTest();
        LeadActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                LeadConvertActionController.convertLead(l.Id);
                Assert.fail('Expected an AuraHandledException for a user without the Lead action permission sets');
            } catch (AuraHandledException e) {
                Assert.areEqual('You don\'t have permission to perform this action.', e.getMessage(),
                    'The denial message is surfaced verbatim and must match the one the LWC shows, so the user '
                    + 'never sees two different phrasings for the same condition');
            }
        }
        Test.stopTest();

        // Assert — the gate ran BEFORE any conversion work.
        Lead untouched = [SELECT IsConverted FROM Lead WHERE Id = :l.Id];
        Assert.isFalse(untouched.IsConverted,
            'A denied call must not convert the Lead — the assertion runs before Database.convertLead');
    }

    /**
     * Covers the generic `catch (Exception e)` tier — masked CONVERT_FAILURE_MESSAGE, stack logged.
     *
     * The class header above records this branch as an accepted, uncoverable gap: it was previously
     * reachable only via a non-DmlException thrown deep in the trigger-driven LeadConvertService,
     * which cannot be provoked without breaking the trigger. Adding the server-side permission gate
     * changed that. The gate's lookup can fail with a QueryException, which is neither
     * AccessDeniedException nor DmlException, so it falls through both typed tiers into the generic
     * one — a real failure mode of the method as it now stands, driven here through the permission
     * service's documented test seam.
     */
    @isTest
    static void convertLead_unexpectedFailure_throwsAuraHandledExceptionWithTheMaskedMessage() {
        Lead l = buildConvertibleLead('Land', 'Masked Failure LLC');
        insert l;

        Test.startTest();
        LeadActionPermissionService.clearCache();
        LeadActionPermissionService.simulateLoadFailure = true;
        try {
            LeadConvertActionController.convertLead(l.Id);
            Assert.fail('Expected an AuraHandledException when the permission lookup fails unexpectedly');
        } catch (AuraHandledException e) {
            Assert.areEqual(
                'Unable to convert this lead. Please try again or contact your administrator.',
                e.getMessage(),
                'An unexpected/system error must surface the FIXED generic message with no platform text '
                + 'interpolated into it (ARCHITECTURE.md §5)');
        } finally {
            LeadActionPermissionService.clearCache();
        }
        Test.stopTest();

        Lead untouched = [SELECT IsConverted FROM Lead WHERE Id = :l.Id];
        Assert.isFalse(untouched.IsConverted, 'A failed gate must leave the Lead unconverted');
    }
}
