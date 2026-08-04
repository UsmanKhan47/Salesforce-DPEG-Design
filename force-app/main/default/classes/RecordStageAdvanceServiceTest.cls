/**
 * @description Tests RecordStageAdvanceService — the generic stage-advance service behind the
 * "advance stage" quick action on NDA__c, LOI__c, Underwriting__c,
 * Construction_Feasibility_Review__c and Development_Feasibility_Review__c.
 *
 * ── HOW THE STAGE MAPS ARE PINNED ────────────────────────────────────────────
 * Each object gets a WALK test that calls advance() repeatedly until it is refused and asserts the
 * EXACT, ORDERED list of returned messages. Because advance() names its target in the message
 * ('LOI moved to Sent.'), that one assertion pins the whole map verbatim — every hop, in order, plus
 * the terminal refusal — without a single re-query and without reaching into private state. Adding,
 * removing or reordering a hop reds the walk immediately and shows exactly where.
 *
 * ── 🔴 THE MOST IMPORTANT TEST IN THIS CLASS ─────────────────────────────────
 * underwritingNeverReachesApprovedFromInProgress. 'Approved' on Underwriting__c is owned by the
 * PRINCIPAL APPROVAL PROCESS, and a naive "same as the other four objects" map would put it one
 * button-click away and bypass the approval entirely. That test is falsifiable in both directions:
 * it asserts the call is REFUSED, that the stage in the database is STILL 'In Progress' (so a write
 * that happened before the refusal would red it), and that the message names the real route.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * No 251-record scenario applies. advance() is a per-transaction-singleton @AuraEnabled operation
 * invoked once per quick-action click — one record, one selector read, one update, no loop over
 * records and no collection DML. Same shape and same exemption as StageAdvanceServiceTest and
 * OpportunityActionPermissionServiceTest (.claude/rules/bulk-test-rule.md, per-transaction-singleton
 * exemption). A 251-record test here would exercise no additional code path.
 *
 * ── 🔴 KNOWN, DELIBERATE COVERAGE GAP: setStage's DmlException catch ─────────
 * That catch exists to surface a validation rule's own message to the user, which is the entire
 * reason this program routes stage writes through Apex. It is currently UNCOVERED, and the reason is
 * a fact about the org rather than a shortcut:
 *
 *   THERE IS NO WAY TO MAKE ONE OF THESE FIVE UPDATES FAIL TODAY. Verified 2026-08-04:
 *     - objects/<each>/validationRules/ does not exist on ANY of the five (design decision D6
 *       defers rule authoring to a follow-on, so this program ships the actions first);
 *     - all six Opportunity validation rules are ISCHANGED(StageName)-scoped, so the mirror write
 *       Underwriting_Opp_Sync makes on the parent cannot trip one;
 *     - the update sends only Id + the stage field, so no untouched required field or lookup is
 *       re-validated;
 *     - the record cannot be deleted between the selector read and the update — they are one call;
 *     - MIXED_DML_OPERATION was TRIED as a synthetic block and MEASURED NOT TO FIRE on this org,
 *       both before and inside Test.startTest(): `insert <User>` followed by the non-setup update
 *       simply succeeds. Do not re-attempt it.
 *   The remaining option was a @TestVisible seam that REDIRECTS THE WRITE to an invalid value.
 *   That was rejected: a test seam able to change what gets written to a stage field is a worse
 *   risk than one uncovered statement, and it would prove nothing a real rule will not prove.
 *
 * ⇒ WHEN THE FIRST VALIDATION RULE ON ANY OF THE FIVE LANDS, ADD ITS TEST HERE. Assert that the
 *   rule's own errorMessage reaches the caller verbatim — that is the behaviour the whole
 *   Apex-not-LDS write decision was made to obtain, and until then it is unproven.
 *
 * @see force-app/main/default/classes/RecordStageAdvanceService.cls
 * @see force-app/main/default/classes/StageAdvanceServiceTest.cls (the Opportunity sibling)
 * @author Salesforce Developer
 */
@isTest
private class RecordStageAdvanceServiceTest {

