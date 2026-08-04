/**
 * @description Tests RecordStageAdvanceController — the @AuraEnabled boundary for the generic
 * "advance stage" quick action on the five stage-controlled acquisitions child objects.
 *
 * The controller is thin, so these tests are about the BOUNDARY, not the stage maps (those are
 * pinned verbatim in RecordStageAdvanceServiceTest). Specifically they pin:
 *
 *   1. that advance() ASSERTS the permission before it writes — proven by a bare Standard User
 *      being refused AND the record being unchanged afterwards;
 *   2. the CATCH ORDER — a denial must surface the agreed denial wording, not the generic
 *      "could not be updated" message, which would send a user to refresh the page over a
 *      permissions problem;
 *   3. that a user-actionable service message (no next step / unsupported object / a surfaced
 *      validation-rule message) reaches the LWC VERBATIM, while an unexpected failure is masked.
 *
 * ⚠ The masked-failure tests deliberately assert only that an AuraHandledException was raised, not
 * its text: AuraHandledException.getMessage() is unreliable inside tests for the generic path, and
 * the two tests that DO assert wording (the denial and the no-next-step) are the ones where the
 * exact string is the product behaviour.
 *
 * No 251-record scenario applies — see the bulk note in RecordStageAdvanceServiceTest.
 *
 * @see force-app/main/default/classes/RecordStageAdvanceController.cls
 * @see force-app/main/default/classes/StageAdvanceControllerTest.cls (the Opportunity sibling)
 * @author Salesforce Developer
 */
@isTest
private class RecordStageAdvanceControllerTest {

