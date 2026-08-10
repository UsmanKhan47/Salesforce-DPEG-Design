/**
 * @description Pinning tests for TestDataFactory's record-type stamps — the private helpers
 * dispositionRecordTypeId (behind createDisposition(s) / DISPOSITION_RT_ON_MARKET /
 * DISPOSITION_RT_OFF_MARKET), ndaRecordTypeId since Tranche 3A (behind createNdas /
 * createDispositionNda(s) / NDA_RT_ACQUISITION / NDA_RT_DISPOSITION), loiRecordTypeId since
 * Tranche 3B (behind createLois / createDispositionLoi(s) / LOI_RT_ACQUISITION /
 * LOI_RT_DISPOSITION), and contractReviewRecordTypeId since Tranche 3C (behind
 * createContractReviews / createDispositionContractReview(s) / CONTRACT_REVIEW_RT_ACQUISITION /
 * CONTRACT_REVIEW_RT_DISPOSITION).
 *
 * ⚠ EVERY "stamps the record type" METHOD HERE IS EXPECTED TO BE RED UNTIL POST-DEPLOY GATE
 * T-A1 RUNS, and that is the design (D13 residual 1). Deploying objects/<Object>/recordTypes/
 * is NOT sufficient: a record type assigned to no profile resolves a real Id from the describe
 * and is still unavailable to everyone, System Administrator included — Modify All Data is an
 * OBJECT permission and confers no record-type access. Under that condition every isAvailable()
 * guard in the factory silently no-ops and every fixture lands on the platform default. These
 * tests exist to turn that into a NAMED failure. Do not guard, skip or delete them to obtain a
 * green suite.
 *
 * WHY THIS CLASS EXISTS. There was no TestDataFactoryTest in this repo before it — the
 * record-type stamp was verified by inspection only. code-review-disposition-foundations.md
 * (PASS 2, suggestion S3) and stage-by-stage-decisions.md D13 residual 2 both called that out
 * as a gap. Two separate things now depend on behaviour nothing here could previously falsify:
 *
 *  1. THE S2 FIX. TestDataFactory.cls's dispositionRecordTypeId used a case-INSENSITIVE `!=`
 *     allow-list guard against a case-SENSITIVE describe-map lookup, so a typo like
 *     'on_market' passed the guard, missed the map, and silently degraded to the platform
 *     default record type - the exact silent failure the method's own Javadoc says it
 *     prevents. The fix (constant-first `.equals()`, both case-sensitive) closed the hole,
 *     but nothing would go red if a future edit reintroduced the case-insensitive `!=`.
 *     dispositionRecordTypeId_caseTypoName_throwsAndNamesTheOffendingValue below is that
 *     permanent falsifier.
 *
 *  2. D13 RESIDUAL 1. During Gate-2 check-only validation, isAvailable() was observed
 *     returning FALSE for an assigned System Administrator even though
 *     getRecordTypeInfosByDeveloperName() resolved a REAL Id for On_Market. Both
 *     TestDataFactory.dispositionRecordTypeId and DispositionService.onMarketRecordTypeId
 *     guard their stamp on `info.isAvailable()`, so under that condition the stamp
 *     SILENTLY NO-OPS and every Disposition lands on the running user's profile default
 *     instead of On_Market. createDisposition_defaultOverload_stampsOnMarketRecordType
 *     below asserts the stamp UNCONDITIONALLY (no isAvailable() guard around the
 *     assertion) so that condition turns into a named, loud test failure instead of
 *     staying invisible. See the method's own comment before "fixing" it with a guard.
 *
 * WHAT THIS CLASS DELIBERATELY DOES NOT DO. It does not test-drive away the distinction
 * TestDataFactory encodes on purpose: an UNRECOGNISED name (a typo) throws, while a name
 * that is legitimately absent/unavailable in this org (record types not deployed yet, or a
 * running user without visibility) degrades to the platform default. Methods 2 and 3 below
 * prove the throw side of that distinction; method 1 is what makes the degrade side
 * observable rather than silent when it fires unexpectedly.
 *
 * No @TestSetup - each method calls TestDataFactory.defaultPropertyAsset() directly, which
 * is safe exactly because there is no @TestSetup transaction here to desync from (see the
 * factory's own class-header warning #1). No 251-record bulk scenario: this is allow-list /
 * describe-map logic, not DML-in-a-loop, and .claude/rules/bulk-test-rule.md targets
 * triggers, batches, and DML-performing services - not a single describe lookup.
 *
 * @see force-app/main/default/classes/TestDataFactory.cls (dispositionRecordTypeId, S2 fix)
 * @see force-app/main/default/classes/DispositionService.cls (onMarketRecordTypeId - the
 *      SAME isAvailable() guard shape, on the production create path)
 * @see agent-output/code-review-disposition-foundations.md (PASS 2, suggestion S3)
 * @see agent-output/stage-by-stage-decisions.md (D13, residual 1 and residual 2)
 */
