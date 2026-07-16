/**
 * Tests for PsaVersionSelector. Covers selectByContractReviewId (found ordered /
 * 251-bulk / null-input) and countByContractReviewId (count / null-input).
 * Factory-based per ARCHITECTURE.md §2; 251-record bulk per
 * .claude/rules/bulk-test-rule.md.
 */
@isTest
private class PsaVersionSelectorTest {

    private static final Integer BULK_N = 251;

    private static Contract_Review__c freshContractReview() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        return TestDataFactory.createContractReview(opp.Id, true);
    }

    @isTest
    static void selectByContractReviewId_returnsVersionsWithFields() {
        Contract_Review__c cr = freshContractReview();
        TestDataFactory.createPsaVersions(3, cr.Id, true);

        Test.startTest();
        List<PSA_Version__c> result = PsaVersionSelector.selectByContractReviewId(cr.Id);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'Should return every PSA version for the Contract Review');
        Assert.isNotNull(result[0].Direction__c, 'Direction__c must be populated for the psaVersionLog LWC');
        Assert.isNotNull(result[0].Version_Date__c, 'Version_Date__c must be populated for the psaVersionLog LWC');
    }

    @isTest
    static void selectByContractReviewId_bulk_returnsAll() {
        Contract_Review__c cr = freshContractReview();
        TestDataFactory.createPsaVersions(BULK_N, cr.Id, true);

        Test.startTest();
        List<PSA_Version__c> result = PsaVersionSelector.selectByContractReviewId(cr.Id);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 PSA versions for the Contract Review');
    }

    @isTest
    static void selectByContractReviewId_nullInput_returnsEmpty() {
        Test.startTest();
        List<PSA_Version__c> result = PsaVersionSelector.selectByContractReviewId(null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null input returns an empty list, not null');
    }

    @isTest
    static void countByContractReviewId_returnsCount() {
        Contract_Review__c cr = freshContractReview();
        TestDataFactory.createPsaVersions(4, cr.Id, true);

        Test.startTest();
        Integer count = PsaVersionSelector.countByContractReviewId(cr.Id);
        Test.stopTest();

        Assert.areEqual(4, count, 'Count must match the number of PSA versions logged');
    }

    @isTest
    static void countByContractReviewId_nullInput_returnsZero() {
        Test.startTest();
        Integer count = PsaVersionSelector.countByContractReviewId(null);
        Test.stopTest();

        Assert.areEqual(0, count, 'Null input returns 0');
    }
}
