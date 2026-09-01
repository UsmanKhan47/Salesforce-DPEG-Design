/**
 * @description Test class for SellMeterController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Reported coverage was 0% going into this pass; the prior test methods
 * already exercised the GREEN/YELLOW/RED banding and the summary rollup
 * thoroughly, so the 0% most likely reflects "not yet executed by
 * RunLocalTests" rather than a defect — see the final report. Adds exact
 * boundary coverage (30 / 90 days), an empty-portfolio scenario, and a
 * 251-record data-volume read test per .claude/rules/bulk-test-rule.md.
 *
 * ⚠ THE BAND FUNCTION MOVED, THE ASSERTIONS DID NOT. bandForPeak now lives in
 * SellMeterService (so the server-side disposition gate and this read path share one
 * implementation); SellMeterController delegates to it. Every band assertion below is
 * UNCHANGED and still exercises the controller end to end, which is the point — a verbatim
 * move should be invisible to this suite, and if it is not, the move was not verbatim.
 * The band function's own boundary fence lives in SellMeterServiceTest; the value of the
 * tests here is that they prove the CONTROLLER still bands correctly through the delegation.
 * @author Unit Testing Agent
 */
@isTest
private class SellMeterControllerTest {

    @testSetup
    static void setup() {
        Property__c pA = TestDataFactory.createProperty(false);
        pA.Asset_Type__c = 'Retail';
        Property__c pB = TestDataFactory.createProperty(false);
        pB.Asset_Type__c = 'Multifamily';
        Property__c pC = TestDataFactory.createProperty(false);
        pC.Asset_Type__c = 'Office';
        insert new List<Property__c>{ pA, pB, pC };

        // Readiness band is driven by days until Peak_Sell_Date__c:
        //   Asset 0: peak in 15 days  -> GREEN  (<= 30)
        //   Asset 1: peak in 60 days  -> YELLOW (31-90)
        //   Asset 2: peak in 120 days -> RED    (> 90)
        //   Asset 3: no peak date     -> RED    (null guard)
        // All use NOI=1,000,000, Cap=5.0 -> Implied=20,000,000.
        //
        // ═══════════════════════════════════════════════════════════════════════════════
        // 🔴 THE TARGET PRICES ON ASSETS 1 AND 2 CHANGED ON 2026-08-31 AND THE CHANGE IS THE
        // WHOLE POINT OF THE FIXTURE. DO NOT PUT THEM BACK ABOVE 20,000,000.
        // ═══════════════════════════════════════════════════════════════════════════════
        // This block used to read: *"only Asset 0 is above its target (18M), giving a 2M portfolio
        // upside."* That was TRUE and it made `testGetMeterSummary_aggregatesBandsAndUpside`
        // VACUOUS for the story-9 change: the only in-the-money asset was the GREEN one, so a
        // portfolio-wide sum and a green-only sum both produced 2,000,000 and the assertion could
        // not tell them apart. It would have passed identically before and after, and against an
        // implementation that computed either figure for both fields.
        //
        // Assets 1 (YELLOW) and 2 (RED) are now IN THE MONEY BY DIFFERENT AMOUNTS, so:
        //   upside          (portfolio-wide) = 2M + 3M + 5M = 10,000,000
        //   sellReadyUpside (GREEN only)     =                 2,000,000
        // The two numbers are now distinguishable, and they are distinguishable from each other's
        // subsets too — a green-only figure computed over YELLOW would be 3M, over RED 5M, over
        // YELLOW+RED 8M, and none of those equals either asserted value. Swapping the two fields
        // fails. Summing the wrong bands fails.
        Date today = Date.today();
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(4, pA.Id, false);
        assets[0].Property__c = pA.Id;
        assets[0].NOI__c = 1000000;
        assets[0].Market_Cap_Rate__c = 5.0;
        assets[0].Target_Sale_Price__c = 18000000;
        assets[0].Argus_Signal__c = 'Sell Now';
        assets[0].Peak_Sell_Date__c = today.addDays(15);

        assets[1].Property__c = pB.Id;
        assets[1].NOI__c = 1000000;
        assets[1].Market_Cap_Rate__c = 5.0;
        // IN THE MONEY BY 3M (implied 20M - target 17M). Excluded from sellReadyUpside because it
        // is YELLOW; included in the portfolio-wide upside because that one counts every band.
        assets[1].Target_Sale_Price__c = 17000000;
        assets[1].Argus_Signal__c = '12 mo';
        assets[1].Peak_Sell_Date__c = today.addDays(60);

        assets[2].Property__c = pC.Id;
        assets[2].NOI__c = 1000000;
        assets[2].Market_Cap_Rate__c = 5.0;
        // IN THE MONEY BY 5M (implied 20M - target 15M), and deliberately a DIFFERENT amount from
        // asset 1's 3M so a mis-summed subset cannot coincidentally equal the right answer.
        assets[2].Target_Sale_Price__c = 15000000;
        assets[2].Argus_Signal__c = 'Hold';
        assets[2].Peak_Sell_Date__c = today.addDays(120);

        assets[3].Property__c = pA.Id;
        assets[3].NOI__c = null;
        assets[3].Market_Cap_Rate__c = null;
        assets[3].Target_Sale_Price__c = null;
        assets[3].Argus_Signal__c = null;
        assets[3].Peak_Sell_Date__c = null;

        insert assets;
    }

