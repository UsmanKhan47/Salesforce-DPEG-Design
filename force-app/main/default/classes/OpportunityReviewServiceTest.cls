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

        // The LOI must be owned by the DEAL's owner, not by whoever's transaction created it. In
        // production that creator is the APPROVER (the LOI stage is entered by the approval's own
        // field update), and with OWD Private that left the record uneditable by the deal team.
        // ⚠ HONEST LIMIT: this assertion cannot FAIL in test context - the running user owns the
        // Opportunity, so a regression that dropped the OwnerId assignment would still produce a
        // matching owner by default. It pins intent, not the defect. Only a real approval by a
        // principal distinguishes the two, which is exactly why this reached production.
        Opportunity dealOwner = [SELECT OwnerId FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(dealOwner.OwnerId, lois[0].OwnerId,
            'LOI is owned by the deal owner, not the running user');

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
     * ⚠ HONEST LIMIT, the same one the OwnerId assertion above carries: this runs as an ADMIN, and
     * the block runs in production as the APPROVER — a principal on a profile T-A1 is most likely
     * to have missed. Green here does not prove the approver can stamp. Gate T-A1 must be verified
     * for the approving principals' profile specifically.
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
        TestDataFactory.placeApprovedLoi(o);

        Test.startTest();
        o.StageName = 'PSA';
        update o;
        Test.stopTest();

        List<Contract_Review__c> crs = [
            SELECT Stage__c FROM Contract_Review__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, crs.size(), 'One Contract review should be created on PSA');
        System.assertEquals('PSA Drafting', crs[0].Stage__c, 'Should start at PSA Drafting');

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
     * still rules out an unguarded stamp is (a) 'PSA' has exactly ONE route in
     * (StageAdvanceService.advance from 'LOI'), so blocking it parks every deal in the org at LOI
     * and the whole contract module becomes unreachable; and (b) this insert shares ONE all-or-none
     * transaction with four sibling children and runs FIRST, so its failure aborts their creation
     * too. Full text in the service header.
     *
     * ⚠ IT RE-QUERIES RecordTypeId. A creation that SUCCEEDED is not evidence the type landed: the
     * in-memory copy carries whatever was assigned, guard or no guard, and D13 residual 1 measured
     * an inserted row reading back null while the describe resolved a real Id.
     *
     * ⚠ THIS OBJECT'S FAILURE MODE IS QUIETER THAN ITS TWO SIBLINGS', WHICH IS WHY THE TEST MATTERS
     * MORE HERE. A Master-type NDA or LOI is visibly broken — the stage map does not fit it. A
     * Master-type Contract Review advances PERFECTLY (both PSA record types share one
     * Negotiation_Status__c sequence); it is wrong only about its Path, its Ball_In_Court__c value
     * set and which persona may drive it. Nothing in the UI would lead anyone to gate T-A1.
     */
    @isTest
    static void contractReviewBlock_stampsTheAcquisitionRecordType() {
        Opportunity o = newOpp('Under Review');
        insert o;
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.placeApprovedLoi(o);

        Test.startTest();
        o.StageName = 'PSA';
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