@isTest
private class TestDataFactoryTest {

    /**
     * 🔴 UNCONDITIONAL BY DESIGN - DO NOT WRAP IN `if (isAvailable()) { ... }`.
     *
     * TestDataFactoryTest.dispositionRecordTypeId (and DispositionService.onMarketRecordTypeId,
     * the identical shape on the production path) already soft-guard the STAMP on
     * isAvailable() - that guard is deliberate and stays, so the rest of the suite keeps
     * running in an org where the On_Market record type has not deployed yet. This TEST is
     * where the softness ends: it exists specifically to make a false isAvailable() reading
     * (D13 residual 1 - observed for an assigned System Administrator, with the Id still
     * resolving) a named, red test rather than an invisible default-record-type fixture.
     * A guard here would recreate the exact vacuous-under-the-condition-of-interest shape
     * DispositionServiceTest.findOrCreateStampsTheOnMarketRecordType already accepts
     * elsewhere for a different reason (that test predates the record-type deploy and must
     * pass in an org that has it and one that does not). This class does not need that
     * accommodation - the record-type metadata is bundled into the same check-only/deploy
     * payload as this class per the D13 gate, so a null/mismatched result here is real
     * evidence, not noise.
     */
    @isTest
    static void createDisposition_defaultOverload_stampsOnMarketRecordType() {
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;

        Test.startTest();
        Disposition__c unsaved = TestDataFactory.createDisposition(assetId, true);
        Test.stopTest();

        Disposition__c created = [SELECT Id, RecordTypeId FROM Disposition__c WHERE Id = :unsaved.Id];

        Schema.RecordTypeInfo onMarketInfo = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(TestDataFactory.DISPOSITION_RT_ON_MARKET);
        Id expectedRecordTypeId = (onMarketInfo != null) ? onMarketInfo.getRecordTypeId() : null;

        Assert.areEqual(expectedRecordTypeId, created.RecordTypeId,
            'TestDataFactory.createDisposition (default overload) must stamp the On_Market '
            + 'record type Id on the inserted row. If this fails while On_Market resolves a '
            + 'real Id in the org, isAvailable() is returning false for the test-running user '
            + 'and the stamp is silently no-opping - see stage-by-stage-decisions.md D13 '
            + 'residual 1. Do not soften this assertion; report the failure instead.');
    }

    /**
     * The permanent falsifier for S2. Apex String `!=` is case-INSENSITIVE while
     * getRecordTypeInfosByDeveloperName().get(...) is case-SENSITIVE; before the fix,
     * 'on_market' passed the old `!=` allow-list check, missed the describe map, and
     * returned null - silently degrading to the platform default instead of throwing. If a
     * future edit reintroduces that case-insensitive comparison, this test goes red instead
     * of staying green over a reopened hole.
     */
    @isTest
    static void createDisposition_caseTypoRecordTypeName_throwsAndNamesTheOffendingValue() {
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;

        Test.startTest();
        Boolean threw = false;
        try {
            // Deliberately wrong case - the real constant is 'On_Market'.
            TestDataFactory.createDisposition(assetId, 'on_market', false);
            Assert.fail('A case-typo\'d record type name (\'on_market\') must throw '
                + 'TestDataFactory.TestDataFactoryException, not silently degrade to the '
                + 'platform default record type');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('on_market'),
                'The exception message must name the offending value so a caller can see '
                + 'exactly what was mistyped. Actual message: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'An unrecognised (case-mismatched) record type name must throw '
            + 'TestDataFactory.TestDataFactoryException');
    }

