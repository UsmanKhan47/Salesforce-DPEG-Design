/**
 * @description Tests PsaVersionService — the PSA version-log append + parent-derivation
 * workflow extracted from PsaVersionController in P6 controller thinning.
 *
 * Covers the Negotiation_Status__c derivation on every branch (first seller version =
 * Initial Draft; a later seller version = Seller Counter; our version = Buyer Counter), the
 * Ball_In_Court__c flip, the Latest_Version__c bump, the null-date default, and both
 * business-rule violations (null Contract Review, unrecognised direction) which throw the
 * typed PsaVersionException. The service does two DML statements with no explicit Savepoint
 * (transaction-level rollback on an unhandled exception) and no collection DML, so there is
 * no rollback catch to force and no 251-record bulk scenario applies (saveVersion is a
 * single-record @AuraEnabled operation invoked once per LWC save).
 *
 * @see force-app/main/default/classes/PsaVersionService.cls
 * @author Salesforce Developer
 */
@isTest
private class PsaVersionServiceTest {

    private static Contract_Review__c newContract() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        return TestDataFactory.createContractReview(o.Id, true); // Stage__c 'PSA Drafting'
    }

    @isTest
    static void sellerFirstVersionIsInitialDraftAndFlipsBallToUs() {
        Contract_Review__c cr = newContract();

        Test.startTest();
        PsaVersionService.saveVersion(cr.Id, 'Seller', null, 'First draft from seller counsel',
            'https://onedrive.example/psa-v1');
        Test.stopTest();

        List<PSA_Version__c> versions = PsaVersionSelector.selectByContractReviewId(cr.Id);
        Assert.areEqual(1, versions.size(), 'Version logged');
        Assert.areEqual('Seller', versions[0].Direction__c, 'Direction captured');
        Assert.areEqual(Date.today(), versions[0].Version_Date__c, 'Null version date defaults to today');

        cr = [SELECT Ball_In_Court__c, Negotiation_Status__c, Latest_Version__c
              FROM Contract_Review__c WHERE Id = :cr.Id];
        Assert.areEqual('Us', cr.Ball_In_Court__c, 'Seller draft puts the ball in OUR court');
        Assert.areEqual('Initial Draft', cr.Negotiation_Status__c, 'Seller drafts first (Section 15)');
        Assert.areEqual(1, cr.Latest_Version__c, 'Version counter maintained');
    }

    @isTest
    static void ourCounterAfterSellerIsBuyerCounterAndFlipsBallToSeller() {
        Contract_Review__c cr = newContract();
        PsaVersionService.saveVersion(cr.Id, 'Seller', Date.today(), 'v1', null);

        Test.startTest();
        PsaVersionService.saveVersion(cr.Id, 'Ours', Date.today(), 'our redline', null);
        Test.stopTest();

        cr = [SELECT Ball_In_Court__c, Negotiation_Status__c, Latest_Version__c
              FROM Contract_Review__c WHERE Id = :cr.Id];
        Assert.areEqual('Seller', cr.Ball_In_Court__c, 'Our redline puts the ball in the seller court');
        Assert.areEqual('Buyer Counter', cr.Negotiation_Status__c, 'Our version = Buyer Counter');
        Assert.areEqual(2, cr.Latest_Version__c, 'Two versions tracked');
        Assert.areEqual(2, PsaVersionSelector.selectByContractReviewId(cr.Id).size(), 'Full history preserved');
    }

    @isTest
    static void sellerCounterAfterFirstVersionIsSellerCounter() {
        Contract_Review__c cr = newContract();
        // First version is ours, so the second seller version is NOT the Initial Draft branch.
        PsaVersionService.saveVersion(cr.Id, 'Ours', Date.today(), 'our opener', null);

        Test.startTest();
        PsaVersionService.saveVersion(cr.Id, 'Seller', Date.today(), 'seller redline', null);
        Test.stopTest();

        cr = [SELECT Ball_In_Court__c, Negotiation_Status__c, Latest_Version__c
              FROM Contract_Review__c WHERE Id = :cr.Id];
        Assert.areEqual('Us', cr.Ball_In_Court__c, 'A seller version puts the ball in OUR court');
        Assert.areEqual('Seller Counter', cr.Negotiation_Status__c,
            'A seller version after the first is a Seller Counter, not the Initial Draft');
        Assert.areEqual(2, cr.Latest_Version__c, 'Version counter bumped');
    }

    @isTest
    static void nullContractThrowsPsaVersionException() {
        Test.startTest();
        try {
            PsaVersionService.saveVersion(null, 'Seller', null, 'x', null);
            Assert.fail('Saving with no Contract Review should throw PsaVersionException');
        } catch (PsaVersionService.PsaVersionException e) {
            Assert.isNotNull(e.getMessage(), 'The no-Contract-Review rule violation carries a user-safe message');
        }
        Test.stopTest();
    }

    @isTest
    static void unknownDirectionThrowsPsaVersionException() {
        Contract_Review__c cr = newContract();

        Test.startTest();
        try {
            PsaVersionService.saveVersion(cr.Id, 'Nobody', null, 'x', null);
            Assert.fail('An unknown direction should throw PsaVersionException');
        } catch (PsaVersionService.PsaVersionException e) {
            Assert.isNotNull(e.getMessage(), 'The bad-direction rule violation carries a user-safe message');
        }
        Test.stopTest();
    }
}
