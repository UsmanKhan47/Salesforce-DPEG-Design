/**
 * Tests CounterOfferController: saving creates a Counter_Offer__c child and stamps
 * the latest price/response onto the parent LOI; getCounterOffers returns the history.
 */
@isTest
private class CounterOfferControllerTest {

    @isTest
    static void saveCreatesHistoryAndStampsLoi() {
        LOI__c loi = new LOI__c();
        insert loi;

        Test.startTest();
        CounterOfferController.saveCounterOffer(loi.Id, 1000000, 'First counter');
        CounterOfferController.saveCounterOffer(loi.Id, 1100000, 'Second counter');
        Test.stopTest();

        List<Counter_Offer__c> offers = CounterOfferController.getCounterOffers(loi.Id);
        System.assertEquals(2, offers.size(), 'Both counter offers should be in the history');

        // Parent LOI reflects the latest counter.
        LOI__c refreshed = [SELECT Counter_Price__c, Counter_Response__c FROM LOI__c WHERE Id = :loi.Id];
        System.assertEquals(1100000, refreshed.Counter_Price__c, 'LOI holds the latest counter price');
        System.assertEquals('Second counter', refreshed.Counter_Response__c, 'LOI holds the latest response');
    }

    @isTest
    static void nullLoiIsHandled() {
        System.assertEquals(0, CounterOfferController.getCounterOffers(null).size(),
            'Null LOI returns an empty history');

        Boolean threw = false;
        try {
            CounterOfferController.saveCounterOffer(null, 500000, 'x');
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'Saving with no LOI should throw');
    }
}