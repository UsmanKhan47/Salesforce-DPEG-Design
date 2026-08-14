/**
 * @description Tests PsaVersionService — the PSA version-log append + parent-derivation
 * workflow extracted from PsaVersionController in P6 controller thinning.
 *
 * Covers the Ball_In_Court__c flip, the Latest_Version__c bump, the null-date default, and both
 * business-rule violations (null Contract Review, unrecognised direction) which throw the
 * typed PsaVersionException. The service does two SOQL and two DML statements with no explicit
 * Savepoint (transaction-level rollback on an unhandled exception) and no collection DML, so there
 * is no rollback catch to force and no 251-record bulk scenario applies (saveVersion is a
 * single-record @AuraEnabled operation invoked once per LWC save).
 *
 * 🔴 IT ALSO PINS WHAT THIS SERVICE MUST NOT DO: Negotiation_Status__c is asserted UNCHANGED on
 * every branch. Logging a version used to DERIVE that field — first seller version = Initial
 * Draft, every later version = Seller Counter / Buyer Counter. Both counter values were removed
 * from the restricted picklist on 2026-08-05 and the status is now moved ONLY by the deal driver
 * through Advance Stage. A regression that re-introduced the derivation would therefore either
 * write a value the picklist REJECTS at runtime, or silently drag the parent's status backwards
 * while the deal driver was mid-negotiation. Asserting "unchanged" is what makes either
 * detectable; asserting nothing about the field would let both through.
 *
 * ⚠ THE EXPECTED VALUE IS PER RECORD TYPE SINCE 2026-08-14, AND THE TWO MUST NOT BE HARMONISED.
 * 'Draft' on the ACQUISITION fixtures, 'Initial Draft' on the DISPOSITION one. In both cases the
 * assertion means the same thing — "still whatever the factory seeded before saveVersion ran" — and
 * in both cases the value is now TestDataFactory.createContractReviews' explicit per-record-type
 * seed rather than the field-level picklist default.
 *
 * This paragraph used to read: "The expected value on every branch is 'Initial Draft' because
 * TestDataFactory does not set Negotiation_Status__c and that is the picklist's default." Both
 * halves are now false. Acquisition Observations phase 3 (observation 7) split the two record
 * types' Negotiation_Status__c sequences, so the field default 'Initial Draft' — which
 * Disposition_PSA still runs on (decision O3, a hard stop) — is no longer a value Acquisition_PSA
 * carries; the factory therefore seeds each type explicitly. Reverting either expectation to the
 * field default would put an acquisition fixture back on an off-record-type value, which Apex DML
 * accepts SILENTLY (record-type picklist restriction is UI-only) and which
 * RecordStageAdvanceService then refuses to advance.
 *
 * ── 🔴 WHAT THE 3C FIX PASS ADDED, AND WHY IT IS THE MOST IMPORTANT PART OF THIS CLASS ──
 * `Ball_In_Court__c = 'Seller'` names the COUNTERPARTY on a purchase and names DPEG on a SALE. The
 * pre-fix service hardcoded 'Us' / 'Seller' and REFUSED 'Buyer' outright, so every disposition PSA
 * version would have recorded the OPPOSITE of what happened — whose turn it is, inverted, silently,
 * on the field the whole card is built around. Three metadata files (the Disposition_PSA record
 * type and both Direction__c / Ball_In_Court__c field files) had already shipped naming THIS class
 * as the enforcement point.
 *
 * counterpartyLabelIsChosenFromTheParentSide is the falsifier: it drives the IDENTICAL call
 * against an acquisition parent and a disposition parent in one test and asserts the two produce
 * DIFFERENT labels. Neither half alone is sufficient — a build that hardcoded 'Buyer' would pass a
 * disposition-only test, and a build that never changed would pass an acquisition-only one. It is
 * the transplanted twin of CounterOfferServiceTest's test of the same name, deliberately, because
 * the two features are one design applied to two objects.
 *
 * ── ⚠ TWO SEPARATE METADATA DEPENDENCIES, AND THEY FAIL DIFFERENTLY ──────────
 *  1. THE 'Buyer' PICKLIST VALUE on Contract_Review__c.Ball_In_Court__c and
 *     PSA_Version__c.Direction__c. Both value sets are <restricted>true</restricted>, so until
 *     those field files deploy, every disposition assertion here fails on the INSERT with
 *     INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST. saveDispositionVersion() converts that into a named
 *     PRECONDITION FAILED rather than a raw DmlException from inside the service.
 *  2. THE RECORD TYPES on Contract_Review__c. Only isSaleSide_recordTypeBeatsTheDispositionLookup
 *     needs them, and it needs them only to RESOLVE an Id — it never inserts — so it is green as
 *     soon as the record types deploy and does NOT wait for post-deploy gate T-A1. Every other
 *     disposition test here deliberately relies on the Disposition__c FALLBACK leg instead, which
 *     is what makes them provable in the current pre-A1 org.
 *
 * Do not soften either. A green suite obtained by removing the 'Buyer' assertions would be a suite
 * that passes on exactly the defect this fix pass exists to close.
 *
 * @see force-app/main/default/classes/PsaVersionService.cls
 * @see force-app/main/default/classes/CounterOfferServiceTest.cls (the LOI half of this same
 *      inversion — the suite this one transplants)
 * @author Salesforce Developer
 */
