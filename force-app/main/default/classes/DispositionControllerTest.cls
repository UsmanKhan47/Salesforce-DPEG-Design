/**
 * @description Test class for DispositionController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Adds branch coverage for getClosingSummary's Wires__r subquery (both states),
 * a delete-based negative scenario, and a 251-record data-volume read test
 * (251 Wire__c children under one Disposition — a real scenario, since a
 * Yardi-mirrored Disposition can legitimately accumulate hundreds of wires).
 *
 * P6 controller thinning: findOrCreate's DML now lives in DispositionService, and
 * every @AuraEnabled method wraps its work in a try/catch that maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). The negative test
 * below therefore now expects an AuraHandledException (not the raw QueryException),
 * and readPathsThrowAuraHandledException covers both catch blocks by running the
 * reads under a bare Standard User whose WITH USER_MODE SOQL on the custom
 * Disposition__c object throws.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * DISPOSITION FOUNDATIONS: findOrCreate NOW HAS TWO CATCHES AND THEY SAY DIFFERENT THINGS
 * ─────────────────────────────────────────────────────────────────────────────────────
 * A sell-meter refusal (DispositionService.SellMeterGateException) is a DESIGNED refusal
 * whose message is authored to be shown, so it is rethrown VERBATIM. Everything else is a
 * platform failure and is masked behind the fixed generic write-failure message. The two
 * are pinned by a MATCHED PAIR of tests below — refusalSurfacesTheSellMeterWording and
 * readPathsThrowAuraHandledException — which assert OPPOSITE message contents. Asserting
 * only "an AuraHandledException was thrown" would pass even if the first catch were
 * deleted, which is exactly the bug the catch exists to prevent.
 *
 * ⚠ FIXTURE PRECONDITION: TestDataFactory.createPropertyAssets does not set
 * Peak_Sell_Date__c, and a null peak bands RED, so an unmodified factory asset is now
 * REFUSED. @TestSetup therefore stamps a GREEN peak date; a test that wants a refusal
 * re-bands the asset explicitly. See DispositionServiceTest's header for why the factory
 * default was deliberately left alone.
 * @author Unit Testing Agent
 */