    @TestSetup
    static void setupTestData() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        // OpportunityReviewService.ensureNda opens one NDA on every Opportunity insert; drop it so
        // "the NDA" is unambiguous.
        delete [SELECT Id FROM NDA__c WHERE Opportunity__c = :deal.Id];
        TestDataFactory.createNda(deal.Id, true);
        TestDataFactory.createLoi(deal.Id, true);
    }

    private static Id dealId() {
        return [SELECT Id FROM Opportunity LIMIT 1].Id;
    }

    private static LOI__c loi() {
        return [SELECT Id, Stage__c FROM LOI__c LIMIT 1];
    }

    private static NDA__c nda() {
        return [SELECT Id, Status__c FROM NDA__c LIMIT 1];
    }

    @isTest
    static void advanceMovesTheRecordAndReturnsTheConfirmation() {
        Id loiId = loi().Id;

        Test.startTest();
        String message = RecordStageAdvanceController.advance(loiId);
        Test.stopTest();

        Assert.areEqual('LOI moved to Prepare/Review.', message,
            'The confirmation naming the new stage is what the LWC toasts');
        Assert.areEqual('Prepare/Review', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'advance must actually write the derived stage');
    }

    @isTest
    static void noNextStepSurfacesItsMessageVerbatim() {
        // A terminal stage. The service's message is user-actionable, so the controller's typed
        // clause must carry it out unchanged rather than replacing it with the generic wording.
        NDA__c record = nda();
        record.Status__c = 'Signed';
        update record;

        Test.startTest();
        try {
            RecordStageAdvanceController.advance(record.Id);
            Assert.fail('A terminal stage has no next step');
        } catch (AuraHandledException e) {
            Assert.areEqual('There is no next step available from the Signed stage.', e.getMessage(),
                'A user-actionable service message must reach the LWC verbatim');
        }
        Test.stopTest();
    }

    @isTest
    static void unsupportedObjectSurfacesItsMessageVerbatim() {
        // An Opportunity belongs to StageAdvanceController, not this one.
        Id oppId = dealId();

        Test.startTest();
        try {
            RecordStageAdvanceController.advance(oppId);
            Assert.fail('An Opportunity is not stage-controlled by this controller');
        } catch (AuraHandledException e) {
            Assert.areEqual('This action is not available on this record.', e.getMessage(),
                'The unsupported-object message reaches the LWC verbatim');
        }
        Test.stopTest();
    }

    @isTest
    static void missingRecordIsMaskedByTheGenericCatch() {
        // A deleted Id makes the fetch-for-use selector throw System.QueryException, which is NOT
        // user-actionable and must land in the generic clause with a fixed message and a logged
        // stack — never with platform text concatenated into it.
        LOI__c record = loi();
        Id deletedId = record.Id;
        delete record;

        Test.startTest();
        try {
            RecordStageAdvanceController.advance(deletedId);
            Assert.fail('advance on a deleted record should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'An unexpected read failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    @isTest
    static void hasStageActionAccessAnswersTrueForAnAdmin() {
        Id loiId = loi().Id;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        Boolean allowed = RecordStageAdvanceController.hasStageActionAccess(loiId);
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        // ⚠ The test-running user holds Modify All Data, which the gate bypasses BEFORE reading
        // Deal_Driver__c. This asserts the plumbing, not the gate — an admin smoke test proves
        // nothing about authorization here. The refusal test below is the one that does.
        Assert.isTrue(allowed, 'An administrator passes the gate via the Modify All Data bypass');
    }

    @isTest
    static void hasStageActionAccessOnAnUnsupportedObjectSurfacesItsMessage() {
        Id oppId = dealId();

        Test.startTest();
        try {
            RecordStageAdvanceController.hasStageActionAccess(oppId);
            Assert.fail('The gate cannot be resolved for an object with no stage config');
        } catch (AuraHandledException e) {
            Assert.areEqual('This action is not available on this record.', e.getMessage(),
                'The unsupported-object message reaches the LWC verbatim from the cacheable check '
                + 'too');
        }
        Test.stopTest();
    }

    @isTest
    static void aFailureOfThePermissionMachineryIsMaskedNotReportedAsADenial() {
        // A fault in the permission lookup is NOT a denial signal. The service lets it propagate on
        // purpose; the controller masks it behind a fixed message and logs the stack. The LWC guard
        // treats a thrown check exactly like false, so the gate still fails CLOSED end to end — the
        // difference is only that a genuine fault reads as a fault rather than as "you lack
        // permission". simulateLookupFailure is the only deterministic way to reach that clause
        // (every user can read their own PermissionSetAssignment rows, so no runAs provokes it).
        Id loiId = loi().Id;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();     // clearCache() resets the flag, so it
        OpportunityActionPermissionService.simulateLookupFailure = true;   // must be set AFTER it
        try {
            RecordStageAdvanceController.hasStageActionAccess(loiId);
            Assert.fail('A permission-machinery fault must not be reported as a clean answer');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A lookup fault maps to a masked AuraHandledException');
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();
    }

    @isTest
    static void refusesAUserWhoIsNotADealDriverAndWritesNothing() {
        Id loiId = loi().Id;
        User bareUser = buildStandardUser('rsac');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bareUser;   // setup DML, isolated from the record DML in @TestSetup
        }

        Test.startTest();
        Boolean refused = false;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                RecordStageAdvanceController.advance(loiId);
                // Reached only if NO exception was raised, i.e. the assert did not run at all.
                // Failing HERE, by name, is the point: without it a missing gate lets the stage
                // write proceed and the test reds much later on whatever the downstream cascade
                // throws first, which reads like a selector or permission-set defect and sends the
                // reader hunting in the wrong class.
                Assert.fail('advance must REFUSE a non-deal-driver. It returned normally, so '
                    + 'RecordStageAdvanceService.assertStageActionAccess did not run');
            } catch (AuraHandledException e) {
                refused = true;
                Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE,
                    e.getMessage(),
                    'A denial must surface the agreed denial wording — NOT the generic '
                    + '"could not be updated" message, which would tell the user to refresh the '
                    + 'page over a permissions problem. This is what the catch ORDER buys');
            }
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The @AuraEnabled entry point must refuse a non-deal-driver');
        Assert.areEqual('Draft', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'A refused call must not write: the stage must still be Draft. A changed stage here '
            + 'would mean the assert ran AFTER the DML instead of before it');
    }

    /**
     * Builds (but does not insert) a bare Standard User for the permission-refusal test. User is a
     * setup object whose required-field shape TestDataFactory deliberately does not cover.
     */
    private static User buildStandardUser(String tag) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'RecStageCtl',
            Alias = 'rsct',
            Email = 'std.recstagectl@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
