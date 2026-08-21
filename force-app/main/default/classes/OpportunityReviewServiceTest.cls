/**
 * Tests OpportunityReviewService: a feasibility-review child is created when an
 * Opportunity enters Development Review / Construction Review, exactly once.
 */
@isTest
private class OpportunityReviewServiceTest {

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    @isTest
    static void underwritingRecordCreatesOnStageEntry() {
        Test.startTest();
        Opportunity o = newOpp('Underwriting'); // insert = stage entry; NDA VR gates updates only
        insert o;
        Test.stopTest();

        List<Underwriting__c> uws = [
            SELECT Stage__c, Status__c FROM Underwriting__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, uws.size(), 'One Underwriting record opens on entering the stage');
        System.assertEquals('Requested', uws[0].Stage__c, 'Underwriting path starts at Requested');
        System.assertEquals('In Progress', uws[0].Status__c, 'Coarse status starts In Progress');

        Opportunity stamped = [SELECT Primary_Underwriting__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(uws[0].Id, stamped.Primary_Underwriting__c,
            'Primary_Underwriting__c stamped so the Opp tab can span to it');

        // Idempotency: re-saving at the same stage must not open a second record.
        update new Opportunity(Id = o.Id, Underwriting_Notes__c = 'touch');
        System.assertEquals(1, [SELECT COUNT() FROM Underwriting__c WHERE Opportunity__c = :o.Id],
            'No duplicate Underwriting on re-save');

        // Numbers entered on the Underwriting record sync back to the Opp mirrors
        // (Underwriting_Opp_Sync flow) so reports and the approval page stay current.
        update new Underwriting__c(Id = uws[0].Id, My_Price__c = 17500000, Underwritten_NOI__c = 1200000);
        stamped = [SELECT My_Price__c, Underwritten_NOI__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(17500000, stamped.My_Price__c, 'Opp mirrors the primary underwriting price');
        System.assertEquals(1200000, stamped.Underwritten_NOI__c, 'Opp mirrors the underwritten NOI');
    }

    @isTest
    static void loiRecordCreatesOnStageEntry() {
        Test.startTest();
        Opportunity o = newOpp('LOI'); // insert = stage entry; the LOI entry gates check ISCHANGED
        insert o;
        Test.stopTest();

        List<LOI__c> lois = [
            SELECT Id, Stage__c, LOI_Status__c, OwnerId FROM LOI__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, lois.size(), 'One LOI opens on entering the LOI stage');
        System.assertEquals('Draft', lois[0].Stage__c, 'LOI path starts at Draft');
        System.assertEquals('Draft', lois[0].LOI_Status__c, 'LOI status starts at Draft');
        System.assertNotEquals(null, lois[0].OwnerId, 'An LOI always has an owner');

        // ⚠ THE OWNER ASSERTION THAT USED TO SIT HERE HAS MOVED, IT WAS NOT DROPPED.
        // It read `assertEquals(dealOwner.OwnerId, lois[0].OwnerId)` and carried an honest-limit
        // note that it could not FAIL in test context, because the running user owns the
        // Opportunity and would therefore match by default. That is still true of the DEGRADED
        // path and is now pinned by loiBlock_unresolvableQueue_fallsBackToTheDealOwner; the
        // PRIMARY rule - the Acquisition queue owns every auto-created LOI (2026-08-15) - is
        // pinned by loiBlock_ownerIsTheAcquisitionQueue, which CAN fail here and is meant to.
        // Keeping a deal-owner assertion in this test as well would simply contradict it.

        // The stamp is the load-bearing half: ApprovalAuditService's LOI gate resolves its target
        // through Primary_LOI__c, and swallows its own failures - so a null here would make the
        // LOI approval silently stamp nothing, reproducing the Underwriting-gate defect.
        //
        // It is written ASYNCHRONOUSLY by LoiPrimaryStampQueueable, which is why the assertion sits
        // after Test.stopTest() - in production the deal is LOCKED by its own approval at the
        // moment the LOI is created, and an inline write throws ENTITY_IS_LOCKED. This test does
        // not reproduce that lock (no approval is running), so it pins the WIRING, not the lock;
        // only a real approval by a principal exercises the reason the queueable exists.
        Opportunity stamped = [SELECT Primary_LOI__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(lois[0].Id, stamped.Primary_LOI__c,
            'Primary_LOI__c stamped so the LOI approval audit can resolve its target');

        // Idempotency: re-saving at the same stage must not open a second LOI.
        update new Opportunity(Id = o.Id, Underwriting_Notes__c = 'touch');
        System.assertEquals(1, [SELECT COUNT() FROM LOI__c WHERE Opportunity__c = :o.Id],
            'No duplicate LOI on re-save');
    }

    /**
     * 🔴 UNCONDITIONAL BY DESIGN — D16.3, Tranche 3B. The LOI twin of
     * ensureNda_stampsTheAcquisitionRecordType, and it must NOT be guarded on isAvailable().
     *
     * The stamp in the service IS guarded, deliberately and for a reason RE-ARGUED for this block
     * rather than inherited from ensureNda (D20/W2): the LOI stage is entered by the LOI approval's
     * own field update, so an unguarded stamp that hit an unavailable record type would throw
     * INVALID_CROSS_REFERENCE_KEY inside the APPROVAL transaction and the approver could not
     * approve at all. Production therefore degrades safely — and THIS is where the loudness lives
     * instead.
     *
     * ⚠ IT RE-QUERIES RecordTypeId. A creation that SUCCEEDED is not evidence the type landed: the
     * in-memory copy carries whatever was assigned, guard or no guard, and D13 residual 1 measured
     * an inserted row reading back null while the describe resolved a real Id.
     *
     * ⚠ HONEST LIMIT: this runs as an ADMIN, and the block runs in production as the APPROVER — a
     * principal on a profile T-A1 is most likely to have missed. Green here does not prove the
     * approver can stamp. Gate T-A1 must be verified for the approving principals' profile
     * specifically. (This note used to say "the same one the OwnerId assertion above carries";
     * that assertion was superseded on 2026-08-15 by loiBlock_ownerIsTheAcquisitionQueue, which
     * carries the SAME admin-vs-approver limit — a queue Id is org state, not principal state, so
     * green there does not prove the approver's own transaction resolves it either.)
     */
    @isTest
    static void loiBlock_stampsTheAcquisitionRecordType() {
        Test.startTest();
        Opportunity o = newOpp('LOI');
        insert o;
        Test.stopTest();

        LOI__c created = [
            SELECT Id, RecordTypeId FROM LOI__c WHERE Opportunity__c = :o.Id LIMIT 1
        ];

        Schema.RecordTypeInfo acquisitionInfo = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get('Acquisition_LOI');
        Assert.isNotNull(acquisitionInfo,
            'PRECONDITION: the LOI__c "Acquisition_LOI" record type does not exist in this org. '
            + 'objects/LOI__c/recordTypes/ must deploy BEFORE this class (metadata before Apex). '
            + 'Available: '
            + Schema.SObjectType.LOI__c.getRecordTypeInfosByDeveloperName().keySet());

        Assert.areEqual(acquisitionInfo.getRecordTypeId(), created.RecordTypeId,
            'D16.3: the LOI auto-created on entry to the LOI stage must carry the Acquisition_LOI '
            + 'record type. A NULL value here means the record type resolved a real Id but is not '
            + 'AVAILABLE to the running user, so the deliberate isAvailable() guard in '
            + 'OpportunityReviewService.acquisitionLoiRecordTypeId() silently no-opped — that is '
            + 'post-deploy gate T-A1 (profile record-type assignment) not having run, and until it '
            + 'does every acquisition LOI lands on Master, which matches NEITHER LOI Path and '
            + 'exposes all TEN Stage__c values. Do not soften this assertion to obtain a green '
            + 'suite; run T-A1.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // LOI OWNERSHIP — the Acquisition queue owns every auto-created LOI (2026-08-15)
    // ─────────────────────────────────────────────────────────────────────────

    /** DeveloperName of the queue the LOI block pins ownership to. */
    private static final String ACQUISITION_QUEUE = 'Acquisition';

    /**
     * 🔴 UNCONDITIONAL BY DESIGN, and the SAME shape as the three record-type stamp tests above:
     * the service degrades quietly in production because it runs inside an approval transaction,
     * so this is where the loudness lives.
     *
     * WHAT IT PINS: ownership of an auto-created LOI is a property of THE PROCESS, not of
     * whichever principal's transaction happened to run the trigger. In production that
     * principal is the APPROVER — the LOI stage is entered by the LOI approval's own field
     * update — and with OWD Private on LOI__c an approver-owned row is uneditable by the deal
     * team ("insufficient access rights on object id" on Advance Stage).
     *
     * ⚠ UNLIKE THE OWNER ASSERTION THIS REPLACES, THIS ONE CAN ACTUALLY FAIL. The old one
     * compared the LOI's owner to the deal's owner, which in test context are the same user
     * either way, so it pinned intent and nothing else. A queue Id is never the running user, so
     * a regression that dropped the queue assignment turns this red immediately.
     *
     * ⚠ EXPECT THIS RED UNTIL BOTH HALVES OF THE METADATA LAND, AND THE TWO PRECONDITIONS BELOW
     * TELL YOU WHICH HALF IS MISSING:
     *   1. the queue itself (queues/Acquisition.queue-meta.xml) — Group precondition;
     *   2. 🔴 LOI__c listed in that queue's `queueSobject` set — QueueSobject precondition. This
     *      is the one that is easy to miss: the queue shipped listing only Lead and Property__c.
     *      A queue that is not enabled for LOI__c CANNOT own one, so the service deliberately
     *      declines to assign it and keeps the deal owner. Do not soften this assertion to obtain
     *      a green suite; add LOI__c to the queue.
     *
     * The expected Id is read from Group DIRECTLY rather than through QueueGroupSelector, so the
     * assertion falsifies the selector as well as the service.
     */
    @isTest
    static void loiBlock_ownerIsTheAcquisitionQueue() {
        Test.startTest();
        Opportunity o = newOpp('LOI');
        insert o;
        Test.stopTest();

        List<Group> queues = [
            SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :ACQUISITION_QUEUE LIMIT 1
        ];
        Assert.isFalse(queues.isEmpty(),
            'PRECONDITION: no queue with DeveloperName "Acquisition" exists in this org. '
            + 'queues/Acquisition.queue-meta.xml must deploy BEFORE this class (metadata before '
            + 'Apex).');

        List<QueueSobject> enabledForLoi = [
            SELECT QueueId FROM QueueSobject
            WHERE SobjectType = 'LOI__c' AND Queue.DeveloperName = :ACQUISITION_QUEUE
            LIMIT 1
        ];
        Assert.isFalse(enabledForLoi.isEmpty(),
            'PRECONDITION: the "Acquisition" queue exists but is NOT enabled to own LOI__c. Add '
            + 'a <queueSobject><sobjectType>LOI__c</sobjectType></queueSobject> entry to '
            + 'queues/Acquisition.queue-meta.xml and deploy it. Until then '
            + 'OpportunityReviewService deliberately declines to assign the queue (assigning a '
            + 'queue that cannot own the object is refused BY THE DML, inside the approval '
            + 'transaction) and falls back to the deal owner.');

        LOI__c created = [SELECT Id, OwnerId FROM LOI__c WHERE Opportunity__c = :o.Id LIMIT 1];
        Assert.areEqual(queues[0].Id, created.OwnerId,
            'The LOI auto-created on entry to the LOI stage must be owned by the Acquisition '
            + 'QUEUE. A USER Id here means the queue could not be resolved and the service fell '
            + 'back to the deal owner — check the two preconditions above. In production the '
            + 'running user on this path is the APPROVER, so an owner that tracks the running '
            + 'user is exactly the defect this rule removes.');
    }

    /**
     * 🔴 THE MOST IMPORTANT TEST IN THIS GROUP — THE REGRESSION GUARD FOR "AN UNRESOLVABLE QUEUE
     * MUST NEVER TAKE DOWN AN APPROVAL".
     *
     * This block runs as a READ-ONLY APPROVER inside the LOI approval transaction. An exception
     * raised here does not cost an LOI — it rolls back the APPROVAL, and the approver is told
     * something unintelligible on an Approve click. That has already happened once on this
     * project (ApprovalAuditService / D10: a TypeException escaped a DmlException-only catch and
     * "Nikhil could not approve at all"). A queue that is missing, renamed, or not enabled for
     * LOI__c must therefore degrade, never throw.
     *
     * ⚠ THE DEGRADED OWNER IS THE DEAL'S OWNER, NOT NULL, AND THAT IS DELIBERATE. Leaving
     * OwnerId unset means the RUNNING USER, i.e. the approver — the original defect. The
     * deal-owner assignment is what this block did before the queue was introduced, so the
     * fallback is "the previous correct-enough answer", not "no answer".
     *
     * It drives the REAL selector against a name that does not exist rather than faking the
     * result, so the not-found path through QueueGroupSelector is genuinely exercised.
     */
    @isTest
    static void loiBlock_unresolvableQueue_fallsBackToTheDealOwner() {
        OpportunityReviewService.queueDeveloperNameOverride = 'ZZ_Nonexistent_Queue_9x7';

        Opportunity o = newOpp('LOI');
        Test.startTest();
        try {
            insert o;
        } catch (Exception e) {
            Assert.fail('An unresolvable Acquisition queue must NEVER throw — on the live path '
                + 'this exception rolls back the LOI APPROVAL, not just the LOI. Got: '
                + e.getTypeName() + ': ' + e.getMessage());
        }
        Test.stopTest();

        LOI__c created = [SELECT Id, OwnerId FROM LOI__c WHERE Opportunity__c = :o.Id LIMIT 1];
        Opportunity deal = [SELECT OwnerId FROM Opportunity WHERE Id = :o.Id LIMIT 1];

        Assert.areEqual(deal.OwnerId, created.OwnerId,
            'With no resolvable queue the LOI falls back to the DEAL OWNER. Null/running-user '
            + 'here means the fallback was removed in favour of leaving OwnerId unset, which on '
            + 'the live path hands the record to the APPROVER — the defect the deal-owner '
            + 'assignment was added to fix in the first place.');
        Assert.isNull(OpportunityReviewService.lastQueueLookupError,
            'A queue that simply does not exist must take the NOT-FOUND path (selector returns '
            + 'null), not the residual catch. A message here means the lookup threw, which is a '
            + 'different failure with a different cause.');
    }

    /**
     * The residual catch in acquisitionQueueId(). No ordinary input reaches it — a missing queue
     * returns null rather than throwing — so it is exercised through the simulate seam, exactly
     * as TransactionActionPermissionService.simulateLookupFailure is.
     *
     * The catch is deliberately WIDE (Exception, not QueryException) for the reason
     * ApprovalAuditService was forced to widen its own: a TypeException is not a DmlException,
     * and a narrow catch is how D10 escaped and rolled back an approval.
     */
    @isTest
    static void loiBlock_queueLookupThrows_isSwallowedAndFallsBack() {
        OpportunityReviewService.simulateQueueLookupFailure = true;

        Opportunity o = newOpp('LOI');
        Test.startTest();
        try {
            insert o;
        } catch (Exception e) {
            Assert.fail('A throwing queue lookup must be swallowed — on the live path it would '
                + 'otherwise roll back the LOI APPROVAL. Got: '
                + e.getTypeName() + ': ' + e.getMessage());
        }
        Test.stopTest();

        LOI__c created = [SELECT Id, OwnerId FROM LOI__c WHERE Opportunity__c = :o.Id LIMIT 1];
        Opportunity deal = [SELECT OwnerId FROM Opportunity WHERE Id = :o.Id LIMIT 1];

        Assert.areEqual(deal.OwnerId, created.OwnerId,
            'A swallowed lookup failure degrades to the deal owner, same as the not-found path');
        Assert.isNotNull(OpportunityReviewService.lastQueueLookupError,
            'The swallowed failure is RECORDED, not ignored — an empty value here means the '
            + 'catch body was emptied and a future failure would leave no trace at all');
    }

    /**
     * Bulk-safety for the LOI block per .claude/rules/bulk-test-rule.md — 251 records forces a
     * SECOND 200-record trigger batch, so the block runs twice in one transaction. bulkCreate
     * below covers the Development/Construction path; nothing covered this one.
     *
     * 🔴 IT IS ALSO THE "RESOLVED ONCE PER INVOCATION" PROOF, WHICH IS WHY IT IS A QUERY-BUDGET
     * TEST AND NOT MERELY A COUNT TEST. The queue lookup is SOQL, unlike the record-type
     * describe beside it. Per record it would be 251 queries against a 100-query limit, i.e. an
     * UNCATCHABLE LimitException — inside the approval transaction. Note what that means for
     * this assertion: a per-record regression most likely fails this test by THROWING before the
     * assertion is ever reached. The bound is asserted anyway so the intent is written down and
     * so a partial regression (say, per-chunk-per-record) is still caught.
     *
     * The bound is expressed structurally ("does not scale with record count") rather than as a
     * hand-tuned number, so it cannot go red because some unrelated bulkified automation was
     * added: any bulk-safe implementation passes, any per-record one fails.
     *
     * ⚠ OWNER IDENTITY IS DELIBERATELY NOT ASSERTED HERE — loiBlock_ownerIsTheAcquisitionQueue
     * owns that fact and is the only test that should go red on the queue metadata gate. What
     * IS asserted is that all 251 share ONE owner, which is gate-independent and still catches
     * the cross-chunk drift this test exists for (a value resolved for the first 200 and lost
     * for the remaining 51 would produce two distinct owners).
     */
    @isTest
    static void bulkLoiCreate_resolvesTheQueueOncePerChunk() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        for (Opportunity o : opps) {
            o.StageName = 'LOI'; // insert = stage entry; the LOI entry gates check ISCHANGED
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert opps;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        List<LOI__c> lois = [SELECT Id, OwnerId FROM LOI__c WHERE Opportunity__c IN :opps];
        Assert.areEqual(251, lois.size(), 'One LOI per deal across the full 251-record batch');

        Set<Id> owners = new Set<Id>();
        for (LOI__c loi : lois) {
            owners.add(loi.OwnerId);
        }
        Assert.areEqual(1, owners.size(),
            'All 251 LOIs share ONE owner. Two distinct owners means the owner was resolved for '
            + 'one 200-record trigger chunk and not the other — the cross-chunk drift a '
            + '200-record test cannot see.');
        Assert.isTrue(queriesUsed < 251,
            'The queue lookup must be resolved ONCE per trigger invocation, never per record. '
            + 'A query count that scales with the 251 records means the lookup moved inside the '
            + 'build loop, which on the live path is 251 queries against a 100-query limit — an '
            + 'UNCATCHABLE LimitException inside the LOI approval transaction. Queries used: '
            + queriesUsed);
    }

    @isTest
    static void ndaOpensOnNewOpportunity() {
        Test.startTest();
        Opportunity o = newOpp('New');
        insert o;
        Test.stopTest();

        List<NDA__c> ndas = [SELECT Status__c FROM NDA__c WHERE Opportunity__c = :o.Id];
        System.assertEquals(1, ndas.size(), 'A new Opportunity opens one NDA from the New stage');
        System.assertEquals('Pending', ndas[0].Status__c, 'NDA starts Pending');

        Opportunity stamped = [SELECT Primary_NDA__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(ndas[0].Id, stamped.Primary_NDA__c,
            'Primary_NDA__c stamped so the NDA tab and the signed-NDA gate have a record');

        // Idempotency: re-saving the Opp must not open a second NDA.
        update new Opportunity(Id = o.Id, Underwriting_Notes__c = 'touch');
        System.assertEquals(1, [SELECT COUNT() FROM NDA__c WHERE Opportunity__c = :o.Id],
            'No duplicate NDA on re-save');
    }

    /**
     * 🔴 D16.3 — THE REGRESSION GUARD, AND IT IS UNCONDITIONAL BY DESIGN. DO NOT WRAP IT IN
     * `if (isAvailable()) { ... }`.
     *
     * OpportunityReviewService.ensureNda predates NDA__c's record types and stamped none, so
     * once Tranche 3A adds Acquisition_NDA / Disposition_NDA every auto-created acquisition
     * NDA would silently land on MASTER — matching neither NDA Path, exposing all six
     * Status__c values, and sitting outside the RecordType-scoped NDA sharing rules this same
     * tranche introduces. That is damage to a LIVE flow, and it happens one deal at a time
     * with no error anywhere.
     *
     * The production stamp is deliberately GUARDED on isAvailable() (see the service header:
     * ensureNda is on the critical path of EVERY Opportunity insert, Database.convertLead
     * included, and an after-insert exception rolls the deal back). This test is where the
     * softness ends. It re-reads RecordTypeId from the database rather than trusting the
     * in-memory row, because a creation that SUCCEEDED is not evidence the type landed —
     * exactly the lesson behind D13 residual 1, post-deploy gate T-A1, and
     * TestDataFactoryTest.createDisposition_defaultOverload_stampsOnMarketRecordType.
     *
     * ⚠ EXPECT THIS TO BE RED UNTIL GATE T-A1 RUNS. objects/NDA__c/recordTypes/ deploying is
     * NOT enough — a record type assigned to no profile resolves a real Id and is still
     * unavailable to everyone, System Administrator included (Modify All Data is an OBJECT
     * permission and confers no record-type access). Report the failure; do not soften it.
     */
    @isTest
    static void ensureNda_stampsTheAcquisitionRecordType() {
        Test.startTest();
        Opportunity o = newOpp('New');
        insert o;
        Test.stopTest();

        NDA__c created = [
            SELECT Id, RecordTypeId FROM NDA__c WHERE Opportunity__c = :o.Id LIMIT 1
        ];

        Schema.RecordTypeInfo acquisitionInfo = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get('Acquisition_NDA');
        Assert.isNotNull(acquisitionInfo,
            'PRECONDITION: the NDA__c "Acquisition_NDA" record type does not exist in this org. '
            + 'objects/NDA__c/recordTypes/ must deploy BEFORE this class (metadata before Apex, '
            + 'design §6 T1). Available: '
            + Schema.SObjectType.NDA__c.getRecordTypeInfosByDeveloperName().keySet());

        Assert.areEqual(acquisitionInfo.getRecordTypeId(), created.RecordTypeId,
            'D16.3: the NDA auto-created by ensureNda must carry the Acquisition_NDA record '
            + 'type. A NULL value here means the record type resolved a real Id but is not '
            + 'AVAILABLE to the running user, so the deliberate isAvailable() guard in '
            + 'OpportunityReviewService.acquisitionNdaRecordTypeId() silently no-opped — that is '
            + 'post-deploy gate T-A1 (profile record-type assignment) not having run, and until '
            + 'it does every acquisition NDA in the org is created on Master. Do not soften this '
            + 'assertion to obtain a green suite; run T-A1.');
    }

    @isTest
    static void inputCheckboxesCreateReviewsAtAnyStage() {
        Opportunity o = newOpp('New');
        insert o;

        Test.startTest();
        // Both inputs requested while the deal is still at New - i.e. BEFORE
        // underwriting, without touching the stage.
        o.Development_Input_Needed__c = true;
        o.Construction_Input_Needed__c = true;
        update o;
        Test.stopTest();

        List<Development_Feasibility_Review__c> dfrs = [
            SELECT Requested_By__c FROM Development_Feasibility_Review__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, dfrs.size(), 'Development review created from the input checkbox');
        System.assertEquals(UserInfo.getUserId(), dfrs[0].Requested_By__c, 'Requester stamped');
        System.assertEquals(1,
            [SELECT COUNT() FROM Construction_Feasibility_Review__c WHERE Opportunity__c = :o.Id],
            'Construction review created from the input checkbox');
        System.assertEquals('New', [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Stage untouched - reviews can open before underwriting');
    }

    @isTest
    static void recheckedInputCheckboxIsIdempotent() {
        Opportunity o = newOpp('New');
        insert o;
        o.Development_Input_Needed__c = true;
        update o;

        Test.startTest();
        o.Development_Input_Needed__c = false;
        update o;
        o.Development_Input_Needed__c = true;
        update o;
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Development_Feasibility_Review__c WHERE Opportunity__c = :o.Id],
            'Re-flipping the checkbox must not create a second review');
    }

    @isTest
    static void developmentReviewCreatesOnInsert() {
        Test.startTest();
        Opportunity o = newOpp('Development Review');
        insert o;
        Test.stopTest();

        List<Development_Feasibility_Review__c> dfrs = [
            SELECT Opportunity__c, Stage__c
            FROM Development_Feasibility_Review__c
            WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, dfrs.size(), 'One Development review should be created');
        System.assertEquals('Requested', dfrs[0].Stage__c, 'Should start at the Requested stage');
        System.assertEquals(0, [SELECT COUNT() FROM Construction_Feasibility_Review__c],
            'No Construction review for a Development-stage opp');
    }

    @isTest
    static void constructionReviewCreatesOnUpdate() {
        Opportunity o = newOpp('New');
        insert o;

        Test.startTest();
        o.StageName = 'Construction Review';
        update o;
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Construction_Feasibility_Review__c WHERE Opportunity__c = :o.Id],
            'One Construction review should be created on the stage change');
        System.assertEquals(0, [SELECT COUNT() FROM Development_Feasibility_Review__c],
            'No Development review for a Construction-stage opp');
    }

    @isTest
    static void contractReviewCreatesOnUpdate() {
        Opportunity o = newOpp('Under Review');
        insert o;
        // Entering PSA crosses the signed-NDA gate (which covers PSA) and the approved-LOI gate.
        TestDataFactory.signPrimaryNda(o);
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        // Completed_LOI_Before_PSA (added 2026-08-12) also gates PSA entry, reading the LOI's OWN
        // Stage__c rather than the Opportunity's Primary_LOI__c/LOI_Approved__c flags.
        // placeApprovedLoi leaves the LOI at its factory-default Stage__c = 'Draft', so drive it to
        // 'Signed' via the real production route first — same fix as
        // StageAdvanceServiceTest.advanceMovesLoiToPsaAndPsaToClosedWon.
        // ⚠ 'Signed' since observation 5 (2026-08-14); it was 'Completed' until the acquisition LOI
        // sequence was renamed. It must stay in step with Completed_LOI_Before_PSA, the rule this
        // line exists to satisfy.
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Signed');

        Test.startTest();
        o.StageName = 'Under Contract (PSA)';
        update o;
        Test.stopTest();

        List<Contract_Review__c> crs = [
            SELECT Stage__c, Negotiation_Status__c
            FROM Contract_Review__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, crs.size(), 'One Contract review should be created on PSA');
        System.assertEquals('PSA Drafting', crs[0].Stage__c, 'Should start at PSA Drafting');
        // 🔴 THE C3 FALSIFIER — see contractReviewBlock_seedsTheAcquisitionNegotiationStatus below
        // for the full argument. Asserted here too, in the ordinary happy-path test, because that
        // is where a future "simplification" back to the field default would be made.
        System.assertEquals('Draft', crs[0].Negotiation_Status__c,
            'The auto-created acquisition Contract Review must be SEEDED with Draft, not left to '
            + 'the field-level default (Initial Draft), which is a Disposition_PSA value');

        // The new Contract Review is stamped back onto the Opportunity so the
        // Contract tab can render its fields via Primary_Contract__r.*
        Opportunity stamped = [SELECT Primary_Contract__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(crs[0].Id, stamped.Primary_Contract__c,
            'Opportunity.Primary_Contract__c should point at the new Contract Review');
    }

    /**
     * 🔴 UNCONDITIONAL BY DESIGN — D16.3, Tranche 3C. The third and last of the trio
     * (ensureNda_stampsTheAcquisitionRecordType, loiBlock_stampsTheAcquisitionRecordType). It must
     * NOT be guarded on isAvailable().
     *
     * The stamp in the service IS guarded, deliberately, and the argument was RE-ARGUED for THIS
     * block rather than inherited from either sibling (D20/W2). It is neither ensureNda's
     * (every Opportunity insert, lead conversion included) nor the LOI block's (runs as a
     * read-only approver inside an approval): this block runs as a DEAL DRIVER WHO HAS EDIT. What
     * still rules out an unguarded stamp is (a) 'Under Contract (PSA)' has exactly ONE route in
     * (StageAdvanceService.advance from 'LOI'), so blocking it parks every deal in the org at LOI
     * and the whole contract module becomes unreachable; and (b) this insert shares ONE all-or-none
     * transaction with four sibling children and runs FIRST, so its failure aborts their creation
     * too. Full text in the service header.
     *
     * ⚠ IT RE-QUERIES RecordTypeId. A creation that SUCCEEDED is not evidence the type landed: the
     * in-memory copy carries whatever was assigned, guard or no guard, and D13 residual 1 measured
     * an inserted row reading back null while the describe resolved a real Id.
     *
     * ⚠ 🔴 THIS PARAGRAPH WAS REWRITTEN 2026-08-14 BECAUSE OBSERVATION 7 CHANGED ITS ANSWER. It
     * used to read: "THIS OBJECT'S FAILURE MODE IS QUIETER THAN ITS TWO SIBLINGS' ... A Master-type
     * Contract Review advances PERFECTLY (both PSA record types share one Negotiation_Status__c
     * sequence); it is wrong only about its Path, its Ball_In_Court__c value set and which persona
     * may drive it. Nothing in the UI would lead anyone to gate T-A1."
     *
     * The premise is dead: RecordStageAdvanceService's shared PSA map was SPLIT (design collision
     * C9), so the two record types no longer share a sequence. A Master-type Contract Review now
     * falls back to the ACQUISITION map — which, because this block also seeds
     * Negotiation_Status__c = 'Draft' explicitly (C3), still fits a row THIS class created. So the
     * quietness survives for the population this test covers, but for a NEW reason and only in
     * combination with the C3 seed. A LEGACY Master-type row (created before this pack, still on
     * 'Initial Draft') is now loudly broken — it refuses on its first Advance Stage click.
     * ⇒ Do not read either half as making the other unnecessary. This test pins the record type;
     *   contractReviewBlock_seedsTheAcquisitionNegotiationStatus pins the status. Remove the seed
     *   and this test still passes while every auto-created PSA is unusable.
     */
    @isTest
    static void contractReviewBlock_stampsTheAcquisitionRecordType() {
        Opportunity o = newOpp('Under Review');
        insert o;
        TestDataFactory.signPrimaryNda(o);
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        // Completed_LOI_Before_PSA (added 2026-08-12) also gates PSA entry, reading the LOI's OWN
        // Stage__c. placeApprovedLoi leaves it at 'Draft', so drive it to 'Completed' via the real
        // production route first — same fix as contractReviewCreatesOnUpdate above. ⚠ 'Signed'
        // since observation 5 (2026-08-14).
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Signed');

        Test.startTest();
        o.StageName = 'Under Contract (PSA)';
        update o;
        Test.stopTest();

        Contract_Review__c created = [
            SELECT Id, RecordTypeId FROM Contract_Review__c WHERE Opportunity__c = :o.Id LIMIT 1
        ];

        Schema.RecordTypeInfo acquisitionInfo = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get('Acquisition_PSA');
        Assert.isNotNull(acquisitionInfo,
            'PRECONDITION FAILED: the Contract_Review__c "Acquisition_PSA" record type does not '
            + 'exist in this org. objects/Contract_Review__c/recordTypes/ must deploy BEFORE this '
            + 'class (metadata before Apex). Available: '
            + Schema.SObjectType.Contract_Review__c.getRecordTypeInfosByDeveloperName().keySet());

        Assert.areEqual(acquisitionInfo.getRecordTypeId(), created.RecordTypeId,
            'PRECONDITION FAILED / post-deploy gate T-A1 — D16.3: the Contract Review auto-created '
            + 'on entry to the PSA stage must carry the Acquisition_PSA record type. A NULL value '
            + 'here means the record type resolved a real Id but is not AVAILABLE to the running '
            + 'user, so the deliberate isAvailable() guard in '
            + 'OpportunityReviewService.acquisitionPsaRecordTypeId() silently no-opped — that is '
            + 'gate T-A1 (profile record-type assignment) not having run, and until it does every '
            + 'acquisition Contract Review lands on Master, matching NEITHER PSA Path and exposing '
            + 'the UNION of both types\' Ball_In_Court__c values (so a purchase offers "Buyer", '
            + 'which names DPEG itself). Do not soften this assertion to obtain a green suite; run '
            + 'T-A1.');
    }

    /**
     * 🔴 THE C3 FALSIFIER. Design collision C3, Acquisition Observations observation 7, 2026-08-14.
     *
     * ── WHAT THIS EXISTS TO CATCH ────────────────────────────────────────────
     * Until this change, the Contract Review insert set ONLY `Opportunity__c` and `Stage__c` and
     * took `Negotiation_Status__c` from the FIELD-LEVEL DEFAULT, which is 'Initial Draft'.
     * Observation 7 removes 'Initial Draft' from `Acquisition_PSA`, so the default became a value
     * this record type does not carry.
     *
     * ⚠ RETRACTED 2026-08-21 — THE PARAGRAPH THAT SAT HERE WAS THE STRONGEST ARGUMENT FOR THIS
     * TEST AND ITS PREMISE IS FALSE. It read: "🔴 AND THAT IS INVISIBLE WITHOUT THIS ASSERTION.
     * Apex DML does NOT enforce record-type picklist restriction, so the insert commits happily on
     * the off-set value: no exception, no error, a green deploy, and — critically —
     * `contractReviewCreatesOnUpdate` and `contractReviewBlock_stampsTheAcquisitionRecordType` both
     * stay GREEN, because neither looks at the status. The damage only surfaces in the UI: the Path
     * renders blank ... Every deal entering 'Under Contract (PSA)' would produce one such record."
     * `Negotiation_Status__c` is `restricted` and this exact rejection was MEASURED on 2026-08-21.
     * So the regression would NOT be invisible: the two sibling tests named above would go RED at
     * their own fixture, because the trigger's insert throws and rolls their Opportunity save back.
     * ⇒ WHAT THIS TEST IS STILL FOR, stated honestly and smaller than before: it is the only test
     * that names the CORRECT value. The siblings would report "your Opportunity save failed" with a
     * platform error code; this one reports which constant is wrong and why the field default is
     * not the fix. Keep it — a diagnosis is worth having even when a detector already exists.
     *
     * ── WHY IT IS NOT SOLVED BY MOVING THE FIELD DEFAULT ─────────────────────
     * `Disposition_PSA` still runs on 'Initial Draft' — `DispositionStageEntryService` seeds it
     * deliberately, and O3 of the requirements doc makes keeping that value ACTIVE a hard stop. The
     * default serves the sell side; the buy side names its own seed. Anyone who "fixes" this by
     * editing the field default breaks the disposition PSA instead, and
     * `DispositionStageEntryServiceTest` is where that would show up.
     *
     * ── THE SECOND ASSERTION IS THE ONE THAT EARNS ITS KEEP ──────────────────
     * Asserting the stored value alone would still pass if someone deleted the explicit stamp AND
     * the field default happened to be right. Walking the record through `advance()` proves the
     * seed is on the ACQUISITION SEQUENCE — which is the property that actually matters and the one
     * the platform will not check.
     */
    @isTest
    static void contractReviewBlock_seedsTheAcquisitionNegotiationStatus() {
        Opportunity o = newOpp('Under Review');
        insert o;
        TestDataFactory.signPrimaryNda(o);
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Signed');

        Test.startTest();
        o.StageName = 'Under Contract (PSA)';
        update o;
        Test.stopTest();

        Contract_Review__c created = [
            SELECT Id, Negotiation_Status__c
            FROM Contract_Review__c WHERE Opportunity__c = :o.Id LIMIT 1
        ];

        Assert.areEqual('Draft', created.Negotiation_Status__c,
            'The auto-created ACQUISITION Contract Review must be seeded with Negotiation_Status__c '
            + '= Draft EXPLICITLY. "Initial Draft" here means the explicit stamp was removed and the '
            + 'FIELD-LEVEL DEFAULT took over — a Disposition_PSA value. ⚠ 2026-08-21: this message '
            + 'used to continue "Apex DML does not enforce record-type picklist restriction, so '
            + 'that commits silently"; it does not — the field is RESTRICTED, the insert throws '
            + 'INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST inside the trigger, and every deal entering '
            + '"Under Contract (PSA)" is BLOCKED rather than quietly damaged. '
            + 'Do NOT fix this by changing the field default: '
            + 'Disposition_PSA still runs on Initial Draft (requirements O3, a hard stop).');

        // 🔴 THE SEED MUST BE ON THE SEQUENCE, NOT MERELY THE RIGHT STRING. This is what a
        // stored-value assertion alone cannot prove.
        String firstHop = RecordStageAdvanceService.advance(created.Id);
        Assert.areEqual('Contract Review moved to Negotiation.', firstHop,
            'The seeded status must be the ENTRY POINT of CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE. A '
            + '"no next step available" refusal here means the seed and the stage map disagree — '
            + 'the record is born unusable even though its status looks plausible.');
    }

    @isTest
    static void noDuplicateOnReentry() {
        Opportunity o = newOpp('Development Review');
        insert o; // creates the first review

        Test.startTest();
        // Move away via Dead/Pass, then come back.
        //
        // This used to move away via Under Review, which the backward-stage block now forbids
        // (Development Review is rank 3, Under Review rank 2). The test's subject is RE-ENTRY
        // IDEMPOTENCY, not the direction of travel, so the "away" hop is re-routed rather than
        // the assertion weakened. Dead/Pass is the only stage that expresses "left and came back"
        // without contradicting the new rules: it is deliberately UNRANKED, so entering it is
        // always allowed (the escape hatch every stranded deal needs) and leaving it is always
        // allowed (reviving a passed deal). It is also outside the signed-NDA gate's stage list,
        // so this fixture still needs no NDA — which keeps the test about duplicate reviews.
        o.StageName = 'Dead/Pass';
        update o; // moves away — no create
        o.StageName = 'Development Review';
        update o; // re-enters — must NOT create a second
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Development_Feasibility_Review__c WHERE Opportunity__c = :o.Id],
            'Re-entering the stage must not create a duplicate review');
    }

    /**
     * Bulk-safety per .claude/rules/bulk-test-rule.md: 251 records forces a
     * second 200-record trigger batch, exposing SOQL/DML-in-loop bugs that a
     * 200-record test would hide. Note OpportunityReviewTrigger.ensureNda also
     * fires on every insert here (251 NDA inserts + 251 Opp stamp updates), on
     * top of the feasibility-review cascade this test targets.
     */
    @isTest
    static void bulkCreate() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        for (Integer i = 0; i < opps.size(); i++) {
            opps[i].StageName = Math.mod(i, 2) == 0 ? 'Development Review' : 'Construction Review';
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        // 251 alternating starting at index 0 (Development): 126 even indices, 125 odd.
        System.assertEquals(126, [SELECT COUNT() FROM Development_Feasibility_Review__c],
            '126 Development reviews from 251 alternating opps');
        System.assertEquals(125, [SELECT COUNT() FROM Construction_Feasibility_Review__c],
            '125 Construction reviews from 251 alternating opps');
        System.assertEquals(251, [SELECT COUNT() FROM NDA__c WHERE Opportunity__c IN :opps],
            'ensureNda still opens one NDA per Opportunity across the full bulk batch');
    }
}
