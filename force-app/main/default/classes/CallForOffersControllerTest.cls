/**
 * Tests for `CallForOffersController` — the `@AuraEnabled` boundary for the two call-for-offers
 * surfaces.
 *
 * ── THE CATCH BLOCKS ARE REACHED, NOT SKIPPED ───────────────────────────────
 * Both reads behind this controller are `WITH USER_MODE`, so `System.runAs` a bare user — one
 * carrying no permission set and therefore no FLS on `Offer_Due_Date__c` — makes the selector throw
 * `System.QueryException` ("No such column ...", which is how the platform reports an FLS denial)
 * and the catch runs. That is the repo-standard technique for covering an `AuraHandledException`
 * boundary, and it is available here precisely BECAUSE these reads are USER_MODE.
 *
 * 🔴 If anyone ever "simplifies" either selector method to `SYSTEM_MODE`, these two tests stop
 * proving anything — SYSTEM_MODE is exactly what suppresses the throw. That is the trap
 * `DispositionTractionController`'s header records as a measured, accepted coverage gap; this
 * controller does not have it and should not acquire it.
 */
@isTest
private class CallForOffersControllerTest {

    /**
     * A user with a real licence and NO permission sets, so `WITH USER_MODE` denies the custom
     * fields. Built here rather than in `TestDataFactory` because it is only meaningful to a test
     * that wants a denial.
     */
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Bare',
            LastName = 'Reader',
            Alias = 'bare',
            Email = 'bare.reader@example.invalid',
            Username = 'bare.reader.' + unique + '@example.invalid',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    @isTest
    static void getUpcomingReturnsTheOrderedList() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(2, true);
        deals[0].Offer_Due_Date__c = Date.today().addDays(9);
        deals[1].Offer_Due_Date__c = Date.today().addDays(1);
        update deals;

        List<CallForOffersService.CallForOffers> rows = CallForOffersController.getUpcoming();

        Assert.areEqual(2, rows.size(), 'Both deals with deadlines are returned');
        Assert.areEqual(deals[1].Id, rows[0].opportunityId, 'Soonest deadline first');
        Assert.areEqual('CRITICAL', rows[0].urgency, 'and it carries the computed band');
    }

    @isTest
    static void getUpcomingReturnsAnEmptyListRatherThanFailingWhenNothingMatches() {
        // EMPTY CONTRACT: "no live deadlines" is a normal answer, not an error state.
        List<CallForOffersService.CallForOffers> rows = CallForOffersController.getUpcoming();
        Assert.isNotNull(rows, 'Never null');
        Assert.areEqual(0, rows.size(), 'Empty when nothing matches');
    }

    @isTest
    static void getForOpportunityReturnsTheSingleDealState() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today();
        update deal;

        CallForOffersService.CallForOffers c = CallForOffersController.getForOpportunity(deal.Id);

        Assert.areEqual('DUE_TODAY', c.urgency, 'The panel gets the computed band');
        Assert.areEqual(0, c.daysRemaining, 'and the countdown');
        Assert.areEqual(deal.Id, c.opportunityId, 'for the record it was asked about');
    }

    @isTest
    static void getForOpportunityTreatsANullIdAsNoDeadlineRatherThanAnError() {
        CallForOffersService.CallForOffers c = CallForOffersController.getForOpportunity(null);
        Assert.areEqual('NO_DUE_DATE', c.urgency,
            'A panel that has not yet received a record id renders the no-deadline state');
    }

    @isTest
    static void aWrongSObjectTypeIsRefusedWithItsOwnMessageNotTheGenericOne() {
        // 🔴 THE POINT OF THIS TEST. Without the type guard a mis-wired panel would render a
        // confident, permanently green "No offer deadline" and nobody would ever learn it was
        // pointed at the wrong record. Asserting the SPECIFIC message is what stops someone
        // "tidying" the guard inside the try, where the catch would replace it with the generic one.
        Account acct = TestDataFactory.createAccount(true);

        try {
            CallForOffersController.getForOpportunity(acct.Id);
            Assert.fail('A non-Opportunity Id must be refused');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('only be read for an Opportunity'),
                'The refusal must name the wiring mistake, not the generic read failure. Got: '
                + e.getMessage());
        }
    }

    @isTest
    static void aDeniedListReadSurfacesAsAnAuraHandledExceptionNotARawQueryException() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(1, true);
        deals[0].Offer_Due_Date__c = Date.today().addDays(3);
        update deals;

        User bare = bareUser();
        insert bare;

        Test.startTest();
        System.runAs(bare) {
            try {
                CallForOffersController.getUpcoming();
                Assert.fail('A user with no FLS on the call-for-offers fields must be refused — '
                    + 'if this line is reached, either the read stopped being USER_MODE or the '
                    + 'bare user acquired a grant, and this test now proves nothing');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Call for offers could not be loaded'),
                    'ARCHITECTURE.md §5: the boundary must never leak platform text. Got: '
                    + e.getMessage());
            }
        }
        Test.stopTest();
    }

    @isTest
    static void aDeniedPanelReadSurfacesAsAnAuraHandledExceptionToo() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        update deal;

        User bare = bareUser();
        insert bare;

        Test.startTest();
        System.runAs(bare) {
            try {
                CallForOffersController.getForOpportunity(deal.Id);
                Assert.fail('A user with no FLS on the call-for-offers fields must be refused');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('offer deadline could not be loaded'),
                    'The panel has its own fixed message. Got: ' + e.getMessage());
            }
        }
        Test.stopTest();
    }
}
