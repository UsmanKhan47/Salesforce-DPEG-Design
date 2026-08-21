/**
 * @description Tests DispositionTractionController — the @AuraEnabled boundary behind
 * lwc/listingAlerts (Tranche 5 Item B).
 *
 * A thin controller, so this suite is deliberately short and tests only the things the controller
 * itself decides: the not-found contract, the null-Id contract, and that a read failure becomes an
 * `AuraHandledException` rather than a raw platform error. The BAND LADDER is proven once, in
 * DispositionTractionServiceTest; re-asserting thresholds here would create a second place to
 * update when they change, which is the drift this design exists to prevent.
 *
 * @see force-app/main/default/classes/DispositionTractionController.cls
 * @author Salesforce Developer
 */
@isTest
private class DispositionTractionControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
    }

    @isTest
    static void getTractionReturnsTheComputedStateForAListedDisposition() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        // ⚠ The factory seeds Listing_Date__c = TODAY, so an aged clock must be set deliberately.
        d.Listing_Date__c = Date.today().addDays(-35);
        update d;

        Test.startTest();
        DispositionTractionService.Traction t =
            DispositionTractionController.getTraction(d.Id);
        Test.stopTest();

        Assert.isNotNull(t, 'getTraction must never return null');
        Assert.areEqual(DispositionTractionService.Band.WEEK_4.name(), t.band,
            'Day 35 with no offers sits on the week-4 rung');
        Assert.areEqual(35, t.daysOnMarket, 'The clock must be read off Listing_Date__c');
        Assert.areEqual(0, t.offerCount, 'No offers exist on this fixture');
        Assert.isTrue(t.isAtRisk, 'WEEK_4 is an at-risk state');
        Assert.areEqual(3, t.rungs.size(),
            'The three rungs must reach the LWC boundary - the panel renders them as real state '
            + 'rather than as the hardcoded list it once shipped');
    }

    /**
     * 🔴 THE NOT-FOUND CONTRACT IS "NOT LISTED", NOT NULL. A null would render an empty box in the
     * LWC that is indistinguishable from a load failure; "the clock has not started" is a true and
     * actionable answer. This is the deliberate difference from
     * `BrokerListingController.getListing`, which DOES return null — that one describes a
     * `Broker_Listing__c` row that genuinely may not exist, whereas every Disposition has a
     * traction state even when it is "none yet".
     */
    @isTest
    static void aNullIdReturnsTheNotListedStateRatherThanNullOrAnException() {
        DispositionTractionService.Traction t = DispositionTractionController.getTraction(null);

        Assert.isNotNull(t, 'A null Id must not produce a null payload');
        Assert.areEqual(DispositionTractionService.Band.NOT_LISTED.name(), t.band,
            'A null Id resolves to NOT_LISTED');
        Assert.isFalse(t.isListed, 'Nothing is listed when there is no record');
    }

    @isTest
    static void anIdThatResolvesToNoRowReturnsTheNotListedState() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Id gone = d.Id;
        delete d;

        DispositionTractionService.Traction t = DispositionTractionController.getTraction(gone);

        Assert.isNotNull(t, 'A deleted record must not produce a null payload');
        Assert.areEqual(DispositionTractionService.Band.NOT_LISTED.name(), t.band,
            'An unresolvable Id renders as not listed');
    }

    /**
     * 🔴 THE PAUSE AT THE `@AuraEnabled` BOUNDARY. The offers are BACK-DATED deliberately:
     * `TestDataFactory.createDispositionOffers` dates every offer TODAY, which pauses the clock at
     * today — indistinguishable from no pause at all. With the dates set explicitly, this test fails
     * if the controller ever loses the first-offer date on its way to the component.
     */
    @isTest
    static void aDispositionWithOffersReportsThemAndPausesTheClockThroughTheController() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        d.Listing_Date__c = Date.today().addDays(-50);
        update d;
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(2, d.Id, false);
        offers[0].Offer_Date__c = Date.today().addDays(-18);
        offers[1].Offer_Date__c = Date.today().addDays(-2);
        insert offers;

        Test.startTest();
        DispositionTractionService.Traction t = DispositionTractionController.getTraction(d.Id);
        Test.stopTest();

        Assert.areEqual(2, t.offerCount, 'Both offers must reach the payload');
        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'Day 50 WITH offers is On Track - an offer is traction (D28/Q1)');
        Assert.isFalse(t.isAtRisk, 'A listing with offers is not at risk at any day');
        Assert.isTrue(t.isPaused, 'The first offer paused the clock');
        Assert.areEqual(32, t.daysOnMarket,
            'Listed 50 days ago, earliest offer 18 days ago: the clock stopped at day 32, not 50');
    }

    /**
     * 🔴 A WRONG SOBJECT TYPE IS REFUSED RATHER THAN RENDERED AS "not listed", AND THIS TEST EXISTS
     * BECAUSE THE FIRST VERSION OF IT MEASURED THE OPPOSITE OF WHAT IT ASSUMED.
     *
     * It was originally written to force the controller's `catch` by handing it a `Property__c` Id,
     * on the assumption that binding a wrong-key-prefix Id into `WHERE Id IN :ids` throws. It does
     * NOT — measured on `usman-dpeg` 2026-08-10, the run returned zero rows and the method happily
     * reported NOT_LISTED. That is a real defect surface, not a test inconvenience: a component
     * wired to the wrong `record-id` would render a confident, permanently green "Not listed yet"
     * forever. Hence the explicit type guard, and hence this test asserts the GUARD rather than the
     * catch.
     *
     * ⚠ THE CONTROLLER'S `catch` REMAINS UNCOVERED, DELIBERATELY. Both of its reads are
     * `WITH SYSTEM_MODE`, so the repo's usual bare-user `runAs` technique cannot make them throw —
     * that is the whole point of the automation-path decision. See the class header for the three
     * approaches that were tried and measured, and for why a `@TestVisible` failure-injection seam
     * was rejected. Do not "fix" this by deleting the catch.
     */
    @isTest
    static void aWrongSObjectTypeIsRefusedRatherThanReportedAsNotListed() {
        Property__c wrongType = [SELECT Id FROM Property__c LIMIT 1];

        Test.startTest();
        try {
            DispositionTractionController.getTraction(wrongType.Id);
            Assert.fail(
                'A non-Disposition Id must be refused. If this line is reached, the type guard was '
                + 'removed and a mis-wired component now renders a permanently green "Not listed '
                + 'yet" instead of an error.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'The refusal reaches the LWC as an AuraHandledException');
        }
        Test.stopTest();
    }
}
