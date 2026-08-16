/**
 * Tests for TopDealsController — the "Top 5 Largest Deals" home-page card (FSD §24.2).
 *
 * 🔴 THE FIXTURE DELIBERATELY INVERTS `Amount` AGAINST `Asking_Price__c`, AND THAT IS WHAT
 * MAKES THIS SUITE NON-VACUOUS. `TestDataFactory.createOpportunities` seeds the two fields
 * to the SAME value, so a test using the factory defaults cannot tell
 * `selectTopByAmount` (this card) apart from `selectTopByAskingPrice` (the pre-existing
 * `recentOpportunities` card) — every assertion would pass against either implementation.
 * The setup below makes the two orderings OPPOSITE, so re-pointing this controller at the
 * wrong selector reds immediately.
 *
 * ⚠ NO 251-RECORD BULK TEST, AND THE REASON IS NOT THE EXEMPTION.
 * `.claude/rules/bulk-test-rule.md` mandates 251 for triggers, batch jobs, DML-performing
 * services and queueables — to force a SECOND trigger batch chunk. This controller is a
 * single `cacheable=true` READ with a `LIMIT 5`: there is no chunking, no DML, and no loop
 * whose behaviour changes with row count, so 251 rows would exercise nothing 8 rows do not.
 * The 251-row proof that the SELECTOR is bulk-safe lives in `OpportunitySelectorTest`,
 * whose `@TestSetup` already builds 251 deals.
 */
@isTest
private class TopDealsControllerTest {

