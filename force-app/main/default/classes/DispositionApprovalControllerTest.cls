/**
 * @description Tests DispositionApprovalController — the thin @AuraEnabled wrapper over
 * DispositionApprovalService (design DEV-2). All business-logic branches (target derivation,
 * typed errors, the pending gate, selectOffer's savepoint) are DispositionApprovalServiceTest's
 * job; this class proves only the CONTROLLER's own contract: marshaling, and the three-catch
 * order (AccessDeniedException verbatim, ApprovalException verbatim, everything else masked).
 *
 * @see force-app/main/default/classes/DispositionApprovalController.cls
 * @see force-app/main/default/classes/DispositionApprovalServiceTest.cls (all business logic)
 * @author Unit Testing Agent
 */
@isTest
private class DispositionApprovalControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c dispositionAt(String recordType, String stage) {
        Disposition__c d = TestDataFactory.createDisposition(assetId(), recordType, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    /**
     * ⚠ THE ASKING PRICE IS SET EXPLICITLY (2026-08-22) AND IS NOT DECORATION. Since the
     * Disposition-Readiness gate landed in DispositionApprovalService, an unpriced fixture at
     * this stage is REFUSED — so this test would stop proving "the happy path returns the
     * confirmation" and start proving "the refusal is masked", silently, while still being
     * named for the former. The other two Readiness fixtures in this class stay unpriced
     * deliberately: the bare-user walk is denied before the read, and the deleted-Id walk
     * throws in the selector — both BEFORE the gate — so pricing them would weaken them.
     */
    @isTest
    static void submitForApproval_positiveScenario_returnsTheConfirmationMessage() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        d.Asking_Price__c = 2500000;
        update d;

        Test.startTest();
        String msg = DispositionApprovalController.submitForApproval(d.Id);
        Test.stopTest();

        System.assert(msg.contains('Sale Decision'), msg);
        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :d.Id AND Status = 'Pending']);
    }

    /**
     * 🔴 THE ApprovalException CATCH — verbatim, ordered SECOND. Deleting it would mask every
     * authored refusal in DispositionApprovalService behind the fixed generic message.
     */
    @isTest
    static void submitForApproval_userActionableRefusal_surfacesVerbatim() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Closing');
        // Wire_Verification_Completed__c left false.

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalController.submitForApproval(d.Id);
            Assert.fail('An incomplete wire must refuse the submit');
        } catch (AuraHandledException e) {
            refused = true;
            System.assert(e.getMessage().contains('Wire verification must be complete'),
                'The AUTHORED replacement for the platform error must reach the caller verbatim: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(refused);
    }

    /** A stage with no approval at all must still surface an AuraHandledException, not throw raw. */
    @isTest
    static void submitForApproval_noApprovalAtStage_surfacesAuraHandledException() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'NDA');

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalController.submitForApproval(d.Id);
            Assert.fail('NDA has no approval — the controller must still surface a user-safe refusal');
        } catch (AuraHandledException e) {
            refused = true;
            System.assert(e.getMessage().contains('No approval applies'), e.getMessage());
        }
        Test.stopTest();

        System.assert(refused);
    }

    @isTest
    static void selectOffer_positiveScenario_advancesAndReturnsConfirmation() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Active Listing');
        NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
        nda.Status__c = 'Signed';
        insert nda; // Offer Selection is gated by All_NDAs_Signed_Before_Progression
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);

        Test.startTest();
        String msg = DispositionApprovalController.selectOffer(d.Id, offer.Id);
        Test.stopTest();

        System.assert(msg.contains('selected'), msg);
        System.assertEquals('Offer Selection',
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c);
    }

    @isTest
    static void selectOffer_wrongStage_surfacesTheRefusalVerbatim() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Release Materials');
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalController.selectOffer(d.Id, offer.Id);
            Assert.fail('On-market Release Materials is the wrong stage for Select Offer');
        } catch (AuraHandledException e) {
            refused = true;
            System.assert(e.getMessage().contains('Active Listing'), e.getMessage());
        }
        Test.stopTest();

        System.assert(refused);
    }

    /**
     * 🔴 THE FIRST CATCH — permission denial, ordered ahead of the ApprovalException catch and
     * surfaced verbatim. Covers both @AuraEnabled entry points in one bare-user pass.
     */
    @isTest
    static void bothMethods_bareUser_areDeniedVerbatim() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);
        User bareUser = buildStandardUser('dact1');
        insert bareUser;

        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            Test.startTest();
            Boolean submitDenied = false;
            try {
                DispositionApprovalController.submitForApproval(d.Id);
                Assert.fail('A bare user must be denied on submitForApproval');
            } catch (AuraHandledException e) {
                submitDenied = true;
                System.assert(e.getMessage().contains('permission'), e.getMessage());
            }
            Boolean selectDenied = false;
            try {
                DispositionApprovalController.selectOffer(d.Id, offer.Id);
                Assert.fail('A bare user must be denied on selectOffer');
            } catch (AuraHandledException e) {
                selectDenied = true;
            }
            Test.stopTest();
            System.assert(submitDenied);
            System.assert(selectDenied);
        }
        DispositionActionPermissionService.clearCache();
    }

    /**
     * 🔴 THE THIRD CATCH — an unexpected platform failure (here: a deleted Disposition Id, which
     * makes the selector's single-row SOQL throw System.QueryException) must be MASKED behind the
     * fixed generic message, never leak the raw exception text.
     */
    @isTest
    static void submitForApproval_unexpectedFailure_isMaskedBehindTheGenericMessage() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalController.submitForApproval(deletedId);
            Assert.fail('A deleted Disposition Id must surface an AuraHandledException');
        } catch (AuraHandledException e) {
            refused = true;
            System.assert(e.getMessage().contains('could not be submitted'),
                'An unexpected failure must map to the fixed generic message, not leak the raw '
                + 'QueryException: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(refused);
    }

    @isTest
    static void selectOffer_unexpectedFailure_isMaskedBehindTheGenericMessage() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Active Listing');
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalController.selectOffer(deletedId, offer.Id);
            Assert.fail('A deleted Disposition Id must surface an AuraHandledException');
        } catch (AuraHandledException e) {
            refused = true;
            System.assert(e.getMessage().contains('offer could not be selected'),
                'An unexpected failure must map to the SELECT-OFFER-specific generic message: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(refused);
    }

    private static User buildStandardUser(String tag) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            Alias = tag.left(8),
            Email = tag + '@example.com.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Test ' + tag,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = tag + '.' + DateTime.now().getTime()
                + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid'
        );
    }
}