    @isTest
    static void testGetPortfolio_bandThresholds() {
        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        Test.stopTest();

        // Only 3 of the 4 @testSetup assets are sell candidates: asset[3] has a
        // null Peak_Sell_Date__c, so the selector's sell-candidate filter
        // (Property__c != null AND Peak_Sell_Date__c != null) now excludes it.
        System.assertEquals(3, rows.size(), 'Three sell-candidate assets expected (asset[3] has no peak date and is filtered out)');

        // Results are ORDER BY Name; factory names 'Test Asset 0..2' sort in insertion order.
        SellMeterController.PropertyRow a0 = rows[0];
        System.assertEquals('GREEN', a0.sellMeter, 'Asset 0: peak in 15 days should be GREEN');
        System.assertNotEquals(null, a0.impliedValue, 'Implied value should be computed for asset 0');
        System.assertEquals('Sell Now', a0.argusSignal, 'Argus signal should pass through');
        System.assertEquals('Retail', a0.assetType, 'Asset type cross-object lookup should resolve');

        SellMeterController.PropertyRow a1 = rows[1];
        System.assertEquals('YELLOW', a1.sellMeter, 'Asset 1: peak in 60 days should be YELLOW');

        SellMeterController.PropertyRow a2 = rows[2];
        System.assertEquals('RED', a2.sellMeter, 'Asset 2: peak in 120 days should be RED');
    }

    @isTest
    static void testGetMeterSummary_aggregatesBandsAndUpside() {
        Test.startTest();
        SellMeterController.MeterSummary s = SellMeterController.getMeterSummary();
        Test.stopTest();

        System.assertEquals(1, s.green, 'One asset (0) within 30 days of peak');
        System.assertEquals(1, s.yellow, 'One asset (1) 30-90 days from peak');
        // asset[3] (no peak date) is now excluded by the sell-candidate filter, so
        // only asset[2] (120 days out) remains in the red bucket.
        System.assertEquals(1, s.red, 'One sell-candidate asset (2, far out); asset[3] with no peak date is filtered out');

        // ─────────────────────────────────────────────────────────────────────────────
        // 🔴 THE TWO UPSIDE FIGURES — THE REGRESSION NET FOR STORY 9 (2026-08-31, item 2).
        // ─────────────────────────────────────────────────────────────────────────────
        // ⚠ THIS PAIR REPLACES A VACUOUS ASSERTION. Until 2026-08-31 the fixture's only
        // in-the-money asset was the GREEN one, so the single `assertEquals(2000000, s.upside)`
        // below produced the same number whether the sum was portfolio-wide or green-only. It
        // proved nothing about the distinction story 9 is entirely about. See the @testSetup
        // block for the fixture change that fixed it — assets 1 (YELLOW, +3M) and 2 (RED, +5M) are
        // now in the money too.
        //
        // 🔴 `upside` IS STILL PORTFOLIO-WIDE AND THAT IS A USER DECISION, NOT AN OVERSIGHT. The
        // design recommended NARROWING this field to green-only and renaming its card; the user
        // declined at Gate 1 (2026-08-31) and asked for the green-only figure to be ADDED beside
        // it instead. So this assertion's SUBJECT is unchanged; only its VALUE moved, and it moved
        // because the fixture gained in-the-money assets, not because the code did.
        System.assertEquals(10000000, s.upside,
            'Portfolio Upside counts EVERY in-the-money asset regardless of band: '
            + 'asset 0 GREEN +2M, asset 1 YELLOW +3M, asset 2 RED +5M = 10M. If this reads '
            + '2,000,000 the field has been narrowed to green-only, which is the change the user '
            + 'declined.');
        System.assertEquals(2000000, s.sellReadyUpside,
            'Sell-Ready Upside counts the GREEN band only: asset 0\'s 2M and nothing else. If this '
            + 'reads 10,000,000 it is summing every band; 3,000,000 means it is summing YELLOW; '
            + '5,000,000 means RED; 8,000,000 means everything except GREEN. Every wrong band '
            + 'combination produces a distinct number, by construction of the fixture.');
        System.assertNotEquals(s.upside, s.sellReadyUpside,
            '🔴 THE TWO FIGURES MUST BE DISTINGUISHABLE IN THIS FIXTURE. If they are ever equal '
            + 'here, the fixture has drifted back to its pre-2026-08-31 shape (one in-the-money '
            + 'asset, and it GREEN) and BOTH assertions above have gone vacuous — they would pass '
            + 'against an implementation that computed either number for both fields.');
        System.assert(s.sellReadyUpside <= s.upside,
            'The green-only figure is a subset of the portfolio-wide one and can never exceed it. '
            + 'It exceeding it would mean the two loops had drifted apart entirely.');
    }

