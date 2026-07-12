/**
 * Tests PsaVersionController: version history, ball-in-court flips, and the
 * Negotiation Status derivation (first seller version = Initial Draft).
 */
@isTest
private class PsaVersionControllerTest {

    private static Contract_Review__c newContract() {
        Opportunity o = new Opportunity(
            Name = 'PSA Test', StageName = 'LOI', CloseDate = Date.today().addDays(30)
        );
        insert o;
        Contract_Review__c cr = new Contract_Review__c(Opportunity__c = o.Id, Stage__c = 'PSA Drafting');
        insert cr;
        return cr;
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
        System.assertEquals('Initial Draft', cr.Negotiation_Status__c, 'Seller drafts first (Section 15)');
        System.assertEquals(1, cr.Latest_Version__c, 'Version counter maintained');
        System.assertEquals('PSA Drafting', cr.Stage__c, 'Stage synced from negotiation status');
    }

    @isTest
    static void backAndForthDerivesCountersAndFlipsBall() {
        Contract_Review__c cr = newContract();
        PsaVersionController.saveVersion(cr.Id, 'Seller', null, 'v1', null);

        Test.startTest();
        PsaVersionController.saveVersion(cr.Id, 'Ours', null, 'our redline', null);
        Test.stopTest();

        cr = [SELECT Ball_In_Court__c, Negotiation_Status__c, Latest_Version__c, Stage__c
              FROM Contract_Review__c WHERE Id = :cr.Id];
        System.assertEquals('Seller', cr.Ball_In_Court__c, 'Our redline puts the ball in the seller court');
        System.assertEquals('Buyer Counter', cr.Negotiation_Status__c, 'Our version = Buyer Counter');
        System.assertEquals(2, cr.Latest_Version__c, 'Two versions tracked');
        System.assertEquals('Counter', cr.Stage__c, 'Buyer/Seller Counter status syncs to the Counter stage');
        System.assertEquals(2, PsaVersionController.getVersions(cr.Id).size(), 'Full history preserved');
    }

    @isTest
    static void nullContractAndBadDirectionAreHandled() {
        System.assertEquals(0, PsaVersionController.getVersions(null).size(), 'Null contract = empty history');

        Boolean threwNull = false;
        try {
            PsaVersionController.saveVersion(null, 'Seller', null, 'x', null);
        } catch (Exception e) {
            threwNull = true;
        }
        System.assert(threwNull, 'Saving with no contract should throw');

        Contract_Review__c cr = newContract();
        Boolean threwDir = false;
        try {
            PsaVersionController.saveVersion(cr.Id, 'Nobody', null, 'x', null);
        } catch (Exception e) {
            threwDir = true;
        }
        System.assert(threwDir, 'An unknown direction should throw');
    }
}