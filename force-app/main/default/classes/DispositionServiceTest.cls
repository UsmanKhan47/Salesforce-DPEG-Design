/**
 * @description Tests DispositionService — the find-or-create Disposition write workflow
 * extracted from DispositionController in P6 controller thinning, plus the server-side
 * sell-meter gate and the On_Market record-type stamp added with Disposition Foundations.
 *
 * ⚠ THERE IS DELIBERATELY NO EXPECTED-VALUE STAMP TEST HERE, AND ITS ABSENCE IS A DECISION.
 * For a few hours on 2026-08-25 both create paths copied the asset's `Target_Sale_Price__c` onto
 * the new Disposition's `Asking_Price__c` ("Expected Value"), and
 * `initiateAndSubmit_stampsExpectedValueFromTheAssetTargetSalePrice` proved it. The user then
 * retired `Asking_Price__c` from the disposition flow entirely — `BOV_Score__c` and the
 * Disposition-Readiness submission gate both read `Property_Asset__r.Target_Sale_Price__c`
 * directly now — so the stamp was removed and that test with it. 🔴 The field still EXISTS and a
 * stamp would still COMPILE; do not re-add either. A copy on the Disposition would be a second,
 * silently-diverging source of truth for a number nothing reads from there.
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
 * ─────────────────────────────────────────────────────────────────────────────────────
 * ⚠ EVERY `initiateAndSubmit` CALL BELOW GAINED A THIRD ARGUMENT ON 2026-08-31 (item 5b), AND
 * THE PRE-EXISTING ONES ALL PASS `null` ON PURPOSE.
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The parameter is `overrideReason` and it is recorded ONLY on the YELLOW branch, so `null` is the
 * correct and expected value for every GREEN and every refusal test. It is not a placeholder
 * waiting to be filled in. The tests that exercise it live in the YELLOW-BAND PRINCIPAL GATE
 * section at the bottom of this class.
 *
 * ⚠ AND A CAVEAT THAT APPLIES TO EVERY YELLOW TEST IN THIS FILE, OLD AND NEW: the test-running
 * user is a System Administrator and holds "Modify All Data", which BYPASSES the new override
 * gate before its custom permission is even consulted. A YELLOW test that passes here says nothing
 * about whether the gate exists. That is why the bottom section uses the
 * `SellMeterOverridePermissionService.simulateLookupFailure` seam (a permission-independent probe
 * for "was the gate reached?") and a real `System.runAs` analyst persona, rather than more
 * administrator-run happy paths.
 *
 * @see force-app/main/default/classes/DispositionService.cls
 * @see force-app/main/default/classes/SellMeterService.cls (the shared band function)
 * @see force-app/main/default/classes/SellMeterOverridePermissionService.cls (the YELLOW gate)
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
     *
     * ⚠ QUALIFIED 2026-08-31 (item 5a) AND STILL TRUE, BUT NOT FOR THE REASON IT LOOKS LIKE.
     * YELLOW now additionally requires `Disposition_Sell_Meter_Override`. This method still passes
     * because it runs as the TEST-RUNNING ADMINISTRATOR, who holds "Modify All Data" and is
     * bypassed — NOT because the gate is absent. So this test says nothing whatever about the
     * gate, in either direction, and must not be read as proof that YELLOW is open. The gate's
     * denial behaviour is proved by `findOrCreate_yellowAsset_deniedForAnAnalystPersona` below,
     * and its band SCOPING by the `simulateLookupFailure` pair further down.
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

    // ═══════════════════════════════════════════════════════════════════════════
    // initiateAndSubmit — the Sell Meter "Initiate" modal path (2026-08-19, DEV-1)
    //
    // NO 251-RECORD BULK TEST — same .claude/rules/bulk-test-rule.md per-transaction-singleton
    // exemption as findOrCreate above, recorded in this method's own header: no trigger, no loop,
    // one invocation per modal click.
    // ═══════════════════════════════════════════════════════════════════════════

    private static Integer pendingApprovalsFor(Id targetId) {
        return [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :targetId AND Status = 'Pending'];
    }

    @isTest
    static void initiateAndSubmit_onMarket_createsAndSubmitsIntoSaleDecisionApproval() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN

        Test.startTest();
        DispositionService.InitiateOutcome outcome =
            DispositionService.initiateAndSubmit(asset.Id, 'On_Market', null);
        Test.stopTest();

        Assert.isNotNull(outcome.dispositionId, 'A Disposition Id must always be populated');
        Assert.isTrue(outcome.submitted, 'The submission must succeed against a fresh GREEN asset');
        Disposition__c created = [
            SELECT Disposition_Stage__c, RecordTypeId FROM Disposition__c WHERE Id = :outcome.dispositionId
        ];
        Assert.areEqual('Disposition Readiness', created.Disposition_Stage__c,
            'The disposition must be created at Readiness');
        Schema.RecordTypeInfo onMarket = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName().get('On_Market');
        if (onMarket != null && onMarket.isAvailable()) {
            Assert.areEqual(onMarket.getRecordTypeId(), created.RecordTypeId,
                'The CHOSEN record type must be stamped — On_Market here');
        }
        Assert.areEqual(1, pendingApprovalsFor(outcome.dispositionId),
            'A real ProcessInstance must be pending against Sale_Decision_Approval');
    }

    @isTest
    static void initiateAndSubmit_offMarket_stampsTheChosenRecordType() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN

        Test.startTest();
        DispositionService.InitiateOutcome outcome =
            DispositionService.initiateAndSubmit(asset.Id, 'Off_Market', null);
        Test.stopTest();

        Assert.isTrue(outcome.submitted, 'Off-market must submit into Sale_Decision_Approval too');
        Schema.RecordTypeInfo offMarket = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName().get('Off_Market');
        Disposition__c created = [SELECT RecordTypeId FROM Disposition__c WHERE Id = :outcome.dispositionId];
        if (offMarket != null && offMarket.isAvailable()) {
            Assert.areEqual(offMarket.getRecordTypeId(), created.RecordTypeId,
                'initiateAndSubmit must stamp the CALLER-CHOSEN type, not the On_Market default '
                + 'findOrCreate always uses — the whole reason this method takes a parameter');
        }
    }

    @isTest
    static void initiateAndSubmit_invalidRecordTypeName_throwsBeforeAnyQuery() {
        Property_Asset__c asset = assetWithPeak(10);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionService.initiateAndSubmit(asset.Id, 'Retail_Strip_Center', null);
            Assert.fail('An off-allow-list record type name must be refused');
        } catch (DispositionService.InvalidRecordTypeException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('On Market or Off Market'), e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A caller-defect record type name must throw InvalidRecordTypeException');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A rejected record type must create nothing');
    }

    @isTest
    static void initiateAndSubmit_blankRecordTypeName_throwsInvalidRecordType() {
        Property_Asset__c asset = assetWithPeak(10);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionService.initiateAndSubmit(asset.Id, '', null);
        } catch (DispositionService.InvalidRecordTypeException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A blank record type name must be refused, same as an unrecognised one');
    }

    /**
     * 🔴 CASE-SENSITIVE BY DESIGN. 'on_market' is off the allow-list even though it reads
     * identically to a human — Apex Set<String> membership is case-sensitive and so is
     * getRecordTypeInfosByDeveloperName()'s own map, and the two must agree.
     */
    @isTest
    static void initiateAndSubmit_wrongCaseRecordTypeName_isRefused() {
        Property_Asset__c asset = assetWithPeak(10);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionService.initiateAndSubmit(asset.Id, 'on_market', null);
        } catch (DispositionService.InvalidRecordTypeException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A mis-cased record type name must be refused, not silently resolved');
    }

    @isTest
    static void initiateAndSubmit_redBandAsset_refusesAndCreatesNothing() {
        Property_Asset__c asset = assetWithPeak(200); // > 90 days => RED

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionService.initiateAndSubmit(asset.Id, 'On_Market', null);
            Assert.fail('A RED asset must not be able to initiate a disposition');
        } catch (DispositionService.SellMeterGateException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('not ready to sell'), e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The RED asset should have raised SellMeterGateException');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused creation must leave NO Disposition behind — the gate applies to this create '
            + 'branch exactly as it does to findOrCreate\'s');
    }

    /**
     * 🔴 THE IDEMPOTENT-FIND BRANCH: NO RECORD-TYPE CHANGE, NO RE-SUBMIT. Re-clicking Initiate on
     * an asset that already has a Disposition must return the SAME Id, unsubmitted, without
     * touching the existing record's type or stage.
     */
    @isTest
    static void initiateAndSubmit_existingDisposition_doesNotResubmitOrChangeRecordType() {
        Property_Asset__c asset = assetWithPeak(10);
        DispositionService.InitiateOutcome first =
            DispositionService.initiateAndSubmit(asset.Id, 'Off_Market', null);
        Assert.areEqual(1, pendingApprovalsFor(first.dispositionId),
            'PRECONDITION: the first click must have submitted a pending approval, or the "must '
            + 'not resubmit" assertion below proves nothing (a second submit would simply also '
            + 'succeed on a never-submitted record)');

        Test.startTest();
        DispositionService.InitiateOutcome second =
            DispositionService.initiateAndSubmit(asset.Id, 'On_Market', null);
        Test.stopTest();

        Assert.areEqual(first.dispositionId, second.dispositionId,
            'A second Initiate click must return the SAME Disposition, never a duplicate');
        Assert.isFalse(second.submitted,
            'The existing-record branch never submits — re-submitting an already-advanced record '
            + 'would either duplicate an approval or fail against a pending one');
        Assert.areEqual(1, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'Still exactly one Disposition for the asset');
        Assert.areEqual(1, pendingApprovalsFor(first.dispositionId),
            'Still exactly ONE pending approval — the second click must not have created a second');
        Schema.RecordTypeInfo offMarket = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName().get('Off_Market');
        if (offMarket != null && offMarket.isAvailable()) {
            Assert.areEqual(offMarket.getRecordTypeId(),
                [SELECT RecordTypeId FROM Disposition__c WHERE Id = :first.dispositionId].RecordTypeId,
                '🔴 THE RECORD TYPE MUST NOT CHANGE — re-stamping On_Market on the second click '
                + 'would silently convert a live off-market sale mid-path');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE YELLOW-BAND PRINCIPAL GATE + THE OVERRIDE AUDIT STAMP
    // (2026-08-31, Tranche 2 items 5a and 5b, stories 12 and 14)
    //
    // 🔴 READ THIS BEFORE ADDING A TEST HERE. The test-running user is a System Administrator and
    // holds "Modify All Data", which BYPASSES the gate before the custom permission is even
    // consulted. Every test in this section that is about DENIAL therefore runs inside
    // System.runAs against a purpose-built persona; a test that "proves" the gate as the running
    // user proves only that the bypass works.
    //
    // 🔴 AND THE HAZARD THIS SECTION EXISTS TO CATCH IS NOT DENIAL — IT IS OVER-REACH. The design
    // hazard for item 5a is an assert that is not band-scoped: a method-wide
    // `assertSellMeterOverrideAccess()` at the top of either create path closes GREEN Initiate to
    // every junior analyst, which no story asks for and which DispositionService's header refuses
    // in terms. NOT ONE OF THE PRE-EXISTING TESTS IN THIS CLASS WOULD GO RED UNDER THAT MUTATION,
    // because they all run as the bypassed administrator. The `simulateLookupFailure` pair below
    // is the only thing in this repo that would.
    //
    // NO 251-RECORD BULK TEST — same .claude/rules/bulk-test-rule.md per-transaction-singleton
    // exemption as the rest of this class, plus the gate's own: it is a question about ONE user
    // with no record collection and no loop.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE BAND-SCOPING FALSIFIER, GREEN HALF. Read it together with the YELLOW half below —
     * neither means anything alone.
     *
     * `simulateLookupFailure` makes `SellMeterOverridePermissionService` THROW the moment it is
     * called, whoever the running user is and whatever they hold. So it is a probe for
     * "was the gate reached?" that is completely independent of permissions, of Modify All Data,
     * and of whether the custom permission has been deployed to this org yet.
     *
     * On a GREEN asset the gate must NOT be reached, so the armed seam must be invisible and the
     * create must succeed exactly as it does today. If someone un-scopes the assert — hoists it to
     * the top of the method, or drops the `if (isOverride)` — this test goes red with a
     * QueryException, which is the loudest available signal for a change whose real-world symptom
     * is "every junior analyst silently lost the Initiate button".
     */
    @isTest
    static void initiateAndSubmit_greenAsset_neverConsultsTheOverrideGate() {
        Property_Asset__c asset = assetWithPeak(10); // <= 30 days => GREEN

        Test.startTest();
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;
        DispositionService.InitiateOutcome outcome;
        try {
            outcome = DispositionService.initiateAndSubmit(asset.Id, 'On_Market', null);
        } catch (QueryException e) {
            Assert.fail('🔴 THE OVERRIDE GATE WAS CONSULTED ON A GREEN ASSET. The assert has been '
                + 'un-scoped from the YELLOW branch, which closes Initiate to every junior analyst '
                + 'holding no principal permission. See DispositionService\'s YELLOW-BAND PRINCIPAL '
                + 'GATE section. Underlying: ' + e.getMessage());
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isNotNull(outcome, 'A GREEN create must complete with the gate seam armed');
        Assert.isNotNull(outcome.dispositionId,
            'GREEN is unchanged by item 5a: the analyst still initiates without a principal');
    }

    /**
     * 🔴 THE BAND-SCOPING FALSIFIER, YELLOW HALF — the presence control for the absence pin above.
     *
     * Without this, the GREEN test passes just as happily against an implementation that DELETED
     * the assert entirely, which is the exact "green and vacuous" shape this repo has been bitten
     * by before. Here the armed seam MUST surface, proving the gate really is on the YELLOW branch
     * rather than nowhere.
     *
     * ⚠ It asserts a QueryException, NOT an AccessDeniedException, and that is the point: the seam
     * simulates the permission MACHINERY faulting, which must propagate as a fault. Denial
     * semantics are a different question, proved by the persona tests below.
     */
    @isTest
    static void initiateAndSubmit_yellowAsset_doesConsultTheOverrideGate() {
        Property_Asset__c asset = assetWithPeak(60); // 31-90 days => YELLOW

        Test.startTest();
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;
        Boolean reached = false;
        try {
            DispositionService.initiateAndSubmit(asset.Id, 'On_Market', 'Fund matures in Q3.');
            Assert.fail('🔴 THE OVERRIDE GATE WAS NOT CONSULTED ON A YELLOW ASSET. The assert is '
                + 'missing from initiateAndSubmit, and every test above still passes because they '
                + 'run as a bypassed administrator.');
        } catch (QueryException e) {
            reached = true;
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(reached, 'The YELLOW branch must consult the override gate');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'The gate sits AHEAD of the insert, so a fault there must leave no Disposition behind');
    }

    /** The same pair, on the second live create path. `findOrCreate` is the GREEN half. */
    @isTest
    static void findOrCreate_greenAsset_neverConsultsTheOverrideGate() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN

        Test.startTest();
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;
        Id dispId;
        try {
            dispId = DispositionService.findOrCreate(asset.Id);
        } catch (QueryException e) {
            Assert.fail('🔴 THE OVERRIDE GATE WAS CONSULTED ON A GREEN ASSET in findOrCreate. '
                + 'Underlying: ' + e.getMessage());
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isNotNull(dispId, 'GREEN find-or-create is unchanged by item 5a');
    }

    /**
     * 🔴 `findOrCreate` IS THE SECOND LIVE @AuraEnabled CREATE PATH AND IT IS NOT DEAD. It is still
     * exposed through `DispositionController.findOrCreate`, still creates on YELLOW with no modal
     * and no confirmation, and its class header records that it "has other callers". Gating only
     * `initiateAndSubmit` would leave the whole feature bypassable by one call — which is why
     * DispositionService's own header instructed that an assert here be added on BOTH create paths
     * at once, not on one. This is the test that fails if someone removes it from this one.
     */
    @isTest
    static void findOrCreate_yellowAsset_doesConsultTheOverrideGate() {
        Property_Asset__c asset = assetWithPeak(60); // YELLOW

        Test.startTest();
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;
        Boolean reached = false;
        try {
            DispositionService.findOrCreate(asset.Id);
            Assert.fail('🔴 findOrCreate IS A SECOND LIVE YELLOW-CREATION BYPASS and its gate is '
                + 'missing. The Override restriction can be defeated by calling this method.');
        } catch (QueryException e) {
            reached = true;
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(reached, 'findOrCreate\'s YELLOW branch must consult the override gate too');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A gate fault must leave no Disposition behind');
    }

    /**
     * 🔴 THE GATE ALSO STAYS ON THE CREATE BRANCH ONLY. An asset's peak sell date drifts with the
     * market, so an existing disposition on an asset that has since re-banded YELLOW must still be
     * reachable — by ANYONE, principal or not. Re-banding a live deal into "you need a principal to
     * open this" is the same navigation-breaks failure the RED gate is create-only to avoid, and it
     * would be unattributable from the UI.
     *
     * The armed seam is the probe again: the existing-record early return sits ahead of both the
     * asset read and the gate, so nothing must fire.
     */
    @isTest
    static void anExistingDispositionOnANowYellowAssetSkipsTheGateEntirely() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN
        Id created = DispositionService.findOrCreate(asset.Id);

        asset.Peak_Sell_Date__c = Date.today().addDays(60); // the market moved: now YELLOW
        update asset;

        Test.startTest();
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;
        Id reopened;
        DispositionService.InitiateOutcome outcome;
        try {
            reopened = DispositionService.findOrCreate(asset.Id);
            outcome = DispositionService.initiateAndSubmit(asset.Id, 'On_Market', null);
        } catch (QueryException e) {
            Assert.fail('The override gate must NOT be consulted when a Disposition already '
                + 'exists — the meter governs STARTING a sale, never reopening one. Underlying: '
                + e.getMessage());
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.areEqual(created, reopened, 'The existing Disposition must come back unchanged');
        Assert.areEqual(created, outcome.dispositionId,
            'Both create paths must return the existing record without consulting the gate');
    }

    // ── THE AUDIT STAMP (item 5b) ────────────────────────────────────────────

    /**
     * 🔴 THIS FIXES A LIVE DEFECT, AND THE FIRST ASSERTION IS THE ONE THAT MATTERS.
     * `Sell_Decision_Trigger__c` is a restricted picklist that already existed, already appeared on
     * `Sale_Decision_Approval`'s approval screen, and defaulted to `Sell Meter Green` with NO
     * WRITER ANYWHERE IN THE REPO — so before this change every override reached the approving
     * principal labelled "Sell Meter Green", which is false about the exact case the field exists
     * to distinguish.
     *
     * ⚠ `Principal Decision` is a RESTRICTED picklist value and restricted picklists ARE enforced
     * by DML in this org. If the value is ever renamed, or removed from either record type, this
     * test fails with a FIELD_INTEGRITY_EXCEPTION rather than an assertion — which is the correct
     * and loudest signal, because the production symptom would be a save the user cannot diagnose.
     *
     * ⚠ RE-QUERIED, NOT READ OFF THE IN-MEMORY sObject. The outcome carries only an Id, and this
     * repo has been bitten by asserting on a stale in-memory record.
     */
    @isTest
    static void initiateAndSubmit_yellowAsset_stampsPrincipalDecisionAndTheReason() {
        Property_Asset__c asset = assetWithPeak(60); // YELLOW
        String reason = 'Fund matures in Q3 and the buyer pool is unusually deep right now.';

        Test.startTest();
        DispositionService.InitiateOutcome outcome =
            DispositionService.initiateAndSubmit(asset.Id, 'On_Market', reason);
        Test.stopTest();

        Assert.isNotNull(outcome.dispositionId,
            'PRECONDITION: the administrator running this test is bypassed by Modify All Data, so '
            + 'the YELLOW create must succeed. If this is null the gate denied the admin and every '
            + 'assertion below is unreachable rather than false.');
        Disposition__c created = [
            SELECT Sell_Decision_Trigger__c, Sell_Meter_Override_Reason__c
            FROM Disposition__c WHERE Id = :outcome.dispositionId
        ];
        Assert.areEqual('Principal Decision', created.Sell_Decision_Trigger__c,
            '🔴 An override MUST NOT reach the approver labelled "Sell Meter Green". That field '
            + 'is on Sale_Decision_Approval\'s approval screen and had no writer at all before '
            + '2026-08-31, so the approving principal was being told the meter was green on every '
            + 'single override.');
        Assert.areEqual(reason, created.Sell_Meter_Override_Reason__c,
            'The principal\'s typed reason must be persisted verbatim, in the SAME DML as the '
            + 'insert — Sale_Decision_Approval sets recordEditability = AdminOnly and locks the '
            + 'record on the very next line, so a later stamp cannot succeed.');
    }

    /**
     * The other half of the pair: a GREEN initiate must stamp NEITHER field.
     *
     * Without this, an unconditional stamp — the obvious "simplification" of dropping the
     * `if (isOverride)` — would pass the test above and silently label every ordinary at-peak
     * initiate as a principal override on the approval screen. That is the same class of false
     * label this item exists to remove, pointed the other way.
     *
     * ⚠ `Sell_Decision_Trigger__c` is asserted as `Sell Meter Green`, not as null: the field
     * carries `<default>true</default>` on that value, so the platform populates it. Asserting
     * null would fail for a reason that has nothing to do with this code.
     */
    @isTest
    static void initiateAndSubmit_greenAsset_stampsNeitherOverrideField() {
        Property_Asset__c asset = assetWithPeak(10); // GREEN

        Test.startTest();
        DispositionService.InitiateOutcome outcome =
            DispositionService.initiateAndSubmit(asset.Id, 'On_Market', 'a reason nobody asked for');
        Test.stopTest();

        Disposition__c created = [
            SELECT Sell_Decision_Trigger__c, Sell_Meter_Override_Reason__c
            FROM Disposition__c WHERE Id = :outcome.dispositionId
        ];
        Assert.areEqual('Sell Meter Green', created.Sell_Decision_Trigger__c,
            'A GREEN initiate must leave the field on its "Sell Meter Green" default — which is '
            + 'TRUE for it. Stamping "Principal Decision" unconditionally would label every '
            + 'ordinary initiate as an override on the approval screen.');
        Assert.isNull(created.Sell_Meter_Override_Reason__c,
            '🔴 A REASON SUPPLIED ON A GREEN CALL IS DISCARDED ON PURPOSE. The client never sends '
            + 'one, and honouring it would let an audit field that means "a principal overrode the '
            + 'meter" be populated on a create where nobody did.');
    }

    // ── REAL PERSONA DENIALS ─────────────────────────────────────────────────

    /**
     * 🔴 THE REAL-PERSONA DENIAL, `initiateAndSubmit`. The seam pair above proves the gate is
     * REACHED on YELLOW and not on GREEN; it says nothing about who passes it. This says a real
     * disposition ANALYST — the persona that could start a YELLOW disposition yesterday — cannot
     * today.
     *
     * ⚠ FIXTURE SHAPE, AND EVERY PIECE OF IT IS LOAD-BEARING:
     *   - `DPEG_Disposition_Edit` is the analyst persona set. It grants Disposition__c create and
     *     `Disposition_Deal_Actions`, and it does NOT grant `Disposition_Sell_Meter_Override` —
     *     the two tokens are deliberate mirror images.
     *   - `DPEG_PropertyMgmt_View` is required and is NOT optional garnish: neither disposition set
     *     grants FLS on `Property_Asset__c.Peak_Sell_Date__c`, and `selectPeakSellDateById` is
     *     `WITH USER_MODE`, which THROWS on a missing field rather than degrading. Without it this
     *     test would die at the selector with a QueryException before ever reaching the gate — and
     *     would read exactly like a passing denial test if the assertion were only "it threw".
     *     That is why the QueryException catch below FAILS the test and names the fixture.
     *   - The record DML happens BEFORE the User insert, and the User + assignment inserts are
     *     wrapped in `System.runAs(current user)`, or the transaction raises MIXED_DML_OPERATION.
     */
    @isTest
    static void initiateAndSubmit_yellowAsset_deniedForAnAnalystPersona() {
        Property_Asset__c asset = assetWithPeak(60); // YELLOW — record DML FIRST

        User analyst = provisionAnalystPersona('dsvcA');

        Test.startTest();
        Boolean refused = false;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(analyst) {
            try {
                DispositionService.initiateAndSubmit(asset.Id, 'On_Market', 'let me through');
                Assert.fail('🔴 A JUNIOR ANALYST MUST NOT BE ABLE TO OVERRIDE THE SELL METER. '
                    + 'Stories 12/14 removed this capability from the analyst persona deliberately '
                    + '(confirmed at Gate 1, 2026-08-31).');
            } catch (SellMeterOverridePermissionService.AccessDeniedException e) {
                refused = true;
                Assert.isTrue(e.getMessage().contains('principal'),
                    'The refusal must name who CAN do it: ' + e.getMessage());
            } catch (System.QueryException e) {
                Assert.fail('FIXTURE FAULT, NOT A PRODUCT FAILURE. The analyst persona could not '
                    + 'complete one of the two selector reads that precede the gate, so this test '
                    + 'never reached the thing it exists to prove. Check that '
                    + 'DPEG_Disposition_Edit and DPEG_PropertyMgmt_View both exist and are '
                    + 'assignable in this org. Underlying: ' + e.getMessage());
            }
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The analyst must be refused the YELLOW create');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused override must leave NO Disposition behind — the gate sits ahead of the '
            + 'insert, so there is nothing to roll back and nothing to clean up');
    }

    /** The same denial on the second live create path. See the method above for the fixture notes. */
    @isTest
    static void findOrCreate_yellowAsset_deniedForAnAnalystPersona() {
        Property_Asset__c asset = assetWithPeak(60); // YELLOW — record DML FIRST

        User analyst = provisionAnalystPersona('dsvcB');

        Test.startTest();
        Boolean refused = false;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(analyst) {
            try {
                DispositionService.findOrCreate(asset.Id);
                Assert.fail('🔴 findOrCreate IS A SECOND LIVE BYPASS. An analyst refused through '
                    + 'initiateAndSubmit must be refused here too, or the restriction is one '
                    + '@AuraEnabled call away from being defeated.');
            } catch (SellMeterOverridePermissionService.AccessDeniedException e) {
                refused = true;
            } catch (System.QueryException e) {
                Assert.fail('FIXTURE FAULT, NOT A PRODUCT FAILURE — see '
                    + 'initiateAndSubmit_yellowAsset_deniedForAnAnalystPersona. Underlying: '
                    + e.getMessage());
            }
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The analyst must be refused the YELLOW create on this path too');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused override must leave NO Disposition behind');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // helpers for the gate tests
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Builds a disposition ANALYST: can read the asset and create Dispositions, holds
     * `Disposition_Deal_Actions`, does NOT hold `Disposition_Sell_Meter_Override`.
     *
     * ⚠ The User insert and both PermissionSetAssignment inserts are SETUP DML and are wrapped in
     * `System.runAs(current user)` so they may share a transaction with the record DML the caller
     * has already done. Without the wrapper this is `MIXED_DML_OPERATION`.
     *
     * ⚠ `Standard User` rather than `Minimum Access - Salesforce` deliberately: the two permission
     * sets supply every custom-object grant this fixture needs, and the profile's standard-object
     * grants are irrelevant to a gate that reads only a custom permission. The repo's
     * Minimum-Access rule exists for denial tests whose SUBJECT is object access; this one's
     * subject is a token.
     */
    private static User provisionAnalystPersona(String tag) {
        User analyst;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            String unique = tag + String.valueOf(Datetime.now().getTime())
                + String.valueOf(Math.abs(Crypto.getRandomInteger()));
            analyst = new User(
                FirstName = 'Junior',
                LastName = 'Analyst',
                Alias = 'jranly',
                Email = 'junior.analyst@example.invalid',
                Username = unique + '@example.invalid.dpeg',
                ProfileId = standard.Id,
                TimeZoneSidKey = 'America/Chicago',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            insert analyst;
            assignPermissionSets(analyst.Id, new List<String>{
                'DPEG_Disposition_Edit',   // Disposition create + Disposition_Deal_Actions
                'DPEG_PropertyMgmt_View'   // Property_Asset__c.Peak_Sell_Date__c FLS (see above)
            });
        }
        return analyst;
    }

    /** Assigns deployed permission sets, by API Name, in one DML. */
    private static void assignPermissionSets(Id assigneeId, List<String> permissionSetNames) {
        List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
            rows.add(new PermissionSetAssignment(AssigneeId = assigneeId, PermissionSetId = ps.Id));
        }
        Assert.areEqual(permissionSetNames.size(), rows.size(),
            'FIXTURE PRECONDITION: every named permission set must exist in this org. A set '
            + 'resolved BY NAME that has been renamed or deleted silently produces a persona with '
            + 'fewer grants than intended, which turns a denial test into a selector failure. '
            + 'Expected ' + String.valueOf(permissionSetNames) + ', found ' + rows.size() + ' of them.');
        insert rows;
    }
}
