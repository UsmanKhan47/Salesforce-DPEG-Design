/**
 * @description Tests RecordStageAdvanceController — the @AuraEnabled boundary for the generic
 * "advance stage" quick action on the SIX stage-controlled child objects. ⚠ "five acquisitions
 * child objects" is what this said until 2026-08-09; Contract_Review__c joined earlier, and since
 * Tranches 3A/3B both NDA__c and LOI__c also serve the DISPOSITION module through their second
 * record type, which answers to a different persona.
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
        // ⚠ Added in Tranche 3B. Underwriting__c is the only stage-controlled object left whose
        // permission gate is knowable from the Id ALONE (one configured sequence, so gateFor()
        // short-circuits and reads nothing). NDA__c and LOI__c now both LOAD the row to pick their
        // record type's gate, which a bare Standard User cannot do on an OWD-Private object — see
        // the note on refusesAUserWhoIsNotADealDriverAndWritesNothing.
        TestDataFactory.createUnderwriting(deal.Id, true);
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

    private static Underwriting__c underwriting() {
        return [SELECT Id, Stage__c FROM Underwriting__c LIMIT 1];
    }

    @isTest
    static void advanceMovesTheRecordAndReturnsTheConfirmation() {
        Id loiId = loi().Id;

        Test.startTest();
        String message = RecordStageAdvanceController.advance(loiId);
        Test.stopTest();

        Assert.areEqual('LOI moved to Under Review.', message,
            'The confirmation naming the new stage is what the LWC toasts');
        Assert.areEqual('Under Review', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'advance must actually write the derived stage');
    }

    @isTest
    static void contractReviewAdvancesTheNegotiationStatusNotTheStage() {
        // 🔴 REGRESSION PIN. Stage__c on this object is a DERIVED PROJECTION: the before-save flow
        // Contract_Review_Stage_Sync recomputes it from Negotiation_Status__c on every save. A first
        // attempt mapped Stage__c directly and produced a button that reported SUCCESS and changed
        // nothing — the DML committed and the flow replaced the value before it was stored.
        // Asserting BOTH fields is what makes that failure detectable here: the status must move,
        // and the stage must follow as a consequence rather than being written directly.
        Contract_Review__c cr = new Contract_Review__c(
            Opportunity__c = dealId(),
            Negotiation_Status__c = 'Draft'
        );
        insert cr;

        Test.startTest();
        String message = RecordStageAdvanceController.advance(cr.Id);
        Test.stopTest();

        Contract_Review__c after = [
            SELECT Negotiation_Status__c, Stage__c FROM Contract_Review__c WHERE Id = :cr.Id
        ];
        Assert.areEqual('Negotiation', after.Negotiation_Status__c,
            'The action must advance Negotiation_Status__c — the only writable driver on this object');
        Assert.areEqual('Review', after.Stage__c,
            'and the before-save flow must derive Stage__c from it, moving the Path as a consequence');
        Assert.isTrue(message.contains('Negotiation'),
            'The confirmation names the status the action actually set');
    }

    @isTest
    static void advanceToWritesAnAllowedExplicitTarget() {
        // The LOI 'Submitted' branch: a broker either counters or accepts. 'Signed' is NOT
        // reachable by advance() from 'Submitted' (LOI_ACQUISITION_NEXT_STAGE derives
        // 'Negotiation'), which is the whole reason advanceTo exists.
        //
        // ⚠ All three stage names were renamed by observation 5 (2026-08-14) — 'Sent' -> 'Submitted',
        // 'Counter' -> 'Negotiation', 'Completed' -> 'Signed'. The scenario is unchanged.
        LOI__c record = loi();
        record.Stage__c = 'Submitted';
        update record;

        Test.startTest();
        String message = RecordStageAdvanceController.advanceTo(record.Id, 'Signed');
        Test.stopTest();

        Assert.isTrue(message.contains('Signed'),
            'The confirmation naming the new stage is what the LWC toasts');
        Assert.areEqual('Signed', [SELECT Stage__c FROM LOI__c WHERE Id = :record.Id].Stage__c,
            'advanceTo must write the explicit target, skipping the derived Negotiation hop');
    }

    @isTest
    static void advanceToRejectsATargetOffTheAllowList() {
        // 🔴 THE ALLOW-LIST IS THE WHOLE SECURITY PROPERTY. Without it any holder of class access
        // could write ANY stage on ANY of five objects, skipping every hop and every gate. This
        // proves a derivable forward hop is refused even though it is a perfectly valid picklist
        // value on the object — membership, not validity, is the test.
        //
        // 🔴 THE PROBED VALUE MOVED FROM 'Sent' TO 'Under Review' (observation 5) AND THE TEST GOT
        // STRONGER, NOT MERELY RENAMED. 'Under Review' is the derivable second hop of the
        // ACQUISITION sequence AND the second stage of the DISPOSITION sequence — the one value the
        // two LOI record types now share. So this refusal simultaneously proves (a) a derivable hop
        // is not writable through advanceTo, and (b) a value's presence on the OTHER record type's
        // sequence does not admit it to this one's allow-list.
        LOI__c record = loi();

        Test.startTest();
        try {
            RecordStageAdvanceController.advanceTo(record.Id, 'Under Review');
            Assert.fail('A stage that is not an allowed explicit target must be refused');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not available'),
                'The refusal is surfaced to the user; got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual('Draft', [SELECT Stage__c FROM LOI__c WHERE Id = :record.Id].Stage__c,
            'A refused target must leave the stage untouched');
    }

    @isTest
    static void advanceToRejectsABlankTarget() {
        Test.startTest();
        try {
            RecordStageAdvanceController.advanceTo(loi().Id, '');
            Assert.fail('A blank target must be refused');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('No target stage'),
                'The blank-target message reaches the LWC verbatim; got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void advanceToCannotTouchAnObjectWithNoAllowedTargets() {
        // The other four objects have LINEAR paths and supply no explicit targets at all, so
        // advanceTo is structurally unreachable for them. 'Signed' is a real NDA status, so this
        // proves the refusal comes from the per-object allow-list and not from value validation.
        Test.startTest();
        try {
            RecordStageAdvanceController.advanceTo(nda().Id, 'Signed');
            Assert.fail('An object with no allowed explicit targets must refuse every target');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not available'),
                'Refused for the NDA too; got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual('Pending', [SELECT Status__c FROM NDA__c WHERE Id = :nda().Id].Status__c,
            'The NDA status must be untouched — a linear object has no explicit-target route');
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

    /**
     * ⚠ SUBJECT MOVED FROM LOI__c TO Underwriting__c IN TRANCHE 3B — a behavioural consequence, not
     * tidying. Since LOI__c gained two record types, resolving its gate LOADS the row, and a bare
     * Standard User cannot read an OWD-Private LOI: the selector raises System.QueryException
     * before the gate is consulted, and this test would then "pass" on a read failure while proving
     * nothing about the assert. Underwriting__c is equally Private and equally DEAL_DRIVER-gated
     * but has ONE configured sequence, so gateFor() short-circuits and reads nothing. The full
     * consequence — a caller who cannot read the record gets the GENERIC message rather than the
     * denial wording — is written up on the twin test in RecordStageAdvanceServiceTest.
     */
    @isTest
    static void refusesAUserWhoIsNotADealDriverAndWritesNothing() {
        Id underwritingId = underwriting().Id;
        User bareUser = buildStandardUser('rsac');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bareUser;   // setup DML, isolated from the record DML in @TestSetup
        }

        Test.startTest();
        Boolean refused = false;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                RecordStageAdvanceController.advance(underwritingId);
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
        Assert.areEqual('Requested',
            [SELECT Stage__c FROM Underwriting__c WHERE Id = :underwritingId].Stage__c,
            'A refused call must not write: the stage must still be Requested. A changed stage '
            + 'here would mean the assert ran AFTER the DML instead of before it');
    }

    /**
     * The SAME refusal through advanceTo, which is a second, independently reachable @AuraEnabled
     * entry point. Added 2026-08-09 with the disposition NDA's Mark Declined action: that bundle
     * calls advanceTo, so until now the branch-target route had no proof at all that its
     * permission assert ran before its DML — and `advance` being gated says nothing about
     * `advanceTo` being gated. Its catch ORDER matters for the same reason: an
     * AccessDeniedException reaching the generic clause would tell a user to refresh the page over
     * a permissions problem.
     *
     * ⚠ IT DENIES BY SEEDING THE GATE'S CACHE RATHER THAN BY System.runAs, AND IT HAS TO
     * (Tranche 3B). advanceTo only exists on objects with an explicit-target allow-list, and after
     * 3B BOTH such objects (LOI__c, NDA__c) are multi-record-type — so resolving the gate LOADS the
     * row, which a bare Standard User cannot do on an OWD-Private object: the selector would raise
     * System.QueryException and the refusal would come from the READ, not from the assert, making
     * the wording assertion below meaningless. Seeding the cache runs as the admin (so the load
     * succeeds) with the gate answering false (so the assert is what refuses), which is precisely
     * the thing under test. Same technique and same justification as
     * RecordStageAdvanceServiceTest.theGateIsResolvedPerRecordTypeNotPerObject. The REAL-persona
     * denial is still covered end to end by refusesAUserWhoIsNotADealDriverAndWritesNothing above.
     */
    @isTest
    static void advanceToRefusesAUserWhoIsNotADealDriverAndWritesNothing() {
        Id loiId = loi().Id;

        Test.startTest();
        Boolean refused = false;
        OpportunityActionPermissionService.clearCache();     // clearCache() resets the field, so
        OpportunityActionPermissionService.cachedHasDealActionAccess = false;   // seed AFTER it
        try {
            RecordStageAdvanceController.advanceTo(loiId, 'Completed');
            Assert.fail('advanceTo must REFUSE a non-deal-driver. It returned normally, so '
                + 'RecordStageAdvanceService.assertStageActionAccess did not run on this entry '
                + 'point — which would leave the explicit-target route ungated while the '
                + 'derived-hop route is gated.');
        } catch (AuraHandledException e) {
            refused = true;
            Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE,
                e.getMessage(),
                'A denial must surface the agreed denial wording, not the generic '
                + '"could not be updated" message');
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'advanceTo must refuse a non-deal-driver');
        Assert.areEqual('Draft', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'A refused explicit-target call must not write');
    }

    /**
     * advanceTo's GENERIC clause. A deleted Id makes the fetch-for-use selector throw
     * System.QueryException, which is not user-actionable and must be masked with a fixed message
     * and a logged stack — never with platform text concatenated into it.
     *
     * ⚠ This is also the one visible consequence of the 2026-08-09 call-order change: the
     * allow-list check now happens AFTER load(), so a non-existent Id with a disallowed target
     * raises QueryException here where it used to raise RecordStageAdvanceException. Both land on
     * a fixed message at this boundary, which is exactly why no user-visible wording changed —
     * and this test is what keeps that true.
     */
    @isTest
    static void advanceToOnAMissingRecordIsMaskedByTheGenericCatch() {
        LOI__c record = loi();
        Id deletedId = record.Id;
        delete record;

        Test.startTest();
        try {
            RecordStageAdvanceController.advanceTo(deletedId, 'Completed');
            Assert.fail('advanceTo on a deleted record should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areNotEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE,
                e.getMessage(),
                'An unexpected read failure must NOT be reported as a permissions problem — that '
                + 'is what the catch order exists to prevent, in both directions');
        }
        Test.stopTest();
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
