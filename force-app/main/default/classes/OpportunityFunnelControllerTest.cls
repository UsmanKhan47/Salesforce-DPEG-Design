/**
 * Tests OpportunityFunnelController: the "Opportunities by Stage" funnel widget,
 * the recent/biggest-deals list, and the open-pipeline snapshot on the
 * Acquisition home page.
 */
@isTest
private class OpportunityFunnelControllerTest {

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    @isTest
    static void getStageCounts_countsEachStageWithRecencyScopingForOutcomes() {
        List<Opportunity> opps = new List<Opportunity>();
        opps.addAll(TestDataFactory.createOpportunities(2, false)); // default stage 'New'
        opps.add(newOpp('Under Review'));
        opps.add(newOpp('Development Review'));
        opps.add(newOpp('Construction Review'));
        opps.add(newOpp('Underwriting'));
        opps.add(newOpp('LOI'));
        opps.add(newOpp('About to Close'));

        // PSA / Closed Won / Dead-Pass are recency-scoped to the last 90 days by
        // CloseDate. One of each pair keeps the factory's default (today + 90,
        // i.e. OUTSIDE the last-90-days window) and must NOT be counted; the other
        // is backdated to today so it falls inside the window and IS counted.
        Opportunity psaOld = newOpp('Under Contract (PSA)');
        Opportunity psaRecent = newOpp('Under Contract (PSA)');
        psaRecent.CloseDate = Date.today();
        opps.add(psaOld);
        opps.add(psaRecent);

        Opportunity wonOld = newOpp('Closed Won');
        Opportunity wonRecent = newOpp('Closed Won');
        wonRecent.CloseDate = Date.today();
        opps.add(wonOld);
        opps.add(wonRecent);

        Opportunity lostOld = newOpp('Dead/Pass');
        Opportunity lostRecent = newOpp('Dead/Pass');
        lostRecent.CloseDate = Date.today();
        opps.add(lostOld);
        opps.add(lostRecent);

        insert opps;

        Test.startTest();
        List<OpportunityFunnelController.StageCount> counts = OpportunityFunnelController.getStageCounts();
        Test.stopTest();

        System.assertEquals(10, counts.size(), 'All 10 funnel stages are always returned, in funnel order');
        System.assertEquals('New', counts[0].label, 'Funnel order starts at New');
        System.assertEquals('Dead/Pass', counts[9].label, 'Funnel order ends at Dead/Pass');

        Map<String, Integer> countByLabel = new Map<String, Integer>();
        for (OpportunityFunnelController.StageCount sc : counts) {
            countByLabel.put(sc.label, sc.count);
        }
        System.assertEquals(2, countByLabel.get('New'), 'Two New opportunities were inserted');
        System.assertEquals(1, countByLabel.get('Under Review'), 'One Under Review opportunity was inserted');
        System.assertEquals(1, countByLabel.get('Development Review'), 'One Development Review opportunity was inserted');
        System.assertEquals(1, countByLabel.get('Construction Review'), 'One Construction Review opportunity was inserted');
        System.assertEquals(1, countByLabel.get('Underwriting'), 'One Underwriting opportunity was inserted');
        System.assertEquals(1, countByLabel.get('LOI'), 'One LOI opportunity was inserted');
        System.assertEquals(1, countByLabel.get('About to Close'), 'About to Close is not recency-scoped, so the raw count is used');
        System.assertEquals(1, countByLabel.get('Under Contract (PSA)'), 'Only the recently-closed PSA opportunity falls in the 90-day window');
        System.assertEquals(1, countByLabel.get('Closed Won'), 'Only the recently-closed Closed Won opportunity falls in the 90-day window');
        System.assertEquals(1, countByLabel.get('Dead/Pass'), 'Only the recently-closed Dead/Pass opportunity falls in the 90-day window');
        // The legacy 'Portfolio Deal' stage was retired (Portfolio Deal rename, Phase A1) and is no
        // longer emitted by STAGE_ORDER, so there is no longer a permanently-zero card to assert on.
        Assert.isFalse(countByLabel.containsKey('Portfolio Deal'),
            'The retired Portfolio Deal stage is no longer returned by the funnel');
    }

    @isTest
    static void getRecentOpportunities_ordersByAskingPriceDescNullsLast() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(5, false);
        opps[0].Asking_Price__c = 5000000;
        opps[1].Asking_Price__c = 9000000;
        opps[2].Asking_Price__c = 2000000;
        opps[3].Asking_Price__c = 7000000;
        opps[4].Asking_Price__c = null;
        insert opps;

        Test.startTest();
        List<OpportunityFunnelController.OppRow> rows = OpportunityFunnelController.getRecentOpportunities();
        Test.stopTest();

        System.assertEquals(5, rows.size(), 'All 5 opportunities are returned (under the 5-row cap)');
        System.assertEquals(9000000, rows[0].price, 'Highest asking price sorts first');
        System.assertEquals(7000000, rows[1].price, 'Second-highest asking price sorts second');
        System.assertEquals(5000000, rows[2].price, 'Third-highest asking price sorts third');
        System.assertEquals(2000000, rows[3].price, 'Fourth-highest asking price sorts fourth');
        System.assertEquals(null, rows[4].price, 'The priceless deal sorts LAST, not first (NULLS LAST)');

