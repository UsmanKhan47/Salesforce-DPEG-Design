/**
 * @description Tests DispositionService — the find-or-create Disposition write workflow
 * extracted from DispositionController in P6 controller thinning, plus the server-side
 * sell-meter gate and the On_Market record-type stamp added with Disposition Foundations.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * NO 251-RECORD BULK TEST — .claude/rules/bulk-test-rule.md PER-TRANSACTION-SINGLETON
 * EXEMPTION APPLIES. RECORDED HERE SO REVIEW DOES NOT DEMAND ONE.
 * ─────────────────────────────────────────────────────────────────────────────────────
 * findOrCreate is STRUCTURALLY single-record-per-transaction: it takes one Id, is reached
 * only from DispositionController.findOrCreate (one @AuraEnabled call per Sell Meter
 * button click), has no trigger behind it and contains no loop. There is no second batch
 * chunk for 251 records to force, so a 251-record test would exercise no additional code
 * path while risking unrelated governor limits — precisely the anti-pattern the exemption
 * exists to prevent. The exemption removes the VOLUME mandate only; the no-SOQL/DML-in-
 * loops rule still holds and this service still satisfies it (2 SOQL / 1 DML on the create
 * path, 1 SOQL on the existing path, all straight-line).
 *
 * ⚠ FIXTURE PRECONDITION THE GATE INTRODUCED. TestDataFactory.createPropertyAssets does
 * NOT set Peak_Sell_Date__c, and a null peak bands RED — so an unmodified factory asset is
 * now REFUSED by findOrCreate. Every test here that expects a creation therefore stamps a
 * peak date explicitly. That is deliberate and is not a workaround: the peak date is the
 * gate's only input, so a test about creation has to state it. The factory default was
 * left alone on purpose — adding a peak date there would silently pull every asset in the
 * repo into PropertyAssetSelector's sell-candidate filter and move SellMeterControllerTest's
 * counts.
 *
 * COVERAGE NOTE ON THE RECORD-TYPE STAMP: the assertion is written so it holds whether or
 * not the §4 record-type metadata has been deployed to the org the suite runs against
 * (the stamp is guarded on isAvailable() precisely so an undeployed record type cannot
 * block a disposition). A green run here is therefore NOT proof the record types exist —
 * post-deploy gate B4 is. What it does prove is that when they exist, On_Market is what
 * gets stamped.
 *
 * @see force-app/main/default/classes/DispositionService.cls
 * @see force-app/main/default/classes/SellMeterService.cls (the shared band function)
 * @author Unit Testing Agent
 */
