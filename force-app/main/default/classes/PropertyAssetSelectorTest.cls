/**
 * Tests for PropertyAssetSelector (P4 cleanup wave E — Disposition module).
 *
 * Both Sell Meter methods are filtered to SELL CANDIDATES only. Since 2026-09-02 the shared
 * predicate has THREE terms, not two:
 *   Property__c != null AND Peak_Sell_Date__c != null AND Status__c != 'Disposed'
 * so the Sell Meter widget shows real disposition-evaluation assets rather than
 * every Property_Asset__c row (un-parented seed junk / assets not yet on the
 * meter / buildings DPEG has already sold). These tests therefore always set BOTH
 * Property__c and Peak_Sell_Date__c on the records they expect back, and assert
 * that records missing either are excluded.
 *
 * 🔴 THE THIRD TERM IS CONVERSION 6 (BA story 49) AND ITS TESTS ARE GROUPED AT THE BOTTOM OF THIS
 * FILE. Two of them carry the whole weight of the change and neither is obvious:
 *   - `bothMeterQueriesExcludeADisposedAssetAndAgreeWithEachOther` asserts BOTH counts in ONE
 *     method, because two separate tests would let one go red and be "fixed" alone — which is
 *     precisely how the summary tiles and the table below them come to disagree;
 *   - `anAssetWithNoStatusAtAllStaysOnTheMeter` is the ONLY test in this class that can tell
 *     `!= 'Disposed'` from `= 'Active'`. On today's data the two predicates are identical, so
 *     every other test passes under either.
 *
 * ⚠ selectPeakSellDateById IS THE EXCEPTION TO THAT FILTER and is tested as one. It backs
 * DispositionService's sell-meter gate, which must be able to READ a null peak date —
 * a null peak is precisely what bands RED and refuses the creation. If that method ever
 * acquires the sell-candidate filter, a refusal turns into a QueryException and the user
 * gets the generic write-failure message instead of the sell-meter wording;
 * selectPeakSellDateById_nullPeakDate_stillReturnsTheRow exists to go red if it does.
 *
 * No @TestSetup: each method creates exactly the assets it needs and asserts
 * against the org total, which equals what it created (SeeAllData=false).
 *
 * No runAs USER_MODE test — Property_Asset__c is custom, FLS gap 0.
 */
