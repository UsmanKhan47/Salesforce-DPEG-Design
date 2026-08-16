/**
 * Tests OpportunityDocStatusController.getDocStatus — the data behind the
 * Deal Summary card: NDA, LOI, Development/Construction review, and Contract review.
 */
@isTest
private class OpportunityDocStatusControllerTest {

    @isTest
    static void returnsAllDealArtifacts() {
        // Land deal that reaches PSA: the trigger spins off a
        // Development review (at Development Review) and a Contract review (at PSA).
        Opportunity opp = TestDataFactory.createOpportunity(null, false);
        opp.StageName = 'Development Review';
        insert opp;

        // The NDA and LOI are now prepared BEFORE the stage move, not after it: entering PSA
        // crosses the signed-NDA gate (which covers PSA) and the approved-LOI gate.
        //
        // Both helpers act on the record the controller actually reads. signPrimaryNda SIGNS the
        // Pending NDA that OpportunityReviewService.ensureNda auto-created and stamped onto
        // Primary_NDA__c, rather than inserting a rival; placeApprovedLoi's LOI is likewise
        // designated Primary_LOI__c, so this test mutates the LOI it hands back instead of
        // inserting a second one the controller would never look at.
        NDA__c nda = TestDataFactory.signPrimaryNda(opp);
        nda.Date_Sent__c = Date.today();
        nda.NDA_Expiry_Date__c = Date.today().addDays(365);
        update nda;

        LOI__c loi = TestDataFactory.placeApprovedLoi(opp);
        loi.LOI_Status__c = 'Submitted';
        loi.Offer_Price__c = 18000000;
        loi.Offer_Cap_Rate__c = 7;
        // Completed_LOI_Before_PSA (added 2026-08-12) gates PSA entry on the LOI's OWN Stage__c,
        // which placeApprovedLoi leaves at its factory-default 'Draft'. This class already writes
        // the LOI record directly (see above), so the LOI is driven to 'Signed' the same way
        // rather than introducing RecordStageAdvanceService here. LOI__c has no validation rules
        // (confirmed: no objects/LOI__c/validationRules folder), so the direct write is safe.
        // ⚠ 'Signed' since observation 5 (2026-08-14); it was 'Completed'.
        loi.Stage__c = 'Signed';
        update loi;

        opp.StageName = 'Under Contract (PSA)';
        update opp;

        Underwriting__c uw = TestDataFactory.createUnderwriting(opp.Id, false);
        uw.Stage__c = 'In Progress';
        uw.My_Price__c = 17000000;
        insert uw;

        Test.startTest();
        OpportunityDocStatusController.DocStatus d =
            OpportunityDocStatusController.getDocStatus(opp.Id);
        Test.stopTest();

        System.assert(d.hasNda, 'NDA should be found');
        System.assertEquals('Signed', d.ndaStatus);
        System.assert(d.hasLoi, 'LOI should be found');
        System.assertEquals('Submitted', d.loiStatus);
        System.assertEquals(18000000, d.loiOfferPrice);

        System.assert(d.hasUnderwriting, 'Underwriting should be found');
        System.assertEquals('In Progress', d.underwritingStage);
        System.assertEquals(17000000, d.underwritingPrice);

        System.assert(d.hasDevelopment, 'Development review should be found');
        System.assertEquals('Requested', d.developmentStage);
        System.assert(!d.hasConstruction, 'No Construction review for a Land deal');

        System.assert(d.hasContract, 'Contract review should be found');
        System.assertEquals('PSA Drafting', d.contractStage);
    }

    @isTest
    static void nullOpportunityReturnsEmpty() {
        Test.startTest();
        OpportunityDocStatusController.DocStatus d =
            OpportunityDocStatusController.getDocStatus(null);
        Test.stopTest();

        System.assert(!d.hasNda && !d.hasLoi && !d.hasUnderwriting && !d.hasDevelopment
            && !d.hasConstruction && !d.hasContract, 'Empty status for null opp');
    }

    // A bare Standard User with no DPEG perm sets: Standard User has Opportunity object
    // read but NO FLS on the custom Primary_NDA__c / Primary_LOI__c / Primary_Underwriting__c
    // fields, so selectPrimaryRefsById's WITH USER_MODE query throws — exercising the
    // read-failure catch that maps it to a user-safe AuraHandledException (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.docstatus.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    /**
     * Covers the read-failure catch on getDocStatus: under a bare Standard User,
     * WITH USER_MODE on Opportunity's custom Primary_* fields (no FLS) throws, and the
     * controller maps it to a user-safe AuraHandledException. Its own method because
     * bareUser() inserts a User (setup DML) and no record DML runs here — the query
     * throws before any — which avoids MIXED_DML_OPERATION. A fake (valid-format,
     * non-existent) Opportunity Id clears the null guard; USER_MODE throws on FLS
     * before any row match, so the Id need not resolve.
     */
    @isTest
    static void readCatchThrowsAuraHandledException() {
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try {
                OpportunityDocStatusController.getDocStatus(fakeId(Opportunity.SObjectType));
                Assert.fail('getDocStatus should throw under a bare user (no FLS on Primary_* fields)');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getDocStatus maps read failure to AuraHandledException');
            }
            Test.stopTest();
        }
    }
}
