/**
 * Tests OpportunityReviewService: a feasibility-review child is created when an
 * Opportunity enters Development Review / Construction Review, exactly once.
 */
@isTest
private class OpportunityReviewServiceTest {

    private static Opportunity newOpp(String stage) {
        return new Opportunity(
            Name = 'Test Deal',
            StageName = stage,
            CloseDate = Date.today().addDays(30)
        );
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

        Test.startTest();
        o.StageName = 'PSA Negotiation';
        update o;
        Test.stopTest();

        List<Contract_Review__c> crs = [
            SELECT Stage__c FROM Contract_Review__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, crs.size(), 'One Contract review should be created on PSA Negotiation');
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
        o.StageName = 'Underwriting';
        update o; // moves away — no create
        o.StageName = 'Development Review';
        update o; // re-enters — must NOT create a second
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Development_Feasibility_Review__c WHERE Opportunity__c = :o.Id],
            'Re-entering the stage must not create a duplicate review');
    }

    @isTest
    static void bulkCreate() {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 50; i++) {
            opps.add(newOpp(Math.mod(i, 2) == 0 ? 'Development Review' : 'Construction Review'));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        System.assertEquals(25, [SELECT COUNT() FROM Development_Feasibility_Review__c],
            '25 Development reviews from 50 alternating opps');
        System.assertEquals(25, [SELECT COUNT() FROM Construction_Feasibility_Review__c],
            '25 Construction reviews from 50 alternating opps');
    }
}