@isTest
private class PropertyAssetSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectAllForMeterSummary_populatesFields() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.NOI__c = 80000;
        asset.Market_Cap_Rate__c = 6.5;
        asset.Target_Sale_Price__c = 1300000;
        asset.Peak_Sell_Date__c = Date.today().addDays(45);
        insert asset;

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForMeterSummary();
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Exactly one sell-candidate Property Asset exists');
        Assert.areEqual(80000, result[0].NOI__c, 'NOI__c should be selected');
        Assert.areEqual(6.5, result[0].Market_Cap_Rate__c, 'Market_Cap_Rate__c should be selected');
        Assert.areEqual(1300000, result[0].Target_Sale_Price__c, 'Target_Sale_Price__c should be selected');
        Assert.areEqual(Date.today().addDays(45), result[0].Peak_Sell_Date__c, 'Peak_Sell_Date__c should be selected');
    }

    @isTest
    static void selectAllForPortfolio_ordersByNameAndPopulatesFields() {
        Property__c prop = TestDataFactory.createProperty(true);
        // Factory names these 'Test Asset 0/1/2' — ORDER BY Name is ascending 0,1,2.
        // Build unsinserted so we can stamp Peak_Sell_Date__c (the filter requires it).
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(3, prop.Id, false);
        for (Property_Asset__c a : assets) {
            a.Peak_Sell_Date__c = Date.today().addDays(45);
        }
        insert assets;

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three sell-candidate assets should return');
        for (Integer i = 1; i < result.size(); i++) {
            Assert.isTrue(result[i - 1].Name <= result[i].Name, 'Rows must be ordered by Name ascending');
        }
        Assert.areEqual('Retail', result[0].Property__r.Asset_Type__c,
            'Property__r.Asset_Type__c should be selected via the parent path');
        Assert.isNotNull(result[0].Id, 'Id must be selected for the row-mapping caller');
        Assert.isNotNull(result[0].NOI__c, 'NOI__c should be selected');
    }

    @isTest
    static void selectAllForMeterSummary_bulk251_readsAll() {
        Property__c prop = TestDataFactory.createProperty(true);
        // Build unsinserted so every one of the 251 gets a Peak_Sell_Date__c and
        // therefore qualifies under the sell-candidate filter.
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(BULK_N, prop.Id, false);
        for (Property_Asset__c a : assets) {
            a.Peak_Sell_Date__c = Date.today().addDays(45);
        }
        insert assets;

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForMeterSummary();
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 sell-candidate assets should be read by the portfolio scan');
    }

    @isTest
    static void selectAllForPortfolio_noAssets_returnsEmpty() {
        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'With no assets the scan returns an empty list, not null');
    }

    @isTest
    static void selectAllForPortfolio_excludesNonCandidates() {
        Property__c prop = TestDataFactory.createProperty(true);

        // Candidate: non-null Property AND non-null Peak_Sell_Date -> INCLUDED.
        Property_Asset__c candidate = TestDataFactory.createPropertyAsset(prop.Id, false);
        candidate.Peak_Sell_Date__c = Date.today().addDays(20);

        // Non-candidate A: has a Property but NO peak date -> EXCLUDED.
        Property_Asset__c noPeak = TestDataFactory.createPropertyAsset(prop.Id, false);
        noPeak.Peak_Sell_Date__c = null;

        // Non-candidate B: has a peak date but a NULL Property lookup -> EXCLUDED.
        Property_Asset__c noProperty = TestDataFactory.createPropertyAsset(null, false);
        noProperty.Peak_Sell_Date__c = Date.today().addDays(20);

        insert new List<Property_Asset__c>{ candidate, noPeak, noProperty };

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the sell candidate is returned; the no-peak and no-property assets are excluded by the filter');
        Assert.areEqual(candidate.Id, result[0].Id, 'The single returned row must be the candidate');
    }

    @isTest
    static void selectAllForMeterSummary_excludesNonCandidates() {
        Property__c prop = TestDataFactory.createProperty(true);

        // Candidate — distinctive NOI marks the row we expect back.
        Property_Asset__c candidate = TestDataFactory.createPropertyAsset(prop.Id, false);
        candidate.Peak_Sell_Date__c = Date.today().addDays(20);
        candidate.NOI__c = 12345;

        // Non-candidate A: Property set, no peak date -> EXCLUDED.
        Property_Asset__c noPeak = TestDataFactory.createPropertyAsset(prop.Id, false);
        noPeak.Peak_Sell_Date__c = null;

        // Non-candidate B: peak date set, null Property lookup -> EXCLUDED.
        Property_Asset__c noProperty = TestDataFactory.createPropertyAsset(null, false);
        noProperty.Peak_Sell_Date__c = Date.today().addDays(20);

        insert new List<Property_Asset__c>{ candidate, noPeak, noProperty };

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForMeterSummary();
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the sell candidate is returned; the no-peak and no-property assets are excluded by the filter');
        Assert.areEqual(12345, result[0].NOI__c,
            'The single returned row must be the candidate (matched by its distinctive NOI)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectPeakSellDateById — the sell-meter gate's read (fetch-for-use)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectPeakSellDateById_returnsThePeakDate() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.Peak_Sell_Date__c = Date.today().addDays(45);
        insert asset;

        Test.startTest();
        Property_Asset__c result = PropertyAssetSelector.selectPeakSellDateById(asset.Id);
        Test.stopTest();

        Assert.areEqual(asset.Id, result.Id, 'The requested asset should be returned');
        Assert.areEqual(Date.today().addDays(45), result.Peak_Sell_Date__c,
            'Peak_Sell_Date__c must be populated - it is the gate\'s only input');
    }

    /**
     * 🔴 A NULL PEAK DATE IS A ROW, NOT A MISS. DispositionService bands a null peak RED
     * and refuses the creation with a user-safe message. If this method ever filters on
     * Peak_Sell_Date__c != null the row disappears, the single-row assignment throws
     * QueryException, and the user gets "This change could not be saved. Refresh the page
     * and try again" for a permanent, deliberate refusal. This test is the fence.
     */
    @isTest
    static void selectPeakSellDateById_nullPeakDate_stillReturnsTheRow() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.Peak_Sell_Date__c = null;
        insert asset;

        Test.startTest();
        Property_Asset__c result = PropertyAssetSelector.selectPeakSellDateById(asset.Id);
        Test.stopTest();

        Assert.areEqual(asset.Id, result.Id,
            'An asset with no peak date must still be READABLE - the null is what bands it RED');
        Assert.isNull(result.Peak_Sell_Date__c, 'The null peak date passes through as null');
    }

    /**
     * FETCH-FOR-USE contract: a miss throws the native System.QueryException rather than
     * returning null. That is what lets DispositionController tell a platform failure
     * (generic message) apart from a sell-meter refusal (the sell-meter wording).
     */
    @isTest
    static void selectPeakSellDateById_missingId_throwsQueryException() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Id ghostId = asset.Id;
        delete asset;

        Test.startTest();
        Boolean threw = false;
        try {
            PropertyAssetSelector.selectPeakSellDateById(ghostId);
            Assert.fail('A deleted asset Id must not resolve to a row');
        } catch (System.QueryException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'fetch-for-use: a miss throws QueryException, it does not return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectByPropertyIds — the Closed Won idempotency guard's read (Tranche 5A)
    //
    // ⚠ This method is the ONE `WITH SYSTEM_MODE` + `without sharing` read on this class.
    // The mode and the sharing keyword cannot be falsified by a test running as an
    // administrator, so what these tests pin is the CONTRACT the service depends on:
    // the key is Property__c alone (no Status__c filter), the field set is minimal, the
    // null/empty short-circuit costs no query, and a property with no asset is simply
    // absent. The mode/sharing decisions rest on measured repo state recorded in the
    // method header and are proved by post-deploy gate A-G4, as a non-admin persona.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectByPropertyIds_returnsTheExistingAssetsPropertyLink() {
        Property__c withAsset = TestDataFactory.createProperty(true);
        Property__c withoutAsset = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(withAsset.Id, true);

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectByPropertyIds(
            new Set<Id>{ withAsset.Id, withoutAsset.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the property that already carries an asset produces a row');
        Assert.areEqual(asset.Id, result[0].Id, 'Id must be selected');
        Assert.areEqual(withAsset.Id, result[0].Property__c,
            'Property__c must be selected — the caller keys the whole guard on it');
    }

    /**
     * 🔴 NO `Status__c` FILTER. A `Disposed` asset still counts as "this property already has
     * an asset", so a re-acquisition does NOT mint a second one — D27.3's "never a second
     * asset for one property", read literally. If a future change adds
     * `AND Status__c = 'Active'` to this query, a bought-sold-rebought property silently
     * grows a rival asset and splits the whole Property Management tree in two. This test is
     * the fence.
     */
    @isTest
    static void selectByPropertyIds_disposedAssetStillCounts() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.Status__c = 'Disposed';
        insert asset;

        Test.startTest();
        List<Property_Asset__c> result =
            PropertyAssetSelector.selectByPropertyIds(new Set<Id>{ prop.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'A Disposed asset must still be seen by the idempotency guard');
    }

    @isTest
    static void selectByPropertyIds_nullOrEmpty_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property_Asset__c> fromNull = PropertyAssetSelector.selectByPropertyIds(null);
        List<Property_Asset__c> fromEmpty =
            PropertyAssetSelector.selectByPropertyIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty input returns an empty list, never null');
        Assert.areEqual(0, spent, 'Neither short-circuit may issue SOQL');
    }

    @isTest
    static void selectByPropertyIds_bulk251_readsAllInOneQuery() {
        List<Property__c> properties = TestDataFactory.createProperties(BULK_N, true);
        List<Property_Asset__c> assets = new List<Property_Asset__c>();
        for (Property__c p : properties) {
            assets.add(new Property_Asset__c(Name = p.Name, Property__c = p.Id, Status__c = 'Active'));
        }
        insert assets;
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property_Asset__c> result = PropertyAssetSelector.selectByPropertyIds(ids);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 existing assets should be returned');
        Assert.areEqual(1, spent, 'A 251-Id read costs exactly one query, not 251');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 🔴 CONVERSION 6 (BA story 49, 2026-09-02) — THE `Status__c != 'Disposed'` TERM
    //
    // Before this date NOTHING in the application wrote `'Disposed'`, so the two Sell
    // Meter queries and eight dashboard reports could not have told the difference. These
    // tests are the fence that keeps the term on BOTH meter queries: if it is removed from
    // one, the summary tiles and the list below them disagree on the SAME page, which is
    // exactly the Home-vs-Dashboard disagreement this item exists to end.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE SHARED-PREDICATE INVARIANT, ASSERTED AS ONE TEST RATHER THAN TWO.
     *
     * `selectAllForMeterSummary` and `selectAllForPortfolio` must return the SAME set. Splitting
     * this into two tests would let one go red and the other green, and someone would "fix" the
     * red one — which is how the two queries drift apart. Asserting both counts in one method
     * makes the disagreement itself the failure.
     */
    @isTest
    static void bothMeterQueriesExcludeADisposedAssetAndAgreeWithEachOther() {
        Property__c prop = TestDataFactory.createProperty(true);

        Property_Asset__c active = TestDataFactory.createPropertyAsset(prop.Id, false);
        active.Peak_Sell_Date__c = Date.today().addDays(20);
        active.Status__c = 'Active';

        Property_Asset__c disposed = TestDataFactory.createPropertyAsset(prop.Id, false);
        disposed.Peak_Sell_Date__c = Date.today().addDays(20);
        disposed.Status__c = 'Disposed';

        insert new List<Property_Asset__c>{ active, disposed };

        Test.startTest();
        List<Property_Asset__c> summary = PropertyAssetSelector.selectAllForMeterSummary();
        List<Property_Asset__c> portfolio = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(1, portfolio.size(),
            'The sold building must leave the Sell Meter TABLE — and with it the Initiate button');
        Assert.areEqual(active.Id, portfolio[0].Id, 'and the survivor is the Active one');
        Assert.areEqual(1, summary.size(),
            '🔴 AND THE SUMMARY MUST AGREE. A 2 here with a 1 above means the term landed on only '
            + 'one of the two queries, so the band tiles and Portfolio Upside now count a building '
            + 'the table below them does not show.');
        Assert.areEqual(portfolio.size(), summary.size(),
            'The two queries share one predicate by contract — see the class header');
    }

    /**
     * 🔴 `!= 'Disposed'` MUST INCLUDE A NULL STATUS, AND THIS IS THE ONLY TEST THAT CAN TELL THE
     * TWO CANDIDATE PREDICATES APART.
     *
     * `Status__c` is `required = false`. SOQL's `!=` returns rows where the field is null;
     * `= 'Active'` does not. On today's data the two predicates give identical answers — the
     * factory stamps `'Active'` and the restricted picklist defaults it — so every OTHER test in
     * this class passes under either. A status-less asset is the discriminator, and it is exactly
     * what a data load or a partial integration write produces.
     */
    @isTest
    static void anAssetWithNoStatusAtAllStaysOnTheMeter() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c blank = TestDataFactory.createPropertyAsset(prop.Id, false);
        blank.Peak_Sell_Date__c = Date.today().addDays(20);
        blank.Status__c = null;
        insert blank;

        // Guard the guard: the platform's picklist default must NOT have filled it in, or this
        // test is asserting the Active case a second time under a misleading name.
        Assert.isNull([SELECT Status__c FROM Property_Asset__c WHERE Id = :blank.Id].Status__c,
            'PRECONDITION: an explicit null survives the insert. If the restricted picklist\'s '
            + '`Active` default has started applying to explicit nulls, this test can no longer '
            + 'discriminate `!= Disposed` from `= Active` and must be replaced, not deleted.');

        Test.startTest();
        List<Property_Asset__c> summary = PropertyAssetSelector.selectAllForMeterSummary();
        List<Property_Asset__c> portfolio = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(1, portfolio.size(),
            '🔴 A NULL STATUS IS NOT A DISPOSAL. A 0 here means the predicate was written as '
            + '`Status__c = \'Active\'`, which silently deletes every status-less asset from the '
            + 'Sell Meter and from the Home page.');
        Assert.areEqual(1, summary.size(), 'and the summary agrees, as it must');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectStatusByIds — Conversion 6's idempotency read (2026-09-02)
    //
    // ⚠ The SECOND `WITH SYSTEM_MODE` + `without sharing` read on this class, and like
    // `selectByPropertyIds` its mode and sharing keyword cannot be falsified by a test
    // running as an administrator. What IS falsified here is the contract:
    // the field set, the null/empty short-circuit, and the one-query bulk cost.
    // 🔴 THE SHARING DECISION IS PROVED ELSEWHERE, AND IT HAS TO BE:
    // `DispositionAssetDisposalServiceTest.nonOwnerPrincipal_disposesTheAssetItCanNeither
    // SeeNorEdit` runs the whole path under `System.runAs` as a persona with no record-level
    // read on Property_Asset__c. Without it, removing `without sharing` from `DisposalReads`
    // would make the read return nothing, the caller do nothing, and every test in THIS class
    // still pass.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectStatusByIds_returnsIdAndStatusOnly() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c active = TestDataFactory.createPropertyAsset(prop.Id, true);
        Property_Asset__c disposed = TestDataFactory.createPropertyAsset(prop.Id, false);
        disposed.Status__c = 'Disposed';
        insert disposed;

        Test.startTest();
        Map<Id, Property_Asset__c> byId = new Map<Id, Property_Asset__c>(
            PropertyAssetSelector.selectStatusByIds(
                new Set<Id>{ active.Id, disposed.Id }));
        Test.stopTest();

        Assert.areEqual(2, byId.size(), 'Both assets resolve');
        Assert.areEqual('Active', byId.get(active.Id).Status__c,
            'Status__c must be selected — the caller keys its whole idempotency guard on it');
        Assert.areEqual('Disposed', byId.get(disposed.Id).Status__c,
            'and it must carry the real value, not a default');
    }

    /**
     * An Id that resolves to nothing is simply absent, never a QueryException.
     * ⚠ THE CALLER IS DRIVEN BY WHAT CAME BACK, NEVER BY WHAT WENT IN — a deleted asset must
     * produce no write rather than a failed one, because a throw here rolls back the disposition's
     * own save.
     */
    @isTest
    static void selectStatusByIds_anUnresolvableIdIsAbsentRatherThanAnError() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Property_Asset__c doomed = TestDataFactory.createPropertyAsset(prop.Id, true);
        Id deletedId = doomed.Id;
        delete doomed;

        Test.startTest();
        List<Property_Asset__c> result =
            PropertyAssetSelector.selectStatusByIds(new Set<Id>{ asset.Id, deletedId });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the surviving asset comes back');
        Assert.areEqual(asset.Id, result[0].Id, 'and it is the right one');
    }

    @isTest
    static void selectStatusByIds_nullOrEmpty_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property_Asset__c> fromNull = PropertyAssetSelector.selectStatusByIds(null);
        List<Property_Asset__c> fromEmpty =
            PropertyAssetSelector.selectStatusByIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty input returns an empty list, never null');
        Assert.areEqual(0, spent,
            'Neither short-circuit may issue SOQL — this read sits on the path of every '
            + 'Disposition save that enters Sale Closes');
    }

    @isTest
    static void selectStatusByIds_bulk251_readsAllInOneQuery() {
        Property__c prop = TestDataFactory.createProperty(true);
        List<Property_Asset__c> assets =
            TestDataFactory.createPropertyAssets(BULK_N, prop.Id, true);
        Set<Id> ids = new Map<Id, Property_Asset__c>(assets).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property_Asset__c> result = PropertyAssetSelector.selectStatusByIds(ids);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 assets should be returned');
        Assert.areEqual(1, spent, 'A 251-Id read costs exactly one query, not 251');
    }
}
