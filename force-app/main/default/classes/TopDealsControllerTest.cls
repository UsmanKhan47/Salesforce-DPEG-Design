/**
 * Tests for TopDealsController — the "Top 5 Largest Deals" home-page card (FSD §24.2).
 *
 * 🔴 THE CARD WAS RE-RANKED ONTO `Asking_Price__c` AND CUT TO TWO COLUMNS ON 2026-08-17
 * (user decision). It used to rank on `Opportunity.Amount` and render six columns. Every
 * assertion below reads the NEW contract: `TopDealRow` carries `id`, `name` and
 * `askingPrice` and nothing else, and the order is by asking price.
 *
 * 🔴 THE FIXTURE DELIBERATELY INVERTS `Amount` AGAINST `Asking_Price__c`, AND THAT IS WHAT
 * MAKES THIS SUITE NON-VACUOUS — the same device as before, now pointing the other way.
 * `TestDataFactory.createOpportunities` seeds the two fields to the SAME value, so a test
 * using the factory defaults cannot tell an asking-price ranking from an `Amount` one: both
 * orderings agree and every assertion passes against either implementation. The setup below
 * makes the two orderings OPPOSITE, so a revert to `Amount` reds immediately.
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
     * Eight deals whose `Asking_Price__c` ranking is the REVERSE of their `Amount` ranking,
     * two of them closed.
     *
     *   index 0..5  active,  Amount 600k..100k DESCENDING, Asking Price 100k..600k ASCENDING
     *   index 6     Closed Won  with the LARGEST asking price of all (9M)
     *   index 7     Dead/Pass   with the second largest             (8M)
     *
     * ⇒ By ASKING PRICE the leader is `Active 5`. By `Amount` it would be `Active 0`. That
     *   single fact is the falsifier for a revert, and it is why the two fields are set in
     *   opposite directions rather than left at the factory defaults.
     *
     * ⚠ BOTH FIELDS ARE SET EXPLICITLY ON THE TWO CLOSED ROWS, INCLUDING THE ONE THE FIXTURE
     * DOES NOT RANK ON. Under the factory defaults their asking prices (≈1.006M / 1.007M)
     * would already have outranked every active row, so the stage-filter test would have
     * passed for an INCIDENTAL reason. Stating both makes the intent survive a future
     * re-ranking of this card in either direction.
     *
     * The two closed rows carry the biggest asking prices ON PURPOSE: if the stage filter is
     * ever dropped they occupy the top two slots, so `excludesClosedAndDeadDeals` fails
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
     * `PropertyAssetService.ensureOnClosedWon` and `DealFolderService.ensureOnClaimStageEntry`
     * both skip a deal with a null `Property__c` (their shared residual R1), and the factory sets
     * none. ⚠ Still true after the 2026-08-27 claim-stage move, and for a second reason worth
     * knowing: these rows are INSERTED at their stage rather than updated into it, and an insert
     * AT a claim stage IS an entry — so the folder service really does run here. It is the null
     * `Property__c`, not the stage, that makes it a no-op.
     */
    @TestSetup
    static void setup() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(8, false);
        for (Integer i = 0; i < 6; i++) {
            deals[i].Name = 'Active ' + i;
            deals[i].Amount = 600000 - (i * 100000);          // 600k, 500k, 400k, 300k, 200k, 100k
            deals[i].Asking_Price__c = 100000 + (i * 100000); // deliberately the OPPOSITE order
        }
        deals[6].Name = 'Closed Giant';
        deals[6].StageName = 'Closed Won';
        deals[6].Amount = 900000;
        deals[6].Asking_Price__c = 9000000;
        deals[7].Name = 'Dead Giant';
        deals[7].StageName = 'Dead/Pass';
        deals[7].Amount = 800000;
        deals[7].Asking_Price__c = 8000000;
        insert deals;
    }

    @isTest
    static void returnsTheFiveHighestActiveAskingPricesHighestFirst() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        Assert.areEqual(5, rows.size(), 'The card shows exactly five deals (FSD §24.2)');
        for (Integer i = 1; i < rows.size(); i++) {
            Assert.isTrue(rows[i - 1].askingPrice >= rows[i].askingPrice,
                'Rows must be ordered by Asking_Price__c descending');
        }
        Assert.areEqual('Active 5', rows[0].name,
            'The highest ACTIVE asking price leads the list');
    }

    /**
     * 🔴 THE FALSIFIER FOR A REVERT TO `Amount` — the single most important test here.
     *
     * `Active 5` has the HIGHEST asking price and the LOWEST Amount; `Active 0` is the exact
     * reverse. An `Amount` ranking puts `Active 0` first, so this assertion is the one that
     * distinguishes the two orderings. Against the `TestDataFactory` defaults (which seed the
     * two fields identically) NO assertion could.
     */
    @isTest
    static void ranksOnAskingPriceAndNotOnAmount() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        Assert.areEqual('Active 5', rows[0].name,
            'Ranking is by Asking_Price__c. If this reads "Active 0" the card has been '
            + 'reverted to an Amount ranking (user decision 2026-08-17 re-ranked it)');
        // ⚠ `==` rather than Assert.areEqual: `askingPrice` is a Decimal, and
        // Assert.areEqual(Object, Object) treats an Integer literal and a Decimal as UNEQUAL
        // even when they denote the same number. Decimal `==` compares by value, ignoring scale.
        Assert.isTrue(rows[0].askingPrice == 600000,
            'and it carries the asking price, not the deal Amount (which is 100000 on this row)');
    }

    /**
     * 🔴 The two closed rows carry the two HIGHEST asking prices in the fixture, so a missing
     * stage filter puts them at positions 0 and 1 — not at the tail where it could be
     * mistaken for an ordering quirk.
     *
     * ⚠ IT ASSERTS ON `name`, NOT ON A `stage` MEMBER. The two-column cut removed `stage`
     * from `TopDealRow`, so the card can no longer report the stage it excluded on. The
     * fixture's two closed rows are uniquely named for exactly this reason; asserting the
     * absence of those NAMES is the same claim one step removed. The stage predicate itself
     * is pinned directly, on the query, by
     * `OpportunitySelectorTest.selectTopActiveByAskingPrice_ordersByAskingPriceAndExcludesClosedDeals`,
     * which still selects `StageName` and checks it row by row against `CLOSED_STAGES`.
     */
    @isTest
    static void excludesClosedAndDeadDeals() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        for (TopDealsController.TopDealRow r : rows) {
            Assert.areNotEqual('Closed Giant', r.name,
                'A Closed Won deal must never appear, however large its asking price');
            Assert.areNotEqual('Dead Giant', r.name, 'nor a Dead/Pass one');
        }
        Assert.areEqual(5, rows.size(),
            'and the LIMIT still yields five, so the filter runs in the QUERY rather than '
            + 'after the LIMIT — filtering in Apex would have returned only three here');
    }

    /**
     * The DTO is exactly as wide as the card: three members, all populated.
     *
     * ⚠ THE SECOND HALF IS THE POINT. Asserting only that the three members are populated
     * would still pass on a DTO that had quietly regrown `amount` / `closeDate` / `days` —
     * and every regrown member is another field in a `WITH USER_MODE` SELECT that throws on
     * the WHOLE ROW for one FLS gap. `JSON.serialize` on the wrapper is what the wire itself
     * sends, so counting its keys pins the contract the LWC actually receives.
     */
    @isTest
    static void theRowCarriesExactlyTheThreeFieldsTheCardRenders() {
        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        TopDealsController.TopDealRow first = rows[0];
        Assert.isNotNull(first.id, 'id backs the record link');
        Assert.isNotNull(first.name, 'name backs the Property Name link label');
        Assert.isNotNull(first.askingPrice, 'askingPrice backs the compact-currency column');

        // 🔴 SINGLE-ARGUMENT `JSON.serialize` ON PURPOSE — IT DOES **NOT** SUPPRESS NULL
        // MEMBERS, which is what makes this a count of the DTO's WIDTH rather than of one
        // row's populated fields. The two-argument form `JSON.serialize(first, true)` is the
        // suppress-Apex-object-nulls variant: switching to it would silently make this a
        // size-2 assertion on any unpriced deal — a test that passes for the wrong reason and
        // stops detecting a regrown member the moment the fixture changes. Do not "improve" it.
        Map<String, Object> wire =
            (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(first));
        Assert.areEqual(3, wire.size(),
            'TopDealRow must stay exactly as wide as the card. A new member here means a new '
            + 'field in OpportunitySelector.selectTopActiveByAskingPrice, and a new way for a '
            + 'persona without that FLS grant to lose the whole card. Wire keys: ' + wire.keySet());
        Assert.isTrue(wire.containsKey('askingPrice'),
            'and the member is named `askingPrice` — the LWC wire contract reads r.askingPrice');
    }

    /**
     * A deal with a null `Asking_Price__c` must sort LAST, not first and not be dropped.
     *
     * 🔴 THE FIXTURE IS TRIMMED SO THE NULL ROW FITS INSIDE THE `LIMIT 5`. With all six
     * active rows present the null one would be the sixth and would never be returned, so
     * "it sorted last" would be indistinguishable from "it was dropped" — and a `NULLS FIRST`
     * regression would be invisible. Deleting three actives leaves four rows under a LIMIT of
     * five, which is the only shape in which the ordering claim is actually falsifiable.
     *
     * ⚠ `NULLS LAST` is what keeps an unpriced deal out of the top of the list without hiding
     * it entirely. The LWC renders a null asking price as an em dash, never `$0`.
     */
    @isTest
    static void aPriceLessDealSortsLastRatherThanFirstOrBeingDropped() {
        delete [SELECT Id FROM Opportunity WHERE Name IN ('Active 0', 'Active 1', 'Active 2')];
        Opportunity noPrice = TestDataFactory.createOpportunity((Id) null, false);
        noPrice.Name = 'No Ask';
        noPrice.Asking_Price__c = null;
        insert noPrice;

        Test.startTest();
        List<TopDealsController.TopDealRow> rows = TopDealsController.getTopDeals();
        Test.stopTest();

        Assert.areEqual(4, rows.size(),
            'Three priced actives plus the unpriced one, all inside the LIMIT of five');
        Assert.areEqual('Active 5', rows[0].name, 'The highest asking price still leads');
        Assert.areEqual('No Ask', rows[rows.size() - 1].name,
            'and the unpriced deal is LAST. Reading it at position 0 means NULLS LAST was '
            + 'dropped from the ORDER BY; not finding it at all means nulls are being filtered');
        Assert.isNull(rows[rows.size() - 1].askingPrice,
            'with a null asking price for the LWC to render as an em dash');
    }

    /**
     * An UNPROVISIONED persona gets the fixed, user-safe message — never a raw
     * `QueryException`. This pins the ARCHITECTURE.md §5 boundary contract on this
     * controller.
     *
     * 🔴 THIS METHOD USED TO ASSERT THE OPPOSITE — that `USER_MODE` "must not throw for a
     * restricted persona on the STANDARD fields this read selects". THAT PREMISE WAS FALSE
     * AND THE TEST FAILED ON FIRST EXECUTION (2026-08-16, `RunLocalTests`), because the read
     * was never standard-fields-only and `WITH USER_MODE` throws on the WHOLE ROW for ONE
     * inaccessible field. A bare `Standard User` with no permission set can therefore never
     * satisfy the old assertion in this org.
     *
     * 🔴 THE PRODUCT BEHAVIOUR IS CORRECT AND WAS NOT CHANGED TO MAKE THIS PASS. The
     * controller catching the `QueryException` and rethrowing a user-safe
     * `AuraHandledException` is exactly what §5 requires, and the LOUD failure is the
     * intended posture for a read a human asked for (contrast the approval-triggered freeze
     * in `MarketDataSnapshotService`, where a throw would roll back the approval).
     *
     * ⚠ THE DENIAL NOW RESTS ON ONE FIELD, NOT THREE (2026-08-17). The two-column cut dropped
     * `Amount`, `Deal_Type__c` and `Asset_Type__c` from the SELECT, leaving `Asking_Price__c`
     * as the only FLS-bearing field in it. That is a NARROWER premise than this test had
     * before, so it is worth stating plainly: `Asking_Price__c` is a Metadata-API-deployed
     * custom field, and such fields arrive with no field permissions for ANY profile (System
     * Administrator included), so an unassigned persona is still denied BY CONSTRUCTION in
     * this repo rather than by luck.
     *
     * ⚠ WHY IT ASSERTS THE THROW RATHER THAN ASSIGNING A PERMISSION SET TO THE FIXTURE.
     * Granting the persona `DPEG_Opportunity_View` would make this a test of PROVISIONING —
     * org state, not code — which is the same class of test that produces the standing
     * gate T-A1 red failures. It would also go green while a regression in the §5 boundary
     * went unnoticed, because the catch block would stop being reached at all.
     *
     * ⚠ FALSIFIERS, so this cannot rot into a tautology: it reds if the controller stops
     * wrapping (a raw `QueryException` escapes the narrow catch and surfaces by type), if it
     * swallows the failure and returns a list or null instead of throwing, or if the
     * user-safe message changes. The literal below is duplicated from
     * `TopDealsController.READ_FAILURE_MESSAGE` (which is private, not `@TestVisible`) on
     * purpose — it is the client-facing wire contract, so changing it should require a
     * deliberate edit in two places.
     */
    @isTest
    static void anUnprovisionedPersonaGetsTheUserSafeMessageNotARawQueryException() {
        User restricted = buildStandardUser();
        insert restricted;

        Test.startTest();
        System.runAs(restricted) {
            try {
                TopDealsController.getTopDeals();
                Assert.fail(
                    'Expected an AuraHandledException for an unprovisioned persona. Reaching '
                    + 'this line means the bare Standard User profile has gained read FLS on '
                    + 'Opportunity.Asking_Price__c. That is a PROVISIONING change, not a code '
                    + 'defect — re-verify this premise before editing this test, and do not '
                    + 'simply delete the assertion.');
            } catch (AuraHandledException e) {
                // Narrow on purpose. A raw QueryException is NOT caught here, so a controller
                // that stopped wrapping fails this test with its real type visible.
                Assert.areEqual(
                    'The largest deals could not be loaded. Refresh the page or contact your '
                    + 'administrator.',
                    e.getMessage(),
                    'The client must receive the fixed user-safe message. A leaked '
                    + '"No such column \'Asking_Price__c\'" reads as a broken app rather than '
                    + 'a permissions gap, which is what §5 exists to prevent');
            }
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