        OpportunityFunnelController.OppRow top = rows[0];
        System.assertNotEquals(null, top.id, 'id is populated');
        System.assertNotEquals(null, top.name, 'name is populated');
        System.assertEquals('New', top.stage, 'stage mirrors StageName');
        System.assertEquals('Retail', top.dealType, 'dealType mirrors Deal_Type__c');
        System.assertEquals('Retail Strip', top.assetType, 'assetType mirrors Asset_Type__c');
        System.assertEquals(0, top.days, 'Created moments ago, so days-since-creation is 0');
    }

    @isTest
    static void getPipelineSnapshot_excludesClosedStagesAndCountsByDealType() {
        List<Opportunity> openCommercial = TestDataFactory.createOpportunities(2, false);
        List<Opportunity> openLand = TestDataFactory.createOpportunities(2, false);
        for (Opportunity o : openLand) {
            o.Deal_Type__c = 'Land';
        }
        Opportunity closedWon = TestDataFactory.createOpportunity(null, false);
        closedWon.StageName = 'Closed Won';
        Opportunity closedLost = TestDataFactory.createOpportunity(null, false);
        closedLost.StageName = 'Dead/Pass';

        List<Opportunity> openDeals = new List<Opportunity>();
        openDeals.addAll(openCommercial);
        openDeals.addAll(openLand);

        List<Opportunity> allOpps = new List<Opportunity>();
        allOpps.addAll(openDeals);
        allOpps.add(closedWon);
        allOpps.add(closedLost);
        insert allOpps;

        Decimal expectedPipelineValue = 0;
        for (Opportunity o : openDeals) {
            expectedPipelineValue += o.Asking_Price__c;
        }

        Test.startTest();
        OpportunityFunnelController.PipelineSnapshot snap = OpportunityFunnelController.getPipelineSnapshot();
        Test.stopTest();

        System.assertEquals(4, snap.openDeals, 'Closed Won and Dead/Pass are excluded from the open-deal count');
        System.assertEquals(expectedPipelineValue, snap.pipelineValue, 'Pipeline value sums only the open deals asking price');
        System.assertEquals(2, snap.landDeals, 'Two Land-type opportunities exist regardless of stage');
        System.assertEquals(4, snap.commercialDeals,
            'The 2 open + 2 closed (default Retail) opportunities are counted regardless of stage');
    }

    @isTest
    static void noOpportunities_allMethodsReturnEmptyOrZeroDefaults() {
        Test.startTest();
        List<OpportunityFunnelController.StageCount> counts = OpportunityFunnelController.getStageCounts();
        List<OpportunityFunnelController.OppRow> recent = OpportunityFunnelController.getRecentOpportunities();
        OpportunityFunnelController.PipelineSnapshot snap = OpportunityFunnelController.getPipelineSnapshot();
        Test.stopTest();

        System.assertEquals(10, counts.size(), 'All 10 funnel stages are always returned, even with zero data');
        for (OpportunityFunnelController.StageCount sc : counts) {
            System.assertEquals(0, sc.count, 'Every stage count is 0 when there are no opportunities: ' + sc.label);
        }
        System.assertEquals(0, recent.size(), 'No opportunities means no rows in the recent-deals list');
        System.assertEquals(0, snap.openDeals, 'No open deals when there is zero data');
        System.assertEquals(0, snap.pipelineValue, 'Pipeline value is 0 (not null) when SUM() has no rows to sum');
        System.assertEquals(0, snap.landDeals, 'No Land deals when there is zero data');
        System.assertEquals(0, snap.commercialDeals, 'No Retail deals when there is zero data');
    }

    // A user on the "Minimum Access - Salesforce" profile has NO Opportunity object
    // access, so even getStageCounts (which reads only the standard StageName/CloseDate
    // fields, where a plain Standard User would NOT trip FLS) throws under WITH USER_MODE
    // on object access. That drives every read-failure catch to a user-safe
    // AuraHandledException (P6 boundaries).
    private static User noAccessUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User u = new User(Alias = 'p6min', Email = 'p6min@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Min', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6min.funnel.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers the read-failure catch on all three @AuraEnabled reads: under a user with no
     * Opportunity object access, WITH USER_MODE throws, and each method maps it to a
     * user-safe AuraHandledException. One method because noAccessUser() inserts a User
     * (setup DML) and no record DML runs here (the queries throw before any) — avoids
     * MIXED_DML_OPERATION.
     */
    @isTest
    static void readCatchesThrowAuraHandledException() {
        User u = noAccessUser();
        System.runAs(u) {
            Test.startTest();
            try { OpportunityFunnelController.getStageCounts(); Assert.fail('getStageCounts should throw under a no-access user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getStageCounts maps read failure to AuraHandledException'); }
            try { OpportunityFunnelController.getRecentOpportunities(); Assert.fail('getRecentOpportunities should throw under a no-access user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getRecentOpportunities maps read failure to AuraHandledException'); }
            try { OpportunityFunnelController.getPipelineSnapshot(); Assert.fail('getPipelineSnapshot should throw under a no-access user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getPipelineSnapshot maps read failure to AuraHandledException'); }
            Test.stopTest();
        }
    }
}