    /**
     * One deal with exactly one of each stage-controlled child. The auto-created NDA is deleted
     * first: OpportunityReviewService.ensureNda opens one NDA on every Opportunity insert, so
     * without this there would be two and "the NDA" would be ambiguous.
     */
    @TestSetup
    static void setupTestData() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        delete [SELECT Id FROM NDA__c WHERE Opportunity__c = :deal.Id];
        TestDataFactory.createNda(deal.Id, true);
        TestDataFactory.createLoi(deal.Id, true);
        TestDataFactory.createUnderwriting(deal.Id, true);
        TestDataFactory.createConstructionReview(deal.Id, null, true);
        TestDataFactory.createDevelopmentReview(deal.Id, null, true);
    }

    private static Id dealId() {
        return [SELECT Id FROM Opportunity LIMIT 1].Id;
    }

    private static NDA__c nda() {
        return [SELECT Id, Status__c FROM NDA__c LIMIT 1];
    }

    private static LOI__c loi() {
        return [SELECT Id, Stage__c FROM LOI__c LIMIT 1];
    }

    private static Underwriting__c underwriting() {
        return [SELECT Id, Stage__c FROM Underwriting__c LIMIT 1];
    }

    private static Construction_Feasibility_Review__c constructionReview() {
        return [SELECT Id, Stage__c FROM Construction_Feasibility_Review__c LIMIT 1];
    }

    private static Development_Feasibility_Review__c developmentReview() {
        return [SELECT Id, Stage__c FROM Development_Feasibility_Review__c LIMIT 1];
    }

    /**
     * Advances a record until the service refuses, returning every confirmation message in order
     * followed by the refusal prefixed 'BLOCKED: '. The refusal is the terminator, so a map with a
     * cycle fails loudly rather than looping.
     */
    private static List<String> advanceUntilBlocked(Id recordId) {
        List<String> messages = new List<String>();
        for (Integer i = 0; i < 12; i++) {
            try {
                messages.add(RecordStageAdvanceService.advance(recordId));
            } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
                messages.add('BLOCKED: ' + e.getMessage());
                return messages;
            }
        }
        Assert.fail('advance() never refused after 12 hops — the stage map has a cycle: ' + messages);
        return messages;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // STAGE MAPS — one walk per object, pinning every hop verbatim
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void ndaWalksPendingToSigned() {
        // ⚠ NDA__c is the object whose stage field is Status__c, not Stage__c. If the config ever
        // hardcoded Stage__c this walk would fail on the very first hop.
        Id ndaId = nda().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(ndaId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'NDA moved to Sent.',
                'NDA moved to Signed.',
                'BLOCKED: There is no next step available from the Signed stage.'
            },
            messages,
            'The NDA map must be exactly Pending -> Sent -> Signed, with Signed terminal');
        Assert.areEqual('Signed', [SELECT Status__c FROM NDA__c WHERE Id = :ndaId].Status__c,
            'The walk must leave the NDA at its terminal status');
    }

    @isTest
    static void loiWalksDraftToCompleted() {
        Id loiId = loi().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(loiId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'LOI moved to Prepare/Review.',
                'LOI moved to Sent.',
                'LOI moved to Counter.',
                'LOI moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'The LOI map must be exactly Draft -> Prepare/Review -> Sent -> Counter -> Completed. '
            + 'Note Prepare/Review carries a literal slash — a value that must never be URL-encoded '
            + 'in Apex');
        Assert.areEqual('Completed', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'The walk must leave the LOI at its terminal stage');
    }

    @isTest
    static void constructionReviewWalksRequestedToCompleted() {
        Id reviewId = constructionReview().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(reviewId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Construction Feasibility Review moved to Site Visit.',
                'Construction Feasibility Review moved to Condition Assessment.',
                'Construction Feasibility Review moved to Cost Estimate.',
                'Construction Feasibility Review moved to Share Opinion.',
                'Construction Feasibility Review moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'The Construction Feasibility Review map must be exactly Requested -> Site Visit -> '
            + 'Condition Assessment -> Cost Estimate -> Share Opinion -> Completed');
        Assert.areEqual('Completed',
            [SELECT Stage__c FROM Construction_Feasibility_Review__c WHERE Id = :reviewId].Stage__c,
            'The walk must leave the review at its terminal stage');
    }

    @isTest
    static void developmentReviewWalksRequestedToCompleted() {
        Id reviewId = developmentReview().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(reviewId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Development Feasibility Review moved to Feasibility analysis.',
                'Development Feasibility Review moved to Vendor proposals.',
                'Development Feasibility Review moved to Share Opinion.',
                'Development Feasibility Review moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'The Development Feasibility Review map must be exactly Requested -> Feasibility '
            + 'analysis -> Vendor proposals -> Share Opinion -> Completed. The lower-cased second '
            + 'words are the org values — "correcting" them yields a map that never matches');
        Assert.areEqual('Completed',
            [SELECT Stage__c FROM Development_Feasibility_Review__c WHERE Id = :reviewId].Stage__c,
            'The walk must leave the review at its terminal stage');
    }

    @isTest
    static void underwritingWalksRequestedToInProgressThenStops() {
        Id underwritingId = underwriting().Id;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(underwritingId);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Underwriting moved to In Progress.',
                'BLOCKED: Underwriting moves to Approved through the principal approval, not this '
                + 'action. Use Submit for Approval.'
            },
            messages,
            'The Underwriting map must advance Requested -> In Progress and then STOP. Reaching '
            + 'Approved is the principal approval process\'s job');
    }

    @isTest
    static void underwritingResumesFromApprovedToCompleted() {
        // Simulates the state ApprovalAuditService leaves behind on principal sign-off. Proves the
        // Underwriting map is deliberately GAPPED rather than merely truncated — the Approved ->
        // Completed hop is live, so a reader cannot conclude the map "just stops at In Progress".
        Underwriting__c record = underwriting();
        record.Stage__c = 'Approved';
        update record;

        Test.startTest();
        List<String> messages = advanceUntilBlocked(record.Id);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'Underwriting moved to Completed.',
                'BLOCKED: There is no next step available from the Completed stage.'
            },
            messages,
            'From Approved the Underwriting map must still advance to Completed');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE APPROVAL CARVE-OUT
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void underwritingNeverReachesApprovedFromInProgress() {
        Underwriting__c record = underwriting();
        record.Stage__c = 'In Progress';
        update record;

        Test.startTest();
        Boolean refused = false;
        String message;
        try {
            RecordStageAdvanceService.advance(record.Id);
            Assert.fail('advance() must REFUSE In Progress -> Approved on Underwriting__c. '
                + 'Approved is owned by the principal approval process; a service that writes it '
                + 'directly lets a single button click produce a principal-approved underwriting '
                + 'that no principal ever saw');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            refused = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The In Progress -> Approved hop must be refused');
        Assert.areEqual('In Progress',
            [SELECT Stage__c FROM Underwriting__c WHERE Id = :record.Id].Stage__c,
            'A refused advance must not write. A stage of Approved here would mean the refusal '
            + 'happened AFTER the DML rather than instead of it');
        Assert.isTrue(message.contains('Submit for Approval'),
            'The refusal must NAME the real route, or the deliberate gap in the map reads as a bug '
            + 'and someone "fixes" it by adding the hop. Actual message: ' + message);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // GUARD CLAUSES
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void nullRecordIdThrows() {
        Test.startTest();
        try {
            RecordStageAdvanceService.advance(null);
            Assert.fail('A null recordId must be rejected');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('No record was provided.', e.getMessage(),
                'A null recordId surfaces the fixed no-record wording');
        }
        Test.stopTest();
    }

    @isTest
    static void unsupportedObjectThrows() {
        // An Opportunity is stage-controlled by the OTHER service (StageAdvanceService). Handing it
        // to this one must be refused rather than silently mis-routed.
        Id oppId = dealId();

        Test.startTest();
        try {
            RecordStageAdvanceService.advance(oppId);
            Assert.fail('An Opportunity is not stage-controlled by this service');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('This action is not available on this record.', e.getMessage(),
                'An unsupported object surfaces the fixed unsupported wording');
        }
        Test.stopTest();
    }

    @isTest
    static void blankStageThrows() {
        // Blanked by UPDATE, not by insert: a picklist default is applied on insert when the field
        // is omitted, so an insert cannot reach this state.
        LOI__c record = loi();
        record.Stage__c = null;
        update record;

        Test.startTest();
        try {
            RecordStageAdvanceService.advance(record.Id);
            Assert.fail('A record with no stage cannot be advanced');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('This record has no stage set, so it cannot be advanced.', e.getMessage(),
                'A blank stage surfaces its own wording rather than "no next step available from '
                + 'the  stage"');
        }
        Test.stopTest();
    }

    @isTest
    static void missingRecordThrowsQueryException() {
        // The selectors are FETCH-FOR-USE: a miss throws the native System.QueryException, which
        // this service deliberately does NOT convert. The controller masks it behind a fixed
        // generic message; converting it here would make a genuine fault read as a business rule.
        LOI__c record = loi();
        Id deletedId = record.Id;
        delete record;

        Test.startTest();
        try {
            RecordStageAdvanceService.advance(deletedId);
            Assert.fail('A deleted record must not be advanced');
        } catch (System.QueryException e) {
            Assert.isNotNull(e, 'A missing record surfaces the native QueryException');
        }
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PERMISSION GATE
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void adminPassesTheGateOnEveryObject() {
        // The test-running user holds Modify All Data, which the gate bypasses on purpose (see
        // OpportunityActionPermissionService). ⚠ This is exactly why an admin smoke test proves
        // nothing about the gate — the denial case below is the one that does.
        Id ndaId = nda().Id;
        Id loiId = loi().Id;
        Id underwritingId = underwriting().Id;
        Id conId = constructionReview().Id;
        Id devId = developmentReview().Id;

        Test.startTest();
        OpportunityActionPermissionService.clearCache();
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(ndaId), 'NDA gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(loiId), 'LOI gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(underwritingId), 'Underwriting gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(conId), 'Construction gate');
        Assert.isTrue(RecordStageAdvanceService.hasStageActionAccess(devId), 'Development gate');
        RecordStageAdvanceService.assertStageActionAccess(loiId); // must not throw
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();
    }

    @isTest
    static void bareUserIsDeniedAndNothingIsWritten() {
        Id loiId = loi().Id;
        User bareUser = buildStandardUser('bare');
        insert bareUser;   // setup DML first — no record DML has run in this transaction yet

        Test.startTest();
        Boolean refused = false;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            Assert.isFalse(RecordStageAdvanceService.hasStageActionAccess(loiId),
                'A user with neither Modify All Data nor Deal_Driver__c must be denied');
            try {
                RecordStageAdvanceService.assertStageActionAccess(loiId);
                Assert.fail('assertStageActionAccess must REFUSE a non-deal-driver. Returning '
                    + 'normally means the gate did not run at all');
            } catch (RecordStageAdvanceService.AccessDeniedException e) {
                refused = true;
                Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE,
                    e.getMessage(),
                    'The denial must use the SHARED wording, so one condition never produces two '
                    + 'phrasings across the Lead, Opportunity and record-stage features');
            }
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The server-side assert must refuse a non-deal-driver');
        Assert.areEqual('Draft', [SELECT Stage__c FROM LOI__c WHERE Id = :loiId].Stage__c,
            'A refused call must not write');
    }

    @isTest
    static void permissionCheckOnAnUnsupportedObjectThrows() {
        Id oppId = dealId();

        Test.startTest();
        try {
            RecordStageAdvanceService.hasStageActionAccess(oppId);
            Assert.fail('The gate cannot be resolved for an object with no stage config');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('This action is not available on this record.', e.getMessage(),
                'An unsupported object is refused before any permission machinery runs');
        }
        try {
            RecordStageAdvanceService.hasStageActionAccess(null);
            Assert.fail('A null recordId cannot resolve a gate');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            Assert.areEqual('No record was provided.', e.getMessage(),
                'A null recordId surfaces the fixed no-record wording');
        }
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // isSupported
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void isSupportedAnswersWithoutThrowing() {
        Id loiId = loi().Id;
        Id oppId = dealId();

        Test.startTest();
        Assert.isTrue(RecordStageAdvanceService.isSupported(loiId),
            'LOI__c is stage-controlled by this service');
        Assert.isFalse(RecordStageAdvanceService.isSupported(oppId),
            'Opportunity belongs to StageAdvanceService, not this one');
        Assert.isFalse(RecordStageAdvanceService.isSupported(null),
            'isSupported is null-safe — it ANSWERS rather than throwing, which is the point of it '
            + 'existing alongside the throwing entry points');
        Test.stopTest();
    }

    /**
     * Builds (but does not insert) a bare Standard User. User is a setup object whose required-field
     * shape TestDataFactory deliberately does not cover, so this mirrors the helper in
     * StageAdvanceControllerTest / OpportunityActionPermissionServiceTest.
     */
    private static User buildStandardUser(String tag) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'RecStage',
            Alias = 'rstg',
            Email = 'std.recstage@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