    @isTest
    static void testBandForPeak_exactBoundaries_30And90Days() {
        delete [SELECT Id FROM Property_Asset__c];
        Property__c prop = TestDataFactory.createProperty(true);
        Date today = Date.today();
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(2, prop.Id, false);
        assets[0].Peak_Sell_Date__c = today.addDays(30);
        assets[1].Peak_Sell_Date__c = today.addDays(90);
        insert assets;

        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        Test.stopTest();

        Map<Id, SellMeterController.PropertyRow> byId = new Map<Id, SellMeterController.PropertyRow>();
        for (SellMeterController.PropertyRow r : rows) {
            byId.put(Id.valueOf(r.id), r);
        }
        System.assertEquals('GREEN', byId.get(assets[0].Id).sellMeter, 'Exactly 30 days out should still be GREEN (<=30)');
        System.assertEquals('YELLOW', byId.get(assets[1].Id).sellMeter, 'Exactly 90 days out should still be YELLOW (<=90)');
    }

    @isTest
    static void testGetPortfolio_noAssets_returnsEmptyResults() {
        delete [SELECT Id FROM Property_Asset__c];

        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        SellMeterController.MeterSummary summary = SellMeterController.getMeterSummary();
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'No Property_Asset__c records exist, so getPortfolio should return an empty list');
        System.assertEquals(0, summary.green + summary.yellow + summary.red, 'No assets means every band count should be zero');
        System.assertEquals(0, summary.upside, 'No assets means portfolio upside should be zero');
        System.assertEquals(0, summary.sellReadyUpside,
            'No assets means Sell-Ready Upside should be zero too — the field must initialise to 0 '
            + 'rather than null, or the LWC\'s money formatter renders an empty tile');
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251
     * Property_Asset__c rows inserted via a single bulk DML statement, to
     * prove the org-wide (no WHERE clause) query and per-row band/implied-value
     * computation in getPortfolio/getMeterSummary scale without a CPU-time or
     * heap-size breach. Filters the returned rows down to just the newly
     * inserted set so the assertion count matches the 251 inserted, per the
     * rule, despite the 4 @TestSetup assets also being visible to this query.
     */
    @isTest
    static void testGetPortfolio_251NewAssets_allRowsProcessed() {
        SellMeterController.MeterSummary before = SellMeterController.getMeterSummary();

        Property__c seedProperty = [SELECT Id FROM Property__c LIMIT 1];
        List<Property_Asset__c> bulkAssets = TestDataFactory.createPropertyAssets(251, seedProperty.Id, false);
        Date farOut = Date.today().addDays(200); // > 90 days out => RED for every new asset
        for (Property_Asset__c a : bulkAssets) {
            a.Peak_Sell_Date__c = farOut;
        }
        insert bulkAssets;
        Set<Id> bulkAssetIds = new Map<Id, Property_Asset__c>(bulkAssets).keySet();

        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        SellMeterController.MeterSummary after = SellMeterController.getMeterSummary();
        Test.stopTest();

        Integer matched = 0;
        for (SellMeterController.PropertyRow r : rows) {
            if (bulkAssetIds.contains(Id.valueOf(r.id))) {
                matched++;
                System.assertEquals('RED', r.sellMeter, 'Every bulk asset is 200 days from peak, so it should band RED');
            }
        }
        System.assertEquals(251, matched, 'All 251 newly inserted assets should be present in getPortfolio results');
        System.assertEquals(251, after.red - before.red, 'The red bucket should grow by exactly the 251 newly inserted assets');
        // The factory deliberately leaves Target_Sale_Price__c null (see TestDataFactory), so no
        // bulk asset is "in the money" and neither figure may move. This pins that 251 RED assets
        // cannot leak into the GREEN-only sum — the direction a mis-scoped band test would fail.
        System.assertEquals(before.sellReadyUpside, after.sellReadyUpside,
            '251 RED assets must contribute nothing to Sell-Ready Upside');
    }

