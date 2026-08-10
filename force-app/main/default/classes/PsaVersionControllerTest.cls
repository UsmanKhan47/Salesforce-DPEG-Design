/**
 * Tests PsaVersionController (thinned in P6). The happy paths prove the delegated behaviour
 * is preserved end-to-end: version history and ball-in-court flips.
 *
 * 🔴 Negotiation_Status__c and the Stage__c it derives are asserted UNCHANGED. Logging a version
 * used to drive both (first seller version = Initial Draft; later versions = Seller/Buyer Counter
 * -> Stage 'Counter'). Those counter values were removed from the restricted picklist on
 * 2026-08-05 and the status is now moved ONLY by the deal driver via Advance Stage, so this
 * asserts the version log stays out of it end-to-end, not just in the service.
 *
 * P6 controller thinning: saveVersion's DML + rules now live in PsaVersionService, and every
 * @AuraEnabled method wraps its work in a try/catch that maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). The negative tests below
 * therefore now expect an AuraHandledException; readCatchThrowsAuraHandledException covers
 * getVersions' read catch via a bare Standard User whose WITH USER_MODE SOQL on the custom
 * PSA_Version__c object throws, and writeFailureThrowsAuraHandledException covers
 * saveVersion's generic write catch via a deleted parent Contract Review Id (the child
 * insert fails INVALID_CROSS_REFERENCE_KEY).
 */
@isTest
private class PsaVersionControllerTest {

    private static Contract_Review__c newContract() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        return TestDataFactory.createContractReview(o.Id, true); // Stage__c 'PSA Drafting'
    }

    // A valid-format but non-existent Id for the given type. The bare-user read throws on
    // object ACCESS under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL on the custom
    // PSA_Version__c object (no object access) throws, exercising the controller's
    // read-failure catch which maps it to a user-safe AuraHandledException (P6).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    @isTest
    static void sellerFirstVersionIsInitialDraft() {
        Contract_Review__c cr = newContract();

        Test.startTest();
        PsaVersionController.saveVersion(cr.Id, 'Seller', Date.today(), 'First draft from seller counsel',
            'https://onedrive.example/psa-v1');
        Test.stopTest();

        List<PSA_Version__c> versions = PsaVersionController.getVersions(cr.Id);
        System.assertEquals(1, versions.size(), 'Version logged');
        System.assertEquals('Seller', versions[0].Direction__c, 'Direction captured');

        cr = [SELECT Ball_In_Court__c, Negotiation_Status__c, Latest_Version__c, Stage__c
              FROM Contract_Review__c WHERE Id = :cr.Id];
        System.assertEquals('Us', cr.Ball_In_Court__c, 'Seller draft puts the ball in OUR court');
        System.assertEquals('Initial Draft', cr.Negotiation_Status__c,
            'Logging a version must NOT touch the status — untouched picklist default');
        System.assertEquals(1, cr.Latest_Version__c, 'Version counter maintained');
        System.assertEquals('PSA Drafting', cr.Stage__c, 'Stage synced from negotiation status');
    }

    @isTest
    static void backAndForthFlipsBallAndLeavesStageAlone() {
        Contract_Review__c cr = newContract();
        PsaVersionController.saveVersion(cr.Id, 'Seller', null, 'v1', null);

        Test.startTest();
        PsaVersionController.saveVersion(cr.Id, 'Ours', null, 'our redline', null);
        Test.stopTest();

        cr = [SELECT Ball_In_Court__c, Negotiation_Status__c, Latest_Version__c, Stage__c
              FROM Contract_Review__c WHERE Id = :cr.Id];
        System.assertEquals('Seller', cr.Ball_In_Court__c, 'Our redline puts the ball in the seller court');
        System.assertEquals('Initial Draft', cr.Negotiation_Status__c,
            'Our redline must NOT move the status — this branch used to write Buyer Counter');
        System.assertEquals(2, cr.Latest_Version__c, 'Two versions tracked');
        System.assertEquals('PSA Drafting', cr.Stage__c,
            'and so the derived Stage must not move either — it used to sync to the removed Counter stage');
        System.assertEquals(2, PsaVersionController.getVersions(cr.Id).size(), 'Full history preserved');
    }

    @isTest
    static void nullContractReturnsEmptyHistory() {
        System.assertEquals(0, PsaVersionController.getVersions(null).size(), 'Null contract = empty history');
    }

    @isTest
    static void nullContractAndBadDirectionThrowAuraHandledException() {
        // P6: the service's PsaVersionException is now caught in the controller and
        // re-thrown as a user-safe AuraHandledException at the LWC boundary.
        try {
            PsaVersionController.saveVersion(null, 'Seller', null, 'x', null);
            Assert.fail('Saving with no contract should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'no-Contract-Review rule violation maps to AuraHandledException');
        }

        Contract_Review__c cr = newContract();
        try {
            PsaVersionController.saveVersion(cr.Id, 'Nobody', null, 'x', null);
            Assert.fail('An unknown direction should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'bad-direction rule violation maps to AuraHandledException');
        }
    }

    // Covers saveVersion's generic (non-PsaVersionException) catch with a deleted parent Contract
    // Review Id, under admin — the deterministic way to reach it without a bare user. Kept apart
    // from the bare-user read test to avoid MIXED_DML_OPERATION.
    //
    // ⚠ WHICH EXCEPTION REACHES THE CATCH CHANGED ON 2026-08-10, THE ASSERTION DID NOT. It used to
    // be the child PSA_Version__c insert failing with INVALID_CROSS_REFERENCE_KEY; PsaVersionService
    // now LOADS the parent first (it derives the Seller/Buyer counterparty label from the parent's
    // record type), so a deleted Id raises System.QueryException one step earlier. Both are caught
    // by the same `catch (Exception e)` and both produce the same fixed WRITE_FAILURE_MESSAGE, so
    // the branch and the user-visible wording are unchanged — only the route in.
    @isTest
    static void writeFailureThrowsAuraHandledException() {
        Contract_Review__c cr = newContract();
        Id deletedCrId = cr.Id;
        delete cr;

        Test.startTest();
        try {
            PsaVersionController.saveVersion(deletedCrId, 'Seller', Date.today(), 'x', null);
            Assert.fail('Saving a version under a deleted Contract Review should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'save failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    // Covers getVersions' read catch: WITH USER_MODE on the custom PSA_Version__c object
    // throws for a bare Standard User (no object access). A non-null fake Contract Review Id
    // is passed so the selector's null guard does not short-circuit before the query. Its own
    // method to avoid MIXED_DML_OPERATION with the setup-object User insert.
    @isTest
    static void readCatchThrowsAuraHandledException() {
        User u = bareUser();
        Id fakeCrId = fakeId(Contract_Review__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try {
                PsaVersionController.getVersions(fakeCrId);
                Assert.fail('expected AuraHandledException from getVersions under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getVersions read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
    }
}
