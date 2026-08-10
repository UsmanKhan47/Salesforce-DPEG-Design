/**
 * @description Tests CounterOfferService — the LOI counter-offer append + parent-stamp
 * workflow extracted from CounterOfferController in P6 controller thinning.
 *
 * Covers the DPEG and counterparty directions (Ball_In_Court__c flip both ways, the
 * counterparty-only Counter_Received_Date__c stamp), the null-date default, and both business-rule
 * violations (null LOI, unrecognised direction) which throw the typed CounterOfferException.
 * The service does one SOQL and two DML statements with no explicit Savepoint (transaction-level
 * rollback on an unhandled exception, matching the pre-thinning behaviour) and no collection DML,
 * so there is no rollback catch to force and no 251-record bulk scenario applies (saveCounterOffer
 * is a single-record @AuraEnabled operation invoked once per LWC save).
 *
 * ── 🔴 WHAT TRANCHE 3B ADDED, AND WHY IT IS THE MOST IMPORTANT PART OF THIS CLASS ──
 * `Ball_In_Court__c = 'Seller'` names the COUNTERPARTY on a purchase and names DPEG on a SALE. The
 * pre-3B service hardcoded 'Us' / 'Seller', so every disposition counter would have recorded the
 * OPPOSITE of what happened — whose turn it is, inverted, silently, on the field the whole card is
 * built around.
 *
 * counterpartyLabelIsChosenFromTheParentSide is the falsifier: it drives the IDENTICAL call
 * against an acquisition parent and a disposition parent in one test and asserts the two produce
 * DIFFERENT labels. Neither half alone is sufficient — a build that hardcoded 'Buyer' would pass a
 * disposition-only test, and a build that never changed would pass an acquisition-only one.
 *
 * ── ⚠ TWO SEPARATE METADATA DEPENDENCIES, AND THEY FAIL DIFFERENTLY ──────────
 *  1. THE 'Buyer' PICKLIST VALUE on LOI__c.Ball_In_Court__c and Counter_Offer__c.Direction__c.
 *     Both value sets are <restricted>true</restricted>, so until the architect's field change
 *     deploys, every disposition assertion here fails on the INSERT with
 *     INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST. saveDispositionCounter() converts that into a named
 *     failure rather than a raw DmlException from inside the service.
 *  2. THE RECORD TYPES on LOI__c. Only isSaleSide_recordTypeBeatsTheDispositionLookup needs them,
 *     and it needs them only to RESOLVE an Id — it never inserts — so it is green as soon as the
 *     record types deploy and does NOT wait for post-deploy gate T-A1. Every other disposition
 *     test here deliberately relies on the Disposition__c FALLBACK leg instead, which is what
 *     makes them provable in the current pre-A1 org.
 *
 * Do not soften either. A green suite obtained by removing the 'Buyer' assertions would be a suite
 * that passes on exactly the defect this tranche exists to fix.
 *
 * @see force-app/main/default/classes/CounterOfferService.cls
 * @author Salesforce Developer
 */
@isTest
private class CounterOfferServiceTest {

    /**
     * A disposition-parented LOI, deliberately built through the Disposition__c LOOKUP rather than
     * through the record type.
     *
     * 🔴 THAT CHOICE IS THE POINT, NOT A CONVENIENCE. TestDataFactory guards its RecordTypeId stamp
     * on isAvailable(), so before post-deploy gate T-A1 the stamp silently no-ops and the row lands
     * on Master — which is ALSO the true state of every LOI in the org during the deploy window.
     * Building the fixture this way therefore tests the exact configuration production will be in
     * on day one, and keeps these assertions provable now rather than blocked behind a manual,
     * non-deployable profile step. The record-type leg is pinned separately, in memory, by
     * isSaleSide_recordTypeBeatsTheDispositionLookup.
     */
    private static LOI__c dispositionLoi() {
        Disposition__c disposition =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        return TestDataFactory.createDispositionLoi(disposition.Id, true);
    }

