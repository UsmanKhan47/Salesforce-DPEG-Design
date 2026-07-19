/**
 * @description Tests CounterOfferService — the LOI counter-offer append + parent-stamp
 * workflow extracted from CounterOfferController in P6 controller thinning.
 *
 * Covers the seller and our-side directions (Ball_In_Court__c flip both ways, the
 * seller-only Counter_Received_Date__c stamp), the null-date default, and both business-rule
 * violations (null LOI, unrecognised direction) which throw the typed CounterOfferException.
 * The service does two DML statements with no explicit Savepoint (transaction-level rollback
 * on an unhandled exception, matching the pre-thinning behaviour) and no collection DML, so
 * there is no rollback catch to force and no 251-record bulk scenario applies (saveCounterOffer
 * is a single-record @AuraEnabled operation invoked once per LWC save).
 *
 * @see force-app/main/default/classes/CounterOfferService.cls
 * @author Salesforce Developer
 */
@isTest
private class CounterOfferServiceTest {

    @isTest
    static void sellerCounterAppendsHistoryStampsLoiAndFlipsBallToUs() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        CounterOfferService.saveCounterOffer(loi.Id, 'Seller', 1000000, 6.25,
            Date.today().addDays(-1), 'Seller came back higher', 'R2', 'v3');
        Test.stopTest();

        List<Counter_Offer__c> offers = CounterOfferSelector.selectByLoiId(loi.Id);
        Assert.areEqual(1, offers.size(), 'Counter recorded in the history');
        Assert.areEqual('Seller', offers[0].Direction__c, 'Direction captured');
        Assert.areEqual(6.25, offers[0].Counter_Cap_Rate__c, 'Cap rate captured');
        Assert.areEqual(Date.today().addDays(-1), offers[0].Counter_Date__c, 'Date captured');
        Assert.areEqual('R2', offers[0].Revision_Number__c, 'Revision number captured');
        Assert.areEqual('v3', offers[0].Subsequent_Version__c, 'Subsequent version captured');

        LOI__c refreshed = [
            SELECT Counter_Price__c, Counter_Cap_Rate__c, Counter_Received_Date__c,
                   Ball_In_Court__c, LOI_Status__c
            FROM LOI__c WHERE Id = :loi.Id
        ];
        Assert.areEqual(1000000, refreshed.Counter_Price__c, 'LOI holds the latest counter price');
        Assert.areEqual(6.25, refreshed.Counter_Cap_Rate__c, 'LOI holds the latest cap rate');
        Assert.areEqual(Date.today().addDays(-1), refreshed.Counter_Received_Date__c,
            'Seller counters stamp the received date');
        Assert.areEqual('Us', refreshed.Ball_In_Court__c, 'Seller counter puts the ball in OUR court');
        Assert.areEqual('Countered', refreshed.LOI_Status__c, 'LOI status reflects the counter');
    }

    @isTest
    static void ourCounterFlipsBallToSellerAndDefaultsDateToToday() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        // Null counterDate must default to today; a blank revision/subsequent stores null.
        CounterOfferService.saveCounterOffer(loi.Id, 'Ours', 950000, null, null, 'ours back', '  ', '');
        Test.stopTest();

        List<Counter_Offer__c> offers = CounterOfferSelector.selectByLoiId(loi.Id);
        Assert.areEqual(1, offers.size(), 'Our counter recorded in the history');
        Assert.areEqual(Date.today(), offers[0].Counter_Date__c, 'Null date defaults to today');
        Assert.isNull(offers[0].Revision_Number__c, 'A blank revision is stored as null');
        Assert.isNull(offers[0].Subsequent_Version__c, 'A blank subsequent version is stored as null');

        LOI__c refreshed = [SELECT Counter_Price__c, Counter_Received_Date__c, Ball_In_Court__c
                            FROM LOI__c WHERE Id = :loi.Id];
        Assert.areEqual(950000, refreshed.Counter_Price__c, 'Latest (our) counter stamped');
        Assert.areEqual('Seller', refreshed.Ball_In_Court__c, 'Our counter puts the ball in the seller court');
        Assert.isNull(refreshed.Counter_Received_Date__c, 'Our counter does not stamp the received date');
    }

    @isTest
    static void nullLoiThrowsCounterOfferException() {
        Test.startTest();
        try {
            CounterOfferService.saveCounterOffer(null, 'Seller', 500000, null, null, 'x', null, null);
            Assert.fail('Saving with no LOI should throw CounterOfferException');
        } catch (CounterOfferService.CounterOfferException e) {
            Assert.isNotNull(e.getMessage(), 'The no-LOI rule violation carries a user-safe message');
        }
        Test.stopTest();
    }

    @isTest
    static void unknownDirectionThrowsCounterOfferException() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        try {
            CounterOfferService.saveCounterOffer(loi.Id, 'Nobody', 500000, null, null, 'x', null, null);
            Assert.fail('An unknown direction should throw CounterOfferException');
        } catch (CounterOfferService.CounterOfferException e) {
            Assert.isNotNull(e.getMessage(), 'The bad-direction rule violation carries a user-safe message');
        }
        Test.stopTest();
    }
}
