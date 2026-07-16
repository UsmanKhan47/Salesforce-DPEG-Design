/**
 * Tests CounterOfferController: saving creates a Counter_Offer__c child with
 * direction/price/cap/date, stamps the latest terms onto the parent LOI, and
 * flips Ball_In_Court__c (seller counter -> Us; our counter -> Seller).
 */
@isTest
private class CounterOfferControllerTest {

    @isTest
    static void saveCreatesHistoryStampsLoiAndFlipsBall() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        CounterOfferController.saveCounterOffer(loi.Id, 'Seller', 1000000, 6.25,
            Date.today().addDays(-1), 'Seller came back higher', 'R2', 'v3');
        Test.stopTest();

        List<Counter_Offer__c> offers = CounterOfferController.getCounterOffers(loi.Id);
        System.assertEquals(1, offers.size(), 'Counter recorded in the history');
        System.assertEquals('Seller', offers[0].Direction__c, 'Direction captured');
        System.assertEquals(6.25, offers[0].Counter_Cap_Rate__c, 'Cap rate captured');
        System.assertEquals(Date.today().addDays(-1), offers[0].Counter_Date__c, 'Date captured');
        System.assertEquals('R2', offers[0].Revision_Number__c, 'Revision number captured');
        System.assertEquals('v3', offers[0].Subsequent_Version__c, 'Subsequent version captured');

        LOI__c refreshed = [
            SELECT Counter_Price__c, Counter_Cap_Rate__c, Counter_Received_Date__c,
                   Ball_In_Court__c, LOI_Status__c
            FROM LOI__c WHERE Id = :loi.Id
        ];
        System.assertEquals(1000000, refreshed.Counter_Price__c, 'LOI holds the latest counter price');
        System.assertEquals(6.25, refreshed.Counter_Cap_Rate__c, 'LOI holds the latest cap rate');
        System.assertEquals(Date.today().addDays(-1), refreshed.Counter_Received_Date__c,
            'Seller counters stamp the received date');
        System.assertEquals('Us', refreshed.Ball_In_Court__c, 'Seller counter puts the ball in OUR court');
        System.assertEquals('Countered', refreshed.LOI_Status__c, 'LOI status reflects the counter');
    }

    @isTest
    static void ourCounterFlipsBallToSeller() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        CounterOfferController.saveCounterOffer(loi.Id, 'Seller', 1000000, null, null, 'theirs', null, null);
        CounterOfferController.saveCounterOffer(loi.Id, 'Ours', 950000, null, null, 'ours back', null, null);
        Test.stopTest();

        System.assertEquals(2, CounterOfferController.getCounterOffers(loi.Id).size(),
            'Full negotiation history preserved');
        LOI__c refreshed = [SELECT Counter_Price__c, Ball_In_Court__c FROM LOI__c WHERE Id = :loi.Id];
        System.assertEquals(950000, refreshed.Counter_Price__c, 'Latest (our) counter stamped');
        System.assertEquals('Seller', refreshed.Ball_In_Court__c, 'Our counter puts the ball in the seller court');
    }

    @isTest
    static void nullLoiAndBadDirectionAreHandled() {
        System.assertEquals(0, CounterOfferController.getCounterOffers(null).size(),
            'Null LOI returns an empty history');

        Boolean threwNull = false;
        try {
            CounterOfferController.saveCounterOffer(null, 'Seller', 500000, null, null, 'x', null, null);
        } catch (Exception e) {
            threwNull = true;
        }
        System.assert(threwNull, 'Saving with no LOI should throw');

        LOI__c loi = TestDataFactory.createLoi(null, true);
        Boolean threwDir = false;
        try {
            CounterOfferController.saveCounterOffer(loi.Id, 'Nobody', 500000, null, null, 'x', null, null);
        } catch (Exception e) {
            threwDir = true;
        }
        System.assert(threwDir, 'An unknown direction should throw');
    }
}
