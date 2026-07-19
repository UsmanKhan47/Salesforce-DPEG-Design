/**
 * Tests CounterOfferController (thinned in P6). The happy paths prove the delegated
 * behaviour is preserved end-to-end: saving creates a Counter_Offer__c child, stamps the
 * latest terms onto the parent LOI, and flips Ball_In_Court__c (seller counter -> Us; our
 * counter -> Seller).
 *
 * P6 controller thinning: saveCounterOffer's DML + rules now live in CounterOfferService,
 * and every @AuraEnabled method wraps its work in a try/catch that maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). The negative tests below
 * therefore now expect an AuraHandledException; readCatchThrowsAuraHandledException covers
 * getCounterOffers' read catch via a bare Standard User whose WITH USER_MODE SOQL on the
 * custom Counter_Offer__c object throws, and writeFailureThrowsAuraHandledException covers
 * saveCounterOffer's generic write catch via a deleted parent LOI Id (the child insert
 * fails INVALID_CROSS_REFERENCE_KEY).
 */
@isTest
private class CounterOfferControllerTest {

    // A valid-format but non-existent Id for the given type. The bare-user read throws on
    // object ACCESS under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL on the custom
    // Counter_Offer__c object (no object access) throws, exercising the controller's
    // read-failure catch which maps it to a user-safe AuraHandledException (P6).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

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
    static void nullLoiReturnsEmptyHistory() {
        System.assertEquals(0, CounterOfferController.getCounterOffers(null).size(),
            'Null LOI returns an empty history');
    }

    @isTest
    static void nullLoiAndBadDirectionThrowAuraHandledException() {
        // P6: the service's CounterOfferException is now caught in the controller and
        // re-thrown as a user-safe AuraHandledException at the LWC boundary.
        try {
            CounterOfferController.saveCounterOffer(null, 'Seller', 500000, null, null, 'x', null, null);
            Assert.fail('Saving with no LOI should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'no-LOI rule violation maps to AuraHandledException');
        }

        LOI__c loi = TestDataFactory.createLoi(null, true);
        try {
            CounterOfferController.saveCounterOffer(loi.Id, 'Nobody', 500000, null, null, 'x', null, null);
            Assert.fail('An unknown direction should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'bad-direction rule violation maps to AuraHandledException');
        }
    }

    // Covers saveCounterOffer's generic write catch: a deleted parent LOI Id makes the
    // child Counter_Offer__c insert fail (INVALID_CROSS_REFERENCE_KEY) under admin — the
    // deterministic way to reach the write-failure catch without a bare user. Kept apart
    // from the bare-user read test so the setup-object User insert and this record DML never
    // share a transaction (MIXED_DML_OPERATION).
    @isTest
    static void writeFailureThrowsAuraHandledException() {
        LOI__c loi = TestDataFactory.createLoi(null, true);
        Id deletedLoiId = loi.Id;
        delete loi;

        Test.startTest();
        try {
            CounterOfferController.saveCounterOffer(deletedLoiId, 'Seller', 500000, 6.0,
                Date.today(), 'x', 'R1', 'v1');
            Assert.fail('Saving a counter under a deleted LOI should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'save failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    // Covers getCounterOffers' read catch: WITH USER_MODE on the custom Counter_Offer__c
    // object throws for a bare Standard User (no object access). Its own method because
    // bareUser() inserts a User (setup DML) and mixing it with record DML would raise
    // MIXED_DML_OPERATION; the read throws at the query, so no record DML runs here.
    @isTest
    static void readCatchThrowsAuraHandledException() {
        User u = bareUser();
        Id fakeLoiId = fakeId(LOI__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try {
                CounterOfferController.getCounterOffers(fakeLoiId);
                Assert.fail('expected AuraHandledException from getCounterOffers under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getCounterOffers read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
    }
}
