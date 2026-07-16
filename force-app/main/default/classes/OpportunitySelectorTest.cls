/**
 * Tests for OpportunitySelector.
 *
 * Coverage: every method (aggregate, count, dynamic count, top-N list, two
 * fetch-for-use single-row reads) plus a 251-record bulk aggregate and a
 * System.runAs(Standard User) proof that USER_MODE does not throw for the
 * restricted persona the P4 design §5 measured.
 *
 * @TestSetup builds 251 'New' Opportunities (factory default CloseDate = today+90,
 * Deal_Type__c = 'Commercial'); test methods QUERY that data — they never call
 * default*() (TestDataFactory ⚠1 cache trap).
 */
@isTest
private class OpportunitySelectorTest {

    private static final Integer BULK_N = 251;

    @TestSetup
    static void setup() {
        TestDataFactory.createOpportunities(BULK_N, true);
    }

    @isTest
    static void countByStage_bulk_groupsAllRecords() {
        Test.startTest();
        List<AggregateResult> results = OpportunitySelector.countByStage();
        Test.stopTest();

        Integer newCount = null;
        for (AggregateResult ar : results) {
            if ('New'.equals((String) ar.get('st'))) {
                newCount = (Integer) ar.get('c');
            }
        }
        Assert.areEqual(BULK_N, newCount, 'All 251 New Opportunities should be grouped into the New bucket');
    }

    @isTest
    static void countByStageInLastNDays_countsOnlyInWindow() {
        // The 251 setup Opportunities have a future CloseDate and must be excluded;
        // create 3 with CloseDate = today so only they fall inside LAST_N_DAYS:90.
        List<Opportunity> recent = TestDataFactory.createOpportunities(3, false);
        for (Opportunity o : recent) {
            o.CloseDate = Date.today();
        }
        insert recent;

        Test.startTest();
        Integer count = OpportunitySelector.countByStageInLastNDays('New', 90);
        Test.stopTest();

        Assert.areEqual(3, count, 'Only the 3 Opportunities with CloseDate = today are within LAST_N_DAYS:90');
    }

    @isTest
    static void selectTopByAskingPrice_ordersDescendingAndLimits() {
        Test.startTest();
        List<Opportunity> top = OpportunitySelector.selectTopByAskingPrice(5);
        Test.stopTest();

        Assert.areEqual(5, top.size(), 'LIMIT should cap the result at 5');
        for (Integer i = 1; i < top.size(); i++) {
            Assert.isTrue(
                top[i - 1].Asking_Price__c >= top[i].Asking_Price__c,
                'Rows must be ordered by Asking_Price__c descending'
            );
        }
        Assert.isNotNull(top[0].Name, 'Name must be populated for the row-mapping caller');
        Assert.isNotNull(top[0].StageName, 'StageName must be populated');
    }

    @isTest
    static void aggregateOpenPipeline_sumsOpenDeals() {
        Set<String> closedStages = new Set<String>{ 'Closed Won', 'Dead/Pass' };

        Test.startTest();
        List<AggregateResult> results = OpportunitySelector.aggregateOpenPipeline(closedStages);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'A pipeline aggregate returns a single summary row');
        Assert.areEqual(BULK_N, (Integer) results[0].get('c'), 'All 251 New deals are open');
        Assert.isNotNull(results[0].get('v'), 'SUM(Asking_Price__c) should be populated when rows match');
    }

    @isTest
    static void countByDealType_matchesCommercialAndLand() {
        Test.startTest();
        Integer commercial = OpportunitySelector.countByDealType('Commercial');
        Integer land = OpportunitySelector.countByDealType('Land');
        Test.stopTest();

        Assert.areEqual(BULK_N, commercial, 'All 251 factory Opportunities are Commercial');
        Assert.areEqual(0, land, 'No Land Opportunities were created');
    }

    @isTest
    static void selectPrimaryRefsById_returnsRecord() {
        Opportunity existing = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        Opportunity result = OpportunitySelector.selectPrimaryRefsById(existing.Id);
        Test.stopTest();

        Assert.areEqual(existing.Id, result.Id, 'Should return the requested Opportunity');
    }

    @isTest
    static void selectPrimaryRefsById_missing_throwsQueryException() {
        Id ghostId = ghostOpportunityId();

        Test.startTest();
        try {
            OpportunitySelector.selectPrimaryRefsById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    @isTest
    static void selectStageRequiredById_returnsStage() {
        Opportunity existing = [SELECT Id, StageName FROM Opportunity LIMIT 1];

        Test.startTest();
        Opportunity result = OpportunitySelector.selectStageRequiredById(existing.Id);
        Test.stopTest();

        Assert.areEqual(existing.Id, result.Id, 'Should return the requested Opportunity');
        Assert.areEqual('New', result.StageName, 'StageName must be populated');
    }

    @isTest
    static void selectStageRequiredById_missing_throwsQueryException() {
        Id ghostId = ghostOpportunityId();

        Test.startTest();
        try {
            OpportunitySelector.selectStageRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    @isTest
    static void userMode_standardUser_doesNotThrow() {
        User standardUser = buildStandardUser();
        insert standardUser;

        Test.startTest();
        System.runAs(standardUser) {
            // Standard fields selected here are permissionable=false (always readable);
            // USER_MODE must not raise an FLS error for a Standard User (P4 design §5).
            List<AggregateResult> results = OpportunitySelector.countByStage();
            Assert.isNotNull(results, 'USER_MODE aggregate must not throw for a Standard User');
        }
        Test.stopTest();
    }

    /** A syntactically valid Opportunity Id that resolves to no row (create then delete). */
    private static Id ghostOpportunityId() {
        Opportunity ghost = TestDataFactory.createOpportunity(null, true);
        Id ghostId = ghost.Id;
        delete ghost;
        return ghostId;
    }

    private static User buildStandardUser() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'oppsel' + System.currentTimeMillis();
        return new User(
            ProfileId = standard.Id,
            LastName = 'OppSelTest',
            Email = 'oppseltest@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            Alias = 'osel',
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