@isTest
private class DispositionControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        // GREEN band (<= 30 days to peak): required before findOrCreate will create.
        asset.Peak_Sell_Date__c = Date.today().addDays(10);
        insert asset;
    }

    // A valid-format but non-existent Id for the given type. The bare-user reads throw on
    // object ACCESS under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL on the custom
    // Disposition__c object (no object access) throws, exercising the controllers'
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
    static void testFindOrCreate_noExistingDisposition_createsOne() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        String dispId = DispositionController.findOrCreate(asset.Id);
        Test.stopTest();

        System.assertNotEquals(null, dispId, 'A new Disposition Id should be returned');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        System.assertEquals(1, count, 'Exactly one Disposition should be created for the asset');
    }

    @isTest
    static void testFindOrCreate_existingDisposition_isIdempotent() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        String dispId1 = DispositionController.findOrCreate(asset.Id);
        String dispId2 = DispositionController.findOrCreate(asset.Id);
        Test.stopTest();

        System.assertEquals(dispId1, dispId2, 'Second call should return the same Disposition Id, not create a duplicate');
        Integer count = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id];
        System.assertEquals(1, count, 'find-or-create must not duplicate the Disposition');
    }

    /**
     * 🔴 THE FIRST CATCH. A red-band refusal must reach the user as the SELL-METER wording,
     * not the generic "This change could not be saved. Refresh the page and try again" —
     * which is advice that can never work, because refreshing will refuse identically
     * forever. This test asserts BOTH halves: the refusal text is present AND the generic
     * text is absent. Deleting DispositionController's SellMeterGateException catch turns
     * this red; asserting only that "an AuraHandledException was thrown" would not.
     */
    @isTest
    static void refusalSurfacesTheSellMeterWording() {
        Property_Asset__c asset = [SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c LIMIT 1];
        asset.Peak_Sell_Date__c = Date.today().addDays(200); // > 90 days => RED
        update asset;

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionController.findOrCreate(asset.Id);
            Assert.fail('A RED asset must be refused at the controller boundary too');
        } catch (AuraHandledException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('not ready to sell'),
                'The user must see the sell-meter refusal, not a generic write failure: ' + e.getMessage());
            Assert.isFalse(e.getMessage().contains('could not be saved'),
                'A designed refusal must NOT be masked behind the generic write-failure message: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The RED asset should have surfaced an AuraHandledException');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused creation must leave no Disposition behind');
    }

    @isTest
    static void testGetClosingSummary_noWires_returnsWireCreatedFalse() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;

        Test.startTest();
        DispositionController.DispositionRow row = DispositionController.getClosingSummary(d.Id);
        Test.stopTest();

        System.assertNotEquals(null, row, 'A row should be returned for a valid Disposition Id');
        System.assertEquals('Closing', row.stage, 'Stage should pass through unchanged');
        System.assertEquals(false, row.wireCreated, 'No Wire__c exists yet, so wireCreated should be false');
    }

    @isTest
    static void testGetClosingSummary_withWire_returnsWireCreatedTrue() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;
        TestDataFactory.createWire(d.Id, true);

        Test.startTest();
        DispositionController.DispositionRow row = DispositionController.getClosingSummary(d.Id);
        Test.stopTest();

        System.assertEquals(true, row.wireCreated, 'A Wire__c child exists, so wireCreated should flip to true');
    }

    @isTest
    static void testGetClosingSummary_invalidId_throwsAuraHandledException() {
        // P6: the selector's raw QueryException is now caught in the controller and
        // re-thrown as a user-safe AuraHandledException at the LWC boundary. A deleted
        // Disposition Id makes the single-row selector SOQL fail under admin — the
        // deterministic way to reach the read-failure catch without a bare user.
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, true);
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        try {
            DispositionController.getClosingSummary(deletedId);
            Assert.fail('Expected an AuraHandledException for a Disposition Id that no longer exists');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'getClosingSummary read failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    // Runs findOrCreate and getClosingSummary under a bare Standard User: WITH USER_MODE
    // on the custom Disposition__c object throws (no object access), exercising both
    // controllers' read-failure catch that maps it to a user-safe AuraHandledException.
    // Kept in its own method: bareUser() inserts a User (setup DML), so mixing it with
    // record DML in one transaction would raise MIXED_DML_OPERATION. The reads throw at
    // the query before any DML, so no record DML runs here.
    @isTest
    static void readPathsThrowAuraHandledException() {
        User u = bareUser();
        Id fakeAssetId = fakeId(Property_Asset__c.SObjectType);
        Id fakeDispId = fakeId(Disposition__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try {
                DispositionController.findOrCreate(fakeAssetId);
                Assert.fail('expected AuraHandledException from findOrCreate under a bare user');
            } catch (AuraHandledException e) {
                // The other half of the matched pair with refusalSurfacesTheSellMeterWording:
                // a PLATFORM failure must be MASKED behind the generic message, and must NOT
                // borrow the sell-meter wording (nothing about the band was even reached here).
                Assert.isTrue(e.getMessage().contains('could not be saved'),
                    'A platform read failure maps to the generic write-failure message: ' + e.getMessage());
                Assert.isFalse(e.getMessage().contains('not ready to sell'),
                    'A platform failure must not be reported as a sell-meter refusal: ' + e.getMessage());
            }
            try {
                DispositionController.getClosingSummary(fakeDispId);
                Assert.fail('expected AuraHandledException from getClosingSummary under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getClosingSummary read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251 Wire__c
     * children under one Disposition, inserted via a single bulk DML statement
     * (TestDataFactory.createWires), to prove the `(SELECT Id FROM Wires__r
     * LIMIT 1)` subquery in getClosingSummary stays correct and cheap at volume.
     */
    @isTest
    static void testGetClosingSummary_251Wires_subqueryStillResolvesCorrectly() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, true);
        TestDataFactory.createWires(251, d.Id, true);

        Test.startTest();
        DispositionController.DispositionRow row = DispositionController.getClosingSummary(d.Id);
        Test.stopTest();

        Integer wireCount = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :d.Id];
        System.assertEquals(251, wireCount, 'All 251 wires should have been inserted');
        System.assertEquals(true, row.wireCreated, 'wireCreated should be true with 251 Wire__c children present');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // initiateAndSubmit — thin wrapper over DispositionService.initiateAndSubmit (DEV-1)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void initiateAndSubmit_positiveScenario_returnsThePopulatedOutcome() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        DispositionService.InitiateOutcome outcome =
            DispositionController.initiateAndSubmit(asset.Id, 'On_Market', null);
        Test.stopTest();

        System.assertNotEquals(null, outcome.dispositionId, 'A Disposition Id must be populated');
        System.assertEquals(true, outcome.submitted, 'A fresh GREEN asset must submit successfully');
        System.assertNotEquals(null, outcome.message, 'The client needs an authored message to toast');
    }

    /**
     * 🔴 THE SAME TWO-CATCH SHAPE AS findOrCreate, PROVED AGAIN ON THE NEW METHOD. A designed
     * refusal (RED band) must surface VERBATIM; deleting the SellMeterGateException catch would
     * mask it behind the generic write-failure message instead.
     */
    @isTest
    static void initiateAndSubmit_redAsset_surfacesTheSellMeterWordingVerbatim() {
        Property_Asset__c asset = [SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c LIMIT 1];
        asset.Peak_Sell_Date__c = Date.today().addDays(200); // RED
        update asset;

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionController.initiateAndSubmit(asset.Id, 'On_Market', null);
            Assert.fail('A RED asset must be refused at the controller boundary too');
        } catch (AuraHandledException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('not ready to sell'),
                'The user must see the sell-meter refusal, not a generic write failure: ' + e.getMessage());
            Assert.isFalse(e.getMessage().contains('could not be saved'),
                'A designed refusal must NOT be masked behind the generic write-failure message: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The RED asset should have surfaced an AuraHandledException');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused creation must leave no Disposition behind');
    }

    /**
     * ⚠ InvalidRecordTypeException DELIBERATELY FALLS INTO THE GENERIC CATCH — it is a caller
     * defect (the modal offers exactly the two allowed values), not something the user can act on.
     */
    @isTest
    static void initiateAndSubmit_invalidRecordType_isMaskedBehindTheGenericMessage() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionController.initiateAndSubmit(asset.Id, 'Not_A_Real_Type', null);
            Assert.fail('An off-allow-list record type must be refused');
        } catch (AuraHandledException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('could not be saved'),
                'A caller defect must be masked behind the generic write-failure message, not the '
                + 'InvalidRecordTypeException detail: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'An invalid record type must still surface an AuraHandledException');
    }

    /**
     * 🔴 A FAILED APPROVAL SUBMISSION IS NOT AN EXCEPTION. It arrives as `submitted = false` with
     * `dispositionId` populated, and the client's contract is to toast a warning and still
     * navigate — this is provoked via the pending-duplicate guard rather than by disabling the
     * approval process, which Apex cannot do.
     */
    @isTest
    static void initiateAndSubmit_pendingDuplicateGuard_returnsSoftOutcomeNotAnException() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c existing = TestDataFactory.createDisposition(asset.Id, false);
        existing.Disposition_Stage__c = 'Disposition Readiness';
        insert existing;
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(existing.Id);
        Approval.process(req); // now genuinely pending

        Test.startTest();
        DispositionService.InitiateOutcome outcome =
            DispositionController.initiateAndSubmit(asset.Id, 'On_Market', null);
        Test.stopTest();

        System.assertEquals(existing.Id, outcome.dispositionId,
            'The existing-record branch must return the SAME Disposition, not throw');
        System.assertEquals(false, outcome.submitted,
            'The existing-record branch never submits — this is not a failure, it is idempotency');
    }

    // A bare Standard User with no DPEG perm sets, to exercise the generic-failure catch on a
    // genuine platform error (the create branch's PropertyAssetSelector read throws under
    // WITH USER_MODE with no object access).
    @isTest
    static void initiateAndSubmit_bareUser_surfacesTheGenericWriteFailureMessage() {
        User u = bareUser();
        Property_Asset__c asset = [SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c LIMIT 1];
        asset.Peak_Sell_Date__c = Date.today().addDays(10);
        update asset;

        System.runAs(u) {
            Test.startTest();
            try {
                DispositionController.initiateAndSubmit(asset.Id, 'On_Market', null);
                Assert.fail('expected AuraHandledException from initiateAndSubmit under a bare user');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('could not be saved'),
                    'A platform failure must map to the generic write-failure message: ' + e.getMessage());
            }
            Test.stopTest();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE THIRD CATCH — SellMeterOverridePermissionService.AccessDeniedException
    // (2026-08-31, Tranche 2 item 5a, stories 12 and 14)
    //
    // 🔴 A SECOND DESIGNED REFUSAL, NOT A SECOND PLATFORM MASK. The two tests below are the
    // MATCHED PAIR for this catch, in the same shape as refusalSurfacesTheSellMeterWording vs
    // readPathsThrowAuraHandledException above: they assert OPPOSITE message contents. Asserting
    // only "an AuraHandledException was thrown" would pass with the catch DELETED, because the
    // generic catch beneath it also throws one — and the user would be told their save failed and
    // would retry forever against a permanent, correct refusal.
    //
    // ⚠ THIS CATCH IS ONLY REACHABLE AS A REAL NON-PRINCIPAL PERSONA. The test-running
    // administrator holds "Modify All Data" and is bypassed by the gate before the custom
    // permission is consulted, so the same code run as the running user takes the SUCCESS path.
    // A denial test that skipped System.runAs would be green, would cover the wrong lines, and
    // would read exactly like a denial test.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void initiateAndSubmit_overrideDenial_surfacesTheAuthoredWordingVerbatim() {
        Property_Asset__c asset = [SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c LIMIT 1];
        asset.Peak_Sell_Date__c = Date.today().addDays(60); // 31-90 days => YELLOW
        update asset;                                        // record DML BEFORE the User insert

        User analyst = provisionAnalystPersona('dctlA');

        Test.startTest();
        Boolean refused = false;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(analyst) {
            try {
                DispositionController.initiateAndSubmit(asset.Id, 'On_Market', 'let me through');
                Assert.fail('A non-principal must be refused the YELLOW override at the controller '
                    + 'boundary too');
            } catch (AuraHandledException e) {
                refused = true;
                Assert.isTrue(e.getMessage().contains('principal'),
                    'The AUTHORED denial must reach the user verbatim — it names WHO can perform '
                    + 'the action, which is the only useful thing to say about a button the user '
                    + 'can SEE (the Sell Meter renders Override disabled, not hidden): '
                    + e.getMessage());
                Assert.isFalse(e.getMessage().contains('could not be saved'),
                    '🔴 DELETING THE AccessDeniedException CATCH TURNS THIS RED. Without it the '
                    + 'refusal falls into the generic catch and the user is told their save failed '
                    + '— advice that can never work against a permanent, correct refusal, and '
                    + 'exactly the defect the SellMeterGateException catch exists to prevent on '
                    + 'this same button: ' + e.getMessage());
                Assert.isFalse(e.getMessage().contains('not ready to sell'),
                    'An override denial is not a RED-band refusal and must not borrow its wording: '
                    + e.getMessage());
            }
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The analyst persona must have been refused');
        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset.Id],
            'A refused override must leave no Disposition behind');
    }

    /**
     * The same catch on `findOrCreate` — the second live @AuraEnabled create path, still exposed,
     * still creating on YELLOW with no modal and no confirmation. Gating only the modal path would
     * leave the whole restriction one call away from being defeated.
     */
    @isTest
    static void findOrCreate_overrideDenial_surfacesTheAuthoredWordingVerbatim() {
        Property_Asset__c asset = [SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c LIMIT 1];
        asset.Peak_Sell_Date__c = Date.today().addDays(60); // YELLOW
        update asset;

        User analyst = provisionAnalystPersona('dctlB');

        Test.startTest();
        Boolean refused = false;
        SellMeterOverridePermissionService.clearCache();
        System.runAs(analyst) {
            try {
                DispositionController.findOrCreate(asset.Id);
                Assert.fail('findOrCreate must refuse a non-principal on YELLOW too');
            } catch (AuraHandledException e) {
                refused = true;
                Assert.isTrue(e.getMessage().contains('principal'),
                    'The authored denial must reach the user verbatim here too: ' + e.getMessage());
                Assert.isFalse(e.getMessage().contains('could not be saved'),
                    'Deleting findOrCreate\'s AccessDeniedException catch turns this red: '
                    + e.getMessage());
            }
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The analyst persona must have been refused on this path too');
    }

    /**
     * 🔴 THE OVER-REACH CONTROL, AT THE CONTROLLER BOUNDARY. Without it, both tests above pass
     * against an assert that was hoisted out of the YELLOW branch and applied to the whole method —
     * which would close GREEN Initiate to every junior analyst, a capability removal nobody asked
     * for and one that no other test in this class would notice (they all run as the bypassed
     * administrator).
     *
     * `simulateLookupFailure` makes the permission service throw the instant it is called,
     * regardless of who is running or what they hold, so it probes "was the gate reached?" and
     * nothing else. On GREEN it must never be reached, so the create must succeed untouched.
     */
    @isTest
    static void initiateAndSubmit_greenAsset_isUnaffectedByTheOverrideGate() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1]; // @TestSetup = GREEN

        Test.startTest();
        SellMeterOverridePermissionService.clearCache();
        SellMeterOverridePermissionService.simulateLookupFailure = true;
        DispositionService.InitiateOutcome outcome;
        try {
            outcome = DispositionController.initiateAndSubmit(asset.Id, 'On_Market', null);
        } catch (AuraHandledException e) {
            Assert.fail('🔴 THE OVERRIDE GATE WAS CONSULTED ON A GREEN ASSET. The assert has been '
                + 'un-scoped from the YELLOW branch, closing Initiate to every junior analyst. '
                + 'Underlying: ' + e.getMessage());
        }
        SellMeterOverridePermissionService.clearCache();
        Test.stopTest();

        Assert.isNotNull(outcome, 'GREEN Initiate stays open to analysts (Gate 1, 2026-08-31)');
        Assert.isNotNull(outcome.dispositionId, 'and it still creates the Disposition');
    }

    /**
     * Builds a disposition ANALYST persona: can read the asset and create Dispositions, holds
     * `Disposition_Deal_Actions`, does NOT hold `Disposition_Sell_Meter_Override`.
     *
     * ⚠ `DPEG_PropertyMgmt_View` IS NOT OPTIONAL. Neither disposition permission set grants FLS on
     * `Property_Asset__c.Peak_Sell_Date__c`, and `PropertyAssetSelector.selectPeakSellDateById` is
     * `WITH USER_MODE`, which THROWS on an inaccessible field rather than degrading — so without it
     * the persona dies at the selector, BEFORE the gate, and every test above would still "pass"
     * if its only assertion were that something was thrown. That is why those tests assert the
     * message contents rather than the exception type alone.
     *
     * ⚠ Setup DML (User + assignments) is wrapped in `System.runAs(current user)` so it can share a
     * transaction with the record DML the caller does first. Without the wrapper:
     * MIXED_DML_OPERATION.
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
            List<String> names = new List<String>{ 'DPEG_Disposition_Edit', 'DPEG_PropertyMgmt_View' };
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :names]) {
                rows.add(new PermissionSetAssignment(AssigneeId = analyst.Id, PermissionSetId = ps.Id));
            }
            Assert.areEqual(names.size(), rows.size(),
                'FIXTURE PRECONDITION: every named permission set must exist in this org. A set '
                + 'resolved BY NAME that has been renamed or deleted silently produces a persona '
                + 'with fewer grants, turning a denial test into a selector failure. Expected '
                + String.valueOf(names) + ', found ' + rows.size() + '.');
            insert rows;
        }
        return analyst;
    }
}