    // A bare Standard User with no DPEG perm sets has no access to the custom
    // Property_Asset__c object, so both selectors' WITH USER_MODE queries throw —
    // exercising each read-failure catch that maps it to a user-safe
    // AuraHandledException (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.sellmeter.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers the read-failure catch on both @AuraEnabled reads: under a bare Standard
     * User, WITH USER_MODE on the custom Property_Asset__c object (no access) throws, and
     * each method maps it to a user-safe AuraHandledException. Its own method because
     * bareUser() inserts a User (setup DML) and no record DML runs here (the queries throw
     * before any) — avoids MIXED_DML_OPERATION.
     */
    @isTest
    static void readCatchesThrowAuraHandledException() {
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try { SellMeterController.getMeterSummary(); Assert.fail('getMeterSummary should throw under a bare user (no access to Property_Asset__c)'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getMeterSummary maps read failure to AuraHandledException'); }
            try { SellMeterController.getPortfolio(); Assert.fail('getPortfolio should throw under a bare user (no access to Property_Asset__c)'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getPortfolio maps read failure to AuraHandledException'); }
            Test.stopTest();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // hasOverrideAccess — the Sell Meter's YELLOW "Override" affordance
    // (2026-08-31, Tranche 2 item 5a, stories 12 and 14)
    //
    // ⚠ THIS METHOD IS A UX AFFORDANCE, NOT THE GATE. The gate is asserted server-side on both
    // DispositionService create paths; this is what lets the LWC render the button DISABLED
    // rather than enabled-then-refused. The gate's own semantics are proved in
    // SellMeterOverridePermissionServiceTest; what belongs HERE is only the controller boundary:
    // does the answer pass through, and is a fault mapped to a user-safe AuraHandledException.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The pass-through. The test-running user is a System Administrator, so "Modify All Data"
     * bypasses the gate and the answer is `true` — which makes this a test of the WIRING and
     * nothing else, and it says so rather than implying it proves the permission model.
     */
    @isTest
    static void hasOverrideAccess_returnsTheServiceAnswer() {
        SellMeterOverridePermissionService.clearCache();

        Test.startTest();
        Boolean viaController = SellMeterController.hasOverrideAccess();
        Boolean viaService = SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        Test.stopTest();

        SellMeterOverridePermissionService.clearCache();
        Assert.areEqual(viaService, viaController,
            'The controller must return the service\'s answer unmodified — it holds no gate logic '
            + 'of its own, and a second copy of the rule here is exactly the drift the service '
            + 'exists to prevent');
        Assert.isTrue(viaController,
            'PRECONDITION: the test-running administrator is bypassed by Modify All Data, so the '
            + 'answer must be true. If this is false the bypass is gone and every other test in '
            + 'this repo that creates a YELLOW disposition as the running user is about to break.');
    }

    /**
     * 🔴 A FAULT IS NOT A DENIAL, AND THE BOUNDARY MUST NOT LEAK IT. The service THROWS when the
     * permission machinery itself fails (rather than returning false, which would report a system
     * fault to the user as "you lack permission"). At this boundary that throw becomes the fixed,
     * generic read-failure message — never platform text, never a stack trace.
     *
     * This is also the only deterministic way to reach the catch: every user can read their OWN
     * PermissionSetAssignment rows, so the real failure mode cannot be provoked.
     *
     * ⚠ The LWC treats a wire error exactly like `false`, so the button stays disabled and the
     * gate still fails closed end to end — the difference is only that a fault reads as a fault.
     */
    @isTest
    static void hasOverrideAccess_mapsAPermissionFaultToAuraHandledException() {
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;

        Test.startTest();
        Boolean threw = false;
        try {
            SellMeterController.hasOverrideAccess();
            Assert.fail('A permission-machinery fault must not return a Boolean — it must surface '
                + 'as an AuraHandledException at the LWC boundary');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('could not be loaded'),
                'The user must get the fixed generic read-failure message: ' + e.getMessage());
            Assert.isFalse(e.getMessage().contains('Simulated'),
                'Platform/exception detail must NEVER be concatenated into a user-facing message '
                + '(ARCHITECTURE.md §5): ' + e.getMessage());
        }
        Test.stopTest();

        SellMeterOverridePermissionService.clearCache();
        Assert.isTrue(threw, 'hasOverrideAccess must map a fault to AuraHandledException');
    }
}
