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
 * Two-tier catch coverage: convertLead_alreadyConvertedLead_throwsAuraHandledExceptionWithRealMessage
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
}