@isTest
private class DispositionServiceTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    /** The @TestSetup asset, re-banded by moving its peak sell date. */
    private static Property_Asset__c assetWithPeak(Integer daysOut) {
        Property_Asset__c asset = [SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c LIMIT 1];
        asset.Peak_Sell_Date__c = (daysOut == null) ? null : Date.today().addDays(daysOut);
        update asset;
        return asset;
    }

    @isTest
    static void findOrCreateCreatesWhenNoneExists() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN

        Test.startTest();
        Id dispId = DispositionService.findOrCreate(asset.Id);
        Test.stopTest();

        Assert.isNotNull(dispId, 'A new Disposition Id should be returned');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        Assert.areEqual(1, count, 'Exactly one Disposition should be created for the asset');
    }

    @isTest
    static void findOrCreateIsIdempotent() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN

        Test.startTest();
        Id first = DispositionService.findOrCreate(asset.Id);
        Id second = DispositionService.findOrCreate(asset.Id);
        Test.stopTest();

        Assert.areEqual(first, second, 'A second call returns the same Disposition, not a duplicate');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        Assert.areEqual(1, count, 'find-or-create must not duplicate the Disposition');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE SELL-METER GATE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The whole reason the gate exists: before this change the RED block lived only in
     * lwc/sellMeterList, so calling the @AuraEnabled method directly created a disposition
     * on an asset the business had said was not ready. It must now refuse.
     */
    @isTest
    static void findOrCreateRefusesARedAsset() {
        Property_Asset__c asset = assetWithPeak(200); // > 90 days => RED

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionService.findOrCreate(asset.Id);
            Assert.fail('A RED asset must not be able to open a disposition');
        } catch (DispositionService.SellMeterGateException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('not ready to sell'),
                'The refusal must carry the user-safe sell-meter wording: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The RED asset should have raised SellMeterGateException');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused creation must leave NO Disposition behind');
    }

    /** A null peak date bands RED too — the asset is not on the meter at all. */
    @isTest
    static void findOrCreateRefusesAnAssetWithNoPeakDate() {
        Property_Asset__c asset = assetWithPeak(null);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionService.findOrCreate(asset.Id);
        } catch (DispositionService.SellMeterGateException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused, 'An asset with no peak sell date bands RED and must be refused');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused creation must leave NO Disposition behind');
    }

    /**
     * 🔴 YELLOW MUST CREATE. The yellow band is exactly what the dashboard's Override
     * button is for (Gate 1 Q2). If this ever goes red, the Override button has become a
     * server-side dead end for the second time — which is one of the two live defects this
     * change was raised to fix.
     */
    @isTest
    static void findOrCreatePermitsAYellowAsset() {
        Property_Asset__c asset = assetWithPeak(60); // 31-90 days => YELLOW

        Test.startTest();
        Id dispId = DispositionService.findOrCreate(asset.Id);
        Test.stopTest();

        Assert.isNotNull(dispId, 'YELLOW is an override, not a refusal - it must create');
        Assert.areEqual(1, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'The override path creates exactly one Disposition');
    }

    /**
     * 🔴 THE GATE IS CREATE-ONLY. An asset's peak sell date drifts with the market, so an
     * already-open disposition would become unreachable the moment its asset re-banded RED.
     * This test builds the disposition while the asset is GREEN, then re-bands the asset to
     * RED and asserts the SAME Id still comes back — the failure mode is "navigation to a
     * live deal breaks", which no user would be able to diagnose.
     */
    @isTest
    static void findOrCreateReturnsAnExistingDispositionEvenWhenTheAssetIsNowRed() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN
        Id created = DispositionService.findOrCreate(asset.Id);

        asset.Peak_Sell_Date__c = Date.today().addDays(365); // the market moved: now RED
        update asset;

        Test.startTest();
        Id reopened = DispositionService.findOrCreate(asset.Id);
        Test.stopTest();

        Assert.areEqual(created, reopened,
            'An existing Disposition must be returned unchanged; the gate governs STARTING, not REOPENING');
        Assert.areEqual(1, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'Reopening must not create a second Disposition');
    }

    /**
     * The create branch reads the asset, so an Id that resolves to no Property_Asset__c
     * throws the selector's native QueryException — NOT SellMeterGateException. The
     * distinction is what lets DispositionController show the generic write-failure message
     * for a platform failure and the sell-meter wording for a designed refusal.
     */
    @isTest
    static void findOrCreateOnAMissingAssetThrowsQueryExceptionNotAGateRefusal() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Id ghostId = asset.Id;
        delete asset;

        Test.startTest();
        Boolean threwQuery = false;
        try {
            DispositionService.findOrCreate(ghostId);
            Assert.fail('A deleted Property Asset should not resolve');
        } catch (DispositionService.SellMeterGateException e) {
            Assert.fail('A missing asset is a platform failure, not a sell-meter refusal');
        } catch (System.QueryException e) {
            threwQuery = true;
        }
        Test.stopTest();

        Assert.isTrue(threwQuery, 'A missing asset surfaces the selector QueryException');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECORD TYPE (Gate 1 Q1 = (a) - stamp On_Market explicitly)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The create branch stamps On_Market rather than inheriting the running user's PROFILE
     * default, which is org state this repo can neither set nor verify.
     *
     * The assertion is conditional on the record type EXISTING and being available, because
     * the stamp itself is guarded that way on purpose (an undeployed record type must not
     * block a disposition). Where it exists, On_Market is asserted exactly; where it does
     * not, the fallback contract is asserted instead — so this method makes a real claim in
     * both orgs rather than quietly passing in one of them.
     */
    @isTest
    static void findOrCreateStampsTheOnMarketRecordType() {
        Property_Asset__c asset = assetWithPeak(10);

        Test.startTest();
        Id dispId = DispositionService.findOrCreate(asset.Id);
        Test.stopTest();

        Disposition__c created = [SELECT Id, RecordTypeId FROM Disposition__c WHERE Id = :dispId];
        Schema.RecordTypeInfo onMarket = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get('On_Market');

        if (onMarket != null && onMarket.isAvailable()) {
            Assert.areEqual(onMarket.getRecordTypeId(), created.RecordTypeId,
                'A Sell-Meter-created disposition must be stamped On_Market, not left to the profile default');
        } else {
            Assert.isNotNull(created.Id,
                'With no available On_Market record type the stamp is skipped and the Disposition is still created');
        }
    }
}
