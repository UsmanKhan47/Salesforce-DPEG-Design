/**
 * Tests for `NdaApprovalService` AND the `@AuraEnabled` boundary it is reached through,
 * `DispositionApprovalController.submitNdaForApproval` — the submit route for the NDA Issue
 * approval. Built 2026-08-31 (Tranche 3 item 2d).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT THIS SUITE IS REALLY DEFENDING, AND IT IS NOT "A BUTTON WORKS"
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * Until 2026-08-31 a disposition NDA moved `Prepare` -> `Approved` in ONE CLICK, through
 * `RecordStageAdvanceService`'s map and the `NDA__c.Move_to_Approved` quick action, gated on the
 * `Disposition_Deal_Actions` custom permission — which `DPEG_Disposition_Edit` (the ANALYST set)
 * grants and `DPEG_Disposition_View` (the PRINCIPAL set) is forbidden to hold. The analyst could
 * make the decision; the principal could not. That hop and that button were retired in the same
 * wave (Gate 1 decision D-7), and THIS is what replaced them.
 * ⇒ So the refusals below are the feature. A build in which every pre-check silently passed would
 * put the transition back in one click, just wearing an approval's clothes.
 * ⚠ The ABSENCE half of that retirement is pinned elsewhere and must stay there:
 * `RecordStageAdvanceServiceTest.dispositionNdaRefusesPrepareAndNamesTheApproval`.
 *
 * ── 🔴 DEPLOY-ORDER DEPENDENCY, STATED SO A RED IS DIAGNOSED CORRECTLY ────────────────────────
 * THREE tests require `approvalProcesses/NDA__c.NDA_Issue_Approval` to be LIVE IN THE ORG. It is a
 * new file in this same wave, deployed BEFORE the Apex (the workflow first, then the approval
 * process, then these classes). `ProcessInstance` is not createable, so there is no fixture that
 * can stand in for it. THE FULL LIST — every method that calls `pendingFor(...)` and expects a
 * NON-ZERO count, which is the mechanical way to re-derive it:
 *
 *   1. `submitsADispositionNdaAtPrepare`
 *   2. `secondSubmitWhileOnePending_isRefusedInWords`
 *   3. `controller_passesTheConfirmationThrough`   ⚠ ADDED TO THIS LIST 2026-08-31 (review W-8).
 *      It was a dependant from the day it was written and the list said it was not — it asserts
 *      `Assert.areEqual(1, pendingFor(nda.Id))`. The block's whole value is COMPLETENESS: a reader
 *      hitting a red on the controller test while trusting "every OTHER test here is independent"
 *      goes hunting for a controller defect that is not there.
 *
 * ⚠ A RED IN ANY OF THE THREE READING "no applicable approval process was found" IS A DEPLOY-ORDER
 * FAILURE, NOT A DEFECT IN THIS CLASS — check that the approval process and its workflow landed
 * first, and that the `Disposition_NDA` record type still exposes `Prepare` (two values left that
 * record type in Setup on a single day in August, each time breaking Apex that named them).
 * Every OTHER test here is independent of it, deliberately: the refusals all fire BEFORE
 * `Approval.process` is reached — including `controller_wrongSObjectType_isRefusedByName`, which
 * never reaches the service at all.
 *
 * ── BULK ──
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not attach here, and this is the
 * narrow structural case the rule's own exemption describes: `submitForApproval` takes ONE Id, is
 * invoked exactly once per quick-action click, has no trigger and no loop, and `Approval.process`
 * caps at 200 submissions per transaction anyway. There is no second batch chunk to force. The
 * "no SOQL/DML in loops" half of the rule is unaffected and is satisfied — this method issues two
 * selector calls and no DML at all.
 *
 * @see force-app/main/default/classes/NdaApprovalService.cls
 * @see force-app/main/default/classes/RecordStageAdvanceServiceTest.cls (the retired hop's refusal)
 */
@isTest
private class NdaApprovalServiceTest {

