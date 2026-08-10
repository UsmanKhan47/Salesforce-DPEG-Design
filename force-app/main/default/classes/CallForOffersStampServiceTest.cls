/**
 * Tests for CallForOffersStampService — Broker Protection's ONLY Opportunity writer
 * (Tranche 4B, 2026-08-10; decisions D3 / D8 / D26).
 *
 * WHAT IS ASSERTED, AND WHY IT IS THE DECISION RATHER THAN THE ENVIRONMENT:
 *   • the OVERWRITE rule (last email wins, per field, never with null);
 *   • the NO-CHANGE SKIP, which is the idempotency guarantee — asserted on the returned
 *     `unchanged` list AND on `Limits.getDmlStatements()`, because "it wrote the same value
 *     again" and "it skipped" are indistinguishable from stored state alone;
 *   • the CONSTANT governor shape (1 SOQL, <= 1 DML) regardless of how many deals matched;
 *   • per-record de-duplication, which is not cosmetic: two properties in one email can fuzzy
 *     match the same registry row, and a duplicate Id in a `Database.update` list throws
 *     `DUPLICATE_VALUE` for the WHOLE statement — `allOrNone = false` does not rescue that;
 *   • field-length/format handling on the two Text/Email destinations;
 *   • partial success — one refused row must not take its siblings with it;
 *   • EXHAUSTIVENESS of the four result populations (added 2026-08-10, review finding S4): a
 *     requested deal the read did not return is reported in `missing`, because it can produce
 *     no `SaveResult` and therefore no refusal — without it, a stamp that never happened was
 *     reported by the caller as `— deal updated`.
 *
 * ⚠ WHAT IS DELIBERATELY *NOT* ASSERTED, RECORDED SO REVIEW DOES NOT ASK FOR IT:
 *
 *   1. NO `System.runAs` FLS/SHARING TEST. The write is `AccessLevel.SYSTEM_MODE` on a
 *      `with sharing` class against an OWD-`ReadWrite` object, so there is no persona for
 *      which it fails — a runAs test would pass identically whatever the mode was, i.e. it
 *      would be unfalsifiable. The sharing proof is post-deploy gate G5, run AS THE PIPELINE
 *      PRINCIPAL, not as an admin.
 *   2. NO `ENTITY_IS_LOCKED` TEST. An approval lock cannot be manufactured inside `@isTest`
 *      here, and asserting a StatusCode this repo has never captured is exactly the mistake
 *      recorded for the converted-Lead lookup. The REFUSAL-HANDLING behaviour is proven
 *      instead through a deleted-Id row, which produces a real `Database.SaveResult` failure
 *      through the identical code path — what matters is that a failure is RETURNED durably
 *      and does not roll its siblings back, and that is mechanism-independent.
 *
 * NO ContentVersion, no ContentNote, no ContentDocument anywhere in this class
 * (`.claude/rules/content-publication-rule.md` is not engaged at all).
 *
 * BULK: `.claude/rules/bulk-test-rule.md`'s 251 mandate does not bind this class's volume,
 * for a reason that is structural rather than convenient — `ExtractAddressQueueable` caps one
 * email at `MAX_PROPERTIES = 10`, and this service is called exactly ONCE per email, so 10 IS
 * the production ceiling for a single call. A 251-request test would encode a state production
 * cannot produce, the anti-pattern that rule's own exemption exists to prevent. The constancy
 * property (1 SOQL / <= 1 DML at N = 10) is asserted instead, which is what would actually
 * catch a bulkification regression.
 */
@isTest
private class CallForOffersStampServiceTest {

    private static final Date DUE = Date.today().addDays(14);

    /** One request, fully populated unless a caller nulls a field afterwards. */
    private static CallForOffersStampService.StampRequest request(
            Id recordId, Date offerDueDate, String brokerName, String brokerEmail) {
        CallForOffersStampService.StampRequest req = new CallForOffersStampService.StampRequest();
        req.recordId = recordId;
        req.offerDueDate = offerDueDate;
        req.listingBrokerName = brokerName;
        req.listingBrokerEmail = brokerEmail;
        return req;
    }