    /**
     * Eight deals whose `Amount` ranking is the REVERSE of their `Asking_Price__c` ranking,
     * two of them closed.
     *
     *   index 0..5  active,  Amount 600k..100k descending, Asking_Price ascending
     *   index 6     Closed Won  with the LARGEST Amount of all (900k)
     *   index 7     Dead/Pass   with the second largest      (800k)
     *
     * The two closed rows carry the biggest amounts ON PURPOSE: if the stage filter is ever
     * dropped they would occupy the top two slots, so `excludesClosedAndDeadDeals` fails
     * loudly rather than by one row at the bottom of the list.
     *
     * 🔴 THE CLOSED STAGES ARE SET **BEFORE THE INSERT**, AND THAT IS THE ONLY WORKABLE SHAPE
     * — DO NOT "TIDY" IT INTO AN INSERT-THEN-UPDATE. Every Opportunity stage gate in this org
     * is guarded by `ISCHANGED(StageName)`, which is FALSE on insert and TRUE on update, so:
     *
     *   insert at 'Closed Won'  -> passes (no stage CHANGE occurred)
     *   update to 'Closed Won'  -> BLOCKED by BOTH `Contract_Signed_Before_Closed_Won` (this
     *                              fixture has no executed PSA) AND
     *                              `NDA_Signed_Before_Deal_Progression` (no signed Primary NDA)
     *
     * Reaching those stages "properly" would mean building a full NDA + LOI + PSA chain per
     * row — a large fixture for a test that only needs a row to EXIST at a closed stage.
     *
     * ⚠ Inserting at `Closed Won` is also safe from the heavyweight close automation:
     * `PropertyAssetService.ensureOnClosedWon` and `DealFolderService.ensureOnClosedWon` both
     * skip a deal with a null `Property__c` (their shared residual R1), and the factory sets none.
     */
    @TestSetup
    static void setup() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(8, false);
        for (Integer i = 0; i < 6; i++) {
            deals[i].Name = 'Active ' + i;
            deals[i].Amount = 600000 - (i * 100000);   // 600k, 500k, 400k, 300k, 200k, 100k
            deals[i].Asking_Price__c = 100000 + (i * 100000); // deliberately the OPPOSITE order
        }
        deals[6].Name = 'Closed Giant';
        deals[6].StageName = 'Closed Won';
        deals[6].Amount = 900000;
        deals[7].Name = 'Dead Giant';
        deals[7].StageName = 'Dead/Pass';
        deals[7].Amount = 800000;
        insert deals;
    }

    @isTest
    static void returnsTheFiveLargestActiveDealsLargestFirst() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        Assert.areEqual(5, rows.size(), 'The card shows exactly five deals (FSD §24.2)');
        for (Integer i = 1; i < rows.size(); i++) {
            Assert.isTrue(rows[i - 1].amount >= rows[i].amount,
                'Rows must be ordered by Amount descending');
        }
        Assert.areEqual('Active 0', rows[0].name,
            'The largest ACTIVE deal by Amount leads the list');
    }

    /**
     * 🔴 The falsifier for re-pointing this card at `selectTopByAskingPrice`.
     *
     * `Active 0` has the LARGEST Amount and the SMALLEST Asking Price; `Active 5` is the
     * reverse. An asking-price ranking would put `Active 5` first, so this assertion is the
     * one that distinguishes the two selectors.
     */
    @isTest
    static void ranksOnAmountAndNotOnAskingPrice() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        Assert.areEqual('Active 0', rows[0].name,
            'Ranking is by Amount. If this reads "Active 5" the card has been re-pointed at '
            + 'Asking_Price__c and is now a duplicate of lwc/recentOpportunities');
        // ⚠ `==` rather than Assert.areEqual: `amount` is a Decimal, and
        // Assert.areEqual(Object, Object) treats an Integer literal and a Decimal as UNEQUAL
        // even when they denote the same number. Decimal `==` compares by value, ignoring scale.
        Assert.isTrue(rows[0].amount == 600000,
            'and it carries the Amount, not the asking price');
    }

    /**
     * 🔴 The two closed rows carry the two LARGEST amounts in the fixture, so a missing
     * stage filter puts them at positions 0 and 1 — not at the tail where it could be
     * mistaken for an ordering quirk.
     */
    @isTest
    static void excludesClosedAndDeadDeals() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        for (TopDealsController.TopDealRow r : rows) {
            Assert.areNotEqual('Closed Won', r.stage, 'A Closed Won deal must never appear');
            Assert.areNotEqual('Dead/Pass', r.stage, 'A Dead/Pass deal must never appear');
        }
        Assert.areEqual(5, rows.size(),
            'and the LIMIT still yields five, so the filter runs in the QUERY rather than '
            + 'after the LIMIT — filtering in Apex would have returned only four here');
    }

    @isTest
    static void everyFieldTheCardRendersIsPopulated() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        TopDealsController.TopDealRow first = rows[0];
        Assert.isNotNull(first.id, 'id backs the record link');
        Assert.isNotNull(first.name, 'name backs the link label');
        Assert.isNotNull(first.stage, 'stage backs the stage pill');
        Assert.isNotNull(first.dealType, 'dealType backs the deal-type pill');
        Assert.isNotNull(first.amount, 'amount backs the compact-currency column');
        Assert.isNotNull(first.closeDate, 'closeDate backs the close-date column');
        Assert.isNotNull(first.days, 'days backs the age column');
        Assert.isTrue(first.days >= 0, 'Age is measured from CreatedDate and cannot be negative');
    }

    /**
     * A deal with a null `Amount` must still be returned (sorted last), not dropped.
     *
     * ⚠ `NULLS LAST` is what keeps an un-costed deal out of the top of the list without
     * hiding it entirely. The LWC renders a null amount as an em dash.
     */
    @isTest
    static void anAmountLessDealSortsLastRatherThanBeingDropped() {
        delete [SELECT Id FROM Opportunity WHERE Name LIKE 'Active %'];
        Opportunity noAmount = TestDataFactory.createOpportunity((Id) null, false);
        noAmount.Name = 'No Amount';
        noAmount.Amount = null;
        insert noAmount;

        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'The only remaining ACTIVE deal comes back even with no Amount');
        Assert.areEqual('No Amount', rows[0].name, 'and it is the amount-less one');
        Assert.isNull(rows[0].amount, 'with a null amount for the LWC to render as an em dash');
    }

    /**
     * `USER_MODE` must not throw for a restricted persona on the STANDARD fields this read
     * selects — the same proof `OpportunitySelectorTest` makes for its own methods.
     *
     * ⚠ THIS IS NOT A PROOF THAT THE CARD WORKS IN PRODUCTION. A `Standard User` in a test
     * org is not a DPEG persona, and `Opportunity.Amount` is `permissionable` and granted by
     * NO permission set in this repo. Post-deploy gate: grant it readable on
     * `DPEG_Acquisition_Edit` / `_View` / `DPEG_Opportunity_View` and open the home page as
     * a real persona. What this test DOES establish is that nothing in the query shape
     * itself refuses a non-administrator.
     */
    @isTest
    static void userModeDoesNotThrowForARestrictedPersona() {
        User restricted = buildStandardUser();
        insert restricted;

        Test.startTest();
        System.runAs(restricted) {
            List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
            Assert.isNotNull(rows, 'The read must return a list rather than throwing');
        }
        Test.stopTest();
    }

    private static User buildStandardUser() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'topdeals' + System.currentTimeMillis();
        return new User(
            ProfileId = standard.Id,
            LastName = 'TopDealsTest',
            Email = 'topdealstest@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            Alias = 'tdeal',
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