@isTest
private class PsaVersionServiceTest {

    private static Contract_Review__c newContract() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        return TestDataFactory.createContractReview(o.Id, true); // Stage__c 'PSA Drafting'
    }

    /**
     * A disposition-parented Contract Review, deliberately built through the Disposition__c LOOKUP
     * rather than through the record type.
     *
     * 🔴 THAT CHOICE IS THE POINT, NOT A CONVENIENCE. TestDataFactory guards its RecordTypeId stamp
     * on isAvailable(), so before post-deploy gate T-A1 the stamp silently no-ops and the row lands
     * on Master — which is ALSO the true state of every Contract Review in the org during the
     * deploy window. Building the fixture this way therefore tests the exact configuration
     * production will be in on day one, and keeps these assertions provable now rather than blocked
     * behind a manual, non-deployable profile step. The record-type leg is pinned separately, in
     * memory, by isSaleSide_recordTypeBeatsTheDispositionLookup.
     */
    private static Contract_Review__c dispositionContract() {
        Disposition__c disposition =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        return TestDataFactory.createDispositionContractReview(disposition.Id, true);
    }

    /**
     * Calls the service against a disposition PSA, converting the one expected metadata failure
     * into a message that names its own cause. Without this the reader gets a raw
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST from two frames inside the service and no hint that
     * the fix is a field deploy rather than a code defect.
     */
    private static void saveDispositionVersion(Id contractReviewId, String direction) {
        try {
            PsaVersionService.saveVersion(contractReviewId, direction, Date.today(),
                'sell-side draft', null);
        } catch (DmlException e) {
            Assert.fail('PRECONDITION FAILED, not a service defect: the disposition PSA version '
                + 'could not be saved. INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST here means the '
                + 'Tranche 3C "Buyer" value has not yet been ADDED to '
                + 'Contract_Review__c.Ball_In_Court__c and PSA_Version__c.Direction__c — both are '
                + 'restricted value sets, and those field files are the metadata half of this fix. '
                + 'Deploy them before reading this as a code failure, and do NOT remove the Buyer '
                + 'assertions to go green. Platform message: ' + e.getMessage());
        }
    }

    private static Contract_Review__c refresh(Id contractReviewId) {
        return [
            SELECT Ball_In_Court__c, Negotiation_Status__c, Latest_Version__c
            FROM Contract_Review__c WHERE Id = :contractReviewId
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ACQUISITION — the live, deployed behaviour. UNCHANGED by the 3C fix pass.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void sellerFirstVersionFlipsBallToUsAndLeavesStatusAlone() {
        Contract_Review__c cr = newContract();

        Test.startTest();
        PsaVersionService.saveVersion(cr.Id, 'Seller', null, 'First draft from seller counsel',
            'https://onedrive.example/psa-v1');
        Test.stopTest();

        List<PSA_Version__c> versions = PsaVersionSelector.selectByContractReviewId(cr.Id);
        Assert.areEqual(1, versions.size(), 'Version logged');
        Assert.areEqual('Seller', versions[0].Direction__c,
            'On a PURCHASE the counterparty is the seller, so the stored label is unchanged from '
            + 'the pre-fix behaviour. A "Buyer" here would mean the side test inverted.');
        Assert.areEqual(Date.today(), versions[0].Version_Date__c, 'Null version date defaults to today');

        cr = refresh(cr.Id);
        Assert.areEqual('Us', cr.Ball_In_Court__c, 'Seller draft puts the ball in OUR court');
        Assert.areEqual('Draft', cr.Negotiation_Status__c,
            'Logging a version must NOT touch the status — this is the untouched factory seed');
        Assert.areEqual(1, cr.Latest_Version__c, 'Version counter maintained');
    }

    @isTest
    static void ourVersionFlipsBallToSellerAndLeavesStatusAlone() {
        Contract_Review__c cr = newContract();
        PsaVersionService.saveVersion(cr.Id, 'Seller', Date.today(), 'v1', null);

        Test.startTest();
        PsaVersionService.saveVersion(cr.Id, 'Ours', Date.today(), 'our redline', null);
        Test.stopTest();

        cr = refresh(cr.Id);
        Assert.areEqual('Seller', cr.Ball_In_Court__c, 'Our redline puts the ball in the seller court');
        Assert.areEqual('Draft', cr.Negotiation_Status__c,
            'Our redline must NOT move the status — this branch used to write Buyer Counter');
        Assert.areEqual(2, cr.Latest_Version__c, 'Two versions tracked');
        Assert.areEqual(2, PsaVersionSelector.selectByContractReviewId(cr.Id).size(), 'Full history preserved');
    }

    @isTest
    static void aLaterSellerVersionStillLeavesStatusAlone() {
        Contract_Review__c cr = newContract();
        // First version is ours, so this drives what used to be the 'Seller Counter' branch.
        PsaVersionService.saveVersion(cr.Id, 'Ours', Date.today(), 'our opener', null);

        Test.startTest();
        PsaVersionService.saveVersion(cr.Id, 'Seller', Date.today(), 'seller redline', null);
        Test.stopTest();

        cr = refresh(cr.Id);
        Assert.areEqual('Us', cr.Ball_In_Court__c, 'A seller version puts the ball in OUR court');
        Assert.areEqual('Draft', cr.Negotiation_Status__c,
            'A later seller version must NOT move the status — it used to write Seller Counter');
        Assert.areEqual(2, cr.Latest_Version__c, 'Version counter bumped');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 DISPOSITION — THE INVERSION. The reason the 3C fix pass touched this class.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void counterpartyLabelIsChosenFromTheParentSide() {
        // 🔴 THE FALSIFIER. The SAME call, the SAME token, two parents — and the stored labels must
        // DIFFER. A build that hardcodes either label passes one half and fails the other, which is
        // exactly why both halves live in one test rather than two.
        Contract_Review__c acquisitionCr = newContract();
        Contract_Review__c saleCr = dispositionContract();

        Test.startTest();
        PsaVersionService.saveVersion(acquisitionCr.Id, 'Seller', Date.today(), 'their draft', null);
        saveDispositionVersion(saleCr.Id, 'Seller');
        Test.stopTest();

        Assert.areEqual('Seller',
            PsaVersionSelector.selectByContractReviewId(acquisitionCr.Id)[0].Direction__c,
            'ACQUISITION: the counterparty is the SELLER');
        Assert.areEqual('Buyer',
            PsaVersionSelector.selectByContractReviewId(saleCr.Id)[0].Direction__c,
            'DISPOSITION: the counterparty is the BUYER. "Seller" here would name DPEG — the '
            + 'record would say we sent ourselves a version.');

        Map<Id, Contract_Review__c> stamped = new Map<Id, Contract_Review__c>([
            SELECT Id, Ball_In_Court__c FROM Contract_Review__c
            WHERE Id IN (:acquisitionCr.Id, :saleCr.Id)
        ]);
        Assert.areEqual('Us', stamped.get(acquisitionCr.Id).Ball_In_Court__c,
            'ACQUISITION: a counterparty version puts the ball in our court');
        Assert.areEqual('Us', stamped.get(saleCr.Id).Ball_In_Court__c,
            'DISPOSITION: the DPEG side of Ball_In_Court__c does NOT invert — a buyer version '
            + 'still puts the ball in our court, and "Us" still means DPEG');
    }

    @isTest
    static void ourVersionOnASalePutsTheBallInTheBuyerCourt() {
        // 🔴 THE URGENT HALF OF THE INVERSION, ISOLATED, AND IT IS THE EXACT DEFECT THE REVIEW
        // NAMED. Ball_In_Court__c is the field that reads WRONG rather than merely oddly: pre-fix
        // this call wrote 'Seller', and on a sale DPEG IS the seller — so the field claimed the
        // ball was with us at the exact moment it passed to the buyer.
        Contract_Review__c saleCr = dispositionContract();

        Test.startTest();
        saveDispositionVersion(saleCr.Id, 'Ours');
        Test.stopTest();

        Contract_Review__c refreshed = refresh(saleCr.Id);
        Assert.areEqual('Buyer', refreshed.Ball_In_Court__c,
            'On a SALE our redline puts the ball in the BUYER\'s court. "Seller" here is the '
            + 'pre-fix defect and names DPEG.');
        Assert.areEqual('Initial Draft', refreshed.Negotiation_Status__c,
            'The disposition branch must not move the status either. 🔴 THE EXPECTED VALUE HERE IS '
            + 'DELIBERATELY NOT "Draft" LIKE ITS ACQUISITION SIBLINGS ABOVE — this fixture is a '
            + 'DISPOSITION Contract Review, and since phase 3 the two record types no longer share '
            + 'a sequence: Disposition_PSA still starts at Initial Draft (requirements O3, a hard '
            + 'stop). Harmonising the two expectations would put a sell-side fixture on a value its '
            + 'own record type does not carry.');
        Assert.areEqual('Ours',
            PsaVersionSelector.selectByContractReviewId(saleCr.Id)[0].Direction__c,
            'The DPEG token is "Ours" on both sides and must not become "Seller" on a sale');
    }

    @isTest
    static void buyerTokenIsAcceptedOnASaleAndRefusedOnAPurchase() {
        // The token asymmetry, both directions in one test. 'Buyer' names the counterparty on a
        // sale and would name DPEG on a purchase, so it is accepted only where it is unambiguous —
        // guessing on the field that decides whose turn it is is the defect being fixed.
        Contract_Review__c saleCr = dispositionContract();
        Contract_Review__c acquisitionCr = newContract();

        Test.startTest();
        saveDispositionVersion(saleCr.Id, 'Buyer');

        Boolean refused = false;
        String message;
        try {
            PsaVersionService.saveVersion(acquisitionCr.Id, 'Buyer', null, 'x', null);
            Assert.fail('"Buyer" must be REFUSED on an acquisition PSA: there DPEG is the buyer, '
                + 'so accepting it would be a guess about which side the caller meant');
        } catch (PsaVersionService.PsaVersionException e) {
            refused = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual('Buyer',
            PsaVersionSelector.selectByContractReviewId(saleCr.Id)[0].Direction__c,
            '"Buyer" is the natural token for a sale and must be accepted there — without this '
            + 'half, the refusal below could pass in a build that rejects "Buyer" everywhere');
        Assert.isTrue(refused, '"Buyer" must be refused on a purchase');
        Assert.areEqual('Pick who sent this version (Seller or Ours).', message,
            'The acquisition-side refusal wording must be BYTE-IDENTICAL to the pre-fix message — '
            + 'no live user sees new wording because of this change');
        Assert.isTrue(PsaVersionSelector.selectByContractReviewId(acquisitionCr.Id).isEmpty(),
            'A refused direction must write nothing at all — the refusal happens before the insert');
    }

    @isTest
    static void theIncumbentSellerTokenStillWorksOnASale() {
        // ⚠ THE COMPATIBILITY GUARANTEE FOR THE DEPLOYED PICKER. lwc/psaVersionLog sends 'Seller'
        // for "Seller sent us a version" and has no disposition variant, so refusing that token on
        // a sale would leave its Save button dead. 'Seller' is the incumbent WIRE token meaning
        // "the counterparty"; the service renames it on write. Deleting this test would let a
        // future "tidy-up" refuse it and break the only deployed client.
        Contract_Review__c saleCr = dispositionContract();

        Test.startTest();
        saveDispositionVersion(saleCr.Id, 'Seller');
        Test.stopTest();

        Assert.areEqual('Buyer',
            PsaVersionSelector.selectByContractReviewId(saleCr.Id)[0].Direction__c,
            'The deployed picker\'s "Seller" token must be ACCEPTED on a sale and STORED as '
            + '"Buyer" — the correction is the whole mechanism');
        Assert.areEqual('Us', refresh(saleCr.Id).Ball_In_Court__c,
            'And the ball goes to US, because the counterparty is the one who sent it');
    }

    @isTest
    static void unknownDirectionOnASaleNamesTheSaleSideChoices() {
        Contract_Review__c saleCr = dispositionContract();

        Test.startTest();
        Boolean threw = false;
        String message;
        try {
            PsaVersionService.saveVersion(saleCr.Id, 'Nobody', null, 'x', null);
            Assert.fail('An unknown direction should throw PsaVersionException');
        } catch (PsaVersionService.PsaVersionException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw, 'An unknown direction must be refused on a sale too');
        Assert.areEqual('Pick who sent this version (Buyer or Ours).', message,
            'The refusal must name THIS Contract Review\'s own valid choices. Saying "Seller" on a '
            + 'sale would send the user looking for an option that means DPEG.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // isSaleSide — the precedence rule, pinned in memory (no DML, no record-type
    // AVAILABILITY needed, so this is provable before post-deploy gate T-A1)
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void isSaleSide_recordTypeBeatsTheDispositionLookup() {
        // 🔴 THE PRECEDENCE RULE, AND THE ONLY PLACE IT IS FALSIFIABLE TODAY. Every other
        // disposition test here exercises the FALLBACK leg (Master record type + populated
        // lookup), so without this one a build that ignored RecordTypeId entirely would pass the
        // whole class. In-memory records only: getRecordTypeInfosByDeveloperName() resolves a real
        // Id whether or not the type is AVAILABLE (measured, D13 residual 1), and nothing is
        // inserted, so this needs the record-type METADATA but not gate T-A1.
        Id acquisitionRtId = contractReviewRecordTypeId(PsaVersionService.RT_ACQUISITION_PSA);
        Id dispositionRtId = contractReviewRecordTypeId(PsaVersionService.RT_DISPOSITION_PSA);
        // A REAL Disposition Id. Nothing here is inserted, so a placeholder would do — but a
        // wrong-object Id in a lookup field is only rejected at DML, which would make this
        // fixture quietly untrue for anyone who later adds an insert to this test.
        Id someDispositionId =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true).Id;

        Test.startTest();
        // Contradictory inputs in BOTH directions: the record type must win each time.
        Boolean acquisitionTypeWithASaleLookup = PsaVersionService.isSaleSide(
            new Contract_Review__c(RecordTypeId = acquisitionRtId, Disposition__c = someDispositionId));
        Boolean dispositionTypeWithNoLookup = PsaVersionService.isSaleSide(
            new Contract_Review__c(RecordTypeId = dispositionRtId, Disposition__c = null));
        // And the fallback, for completeness: no record type at all.
        Boolean masterWithASaleLookup = PsaVersionService.isSaleSide(
            new Contract_Review__c(Disposition__c = someDispositionId));
        Boolean masterWithNoLookup = PsaVersionService.isSaleSide(new Contract_Review__c());
        Test.stopTest();

        Assert.isFalse(acquisitionTypeWithASaleLookup,
            'An explicit Acquisition_PSA record type must win over a stray Disposition__c value. '
            + 'True here means the lookup is being consulted FIRST and a mis-keyed row would '
            + 'silently switch sides.');
        Assert.isTrue(dispositionTypeWithNoLookup,
            'An explicit Disposition_PSA record type is sufficient on its own — the lookup is a '
            + 'FALLBACK for the migration window, not a second requirement');
        Assert.isTrue(masterWithASaleLookup,
            'THE MIGRATION-WINDOW CASE, and the one production will actually be in on day one: no '
            + 'record type, so the Disposition__c lookup decides. ⚠ THE REASON CHANGED ON '
            + '2026-08-14 AND THE DIRECTION IS NOW THE OPPOSITE. This used to read: it matters '
            + 'MORE on this object than on LOI__c, because both PSA record types expose the same '
            + 'four statuses, so a Master-type disposition PSA walks its path perfectly and is '
            + 'wrong only about vocabulary, i.e. invisibly. Observation 7 split the two sequences, '
            + 'so such a row is now REFUSED loudly by RecordStageAdvanceService on its first '
            + 'Advance Stage click. The lookup still decides here anyway: that refusal is a '
            + 'DIFFERENT class on a DIFFERENT action, and logging a version refuses nothing, so '
            + 'without clause 2 this row takes buy-side vocabulary into Ball_In_Court__c silently.');
        Assert.isFalse(masterWithNoLookup,
            'Neither signal present defaults to ACQUISITION, matching CounterOfferService and '
            + 'RecordStageAdvanceService\'s defaultTypeKey — every Contract Review in the org '
            + 'today is buy-side by construction');
    }

    /** Resolves a Contract Review record type Id, asserting it EXISTS so a missing deploy names itself. */
    private static Id contractReviewRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'PRECONDITION: the Contract_Review__c record type "' + developerName + '" does not '
            + 'exist in this org. objects/Contract_Review__c/recordTypes/ must deploy BEFORE this '
            + 'class (metadata before Apex). Note this test needs the type to EXIST, not to be '
            + 'AVAILABLE, so gate T-A1 is NOT a precondition here. Available: '
            + Schema.SObjectType.Contract_Review__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // GUARD CLAUSES
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void nullContractThrowsPsaVersionException() {
        // ⚠ The null-contractReviewId guard deliberately stays AHEAD of the parent load — it is the
        // one refusal that needs no row. If it ever moved behind the read this would raise
        // System.QueryException instead, which the controller masks with a DIFFERENT message.
        Test.startTest();
        try {
            PsaVersionService.saveVersion(null, 'Seller', null, 'x', null);
            Assert.fail('Saving with no Contract Review should throw PsaVersionException');
        } catch (PsaVersionService.PsaVersionException e) {
            Assert.areEqual('No Contract Review is linked to this deal yet.', e.getMessage(),
                'The no-Contract-Review rule violation carries its own user-safe message, '
                + 'surfaced verbatim');
        }
        Test.stopTest();
    }

    @isTest
    static void unknownDirectionThrowsPsaVersionException() {
        Contract_Review__c cr = newContract();

        Test.startTest();
        try {
            PsaVersionService.saveVersion(cr.Id, 'Nobody', null, 'x', null);
            Assert.fail('An unknown direction should throw PsaVersionException');
        } catch (PsaVersionService.PsaVersionException e) {
            Assert.areEqual('Pick who sent this version (Seller or Ours).', e.getMessage(),
                'The acquisition-side wording is unchanged from before the 3C fix pass');
        }
        Test.stopTest();
    }

    @isTest
    static void aMissingContractReviewRaisesQueryExceptionNotARefusal() {
        // ⚠ PINS THE ONE VISIBLE CONSEQUENCE OF THE ORDERING CHANGE — the same one Tranche 3B made
        // to CounterOfferService.saveCounterOffer and 3A made to
        // RecordStageAdvanceService.advanceTo. The direction used to be validated before anything
        // was read; the set of valid tokens is now a property of the record type, which is a
        // property of the row, so the load happens first. Both outcomes are masked behind the
        // controller's fixed generic message, so nothing a user sees changes — but a future
        // "optimisation" that moves the direction check back in front of the load would silently
        // restore a caller-supplied label, and this test is what stops it.
        Contract_Review__c cr = newContract();
        Id deletedId = cr.Id;
        delete cr;

        Test.startTest();
        try {
            PsaVersionService.saveVersion(deletedId, 'Nobody', null, 'x', null);
            Assert.fail('A version against a deleted Contract Review must not succeed');
        } catch (System.QueryException e) {
            Assert.isNotNull(e, 'The parent load runs before the direction check, so a missing row '
                + 'surfaces the native QueryException');
        } catch (PsaVersionService.PsaVersionException e) {
            Assert.fail('The direction must be validated AFTER the parent is loaded, because the '
                + 'valid tokens are keyed by record type. A PsaVersionException here means the '
                + 'check ran first and the label could again be taken from the caller. Message: '
                + e.getMessage());
        }
        Test.stopTest();
    }
}