    /**
     * Preserves the pre-existing null-argument behaviour: both DISPOSITION_RT_ON_MARKET and
     * DISPOSITION_RT_OFF_MARKET are non-null literals, so a null caller argument is simply
     * not equal to either and still throws - unchanged by the S2 fix.
     */
    @isTest
    static void createDisposition_nullRecordTypeName_throws() {
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;

        Test.startTest();
        Boolean threw = false;
        try {
            TestDataFactory.createDisposition(assetId, null, false);
            Assert.fail('A null record type name must throw '
                + 'TestDataFactory.TestDataFactoryException, preserving the existing '
                + 'behaviour the allow-list already encoded');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'A null record type name must throw TestDataFactory.TestDataFactoryException, '
            + 'not silently resolve to a default record type');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // NDA__c record types (Tranche 3A, D7 / D14.1 / D16.3)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 UNCONDITIONAL BY DESIGN — see the class header before "fixing" this with a guard.
     *
     * The three-argument createNdas overload is the one every existing NDA test in the repo
     * already calls, so this is the assertion that proves the default did not quietly change
     * meaning when the overload gained a record type.
     */
    @isTest
    static void createNda_defaultOverload_stampsAcquisitionRecordType() {
        Test.startTest();
        NDA__c unsaved = TestDataFactory.createNda(null, true);
        Test.stopTest();

        NDA__c created = [SELECT Id, RecordTypeId, Status__c FROM NDA__c WHERE Id = :unsaved.Id];

        Assert.areEqual(expectedNdaRecordTypeId(TestDataFactory.NDA_RT_ACQUISITION),
            created.RecordTypeId,
            'TestDataFactory.createNda (default overload) must stamp Acquisition_NDA. A null '
            + 'value here while the describe resolves a real Id means isAvailable() is false '
            + 'for the test-running user — post-deploy gate T-A1. Report it; do not soften.');
        Assert.areEqual('Pending', created.Status__c,
            'The acquisition seed status must be Pending — the Acquisition_NDA default. '
            + '"Not Sent" is a DISPOSITION-only value and Apex DML would accept it silently, '
            + 'because record-type picklist restriction is enforced by the UI only.');
    }

    /**
     * 🔴 UNCONDITIONAL BY DESIGN. The disposition twin, and it additionally pins the two things
     * DispositionStageEntryService's idempotency depends on: the seed status must be the
     * Disposition_NDA default ('Not Sent', NOT the acquisition's 'Pending'), and Party_Role__c
     * must be 'Buyer' — which is the service's idempotency KEY, so a fixture that stopped
     * carrying it would silently stop suppressing auto-create.
     */
    @isTest
    static void createDispositionNda_stampsDispositionRecordTypeStatusAndBuyerRole() {
        Test.startTest();
        NDA__c unsaved = TestDataFactory.createDispositionNda(null, true);
        Test.stopTest();

        NDA__c created = [
            SELECT Id, RecordTypeId, Status__c, Party_Role__c FROM NDA__c WHERE Id = :unsaved.Id
        ];

        Assert.areEqual(expectedNdaRecordTypeId(TestDataFactory.NDA_RT_DISPOSITION),
            created.RecordTypeId,
            'TestDataFactory.createDispositionNda must stamp Disposition_NDA. A null value here '
            + 'while the describe resolves a real Id is post-deploy gate T-A1, not a factory bug.');
        Assert.areEqual('Not Sent', created.Status__c,
            'The disposition seed status must be Not Sent — Disposition_NDA\'s default. Pending '
            + 'is restricted OFF this record type, and Apex DML does not enforce that, so a '
            + 'shared seed value would produce a fixture RecordStageAdvanceService cannot advance.');
        Assert.areEqual('Buyer', created.Party_Role__c,
            'Party_Role__c = Buyer is DispositionStageEntryService\'s idempotency key (D19.1). A '
            + 'fixture without it would stop suppressing auto-create, and the suppression tests '
            + 'would pass for the wrong reason.');
    }

    /** The NDA-side permanent falsifier for the constant-first `.equals()` guard (S2's shape). */
    @isTest
    static void createNdas_caseTypoRecordTypeName_throwsAndNamesTheOffendingValue() {
        Test.startTest();
        Boolean threw = false;
        try {
            // Deliberately wrong case — the real constant is 'Acquisition_NDA'.
            TestDataFactory.createNdas(1, null, 'acquisition_nda', false);
            Assert.fail('A case-typo\'d NDA record type name must throw '
                + 'TestDataFactory.TestDataFactoryException, not silently degrade to the '
                + 'platform default record type');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('acquisition_nda'),
                'The exception message must name the offending value. Actual: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'An unrecognised NDA record type name must throw');
    }

    /** Both NDA constants are non-null literals, so a null argument is not equal to either. */
    @isTest
    static void createNdas_nullRecordTypeName_throws() {
        Test.startTest();
        Boolean threw = false;
        try {
            TestDataFactory.createNdas(1, null, null, false);
            Assert.fail('A null NDA record type name must throw '
                + 'TestDataFactory.TestDataFactoryException');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A null NDA record type name must throw');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // LOI__c record types (Tranche 3B, D6 / D16.3)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 UNCONDITIONAL BY DESIGN — see the class header before "fixing" this with a guard.
     *
     * createLoi is called by a dozen existing tests across the repo, so this is the assertion that
     * proves the default did not quietly change meaning when the overload gained a record type.
     */
    @isTest
    static void createLoi_defaultOverload_stampsAcquisitionRecordType() {
        Test.startTest();
        LOI__c unsaved = TestDataFactory.createLoi(null, true);
        Test.stopTest();

        LOI__c created = [SELECT Id, RecordTypeId, Stage__c FROM LOI__c WHERE Id = :unsaved.Id];

        Assert.areEqual(expectedLoiRecordTypeId(TestDataFactory.LOI_RT_ACQUISITION),
            created.RecordTypeId,
            'TestDataFactory.createLoi (default overload) must stamp Acquisition_LOI. A null value '
            + 'here while the describe resolves a real Id means isAvailable() is false for the '
            + 'test-running user — post-deploy gate T-A1. Report it; do not soften.');
        Assert.areEqual('Draft', created.Stage__c,
            'The acquisition seed stage must be Draft. "Received" is a DISPOSITION-only value and '
            + 'Apex DML would accept it silently, because record-type picklist restriction is '
            + 'enforced by the UI only.');
    }

    /**
     * 🔴 UNCONDITIONAL BY DESIGN. The disposition twin. It additionally pins the two facts
     * CounterOfferService depends on: the seed stage must be the Disposition_LOI default
     * ('Received', NOT the acquisition's 'Draft'), and Opportunity__c must be NULL — a fixture
     * carrying both parents would make the record-type clause and the lookup clause of
     * isSaleSide indistinguishable.
     */
    @isTest
    static void createDispositionLoi_stampsDispositionRecordTypeStageAndParent() {
        Disposition__c parent =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);

        Test.startTest();
        LOI__c unsaved = TestDataFactory.createDispositionLoi(parent.Id, true);
        Test.stopTest();

        LOI__c created = [
            SELECT Id, RecordTypeId, Stage__c, Disposition__c, Opportunity__c, Submitted_Date__c
            FROM LOI__c WHERE Id = :unsaved.Id
        ];

        Assert.areEqual(expectedLoiRecordTypeId(TestDataFactory.LOI_RT_DISPOSITION),
            created.RecordTypeId,
            'TestDataFactory.createDispositionLoi must stamp Disposition_LOI. A null value here '
            + 'while the describe resolves a real Id is post-deploy gate T-A1, not a factory bug.');
        Assert.areEqual('Received', created.Stage__c,
            'The disposition seed stage must be Received — Disposition_LOI\'s default. The two LOI '
            + 'value sets are FULLY DISJOINT, so unlike NDA__c there is no shared value that could '
            + 'have served both and a hardcoded Draft would produce a fixture off its own record '
            + 'type\'s value set.');
        Assert.areEqual(parent.Id, created.Disposition__c, 'Parented to the Disposition');
        Assert.isNull(created.Opportunity__c,
            'A disposition LOI must carry NO Opportunity — that is what keeps the two clauses of '
            + 'CounterOfferService.isSaleSide independently testable');
        Assert.isNull(created.Submitted_Date__c,
            'Submitted_Date__c is acquisition-directional (we submit the LOI on a purchase; on a '
            + 'sale it ARRIVES from the buyer) and is layout-excluded from this record type');
    }

    /** The LOI-side permanent falsifier for the constant-first `.equals()` guard (S2's shape). */
    @isTest
    static void createLois_caseTypoRecordTypeName_throwsAndNamesTheOffendingValue() {
        Test.startTest();
        Boolean threw = false;
        try {
            // Deliberately wrong case — the real constant is 'Acquisition_LOI'.
            TestDataFactory.createLois(1, null, 'acquisition_loi', false);
            Assert.fail('A case-typo\'d LOI record type name must throw '
                + 'TestDataFactory.TestDataFactoryException, not silently degrade to the '
                + 'platform default record type');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('acquisition_loi'),
                'The exception message must name the offending value. Actual: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'An unrecognised LOI record type name must throw');
    }

    /** Both LOI constants are non-null literals, so a null argument is not equal to either. */
    @isTest
    static void createLois_nullRecordTypeName_throws() {
        Test.startTest();
        Boolean threw = false;
        try {
            TestDataFactory.createLois(1, null, null, false);
            Assert.fail('A null LOI record type name must throw '
                + 'TestDataFactory.TestDataFactoryException');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A null LOI record type name must throw');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Contract_Review__c record types (Tranche 3C, D16.3)
    //
    // 🔴 THIS BLOCK IS SHAPED DIFFERENTLY FROM THE NDA AND LOI BLOCKS ABOVE, AND THE DIFFERENCE IS
    // THE POINT. Those two assert a per-record-type SEED VALUE alongside the stamp, because their
    // value sets differ. Contract_Review__c's two record types expose the IDENTICAL four
    // Negotiation_Status__c values and the identical three Stage__c values — Disposition_PSA's own
    // record type file says so deliberately — so there is no seed to discriminate on and asserting
    // one would be asserting a coincidence. What these tests pin instead is the RecordTypeId itself
    // and the PARENT LOOKUP, which is the discriminator ContractExecutionService actually branches
    // on.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 UNCONDITIONAL BY DESIGN — see the class header before "fixing" this with a guard.
     *
     * createContractReview is called by PsaVersionSelectorTest, PsaVersionServiceTest,
     * PsaVersionControllerTest and others, so this is the assertion that proves the default did not
     * quietly change meaning when the overload gained a record type.
     */
    @isTest
    static void createContractReview_defaultOverload_stampsAcquisitionRecordType() {
        Test.startTest();
        Contract_Review__c unsaved = TestDataFactory.createContractReview(null, true);
        Test.stopTest();

        Contract_Review__c created = [
            SELECT Id, RecordTypeId, Negotiation_Status__c, Disposition__c
            FROM Contract_Review__c WHERE Id = :unsaved.Id
        ];

        Assert.areEqual(expectedContractReviewRecordTypeId(
                TestDataFactory.CONTRACT_REVIEW_RT_ACQUISITION),
            created.RecordTypeId,
            'PRECONDITION FAILED / post-deploy gate T-A1: TestDataFactory.createContractReview '
            + '(default overload) must stamp Acquisition_PSA. A null value here while the describe '
            + 'resolves a real Id means isAvailable() is false for the test-running user, so the '
            + 'deliberate guard in TestDataFactory.contractReviewRecordTypeId() silently no-opped. '
            + 'Report it; do not soften.');
        Assert.isNull(created.Disposition__c,
            'An acquisition Contract Review must carry NO Disposition — that lookup is the '
            + 'discriminator ContractExecutionService.handleExecution branches on, so a fixture '
            + 'carrying both parents would run BOTH arms.');
    }

    /**
     * 🔴 UNCONDITIONAL BY DESIGN. The disposition twin. It additionally pins the parent asymmetry
     * ContractExecutionService depends on: Disposition__c set, Opportunity__c NULL.
     */
    @isTest
    static void createDispositionContractReview_stampsDispositionRecordTypeAndParent() {
        Disposition__c parent =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);

        Test.startTest();
        Contract_Review__c unsaved =
            TestDataFactory.createDispositionContractReview(parent.Id, true);
        Test.stopTest();

        Contract_Review__c created = [
            SELECT Id, RecordTypeId, Disposition__c, Opportunity__c
            FROM Contract_Review__c WHERE Id = :unsaved.Id
        ];

        Assert.areEqual(expectedContractReviewRecordTypeId(
                TestDataFactory.CONTRACT_REVIEW_RT_DISPOSITION),
            created.RecordTypeId,
            'PRECONDITION FAILED / post-deploy gate T-A1: '
            + 'TestDataFactory.createDispositionContractReview must stamp Disposition_PSA. A null '
            + 'value here while the describe resolves a real Id is gate T-A1, not a factory bug.');
        Assert.areEqual(parent.Id, created.Disposition__c, 'Parented to the Disposition');
        Assert.isNull(created.Opportunity__c,
            'A disposition Contract Review must carry NO Opportunity. This is load-bearing rather '
            + 'than tidy: ContractExecutionService.handleExecution runs its acquisition and '
            + 'disposition arms off the two parent LOOKUPS (never the record type), so a fixture '
            + 'with both would run both arms and make the two behaviours indistinguishable.');
    }

    /** The PSA-side permanent falsifier for the constant-first `.equals()` guard (S2's shape). */
    @isTest
    static void createContractReviews_caseTypoRecordTypeName_throwsAndNamesTheOffendingValue() {
        Test.startTest();
        Boolean threw = false;
        try {
            // Deliberately wrong case — the real constant is 'Acquisition_PSA'.
            TestDataFactory.createContractReviews(1, null, 'acquisition_psa', false);
            Assert.fail('A case-typo\'d Contract Review record type name must throw '
                + 'TestDataFactory.TestDataFactoryException, not silently degrade to the '
                + 'platform default record type');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('acquisition_psa'),
                'The exception message must name the offending value. Actual: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'An unrecognised Contract Review record type name must throw. ⚠ The guard matters MORE '
            + 'on this object than on NDA__c or LOI__c, not less: a mis-typed PSA record type '
            + 'produces a fixture that walks its stage sequence PERFECTLY (both types share one '
            + 'map) and is wrong only about which PERSONA may drive it — so no walk test would '
            + 'catch it.');
    }

    /** Both PSA constants are non-null literals, so a null argument is not equal to either. */
    @isTest
    static void createContractReviews_nullRecordTypeName_throws() {
        Test.startTest();
        Boolean threw = false;
        try {
            TestDataFactory.createContractReviews(1, null, null, false);
            Assert.fail('A null Contract Review record type name must throw '
                + 'TestDataFactory.TestDataFactoryException');
        } catch (TestDataFactory.TestDataFactoryException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A null Contract Review record type name must throw');
    }

    /**
     * The expected Id for an NDA record type, asserting the type EXISTS first so a missing
     * deployment reads as "metadata before Apex" rather than as a null-vs-null false pass.
     */
    private static Id expectedNdaRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'PRECONDITION: the NDA__c record type "' + developerName + '" does not exist in this '
            + 'org. objects/NDA__c/recordTypes/ must deploy BEFORE this class (design §6 T1). '
            + 'Available: '
            + Schema.SObjectType.NDA__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    /** The LOI twin of expectedNdaRecordTypeId. */
    private static Id expectedLoiRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'PRECONDITION: the LOI__c record type "' + developerName + '" does not exist in this '
            + 'org. objects/LOI__c/recordTypes/ must deploy BEFORE this class (metadata before '
            + 'Apex). Available: '
            + Schema.SObjectType.LOI__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    /** The Contract Review twin of expectedNdaRecordTypeId. */
    private static Id expectedContractReviewRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'PRECONDITION FAILED: the Contract_Review__c record type "' + developerName + '" does '
            + 'not exist in this org. objects/Contract_Review__c/recordTypes/ must deploy BEFORE '
            + 'this class (metadata before Apex). Available: '
            + Schema.SObjectType.Contract_Review__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }
}