    private static Opportunity reload(Id recordId) {
        return [
            SELECT Id, Offer_Due_Date__c, Listing_Broker_Name__c, Listing_Broker_Email__c
            FROM Opportunity WHERE Id = :recordId
        ];
    }

    // ── The happy path ───────────────────────────────────────────────────────

    @isTest
    static void stamp_blankDeal_writesAllThreeFields() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid')
            });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The one deal must be stamped');
        Assert.areEqual(deal.Id, result.stamped[0], '');
        Assert.areEqual(0, result.refusals.size(), 'A blank, unlocked deal refuses nothing');
        Assert.areEqual(0, result.unchanged.size(), 'and nothing was already current');

        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c, 'The offer deadline is the point of the feature');
        Assert.areEqual('Pat Lister', stamped.Listing_Broker_Name__c, '');
        Assert.areEqual('pat.lister@example.invalid', stamped.Listing_Broker_Email__c, '');
    }

    // ── The overwrite rule ───────────────────────────────────────────────────

    @isTest
    static void stamp_existingDate_isOVERWRITTENByTheNewerEmail() {
        // 🔴 THE DECISION, PINNED. A call-for-offers deadline is a fact that CHANGES
        // ("deadline extended to Friday"), and the newest email is the authority. If this ever
        // starts asserting fill-if-blank, an extension has become invisible to whoever reads
        // the Offers Due Soon list view — and the deferred T-2 notification would fire on the
        // stale date. The value being overwritten here is the shape LeadConvertService leaves
        // behind (it copies Lead.Offer_Due_Date__c onto the Opportunity at conversion), which
        // is the single most common way a stamped deal already has a date.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        deal.Listing_Broker_Name__c = 'Old Listing Broker';
        deal.Listing_Broker_Email__c = 'old@example.invalid';
        insert deal;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, 'New Listing Broker', 'new@example.invalid')
            });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The deal must be updated, not skipped');
        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c,
            'LAST EMAIL WINS. Fill-if-blank would freeze the first deadline and make an extension '
            + 'invisible — including to the deferred T-2 notification');
        Assert.areEqual('New Listing Broker', stamped.Listing_Broker_Name__c, '');
        Assert.areEqual('new@example.invalid', stamped.Listing_Broker_Email__c, '');
    }

    @isTest
    static void stamp_nullIncomingValues_neverBlankWhatIsAlreadyThere() {
        // The other half of the rule, and the half that protects real data: an email that says
        // nothing about the broker must not ERASE a broker the deal already knows. Mirrors U1's
        // and applyPropertyBlock's fill-if-present discipline.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        deal.Listing_Broker_Name__c = 'Keep Me';
        deal.Listing_Broker_Email__c = 'keep.me@example.invalid';
        insert deal;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, null, null)
            });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The date alone is a change, so the row is written');
        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c, 'The non-null value still overwrites');
        Assert.areEqual('Keep Me', stamped.Listing_Broker_Name__c,
            'A null incoming value means "this email said nothing about it", NEVER "clear it"');
        Assert.areEqual('keep.me@example.invalid', stamped.Listing_Broker_Email__c, '');
    }

    @isTest
    static void stamp_allValuesNull_writesNothingAtAll() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, null, null, null)
            });
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, result.stamped.size(), 'There is nothing to stamp');
        Assert.areEqual(1, result.unchanged.size(), 'and the deal is reported as unchanged, not refused');
        Assert.areEqual(dmlBefore, dmlAfter,
            'ZERO DML. A matched deal that the email says nothing new about must not have its '
            + 'LastModifiedDate churned');
    }

    // ── Idempotency ──────────────────────────────────────────────────────────

    @isTest
    static void stamp_replayedWithIdenticalValues_isAZeroDmlNoOp() {
        // 🔴 THE IDEMPOTENCY GUARANTEE. A platform redelivery, or the same campaign email sent
        // twice, must cost nothing. Asserted on DML COUNT and not only on stored state, because
        // "wrote the same value again" and "skipped" leave identical rows behind.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        List<CallForOffersStampService.StampRequest> requests =
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid')
            };

        Test.startTest();
        CallForOffersStampService.StampResult first = CallForOffersStampService.stamp(requests);

        Integer dmlBefore = Limits.getDmlStatements();
        CallForOffersStampService.StampResult second = CallForOffersStampService.stamp(requests);
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(1, first.stamped.size(), 'Precondition: the first pass really did write');
        Assert.areEqual(0, second.stamped.size(), 'The replay must write nothing');
        Assert.areEqual(1, second.unchanged.size(), 'and must report the deal as already current');
        Assert.areEqual(dmlBefore, dmlAfter,
            'THE LOAD-BEARING ASSERTION: a replay consumes ZERO DML statements. If this fails, '
            + 'the no-change skip has been removed and every redelivery now churns a live deal');
    }

    // ── De-duplication ───────────────────────────────────────────────────────

    @isTest
    static void stamp_twoPropertiesResolvingToOneDeal_isOneRowNotADuplicateIdFailure() {
        // 🔴 NOT COSMETIC. Two addresses in one email can fuzzy-match the SAME registry row and
        // therefore the same deal. A duplicate Id inside one Database.update list throws
        // DUPLICATE_VALUE ("duplicate id in list") for the WHOLE statement, and allOrNone=false
        // does not rescue it — so without the merge, a two-property blast about one asset would
        // stamp NOTHING and report a refusal no reader could interpret.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid'),
                request(deal.Id, DUE.addDays(1), 'Someone Else', 'someone.else@example.invalid')
            });
        Test.stopTest();

        Assert.areEqual(0, result.refusals.size(),
            'A duplicate Id must never reach the DML statement. Refusals: ' + result.refusals);
        Assert.areEqual(1, result.stamped.size(), 'One deal, one row, one stamp');

        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c,
            'Merging is FILL-IF-PRESENT in list order, so the FIRST non-null value wins. The '
            + 'caller supplies requests in its deterministic cluster-key processing order, so '
            + 'this is deterministic rather than merely arbitrary');
        Assert.areEqual('Pat Lister', stamped.Listing_Broker_Name__c, '');
    }

    @isTest
    static void stamp_mergesFieldByField_notWholeRequest() {
        // A partially-populated first request must not shadow a later one's other fields.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, null, null),
                request(deal.Id, DUE.addDays(5), 'Late Broker', 'late@example.invalid')
            });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), '');
        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c, 'The first non-null date wins');
        Assert.areEqual('Late Broker', stamped.Listing_Broker_Name__c,
            'but a field the first request left blank is filled from the second — the merge is '
            + 'PER FIELD, not per request');
        Assert.areEqual('late@example.invalid', stamped.Listing_Broker_Email__c, '');
    }

    // ── Input hygiene ────────────────────────────────────────────────────────

    @isTest
    static void stamp_nullAndEmptyInput_returnEmptyResultsAndNoQueries() {
        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        CallForOffersStampService.StampResult forNull = CallForOffersStampService.stamp(null);
        CallForOffersStampService.StampResult forEmpty = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>());
        Integer soqlAfter = Limits.getQueries();
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, forNull.stamped.size(), 'Null in, empty result out — never an NPE');
        Assert.areEqual(0, forEmpty.stamped.size(), '');
        Assert.areEqual(soqlBefore, soqlAfter,
            'AN ALL-UNMATCHED CALL-FOR-OFFERS BLAST MUST COST NOTHING. This short-circuit is why '
            + 'the branch is exactly as cheap as it was before Tranche 4B when nothing matched');
        Assert.areEqual(dmlBefore, dmlAfter, '');
    }

    @isTest
    static void stamp_nonOpportunityAndNullIds_areDroppedNotThrown() {
        // Q1 scoped this feature to Opportunity only. A Lead Id arriving here would be a caller
        // defect, and a caller defect must not become a DML failure on a live inbound email.
        Lead notADeal = TestDataFactory.createLead(true);
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                null,
                request(null, DUE, 'Ghost', 'ghost@example.invalid'),
                request(notADeal.Id, DUE, 'Wrong Object', 'wrong@example.invalid'),
                request(deal.Id, DUE, 'Right Object', 'right@example.invalid')
            });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'Only the Opportunity is stamped');
        Assert.areEqual(deal.Id, result.stamped[0], '');
        Assert.areEqual(0, result.refusals.size(), 'and nothing is refused — the junk never reached the DML');
        Assert.isNull([SELECT Offer_Due_Date__c FROM Lead WHERE Id = :notADeal.Id].Offer_Due_Date__c,
            '🔴 Q1 = OPPORTUNITY ONLY. Lead.Offer_Due_Date__c exists and is DELIBERATELY not written');
    }

    // ── Field length / format ────────────────────────────────────────────────

    @isTest
    static void stamp_overLongBrokerName_isClippedToTheFieldsRealLength() {
        // Listing_Broker_Name__c is Text(120), NOT 255. ⚠ CORRECTED 2026-08-10 (review finding
        // W1): this comment used to justify the clip by "this service also accepts the
        // U1-resolved ENVELOPE sender name, which comes off From_Name__c (Text(255))". That
        // envelope fallback was REMOVED from ExtractAddressQueueable.routeCallForOffers, so
        // every value reaching this service today is already clipped to 120 by its caller. The
        // clip stays because that is a property of TODAY'S CALLERS, not of this service — the
        // first caller that arrives without one turns a 121-character display name into a
        // STRING_TOO_LONG on a live deal, and this test is what keeps the guard honest.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        String tooLong = 'N'.repeat(200);

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, tooLong, 'ok@example.invalid')
            });
        Test.stopTest();

        Assert.areEqual(0, result.refusals.size(),
            'A long broker name must never refuse the stamp. Refusals: ' + result.refusals);
        Assert.areEqual(120, reload(deal.Id).Listing_Broker_Name__c.length(),
            'Clipped to the DESTINATION length (120), not to 255');
    }

    @isTest
    static void stamp_malformedBrokerEmail_isDroppedRatherThanRefusingTheWholeRow() {
        // Listing_Broker_Email__c is an Email field, so a malformed value is an
        // INVALID_EMAIL_ADDRESS that would refuse the entire row — taking the offer deadline,
        // the one thing this feature exists to deliver, down with it.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, 'Pat Lister', 'not an email at all')
            });
        Test.stopTest();

        Assert.areEqual(0, result.refusals.size(),
            'The row must still save. Refusals: ' + result.refusals);
        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c, 'THE DEADLINE STILL LANDS — that is the point');
        Assert.isNull(stamped.Listing_Broker_Email__c, 'and the unusable address is simply not written');
    }

    // ── Partial success ──────────────────────────────────────────────────────

    @isTest
    static void stamp_oneRefusedRow_doesNotRollBackItsSiblings() {
        // 🔴 THE allOrNone = false CONTRACT — the reason this class exists in the shape it does.
        //
        // In production the refusal is ENTITY_IS_LOCKED: a deal sitting under
        // Underwriting_Approval or LOI_Approval, both recordEditability = AdminOnly, which
        // AccessLevel.SYSTEM_MODE does NOT unlock (measured in this repo — see
        // OpportunityReviewService's LOI block). That state cannot be manufactured in @isTest.
        //
        // A DELETED record produces a genuine Database.SaveResult failure through the IDENTICAL
        // code path — but only if the row was still READABLE when the decision was taken, which
        // is exactly what a lock does and a plain delete does not (the selector would simply not
        // return it, and the refusal would never happen). The `simulateReadResult` seam supplies
        // that snapshot. NOTHING ABOUT THE WRITE IS FAKED: the Database.update, the SaveResult
        // loop, the partial success and describeRefusal are all real. Only the read is seamed.
        Opportunity healthy = TestDataFactory.createOpportunity(null, true);
        Opportunity doomed = TestDataFactory.createOpportunity(null, true);
        Id doomedId = doomed.Id;

        // The snapshot the selector WOULD have returned, taken while both rows were live.
        List<Opportunity> snapshot = [
            SELECT Id, Offer_Due_Date__c, Listing_Broker_Name__c, Listing_Broker_Email__c
            FROM Opportunity WHERE Id IN :new List<Id>{ healthy.Id, doomedId } ORDER BY Id
        ];
        delete doomed;

        Test.startTest();
        CallForOffersStampService.simulateReadResult = snapshot;
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(healthy.Id, DUE, 'Healthy Broker', 'healthy@example.invalid'),
                request(doomedId, DUE, 'Doomed Broker', 'doomed@example.invalid')
            });
        CallForOffersStampService.simulateReadResult = null;
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(),
            'THE SIBLING MUST SURVIVE. With allOrNone = true the whole statement would roll back, '
            + 'and one locked deal would silently cost every other deal in the same email its '
            + 'stamp — and would take the caller\'s already-committed Task and staging stamp too');
        Assert.areEqual(healthy.Id, result.stamped[0], '');
        Assert.areEqual(1, result.refusals.size(), 'and the failure is RETURNED, never swallowed');
        Assert.isTrue(result.refusals[0].contains(String.valueOf(doomedId)),
            'The refusal must NAME the record — a human triaging Error__c on the staging row has '
            + 'nothing else to go on. Actual: ' + result.refusals[0]);
        Assert.isTrue(result.refusals[0].contains('stamp refused'),
            'and must be recognisable in a joined Error__c blob. Actual: ' + result.refusals[0]);
        Assert.areEqual(DUE, reload(healthy.Id).Offer_Due_Date__c,
            'and the surviving stamp is really committed, not merely reported');
    }

    @isTest
    static void stamp_requestedDealTheReadDidNotReturn_isReportedAsMissing() {
        // 🔴 THE FOURTH POPULATION (added 2026-08-10, review finding S4). Before it, a requested
        // Id the selector did not return fell out of stamped, unchanged AND refusals — while the
        // caller's outcome label still read '— deal updated'. A stamp that provably never
        // happened, reported as a success, with nothing anywhere to contradict it.
        //
        // ⚠ IT CANNOT BE COVERED BY THE REFUSAL PATH, WHICH IS THE WHOLE REASON IT EXISTS: a
        // refusal needs a Database.SaveResult, and a row the read never returned is never put
        // into the DML at all. The production shape is the selector header's Private-OWD
        // residual — a `with sharing` read returning zero rows for a pipeline principal who owns
        // no deals — which cannot be manufactured here (Opportunity OWD is ReadWrite and G5 is
        // the real proof), so the simulateReadResult seam supplies the identical INPUT: a
        // snapshot that is missing one of the two requested rows. Everything downstream is real.
        Opportunity present = TestDataFactory.createOpportunity(null, true);
        Opportunity absent = TestDataFactory.createOpportunity(null, true);

        List<Opportunity> partialSnapshot = [
            SELECT Id, Offer_Due_Date__c, Listing_Broker_Name__c, Listing_Broker_Email__c
            FROM Opportunity WHERE Id = :present.Id
        ];

        Test.startTest();
        CallForOffersStampService.simulateReadResult = partialSnapshot;
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(present.Id, DUE, 'Present Broker', 'present@example.invalid'),
                request(absent.Id, DUE, 'Absent Broker', 'absent@example.invalid')
            });
        CallForOffersStampService.simulateReadResult = null;
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(),
            'The readable deal is still stamped — an unreadable sibling costs it nothing');
        Assert.areEqual(present.Id, result.stamped[0], '');
        Assert.areEqual(0, result.refusals.size(),
            'and nothing was REFUSED — there was no SaveResult to refuse, which is exactly why '
            + 'refusals could never have caught this. Actual: ' + result.refusals);
        Assert.areEqual(0, result.unchanged.size(), '');

        Assert.areEqual(1, result.missing.size(),
            '🔴 THE LOAD-BEARING ASSERTION: the unreadable deal is REPORTED. Delete the missing '
            + 'population and this email goes back to reporting "— deal updated" for a deal it '
            + 'never touched. Actual: ' + result.missing);
        Assert.isTrue(result.missing[0].contains(String.valueOf(absent.Id)),
            'and it must NAME the deal — the caller funnels this into Error__c, where a human '
            + 'triaging the staging row has nothing else to go on. Actual: ' + result.missing[0]);
        Assert.isNull(reload(absent.Id).Offer_Due_Date__c,
            'Precondition: nothing was written to the deal the read did not return');
    }

    @isTest
    static void stamp_everyRequestedIdLandsInExactlyOnePopulation() {
        // The EXHAUSTIVENESS claim in StampResult's Javadoc, asserted rather than promised —
        // that claim is what makes "the outcome label describes the match, not the write" safe
        // to rely on. Three requested deals, three different fates in ONE call: one written, one
        // already current (the no-change skip), one not read back at all.
        Opportunity toWrite = TestDataFactory.createOpportunity(null, true);
        Opportunity alreadyCurrent = TestDataFactory.createOpportunity(null, false);
        alreadyCurrent.Offer_Due_Date__c = DUE;
        insert alreadyCurrent;
        Opportunity unreadable = TestDataFactory.createOpportunity(null, true);

        List<Opportunity> snapshot = [
            SELECT Id, Offer_Due_Date__c, Listing_Broker_Name__c, Listing_Broker_Email__c
            FROM Opportunity WHERE Id IN :new List<Id>{ toWrite.Id, alreadyCurrent.Id }
        ];

        Test.startTest();
        CallForOffersStampService.simulateReadResult = snapshot;
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(toWrite.Id, DUE, null, null),
                request(alreadyCurrent.Id, DUE, null, null),
                request(unreadable.Id, DUE, null, null)
            });
        CallForOffersStampService.simulateReadResult = null;
        Test.stopTest();

        Assert.areEqual(new List<Id>{ toWrite.Id }, result.stamped, '');
        Assert.areEqual(new List<Id>{ alreadyCurrent.Id }, result.unchanged,
            'The deal that already carried the deadline is the no-change skip, not a write');
        Assert.areEqual(0, result.refusals.size(), '');
        Assert.areEqual(1, result.missing.size(), '');
        Assert.areEqual(3,
            result.stamped.size() + result.unchanged.size()
                + result.refusals.size() + result.missing.size(),
            '🔴 EVERY REQUESTED ID IS ACCOUNTED FOR EXACTLY ONCE. If this sum ever drops below '
            + 'the number of requests, some deal has gone missing silently — which is precisely '
            + 'the defect the fourth population was added to close');
    }

    @isTest
    static void stamp_simulateStampFailure_throwsAndNamesTheRecords() {
        // Seam #1's own coverage. Its REAL proof is at the queueable level
        // (ExtractAddressQueueableTest.callForOffers_stampThrows_stillReachesFinishAndLogsTheTask),
        // where it establishes the redelivery contract; here it only confirms the message names
        // the records, which is what makes that test's Error__c assertion meaningful.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        CallForOffersStampService.simulateStampFailure = true;
        try {
            CallForOffersStampService.stamp(
                new List<CallForOffersStampService.StampRequest>{
                    request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid')
                });
            Assert.fail('The seam must throw');
        } catch (DmlException e) {
            Assert.isTrue(e.getMessage().contains(String.valueOf(deal.Id)),
                'The simulated failure must name the records it was asked to stamp, so the '
                + 'caller\'s Error__c genuinely identifies the deal. Actual: ' + e.getMessage());
        }
        CallForOffersStampService.simulateStampFailure = false;
        Test.stopTest();

        Assert.isNull(reload(deal.Id).Offer_Due_Date__c,
            'and nothing was written — the seam throws BEFORE any read or write');
    }

    // ── Governor shape ───────────────────────────────────────────────────────

    @isTest
    static void stamp_tenDeals_costsExactlyOneQueryAndOneDml() {
        // 🔴 THE CONSTANCY PROPERTY, WHICH IS THE POINT — not the number ten. Ten is
        // ExtractAddressQueueable.MAX_PROPERTIES, i.e. the real production ceiling for one
        // email. A future change that reads or writes per deal fails HERE, before it fails in
        // the queueable's own pinned call-for-offers budget, and long before production.
        List<Opportunity> deals = TestDataFactory.createOpportunities(10, true);
        List<CallForOffersStampService.StampRequest> requests =
            new List<CallForOffersStampService.StampRequest>();
        for (Opportunity deal : deals) {
            requests.add(request(deal.Id, DUE, 'Blast Broker', 'blast@example.invalid'));
        }

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(requests);
        Integer soqlAfter = Limits.getQueries();
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(10, result.stamped.size(), 'All ten deals are stamped');
        Assert.areEqual(1, soqlAfter - soqlBefore,
            'EXACTLY ONE query for ten deals, CONSTANT in the number of matched deals');
        Assert.areEqual(1, dmlAfter - dmlBefore,
            'and EXACTLY ONE DML statement, likewise constant');
    }
}
