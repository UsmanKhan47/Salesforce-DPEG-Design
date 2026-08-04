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
