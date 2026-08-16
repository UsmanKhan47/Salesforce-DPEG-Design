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
 *
 * ⚠ 2026-08-12 — Sale_Process__c JOINED THE STAMP SET (Defect 4,
 * agent-output/design-requirements-pipeline-defects.md). A new "Sale_Process__c" section near
 * the bottom mirrors the OVERWRITE / null-preserves / no-change-skip tests already pinned above
 * for `Offer_Due_Date__c`, and adds ONE test this field alone needs:
 * `stamp_saleProcessOffListValue_isDroppedButTheRestOfTheRowStillStamps`, which uses the new
 * `simulateSaleProcessValues` seam — the ONLY way the restricted-picklist describe guard can be
 * made to fire in a test, because every value reaching `buildChange` through the real pipeline
 * has already been validated against `Lead.Sale_Process__c`, which is byte-identical to
 * `Opportunity.Sale_Process__c` today.
 *
 * ⚠ 2026-08-14 — `Call_For_Offers_Received_Date__c` JOINED THE STAMP SET. Its own section mirrors
 * the same three shared guards again (overwrite / null-preserves / no-change-skip) and adds ONE
 * test no other field here needs: `stamp_receivedDate_isPerEmailSoTheMergeHasNothingToChooseBetween`
 * pins that this value is PER EMAIL while its neighbours are per property. It needs no seam and
 * no describe guard — it is a Date, so there is no value set for it to be off.
 *
 * 🔴 ONE PRE-EXISTING CLAIM IN THIS CLASS IS NOW NARROWER BY EXACTLY ONE DAY, AND IT IS DELIBERATE.
 * `stamp_replayedWithIdenticalValues_isAZeroDmlNoOp` is UNMODIFIED and still passes, because a
 * replayed request carries a replayed date. What changed is the production shape behind it: the
 * caller falls back to the pipeline's own receipt date when an email states no send time, so the
 * SAME campaign email arriving again on a LATER DAY now costs one DML rather than zero. That is a
 * second arrival being recorded, not churn — see `CallForOffersStampService`'s header, which
 * amends the claim in place rather than leaving it standing.
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
            SELECT Id, Offer_Due_Date__c, Listing_Broker_Name__c, Listing_Broker_Email__c,
                   Sale_Process__c, Call_For_Offers_Received_Date__c
            FROM Opportunity WHERE Id = :recordId
        ];
    }

    // ── The happy path ───────────────────────────────────────────────────────

    @isTest
    static void stamp_blankDeal_writesAllFiveFields() {
        // ⚠ RENAMED TWICE, AND THE RULE BEHIND BOTH RENAMES IS THE POINT: the happy-path test
        // must exercise EVERY field the service writes, or it becomes the one place in this class
        // that quietly lags the stamp set. It was "...writesAllThreeFields" until Sale_Process__c
        // joined on 2026-08-12 (code review S1), and "...writesAllFourFields" until
        // Call_For_Offers_Received_Date__c joined on 2026-08-14. The service now writes FIVE
        // fields on a blank deal.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        Date received = Date.today().addDays(-1);

        CallForOffersStampService.StampRequest req =
            request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid');
        req.saleProcess = 'Call for Offers'; // an ACTIVE Opportunity.Sale_Process__c value —
        // see stamp_saleProcessOnListValue_isWrittenAgainstTheRealLiveDescribe below, which
        // proves this exact value against the real live describe, not a simulated set.
        req.callForOffersReceivedDate = received;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The one deal must be stamped');
        Assert.areEqual(deal.Id, result.stamped[0], '');
        Assert.areEqual(0, result.refusals.size(), 'A blank, unlocked deal refuses nothing');
        Assert.areEqual(0, result.unchanged.size(), 'and nothing was already current');

        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c, 'The offer deadline is the point of the feature');
        Assert.areEqual('Pat Lister', stamped.Listing_Broker_Name__c, '');
        Assert.areEqual('pat.lister@example.invalid', stamped.Listing_Broker_Email__c, '');
        Assert.areEqual('Call for Offers', stamped.Sale_Process__c,
            'THE FOURTH FIELD: Sale_Process__c joined the stamp set 2026-08-12 and belongs in the '
            + 'happy-path test alongside the other three, not only in the dedicated Sale_Process__c '
            + 'section further down this class');
        Assert.areEqual(received, stamped.Call_For_Offers_Received_Date__c,
            'THE FIFTH FIELD: Call_For_Offers_Received_Date__c joined 2026-08-14, on the same '
            + 'terms — it belongs here as well as in its own section below');
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

    // ── Sale_Process__c (Defect 4, added 2026-08-12) ─────────────────────────
    //
    // MEASURED: after a call-for-offers stamp, Opportunity.Sale_Process__c still read
    // 'Off-Market' while the very extraction that produced the stamp returned
    // sale_process = 'Call for Offers'. Sale_Process__c joins the LAST-WINS set (the deadline's
    // rule, not the listing broker's — see buildChange's own comment for the argument) and
    // carries ONE guard the other three stamped fields do not need: it is a RESTRICTED
    // picklist, so it is describe-guarded against the LIVE Opportunity.Sale_Process__c value
    // set rather than a hardcoded list.

    @isTest
    static void stamp_saleProcess_isOverwrittenByTheNewerEmail() {
        // The overwrite half of the rule, mirroring stamp_existingDate_isOVERWRITTENByTheNewerEmail
        // for the field this fix adds. 'Off-Market' is what LeadConvertService would have carried
        // onto the deal at conversion; a later call-for-offers email is newer information that the
        // seller has since moved the asset to a marketed process, and the deal must not keep
        // contradicting what the pipeline now knows.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Sale_Process__c = 'Off-Market';
        insert deal;

        CallForOffersStampService.StampRequest req = request(deal.Id, DUE, null, null);
        req.saleProcess = 'Call for Offers';

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The date alone would be a change; the sale process changes too');
        Assert.areEqual('Call for Offers', reload(deal.Id).Sale_Process__c,
            'LAST-WINS: a deal reading Off-Market while this pipeline holds an email announcing a '
            + 'call for offers is actively misleading the deal team — the same "campaign fact that '
            + 'changes" argument as the offer deadline, not the listing broker\'s fill-if-present one');
    }

    @isTest
    static void stamp_saleProcessNullIncoming_neverErasesWhatTheDealAlreadyKnows() {
        // The other half of the rule, mirroring stamp_nullIncomingValues_neverBlankWhatIsAlreadyThere:
        // an email that says nothing about sale_process must not blank a value the deal already has.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Sale_Process__c = 'On-Market Listing';
        insert deal;

        CallForOffersStampService.StampRequest req = request(deal.Id, DUE, null, null); // the date forces a write
        req.saleProcess = null;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The deadline alone is a change, so the row is written');
        Assert.areEqual('On-Market Listing', reload(deal.Id).Sale_Process__c,
            'A null incoming sale_process means "this email said nothing about it", NEVER "clear it"');
    }

    @isTest
    static void stamp_saleProcessUnchanged_isDroppedFromTheNoChangeSkip() {
        // The idempotency half, mirroring stamp_replayedWithIdenticalValues_isAZeroDmlNoOp for this
        // one field in isolation: a request whose sale_process already matches the stored value must
        // not, by itself, cost the deal a write.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Sale_Process__c = 'Call for Offers';
        insert deal;

        CallForOffersStampService.StampRequest req = new CallForOffersStampService.StampRequest();
        req.recordId = deal.Id;
        req.saleProcess = 'Call for Offers';

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(1, result.unchanged.size(),
            'Nothing this email carries is new to the deal, including the sale process');
        Assert.areEqual(dmlBefore, dmlAfter,
            'ZERO DML. A field-by-field no-change skip must hold for THIS field too, or a replayed '
            + 'call-for-offers email starts churning LastModifiedDate on a live deal again');
    }

    @isTest
    static void stamp_saleProcessOffListValue_isDroppedButTheRestOfTheRowStillStamps() {
        // 🔴 THE DESCRIBE GUARD, MADE FALSIFIABLE. Every value that reaches buildChange has
        // already been validated by LLMExtractionParser against Lead.Sale_Process__c, and the
        // Lead and Opportunity picklists are byte-identical TODAY — so no input reachable
        // through the real pipeline can be off-list, the guard never fires on a real email, and
        // no test could otherwise tell "the guard works" from "there is no guard". Injecting a
        // set that OMITS 'Call for Offers' and then supplying exactly that value makes the drop
        // OBSERVABLE. This is the ONLY test in this class that uses simulateSaleProcessValues.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        CallForOffersStampService.StampRequest req =
            request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid');
        req.saleProcess = 'Call for Offers';

        Test.startTest();
        CallForOffersStampService.simulateSaleProcessValues = new Set<String>{
            'Off-Market', 'On-Market Listing', 'Auction' // 'Call for Offers' deliberately OMITTED
        };
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        CallForOffersStampService.simulateSaleProcessValues = null;
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(),
            'THE WHOLE POINT: one bad picklist value must not cost the row the rest of its stamp');
        Assert.areEqual(0, result.refusals.size(),
            'The guard drops the value BEFORE the DML, so there is nothing to refuse. Refusals: '
            + result.refusals);

        Opportunity stamped = reload(deal.Id);
        Assert.isNull(stamped.Sale_Process__c,
            '🔴 THE LOAD-BEARING ASSERTION: an off-list value is DROPPED rather than pushed to the '
            + 'DML, where it would fail INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and take the '
            + 'deadline and listing-broker stamp down with it in the same row');
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c,
            'AND THE DEADLINE STILL LANDS — a dropped Sale_Process__c must not touch either of the '
            + 'other two fields in the same StampRequest');
        Assert.areEqual('Pat Lister', stamped.Listing_Broker_Name__c, '');
    }

    @isTest
    static void stamp_saleProcessOnListValue_isWrittenAgainstTheRealLiveDescribe() {
        // The seam's counterpart, WITHOUT it: proves the guard's normal path (the real
        // Opportunity.Sale_Process__c describe, not a simulated set) accepts a genuine value.
        // simulateSaleProcessValues is left untouched/null here on purpose.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        CallForOffersStampService.StampRequest req =
            request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid');
        req.saleProcess = 'Auction';

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), '');
        Assert.areEqual(0, result.refusals.size(), '');
        Assert.areEqual('Auction', reload(deal.Id).Sale_Process__c,
            'Against the REAL live picklist (no seam active), a genuine value is written normally');
    }

    // ── Call_For_Offers_Received_Date__c (2026-08-14) ────────────────────────
    //
    // The field replaces a DERIVED PROXY on the read side (`CallForOffersService` header §4), so
    // the tests below pin the three shared guards for it exactly as the Sale_Process__c section
    // above does — plus the one thing this field alone needs, which is the direction of its
    // overwrite. It carries no describe guard and needs none: it is a Date, so there is no value
    // set for it to be off.

    @isTest
    static void stamp_receivedDate_isWrittenOntoABlankDeal() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        Date received = Date.today().addDays(-1);

        CallForOffersStampService.StampRequest req =
            request(deal.Id, DUE, 'Pat Lister', 'pat.lister@example.invalid');
        req.callForOffersReceivedDate = received;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The deal must be stamped');
        Assert.areEqual(received, reload(deal.Id).Call_For_Offers_Received_Date__c,
            'THE REAL VALUE, STORED. Before this field existed the surface derived a "received '
            + 'date" from Broker_First_Seen__c/CreatedDate — a fact about the DEAL, not the email');
    }

    @isTest
    static void stamp_receivedDate_isOVERWRITTENByTheNewerEmail() {
        // 🔴 THE DIRECTION, PINNED, AND IT IS NOT INHERITED FROM THE DEADLINE'S ARGUMENT.
        // The deadline is last-wins because it CHANGES ("extended to Friday"). A received date
        // does not change — a NEW EMAIL simply has a new one. What forces last-wins here is that
        // the two are read AS A PAIR: under fill-if-blank this deal would report the September
        // deadline it is about to receive as having arrived back in June, and the column that
        // exists to answer "how fresh is this?" would answer it wrongly. If this test is ever
        // rewritten to assert fill-if-blank, that is the property being given up.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Call_For_Offers_Received_Date__c = Date.today().addDays(-60);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        insert deal;

        Date newer = Date.today();
        CallForOffersStampService.StampRequest req = request(deal.Id, DUE, null, null);
        req.callForOffersReceivedDate = newer;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The row is written, not skipped');
        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(newer, stamped.Call_For_Offers_Received_Date__c,
            'LAST EMAIL WINS — the received date must move with the deadline it arrived beside');
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c,
            'and the pair moves TOGETHER, which is the whole reason this field is last-wins');
    }

    @isTest
    static void stamp_receivedDateNullIncoming_neverErasesWhatTheDealAlreadyKnows() {
        // The second shared guard. A caller that could derive no arrival date for this email must
        // not blank one an earlier email established.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        Date known = Date.today().addDays(-9);
        deal.Call_For_Offers_Received_Date__c = known;
        insert deal;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{
                request(deal.Id, DUE, null, null)   // callForOffersReceivedDate left null
            });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(), 'The date alone is a change, so the row is written');
        Assert.areEqual(known, reload(deal.Id).Call_For_Offers_Received_Date__c,
            'A null incoming value means "this email carried no arrival date", NEVER "clear it"');
    }

    @isTest
    static void stamp_receivedDateUnchanged_isDroppedByTheNoChangeSkip() {
        // The third shared guard, and the one that keeps replay free. Asserted on DML COUNT as
        // well as on stored state, because "wrote the same date again" and "skipped" leave
        // identical rows behind — the whole reason the other idempotency tests in this class
        // measure the counter.
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        Date received = Date.today().addDays(-3);
        deal.Call_For_Offers_Received_Date__c = received;
        deal.Offer_Due_Date__c = DUE;
        insert deal;

        CallForOffersStampService.StampRequest req = request(deal.Id, DUE, null, null);
        req.callForOffersReceivedDate = received;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ req });
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, result.stamped.size(), 'Nothing about this email is new to this deal');
        Assert.areEqual(1, result.unchanged.size(), 'so it is reported as unchanged, not refused');
        Assert.areEqual(dmlBefore, dmlAfter,
            'and it costs ZERO DML. An email that states its own send time replays to the byte, '
            + 'so this is the shape a RoutingRetrySweepBatch replay takes');
    }

    @isTest
    static void stamp_receivedDate_isPerEmailSoTheMergeHasNothingToChooseBetween() {
        // ⚠ THE ONE ASYMMETRY IN THIS CLASS, PINNED. offerDueDate and saleProcess are PER
        // PROPERTY — a portfolio blast can quote a different deadline per asset — but an email
        // has exactly ONE arrival time, so the caller sets the identical value on every request.
        // Two properties fuzzy-matching the SAME deal is the case that would otherwise force a
        // choice; here there is nothing to choose, and the merge must still collapse them to ONE
        // row (a duplicate Id in one Database.update throws DUPLICATE_VALUE for the whole
        // statement, which allOrNone = false does not rescue).
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        Date received = Date.today().addDays(-4);

        CallForOffersStampService.StampRequest first = request(deal.Id, DUE, null, null);
        first.callForOffersReceivedDate = received;
        CallForOffersStampService.StampRequest second =
            request(deal.Id, null, 'Pat Lister', null);
        second.callForOffersReceivedDate = received;

        Test.startTest();
        CallForOffersStampService.StampResult result = CallForOffersStampService.stamp(
            new List<CallForOffersStampService.StampRequest>{ first, second });
        Test.stopTest();

        Assert.areEqual(1, result.stamped.size(),
            'ONE row, not two — a duplicate Id would have failed the whole statement');
        Assert.areEqual(0, result.refusals.size(), 'and nothing was refused');
        Opportunity stamped = reload(deal.Id);
        Assert.areEqual(received, stamped.Call_For_Offers_Received_Date__c, '');
        Assert.areEqual(DUE, stamped.Offer_Due_Date__c, 'the per-property deadline still merged in');
        Assert.areEqual('Pat Lister', stamped.Listing_Broker_Name__c, 'and so did the broker name');
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