    /**
     * Calls the service against a disposition LOI, converting the one expected metadata failure
     * into a message that names its own cause. Without this the reader gets a raw
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST from two frames inside the service and no hint that
     * the fix is a field deploy rather than a code defect.
     */
    private static void saveDispositionCounter(Id loiId, String direction, Decimal price) {
        try {
            CounterOfferService.saveCounterOffer(loiId, direction, price, 6.0,
                Date.today(), 'note', null, null);
        } catch (DmlException e) {
            Assert.fail('PRECONDITION FAILED, not a service defect: the disposition counter could '
                + 'not be saved. INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST here means the Tranche 3B '
                + '"Buyer" value has not yet been ADDED to LOI__c.Ball_In_Court__c and '
                + 'Counter_Offer__c.Direction__c — both are restricted value sets, and that field '
                + 'change is the metadata half of this tranche. Deploy it before reading this as a '
                + 'code failure, and do NOT remove the Buyer assertions to go green. Platform '
                + 'message: ' + e.getMessage());
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ACQUISITION — the live, deployed behaviour. UNCHANGED by Tranche 3B.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void sellerCounterAppendsHistoryStampsLoiAndFlipsBallToUs() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        CounterOfferService.saveCounterOffer(loi.Id, 'Seller', 1000000, 6.25,
            Date.today().addDays(-1), 'Seller came back higher', 'R2', 'v3');
        Test.stopTest();

        List<Counter_Offer__c> offers = CounterOfferSelector.selectByLoiId(loi.Id);
        Assert.areEqual(1, offers.size(), 'Counter recorded in the history');
        Assert.areEqual('Seller', offers[0].Direction__c,
            'On a PURCHASE the counterparty is the seller, so the stored label is unchanged from '
            + 'the pre-3B behaviour. A "Buyer" here would mean the side test inverted.');
        Assert.areEqual(6.25, offers[0].Counter_Cap_Rate__c, 'Cap rate captured');
        Assert.areEqual(Date.today().addDays(-1), offers[0].Counter_Date__c, 'Date captured');
        Assert.areEqual('R2', offers[0].Revision_Number__c, 'Revision number captured');
        Assert.areEqual('v3', offers[0].Subsequent_Version__c, 'Subsequent version captured');

        LOI__c refreshed = [
            SELECT Counter_Price__c, Counter_Cap_Rate__c, Counter_Received_Date__c,
                   Ball_In_Court__c, LOI_Status__c
            FROM LOI__c WHERE Id = :loi.Id
        ];
        Assert.areEqual(1000000, refreshed.Counter_Price__c, 'LOI holds the latest counter price');
        Assert.areEqual(6.25, refreshed.Counter_Cap_Rate__c, 'LOI holds the latest cap rate');
        Assert.areEqual(Date.today().addDays(-1), refreshed.Counter_Received_Date__c,
            'A counterparty counter stamps the received date');
        Assert.areEqual('Us', refreshed.Ball_In_Court__c,
            'A counterparty counter puts the ball in OUR court. "Us" means DPEG on both sides and '
            + 'is the one value that never inverts.');
        Assert.areEqual('Countered', refreshed.LOI_Status__c, 'LOI status reflects the counter');
    }

    @isTest
    static void ourCounterFlipsBallToSellerAndDefaultsDateToToday() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        // Null counterDate must default to today; a blank revision/subsequent stores null.
        CounterOfferService.saveCounterOffer(loi.Id, 'Ours', 950000, null, null, 'ours back', '  ', '');
        Test.stopTest();

        List<Counter_Offer__c> offers = CounterOfferSelector.selectByLoiId(loi.Id);
        Assert.areEqual(1, offers.size(), 'Our counter recorded in the history');
        Assert.areEqual('Ours', offers[0].Direction__c, 'DPEG is "Ours" on both sides');
        Assert.areEqual(Date.today(), offers[0].Counter_Date__c, 'Null date defaults to today');
        Assert.isNull(offers[0].Revision_Number__c, 'A blank revision is stored as null');
        Assert.isNull(offers[0].Subsequent_Version__c, 'A blank subsequent version is stored as null');

        LOI__c refreshed = [SELECT Counter_Price__c, Counter_Received_Date__c, Ball_In_Court__c
                            FROM LOI__c WHERE Id = :loi.Id];
        Assert.areEqual(950000, refreshed.Counter_Price__c, 'Latest (our) counter stamped');
        Assert.areEqual('Seller', refreshed.Ball_In_Court__c,
            'On a PURCHASE our counter puts the ball in the seller court');
        Assert.isNull(refreshed.Counter_Received_Date__c, 'Our counter does not stamp the received date');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 DISPOSITION — THE INVERSION. The reason this tranche touched this class.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void counterpartyLabelIsChosenFromTheParentSide() {
        // 🔴 THE FALSIFIER. The SAME call, the SAME token, two parents — and the stored labels must
        // DIFFER. A build that hardcodes either label passes one half and fails the other, which is
        // exactly why both halves live in one test rather than two.
        LOI__c acquisitionLoi = TestDataFactory.createLoi(null, true);
        LOI__c saleLoi = dispositionLoi();

        Test.startTest();
        CounterOfferService.saveCounterOffer(acquisitionLoi.Id, 'Seller', 1000000, 6.0,
            Date.today(), 'their counter', null, null);
        saveDispositionCounter(saleLoi.Id, 'Seller', 2000000);
        Test.stopTest();

        Assert.areEqual('Seller', CounterOfferSelector.selectByLoiId(acquisitionLoi.Id)[0].Direction__c,
            'ACQUISITION: the counterparty is the SELLER');
        Assert.areEqual('Buyer', CounterOfferSelector.selectByLoiId(saleLoi.Id)[0].Direction__c,
            'DISPOSITION: the counterparty is the BUYER. "Seller" here would name DPEG — the '
            + 'record would say we countered ourselves.');

        Map<Id, LOI__c> stamped = new Map<Id, LOI__c>([
            SELECT Id, Ball_In_Court__c FROM LOI__c
            WHERE Id IN (:acquisitionLoi.Id, :saleLoi.Id)
        ]);
        Assert.areEqual('Us', stamped.get(acquisitionLoi.Id).Ball_In_Court__c,
            'ACQUISITION: a counterparty counter puts the ball in our court');
        Assert.areEqual('Us', stamped.get(saleLoi.Id).Ball_In_Court__c,
            'DISPOSITION: the DPEG side of Ball_In_Court__c does NOT invert — a buyer counter '
            + 'still puts the ball in our court, and "Us" still means DPEG');
    }

    @isTest
    static void ourCounterOnASalePutsTheBallInTheBuyerCourt() {
        // 🔴 THE URGENT HALF OF THE INVERSION, ISOLATED. Ball_In_Court__c is the field that reads
        // WRONG rather than merely oddly: pre-3B this call wrote 'Seller', and on a sale DPEG IS
        // the seller — so the badge would have said the ball was in our court at the exact moment
        // we had handed it to the buyer.
        LOI__c saleLoi = dispositionLoi();

        Test.startTest();
        saveDispositionCounter(saleLoi.Id, 'Ours', 2100000);
        Test.stopTest();

        LOI__c refreshed = [SELECT Ball_In_Court__c, Counter_Received_Date__c
                            FROM LOI__c WHERE Id = :saleLoi.Id];
        Assert.areEqual('Buyer', refreshed.Ball_In_Court__c,
            'On a SALE our counter puts the ball in the BUYER\'s court. "Seller" here is the '
            + 'pre-3B defect and names DPEG.');
        Assert.isNull(refreshed.Counter_Received_Date__c,
            'Our own counter never stamps the received date, on either side');
        Assert.areEqual('Ours', CounterOfferSelector.selectByLoiId(saleLoi.Id)[0].Direction__c,
            'The DPEG token is "Ours" on both sides and must not become "Seller" on a sale');
    }

    @isTest
    static void buyerTokenIsAcceptedOnASaleAndRefusedOnAPurchase() {
        // The token asymmetry, both directions in one test. 'Buyer' names the counterparty on a
        // sale and would name DPEG on a purchase, so it is accepted only where it is unambiguous —
        // guessing on the field that decides whose turn it is is the defect being fixed.
        LOI__c saleLoi = dispositionLoi();
        LOI__c acquisitionLoi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        saveDispositionCounter(saleLoi.Id, 'Buyer', 2200000);

        Boolean refused = false;
        String message;
        try {
            CounterOfferService.saveCounterOffer(acquisitionLoi.Id, 'Buyer', 900000, null,
                null, 'x', null, null);
            Assert.fail('"Buyer" must be REFUSED on an acquisition LOI: there DPEG is the buyer, '
                + 'so accepting it would be a guess about which side the caller meant');
        } catch (CounterOfferService.CounterOfferException e) {
            refused = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual('Buyer', CounterOfferSelector.selectByLoiId(saleLoi.Id)[0].Direction__c,
            '"Buyer" is the natural token for a sale and must be accepted there — without this '
            + 'half, the refusal below could pass in a build that rejects "Buyer" everywhere');
        Assert.isTrue(refused, '"Buyer" must be refused on a purchase');
        Assert.areEqual('Pick who made this counter (Seller or Ours).', message,
            'The acquisition-side refusal wording must be BYTE-IDENTICAL to the pre-3B message — '
            + 'no live user sees new wording because of this change');
        Assert.isTrue(CounterOfferSelector.selectByLoiId(acquisitionLoi.Id).isEmpty(),
            'A refused direction must write nothing at all — the refusal happens before the insert');
    }

    @isTest
    static void theIncumbentSellerTokenStillWorksOnASale() {
        // ⚠ THE COMPATIBILITY GUARANTEE FOR THE DEPLOYED PICKER. lwc/loiCounterOffer sends 'Seller'
        // for "they countered" and has no disposition variant yet, so refusing that token on a sale
        // would leave its Save button dead until the UI wave lands. 'Seller' is the incumbent WIRE
        // token meaning "the counterparty"; the service renames it on write. Deleting this test
        // would let a future "tidy-up" refuse it and break the only deployed client.
        LOI__c saleLoi = dispositionLoi();

        Test.startTest();
        saveDispositionCounter(saleLoi.Id, 'Seller', 2300000);
        Test.stopTest();

        Assert.areEqual('Buyer', CounterOfferSelector.selectByLoiId(saleLoi.Id)[0].Direction__c,
            'The deployed picker\'s "Seller" token must be ACCEPTED on a sale and STORED as '
            + '"Buyer" — the correction is the whole mechanism');
    }

    @isTest
    static void unknownDirectionOnASaleNamesTheSaleSideChoices() {
        LOI__c saleLoi = dispositionLoi();

        Test.startTest();
        Boolean threw = false;
        String message;
        try {
            CounterOfferService.saveCounterOffer(saleLoi.Id, 'Nobody', 500000, null, null,
                'x', null, null);
            Assert.fail('An unknown direction should throw CounterOfferException');
        } catch (CounterOfferService.CounterOfferException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw, 'An unknown direction must be refused on a sale too');
        Assert.areEqual('Pick who made this counter (Buyer or Ours).', message,
            'The refusal must name THIS LOI\'s own valid choices. Saying "Seller" on a sale would '
            + 'send the user looking for an option that means DPEG.');
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
        Id acquisitionRtId = loiRecordTypeId(CounterOfferService.RT_ACQUISITION_LOI);
        Id dispositionRtId = loiRecordTypeId(CounterOfferService.RT_DISPOSITION_LOI);
        // A REAL Disposition Id. Nothing here is inserted, so a placeholder would do — but a
        // wrong-object Id in a lookup field is only rejected at DML, which would make this
        // fixture quietly untrue for anyone who later adds an insert to this test.
        Id someDispositionId =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true).Id;

        Test.startTest();
        // Contradictory inputs in BOTH directions: the record type must win each time.
        Boolean acquisitionTypeWithASaleLookup = CounterOfferService.isSaleSide(
            new LOI__c(RecordTypeId = acquisitionRtId, Disposition__c = someDispositionId));
        Boolean dispositionTypeWithNoLookup = CounterOfferService.isSaleSide(
            new LOI__c(RecordTypeId = dispositionRtId, Disposition__c = null));
        // And the fallback, for completeness: no record type at all.
        Boolean masterWithASaleLookup = CounterOfferService.isSaleSide(
            new LOI__c(Disposition__c = someDispositionId));
        Boolean masterWithNoLookup = CounterOfferService.isSaleSide(new LOI__c());
        Test.stopTest();

        Assert.isFalse(acquisitionTypeWithASaleLookup,
            'An explicit Acquisition_LOI record type must win over a stray Disposition__c value. '
            + 'True here means the lookup is being consulted FIRST and a mis-keyed row would '
            + 'silently switch sides.');
        Assert.isTrue(dispositionTypeWithNoLookup,
            'An explicit Disposition_LOI record type is sufficient on its own — the lookup is a '
            + 'FALLBACK for the migration window, not a second requirement');
        Assert.isTrue(masterWithASaleLookup,
            'THE MIGRATION-WINDOW CASE, and the one production will actually be in on day one: no '
            + 'record type, so the Disposition__c lookup decides');
        Assert.isFalse(masterWithNoLookup,
            'Neither signal present defaults to ACQUISITION, matching '
            + 'RecordStageAdvanceService\'s defaultTypeKey — every LOI in the org today is '
            + 'buy-side by construction');
    }

    /** Resolves an LOI record type Id, asserting it EXISTS so a missing deploy names itself. */
    private static Id loiRecordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        Assert.isNotNull(info,
            'PRECONDITION: the LOI__c record type "' + developerName + '" does not exist in this '
            + 'org. objects/LOI__c/recordTypes/ must deploy BEFORE this class (metadata before '
            + 'Apex). Note this test needs the type to EXIST, not to be AVAILABLE, so gate T-A1 is '
            + 'NOT a precondition here. Available: '
            + Schema.SObjectType.LOI__c.getRecordTypeInfosByDeveloperName().keySet());
        return info.getRecordTypeId();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // GUARD CLAUSES
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void nullLoiThrowsCounterOfferException() {
        // ⚠ The null-loiId guard deliberately stays AHEAD of the parent load — it is the one
        // refusal that needs no row. If it ever moved behind the read this would raise
        // System.QueryException instead, which the controller masks with a DIFFERENT message.
        Test.startTest();
        try {
            CounterOfferService.saveCounterOffer(null, 'Seller', 500000, null, null, 'x', null, null);
            Assert.fail('Saving with no LOI should throw CounterOfferException');
        } catch (CounterOfferService.CounterOfferException e) {
            Assert.areEqual('No primary LOI is set on this deal.', e.getMessage(),
                'The no-LOI rule violation carries its own user-safe message, surfaced verbatim');
        }
        Test.stopTest();
    }

    @isTest
    static void unknownDirectionThrowsCounterOfferException() {
        LOI__c loi = TestDataFactory.createLoi(null, true);

        Test.startTest();
        try {
            CounterOfferService.saveCounterOffer(loi.Id, 'Nobody', 500000, null, null, 'x', null, null);
            Assert.fail('An unknown direction should throw CounterOfferException');
        } catch (CounterOfferService.CounterOfferException e) {
            Assert.areEqual('Pick who made this counter (Seller or Ours).', e.getMessage(),
                'The acquisition-side wording is unchanged from before Tranche 3B');
        }
        Test.stopTest();
    }

    @isTest
    static void aMissingLoiRaisesQueryExceptionNotARefusal() {
        // ⚠ PINS THE ONE VISIBLE CONSEQUENCE OF THE 3B ORDERING CHANGE — the same one Tranche 3A
        // made to RecordStageAdvanceService.advanceTo. The direction used to be validated before
        // anything was read; the set of valid tokens is now a property of the record type, which is
        // a property of the row, so the load happens first. Both outcomes are masked behind the
        // controller's fixed generic message, so nothing a user sees changes — but a future
        // "optimisation" that moves the direction check back in front of the load would silently
        // restore a caller-supplied label, and this test is what stops it.
        LOI__c loi = TestDataFactory.createLoi(null, true);
        Id deletedId = loi.Id;
        delete loi;

        Test.startTest();
        try {
            CounterOfferService.saveCounterOffer(deletedId, 'Nobody', 500000, null, null,
                'x', null, null);
            Assert.fail('A counter against a deleted LOI must not succeed');
        } catch (System.QueryException e) {
            Assert.isNotNull(e, 'The parent load runs before the direction check, so a missing row '
                + 'surfaces the native QueryException');
        } catch (CounterOfferService.CounterOfferException e) {
            Assert.fail('The direction must be validated AFTER the parent is loaded, because the '
                + 'valid tokens are keyed by record type. A CounterOfferException here means the '
                + 'check ran first and the label could again be taken from the caller. Message: '
                + e.getMessage());
        }
        Test.stopTest();
    }
}
