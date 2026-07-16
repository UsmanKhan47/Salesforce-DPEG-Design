/**
 * Tests for CounterOfferSelector (P4 cleanup wave E — Disposition module).
 *
 * Covers the one relocated query: field population, CreatedDate DESC (primary
 * sort, made deterministic via Test.setCreatedDate), the empty-result and
 * null-Id -> empty contracts, and a 251-record data-volume read.
 *
 * @TestSetup builds Opportunity -> LOI with explicit parent Ids (creating the
 * Opportunity also fires OpportunityReviewTrigger, which adds one NDA — irrelevant
 * here). Test methods QUERY the LOI (TestDataFactory ⚠1 cache trap). No runAs
 * USER_MODE test — Counter_Offer__c is custom, FLS gap 0.
 */
@isTest
private class CounterOfferSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createLoi(opp.Id, true);
    }

    private static Id loiId() {
        return [SELECT Id FROM LOI__c LIMIT 1].Id;
    }

    @isTest
    static void selectByLoiId_populatesEverySelectedField() {
        Id loi = loiId();
        // Factory default (i=0): Direction 'Seller', price 1050000, cap 6.25,
        // date today, Revision_Number__c '1' (TEXT). Response/Subsequent are null.
        TestDataFactory.createCounterOffer(loi, true);

        Test.startTest();
        List<Counter_Offer__c> result = CounterOfferSelector.selectByLoiId(loi);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Exactly one counter offer exists for the LOI');
        Counter_Offer__c c = result[0];
        Assert.isNotNull(c.Name, 'Name (AutoNumber) should be selected');
        Assert.areEqual('Seller', c.Direction__c, 'Direction__c should be selected');
        Assert.areEqual(1050000, c.Counter_Price__c, 'Counter_Price__c should be selected');
        Assert.areEqual(6.25, c.Counter_Cap_Rate__c, 'Counter_Cap_Rate__c should be selected');
        Assert.areEqual(Date.today(), c.Counter_Date__c, 'Counter_Date__c should be selected');
        Assert.areEqual('1', c.Revision_Number__c, 'Revision_Number__c (TEXT) should be selected');
        // Accessing null-valued selected fields proves they are in the SELECT.
        Assert.isNull(c.Counter_Response__c, 'Counter_Response__c should be selected (null on factory default)');
        Assert.isNull(c.Subsequent_Version__c, 'Subsequent_Version__c should be selected (null on factory default)');
        Assert.isNotNull(c.CreatedDate, 'CreatedDate should be selected');
    }

    @isTest
    static void selectByLoiId_ordersByCreatedDateDesc() {
        Id loi = loiId();
        Counter_Offer__c older = TestDataFactory.createCounterOffer(loi, true);
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-5));
        Counter_Offer__c newer = TestDataFactory.createCounterOffer(loi, true);

        Test.startTest();
        List<Counter_Offer__c> result = CounterOfferSelector.selectByLoiId(loi);
        Test.stopTest();

        Assert.areEqual(2, result.size(), 'Both counter offers should return');
        Assert.areEqual(newer.Id, result[0].Id,
            'ORDER BY CreatedDate DESC should place the most recent counter offer first');
    }

    @isTest
    static void selectByLoiId_noOffers_returnsEmpty() {
        Id loi = loiId();

        Test.startTest();
        List<Counter_Offer__c> result = CounterOfferSelector.selectByLoiId(loi);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'An LOI with no counter offers returns an empty list, not null');
    }

    @isTest
    static void selectByLoiId_nullId_returnsEmpty() {
        Test.startTest();
        List<Counter_Offer__c> result = CounterOfferSelector.selectByLoiId(null);
        Test.stopTest();

        // The selector mirrors the original query (no pre-query guard); the WHERE
        // bind matches no null-LOI counter offers, so the result is empty.
        Assert.areEqual(0, result.size(), 'A null LOI Id matches no counter offers and returns an empty list');
    }

    @isTest
    static void selectByLoiId_bulk251_readsAll() {
        Id loi = loiId();
        TestDataFactory.createCounterOffers(BULK_N, loi, true);

        Test.startTest();
        List<Counter_Offer__c> result = CounterOfferSelector.selectByLoiId(loi);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 counter offers under the LOI should be read');
    }
}