    private static final String RT_DISPOSITION_NDA = 'Disposition_NDA';
    private static final String RT_ACQUISITION_NDA = 'Acquisition_NDA';

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true
        );
        // The acquisition NDA's parent — the record-type refusal test needs a real Opportunity,
        // because NDA__c is dual-parented and an acquisition NDA hangs off Opportunity__c.
        TestDataFactory.createOpportunities(1, true);
    }

    private static Id dispositionId() {
        return [SELECT Id FROM Disposition__c LIMIT 1].Id;
    }

    /**
     * A disposition NDA at a chosen status, with the record-type stamp READ BACK before the caller
     * is allowed to proceed.
     *
     * 🔴 THE READ-BACK IS THE POINT, and it is copied from `RecordStageAdvanceServiceTest`'s
     * helper for the reason recorded there: a stamped `RecordTypeId` that reads back null means
     * the record type is not assigned to the running user's profile, under which condition every
     * assertion below would fail with a confusing message diff instead of naming the real cause.
     *
     * @param status The `Status__c` to seed. Must be on the Disposition_NDA subset — the picklist
     *               is RESTRICTED and DML enforces the subset, so a wrong value fails the INSERT,
     *               which is a fixture failure wearing a service failure's clothes.
     * @return The inserted NDA.
     */
    private static NDA__c dispositionNdaAt(String status) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId(), false);
        nda.Status__c = status;
        insert nda;

        NDA__c stored = [SELECT Id, Status__c, RecordTypeId FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual(recordTypeId(RT_DISPOSITION_NDA), stored.RecordTypeId,
            'PRECONDITION FAILED, not a service defect: the Disposition_NDA record type did not '
            + 'land on the inserted row, which means it is assigned to no profile. Every assertion '
            + 'below is blocked until that is fixed, and none may be softened to go green');
        return stored;
    }

    private static Id recordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'The NDA__c record type "' + developerName + '" does not exist in this org. '
            + 'objects/NDA__c/recordTypes/ must be deployed before this suite can run. Available: '
            + Schema.SObjectType.NDA__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    private static Integer pendingFor(Id targetId) {
        return [
            SELECT COUNT() FROM ProcessInstance
            WHERE TargetObjectId = :targetId AND Status = 'Pending'
        ];
    }

    /** Runs the service and returns the refusal message, failing loudly if it did NOT refuse. */
    private static String refusalFor(Id ndaId) {
        try {
            NdaApprovalService.submitForApproval(ndaId);
            Assert.fail('The submission must have been refused, and it was not. '
                + 'A pre-check that silently passes puts the one-click bypass back');
        } catch (NdaApprovalService.ApprovalException e) {
            return e.getMessage();
        }
        return null;
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

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE HAPPY PATH
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * A disposition NDA at `Prepare` is accepted into an approval process, and the confirmation
     * NAMES which one.
     *
     * ⚠ REQUIRES `NDA_Issue_Approval` TO BE DEPLOYED — see the class header.
     * ⚠ THE MESSAGE IS ASSERTED, NOT JUST THE INSTANCE. The user has pressed a button labelled only
     * "Submit for Approval" on a record page carrying four other actions; a generic "Submitted"
     * toast would not let them confirm they pressed the right one.
     */
    @isTest
    static void submitsADispositionNdaAtPrepare() {
        NDA__c nda = dispositionNdaAt('Prepare');

        Test.startTest();
        String message = NdaApprovalService.submitForApproval(nda.Id);
        Test.stopTest();

        Assert.areEqual('The NDA has been submitted for the NDA Issue approval.', message,
            'The confirmation must NAME the approval');
        Assert.areEqual(1, pendingFor(nda.Id),
            'and a real ProcessInstance must exist. Zero here, with no exception, would mean '
            + 'Approval.process was never reached — check that NDA_Issue_Approval is deployed and '
            + 'that its entry criteria still match Status = Prepare AND Is_Disposition_NDA__c');
    }

    /**
     * The `@AuraEnabled` boundary passes the authored confirmation through unchanged.
     *
     * ⚠ IT ALSO PINS THE PARAMETER NAME. `submitNdaForApproval(Id ndaId)` — the LWC binds
     * imperatively BY NAME, so a rename here is not a compile error on either side; it simply
     * arrives null and the user gets "No record was provided." from a button they clicked on a real
     * record. `ndaSubmitForApproval.test.js` pins the client half of the same contract.
     */
    @isTest
    static void controller_passesTheConfirmationThrough() {
        NDA__c nda = dispositionNdaAt('Prepare');

        Test.startTest();
        String message = DispositionApprovalController.submitNdaForApproval(nda.Id);
        Test.stopTest();

        Assert.areEqual('The NDA has been submitted for the NDA Issue approval.', message,
            'The controller is THIN — it must not reword the service\'s confirmation');
        Assert.areEqual(1, pendingFor(nda.Id), 'and the submission must have actually happened');
    }

    /**
     * 🔴 REVIEW S-1 — A WRONG SOBJECT TYPE IS NAMED, NOT FLATTENED INTO "REFRESH THE PAGE".
     *
     * `submitNdaForApproval` is the only method on `DispositionApprovalController` that does NOT
     * take a `Disposition__c`, so it is the only one a quick action can plausibly be wired to the
     * wrong record. Without the guard, a Disposition Id reaches
     * `NdaSelector.selectStageRequiredById`, whose single-row assignment throws a raw
     * `QueryException`; catch 3 turns that into "This could not be submitted for approval. Refresh
     * the page or contact your administrator." — advice that cannot work, on a METADATA defect that
     * survives every refresh.
     *
     * ⚠ IT ASSERTS THE MESSAGE, NOT MERELY THAT SOMETHING THREW. Both the guarded and the unguarded
     * build throw `AuraHandledException` here; only the wording tells them apart, which is the
     * entire point of the guard.
     *
     * ⚠ AND IT PROVES THE GUARD IS OUTSIDE THE TRY. Inside it, catch 3's `catch (Exception)` would
     * swallow this exception and re-throw the generic message — so a build that "simplified" the
     * guard into the try block fails on this exact assertion.
     */
    @isTest
    static void controller_wrongSObjectType_isRefusedByName() {
        Id notAnNda = dispositionId();

        Test.startTest();
        String message;
        try {
            DispositionApprovalController.submitNdaForApproval(notAnNda);
            Assert.fail('A Disposition Id must be refused by the NDA submit action. Reaching the '
                + 'service means the SObject-type guard is gone');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual(DispositionApprovalController.NDA_WRONG_TYPE_MESSAGE, message,
            'The refusal must NAME the wiring mistake. The generic submit-failure message here '
            + 'means either the guard is missing (a QueryException fell through to catch 3) or it '
            + 'was moved INSIDE the try, where catch (Exception) swallows its own '
            + 'AuraHandledException: ' + message);
        Assert.areEqual(0, pendingFor(notAnNda),
            'and nothing may have been submitted against the wrong record');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE REFUSALS — WHICH ARE THE FEATURE
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 AN ACQUISITION NDA IS REFUSED, AND THE GATE FAILS **CLOSED**.
     *
     * The approval's second entry criterion is `Is_Disposition_NDA__c = True`, a formula over
     * `RecordType.DeveloperName`. This service mirrors it from `RecordTypeId` through a describe
     * rather than reading the formula — a formula's value on an in-memory row is not a guarantee to
     * lean on, and `RecordTypeId` has no FLS surface so it cannot be denied to a persona.
     *
     * ⚠ WITHOUT THIS PRE-CHECK THE USER WOULD STILL BE REFUSED — by the PLATFORM, with "no
     * applicable approval process was found", which names nothing they can act on. That is the
     * entire reason the pre-check exists, so asserting the WORDING is the assertion, not the
     * refusal.
     */
    @isTest
    static void acquisitionNda_isRefusedByRecordType() {
        Opportunity deal = [SELECT Id FROM Opportunity LIMIT 1];
        NDA__c acquisition =
            TestDataFactory.createNdas(1, deal.Id, TestDataFactory.NDA_RT_ACQUISITION, false)[0];
        acquisition.RecordTypeId = recordTypeId(RT_ACQUISITION_NDA);
        acquisition.Status__c = 'Pending';
        insert acquisition;

        Test.startTest();
        String message = refusalFor(acquisition.Id);
        Test.stopTest();

        Assert.areEqual(
            'Only a disposition NDA can be submitted for the NDA Issue approval.',
            message,
            'The record-type gate must refuse in WORDS. The platform\'s own refusal here would be '
            + '"no applicable approval process was found", which tells the user nothing');
        Assert.areEqual(0, pendingFor(acquisition.Id),
            'and nothing may be submitted on the acquisition side');
    }

    /**
     * 🔴 A DISPOSITION NDA THAT IS NOT AT `Prepare` IS REFUSED, AND THE REFUSAL NAMES BOTH STATUSES.
     *
     * ⚠ `Approved` IS THE FIXTURE ON PURPOSE — it is the status the RETIRED one-click button used
     * to write. A build that accepted it would let a user re-submit an NDA that has already been
     * approved, which is the closest reachable shape to the bypass this feature replaced.
     */
    @isTest
    static void wrongStatus_isRefusedAndNamesBothStatuses() {
        NDA__c nda = dispositionNdaAt('Approved');

        Test.startTest();
        String message = refusalFor(nda.Id);
        Test.stopTest();

        Assert.areEqual(
            'An NDA can only be submitted for the NDA Issue approval from the Prepare status. '
            + 'This NDA is at Approved.',
            message,
            'The refusal must name the REQUIRED status and the ACTUAL one — a message that named '
            + 'only one of the two reads as a rule the user cannot check');
        Assert.areEqual(0, pendingFor(nda.Id), 'and nothing may be submitted');
    }

    /**
     * A blank status gets its own clause rather than "This NDA is at ."
     *
     * 🔴 IT IS A REACHABLE STATE, NOT A DEFENSIVE BRANCH. `Disposition_NDA` has NO record-type
     * default on `Status__c` — the user cleared it on 2026-08-25 — so a UI-created NDA arrives
     * blank. Only auto-created ones are seeded at `Prepare`.
     */
    @isTest
    static void blankStatus_getsItsOwnWording() {
        NDA__c nda = dispositionNdaAt(null);

        Test.startTest();
        String message = refusalFor(nda.Id);
        Test.stopTest();

        Assert.areEqual(
            'An NDA can only be submitted for the NDA Issue approval from the Prepare status. '
            + 'This NDA has no status set.',
            message,
            'A blank status must not render as "This NDA is at .", which reads as a rendering bug '
            + 'rather than as a rule');
    }

    /**
     * 🔴 A SECOND SUBMIT WHILE ONE IS PENDING IS REFUSED IN WORDS, NOT BY A PLATFORM EXCEPTION.
     *
     * This is the failure the brief singled out. `Approval.process` on an already-pending record
     * throws platform text that is not a sentence to show a user; the `selectPendingByTargetId`
     * pre-check turns it into one. The client surfaces it verbatim, sticky, because it tells the
     * user what to DO (recall the pending approval, or wait).
     *
     * ⚠ IT IS NOT A LOCK AND DOES NOT CLAIM TO BE. Two simultaneous clicks could both pass this
     * check; the platform remains the real backstop and the controller masks its refusal. This
     * exists for the MESSAGE.
     * ⚠ REQUIRES `NDA_Issue_Approval` TO BE DEPLOYED — see the class header.
     */
    @isTest
    static void secondSubmitWhileOnePending_isRefusedInWords() {
        NDA__c nda = dispositionNdaAt('Prepare');
        NdaApprovalService.submitForApproval(nda.Id);
        Assert.areEqual(1, pendingFor(nda.Id),
            'PRECONDITION: the first submission must have been accepted, or this test proves '
            + 'nothing about the second');

        Test.startTest();
        String message = refusalFor(nda.Id);
        Test.stopTest();

        Assert.areEqual('This NDA is already pending approval.', message,
            'The duplicate-submission guard must refuse in words. The platform\'s own exception '
            + 'here is masked by the controller as "refresh the page", advice that can never work');
        Assert.areEqual(1, pendingFor(nda.Id),
            'and the refusal must not have created a second instance');
    }

    /** A null Id is refused before anything is read. */
    @isTest
    static void nullId_isRefused() {
        Test.startTest();
        String message = refusalFor(null);
        Test.stopTest();

        Assert.areEqual('No record was provided.', message,
            'A null Id must produce an authored refusal, not a null dereference three lines later');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // AUTHORIZATION
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE GATE RUNS **BEFORE** EVERY OTHER CHECK, AND THAT ORDERING IS THE ASSERTION.
     *
     * Every refusal in this class leaks something about the record — its status, its record type —
     * so authorization has to be settled before any of them can be reached. The fixture is at
     * `Approved`, i.e. a status that WOULD produce its own refusal: a bare user must get
     * `AccessDeniedException`, never the status message. If the assert ever moves below the
     * selector read, this test goes red on the message rather than on the exception type.
     *
     * ⚠ `clearCache()` ON BOTH SIDES OF THE `runAs`. The permission answer is memoized per
     * execution context and the running user changes inside the block; without the reset the
     * cached admin answer would be reused and this test would pass vacuously.
     */
    @isTest
    static void bareUser_isDeniedBeforeAnyRead() {
        NDA__c nda = dispositionNdaAt('Approved');
        User bareUser = buildStandardUser('ndaas1');
        insert bareUser;

        Test.startTest();
        Boolean denied = false;
        String message = '';
        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                NdaApprovalService.submitForApproval(nda.Id);
                Assert.fail('A user with no disposition-driver grant must be denied');
            } catch (DispositionActionPermissionService.AccessDeniedException e) {
                denied = true;
                message = e.getMessage();
            } catch (NdaApprovalService.ApprovalException e) {
                Assert.fail('THE GATE RAN TOO LATE. A bare user reached the status pre-check and '
                    + 'was told about the record instead of about their access: ' + e.getMessage());
            }
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(denied,
            'The permission assert must be the FIRST statement — a bare user must never reach the '
            + 'selector read');
        Assert.areEqual(DispositionActionPermissionService.NO_PERMISSION_MESSAGE, message,
            'and it must carry the shared denial wording every gate in this org uses, so a denied '
            + 'user is sent to the right person');
        Assert.areEqual(0, pendingFor(nda.Id), 'Nothing should have been submitted');
    }

    /**
     * The controller translates a denial into an `AuraHandledException` carrying the SAME wording,
     * rather than masking it behind the generic failure message.
     *
     * 🔴 THE CATCH ORDER IS WHAT THIS PINS. `AccessDeniedException` is caught FIRST; falling
     * through to the generic clause would tell a user with a permission problem to "refresh the
     * page or contact your administrator", which hides the reason and sends them to the wrong
     * person.
     */
    @isTest
    static void controller_surfacesTheDenialVerbatim() {
        NDA__c nda = dispositionNdaAt('Prepare');
        User bareUser = buildStandardUser('ndaas2');
        insert bareUser;

        Test.startTest();
        String message = '';
        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                DispositionApprovalController.submitNdaForApproval(nda.Id);
                Assert.fail('The controller must not swallow a denial');
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.areEqual(DispositionActionPermissionService.NO_PERMISSION_MESSAGE, message,
            'The denial must reach the user VERBATIM. The generic '
            + '"This could not be submitted for approval..." here means the AccessDeniedException '
            + 'catch was removed or reordered below the generic one');
    }

    /**
     * The controller surfaces a user-actionable refusal verbatim too — the second of its three
     * catches, typed to `NdaApprovalService.ApprovalException`.
     *
     * ⚠ THAT TYPE IS DELIBERATELY SEPARATE FROM `DispositionApprovalService.ApprovalException`. The
     * two methods live on the same controller and catch different types on purpose, so a refusal
     * authored for a Disposition can never surface on the NDA's button. Merging them would compile
     * and pass a naive suite.
     */
    @isTest
    static void controller_surfacesTheRefusalVerbatim() {
        NDA__c nda = dispositionNdaAt('Approved');

        Test.startTest();
        String message = '';
        try {
            DispositionApprovalController.submitNdaForApproval(nda.Id);
            Assert.fail('An NDA at Approved must be refused');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(message.contains('Prepare'),
            'The authored guidance must reach the user, naming the status that IS accepted. A '
            + 'generic message here means catch 2 was removed and every designed refusal in this '
            + 'feature now reads as "refresh the page": ' + message);
    }
}
