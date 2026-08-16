/**
 * Broker Protection — THE ONLY CLASS IN THIS MODULE THAT WRITES AN `Opportunity`.
 * Added 2026-08-10, Tranche 4B (decisions D3 / D8 / D26).
 *
 * One inbound call-for-offers email can name several properties; each property that the
 * claim pipeline can match to a CONVERTED winner resolves to a live deal, and this class
 * stamps that deal's call-for-offers block: `Offer_Due_Date__c`, `Listing_Broker_Name__c`,
 * `Listing_Broker_Email__c`, — since 2026-08-12 — `Sale_Process__c`, and — since 2026-08-14 —
 * `Call_For_Offers_Received_Date__c`. It does nothing else
 * — no stage change, no child record,
 * no notification (D9), no Lead and no registry claim (D3, which is enforced upstream in
 * `ExtractAddressQueueable` and can never be reached from here because this class holds no
 * Lead or registry DML of any kind).
 *
 * ═══ WHY A NEW SERVICE RATHER THAN AN EXISTING ONE ═══
 * Each of the three candidates holds a stated invariant this write would break:
 *   • `EmailToLeadService` owns Lead DML and ONLY Lead DML in this pipeline.
 *   • `PropertyClaimService` owns `Property_Registry__c` / `Competing_Broker_Submission__c`
 *     DML and nothing else.
 *   • `ExtractAddressQueueable` states, in its own header, that it holds NO SOQL and NO DML
 *     of its own.
 * A new service is the only placement that breaks none of the three.
 *
 * ═══ 🔴 `allOrNone = false` IS MANDATORY. THE DEAL MAY BE LOCKED BY ITS OWN APPROVAL. ═══
 * `Underwriting_Approval` and `LOI_Approval` both carry `recordEditability = AdminOnly`, and
 * a deal sitting at Underwriting or LOI is precisely the kind of live deal a broker blasts a
 * call for offers about. `AccessLevel.SYSTEM_MODE` **does not lift an approval lock** —
 * measured in this repo, see `OpportunityReviewService`'s LOI block, where the inline
 * back-stamp still threw `ENTITY_IS_LOCKED` after the CRUD fix landed. So `ENTITY_IS_LOCKED`
 * is a REAL AND REASONABLY COMMON INPUT here, not a theoretical one, and:
 *   1. One locked deal must not roll back another deal's stamp in the same email.
 *   2. Neither may roll back the `Task`, the staging stamp, or anything the routing
 *      transaction already committed.
 * Partial success is therefore the contract, and every `SaveResult` failure is RETURNED to
 * the caller in `StampResult.refusals` — never swallowed, and never parked in a
 * transaction-scoped static the way `EmailThreadAdopterService.lastRunFailureCodes` is (that
 * shape makes a total failure indistinguishable from "nothing needed doing"). The caller
 * funnels `refusals` into `Inbound_Email_Staging__c.Error__c`, which is durable.
 *
 * ═══ Sale_Process__c JOINED THE LAST-WINS SET 2026-08-12 — AND IS THE ONLY DESCRIBE-GUARDED
 * FIELD HERE ═══
 * MEASURED on a live run: after a call-for-offers stamp the deal still read
 * `Sale_Process__c = 'Off-Market'` while the same extraction returned
 * `sale_process = 'Call for Offers'`. It is a fact about THE CAMPAIGN, in the deadline's class
 * rather than the listing broker's — the full argument is at the write itself in `buildChange`,
 * where a future reader will actually be standing. Two things it does NOT change: the three
 * shared guards (never write blank, never churn an unchanged deal, merge by `recordId` first)
 * and the governor shape (`getDescribe()` is a describe, not a query, so the pinned
 * `1 SOQL / <=1 DML` is untouched). 🔴 The one thing it DOES add is a restricted-picklist
 * describe guard the other fields do not need and must not be "harmonised" away — see
 * `saleProcessValues()`.
 *
 * ═══ THE OVERWRITE RULE: LAST EMAIL WINS, PER FIELD, NEVER WITH NULL ═══
 * A call-for-offers deadline is a fact that CHANGES ("deadline extended to Friday"), and the
 * newest email is the authority — fill-if-blank would freeze the first date and make an
 * extension invisible. So a non-null incoming value OVERWRITES; a null incoming value is
 * ignored entirely, mirroring U1's and `applyPropertyBlock`'s established fill-if-present
 * discipline. Two consequences, both deliberate:
 *   • A value the deal already carried FROM CONVERSION is overwritten. `LeadConvertService`
 *     copies `Lead.Offer_Due_Date__c` -> `Opportunity.Offer_Due_Date__c`, and that value came
 *     from THIS pipeline, out of the winning broker's own earlier email. A later
 *     call-for-offers email about the same property is newer information about the same
 *     deadline, so it wins.
 *   • ⚠ NAMED COST: a value a human hand-edited is also overwritten. The mitigation is the
 *     audit trail, not a guard — every stamp is reconstructable from the
 *     `Inbound_Email_Staging__c` row (raw body, full `Extracted_JSON__c`,
 *     `Routed_Record_Ids__c`, outcome label). Field History Tracking would be stronger, but
 *     `Opportunity.enableHistory` is `false` today and turning it on is an object-wide change
 *     to a live standard object — out of scope for this tranche.
 *
 * ═══ 🔴 Call_For_Offers_Received_Date__c JOINED THE STAMP SET 2026-08-14, AND IT IS THE ONLY
 * FIELD HERE THAT IS PER-EMAIL RATHER THAN PER-PROPERTY ═══
 * It replaces a DERIVED PROXY. `CallForOffersService` used to answer the table's "Received"
 * column from `Broker_First_Seen__c` falling back to `Opportunity.CreatedDate` — both of which
 * answer *when did this DEAL arrive*, never *when did the call-for-offers email land*. On a deal
 * whose first broker contact predates the campaign by months the column was months wrong, which
 * is precisely the mistake the column's own label invites. The field is the real value; the
 * proxy has been renamed and demoted (see that class's header §4).
 *
 * WHAT IS WRITTEN: the date of `LLMExtractionResult.sentDatetime` — the email's own send time,
 * as the caller already parses it for the claim path — falling back to the moment the pipeline
 * processed the email when the extraction states none (the prompt is deliberately
 * explicit-or-EMPTY on that key, so a blank is expected traffic, not a fault). 🔴 BOTH LEGS ARE
 * REAL TIMESTAMPS OF *THIS EMAIL*, which is the whole difference from the proxy: the proxy was a
 * true fact about a DIFFERENT object. The date a human reads as "received" and the timestamp the
 * module ARBITRATES with (`Competing_Broker_Submission__c.Submitted_DateTime__c`) are therefore
 * CONSISTENT BY DERIVATION: both are `parseSentDatetime(extraction.sentDatetime)`, the same
 * function over the same input, so neither can be re-sourced without the other. The
 * `EmailThreadAnchorService` shape.
 *
 * ⚠ AMENDED 2026-08-14 — THE PREVIOUS WORDING CLAIMED MORE THAN THE CODE DOES AND IS RETRACTED,
 * verbatim: *"because the caller hands us the SAME `submittedOn` instant it stamps on
 * `Competing_Broker_Submission__c.Submitted_DateTime__c`, the date a human reads as 'received' and
 * the timestamp the module ARBITRATES with can never disagree — by construction, not by
 * convention."* Two things are wrong with it and the second is the one that misleads:
 *   1. The two values NEVER COEXIST on one email, so there is no disagreement to prevent. The
 *      caller's call-for-offers branch (`routeCallForOffers`) and its claim branch
 *      (`routeProperties`) are MUTUALLY EXCLUSIVE — the gate returns before the claim path runs —
 *      and the gated branch writes no `Competing_Broker_Submission__c` row at all, by design (D3).
 *   2. It is a SECOND call to `parseSentDatetime`, not a shared variable. On the blank
 *      `sent_datetime` path that function falls back to `Datetime.now()`, so two calls are two
 *      different instants, and across midnight two different DATES.
 * Neither is a defect — the behaviour is right — but "by construction" sent a reader looking for a
 * shared value, and there is none to find. What is actually guaranteed is the derivation, above.
 *
 * LAST-WINS, like the deadline and for a STRONGER reason than the deadline has. The two are ONE
 * FACT ABOUT ONE EMAIL and must not be allowed to straddle two: under fill-if-blank a deal would
 * read "Received Jun 1 / Offers due Sep 1" where the September deadline came out of an August
 * email, and the pair — which exists to answer *how fresh is this deadline* — becomes
 * unanswerable and actively misleading. The latest call-for-offers email is the one whose
 * deadline is live, so its arrival date is the matching one.
 *
 * PER EMAIL, NOT PER PROPERTY — the one asymmetry in this class. `offerDueDate` and `saleProcess`
 * are per-property because a portfolio blast can quote a different deadline and a different
 * process per asset; an email has exactly ONE arrival time, and the extraction carries exactly
 * one `sent_datetime` for the whole message. The caller therefore sets the identical value on
 * every request, which also makes the `mergeByRecord` fill-if-present collapse a no-op for it.
 *
 * ⚠ TWO NAMED RESIDUALS, STATED RATHER THAN HIDDEN. (1) The two legs read two different clocks —
 * the BROKER's stated send time, or DPEG's receipt — so two deals stamped by the same blast can
 * differ by the coordinator's forwarding delay. (2) Last-wins over a broker-stated timestamp is
 * therefore NOT MONOTONIC: a stale forward of an old message, arriving today but stating a send
 * time three weeks ago, moves this date BACKWARD. Both are inherited from the claim path
 * deliberately rather than invented here — `submittedOn` already arbitrates real property claims
 * on exactly these terms — and the alternative (ignore what the email says, always stamp today)
 * would report a three-week-old forward as new, which is worse. `Inbound_Email_Staging__c`
 * remains the byte-exact audit trail either way.
 *
 * ═══ IDEMPOTENCY IS THE NO-CHANGE SKIP, AND IT IS LOAD-BEARING ═══
 * A record whose stored values ALREADY equal every incoming value is dropped from the update
 * list entirely. That is what makes a platform redelivery — or the same campaign email sent
 * twice — cost ZERO DML rather than churning `LastModifiedDate` on a live deal. It is also
 * why the read exists at all: without it this class could write blind and skip nothing.
 *
 * ⚠ AMENDED 2026-08-14 — THE CLAUSE "or the same campaign email sent twice" IS NOW NARROWER BY
 * EXACTLY ONE DAY, AND THAT IS A DECISION RATHER THAN AN EROSION. The received date is
 * last-wins and effectively always non-null, so an identical campaign email arriving on a LATER
 * DAY with no stated `sent_datetime` now changes one field and costs one DML. It is not churn:
 * a second arrival IS a new fact, and it is the fact the column exists to report. Everything the
 * original clause was written to protect is intact, one path at a time:
 *   • a platform REDELIVERY still costs zero — the duplicate-Message-Id guard returns before the
 *     callout and never reaches this class at all;
 *   • a `RoutingRetrySweepBatch` replay is not a replay of a WRITE — SP-5 measured that a `Failed`
 *     row's attempt rolled back and committed nothing, so its retry is the FIRST stamp;
 *   • an email that DOES state its `sent_datetime` replays to the byte, which is why
 *     `stamp_replayedWithIdenticalValues_isAZeroDmlNoOp` is unmodified and still passes.
 * The one genuinely widened case is the narrow one named above: same email, no stated send time,
 * a different calendar day.
 *
 * ═══ GOVERNOR SHAPE — CONSTANT IN THE NUMBER OF MATCHED DEALS ═══
 * Exactly **1 SOQL and at most 1 DML per call**, whether the email matched one deal or ten.
 * `AttachmentPersistQueueable` is the precedent: constancy is the property, not the number.
 * A future change that reads or writes per deal must fail
 * `ExtractAddressQueueableTest.callForOffers_matched_governorBudget...` rather than ship.
 *
 * ═══ LAYER ═══
 * Service. All SOQL is in `OpportunitySelector.selectCallForOffersTargetsByIds` (`WITH
 * SYSTEM_MODE` — that method's header argues the mode and the sharing keyword SEPARATELY, per
 * D25). `with sharing` on this class, which is SUFFICIENT rather than merely inherited:
 * `Opportunity` OWD is `ReadWrite`, measured against the org via Tooling `EntityDefinition`
 * on 2026-08-10, so a `with sharing` read and update reach every deal.
 *
 * 🔴 IF OPPORTUNITY IS EVER NARROWED TO PRIVATE, THE READ FAILS FIRST — AND `refusals` CANNOT
 * SEE IT. ⚠ CORRECTED 2026-08-10: this paragraph used to say the UPDATE "starts being REFUSED
 * … which `allOrNone = false` turns into a silent refusal recorded in `refusals`". That is
 * wrong about the mechanism, and the error mattered, because it claimed a channel that does not
 * exist. The selector read runs FIRST and is `with sharing`, so under a Private OWD it returns
 * ZERO ROWS for a pipeline principal who owns no deals; `updates` is then empty, the
 * `Database.update` is never attempted, and there is no `SaveResult` and therefore no refusal
 * of any kind. `StampResult.missing` is the population that catches it (added 2026-08-10, review
 * finding S4) — a read-side diff is the only thing that can. The remedy, if it ever happens, is
 * a narrow `private without sharing` inner class in the SELECTOR holding only that query (the
 * `LeadSelector.GuestReads` / `InboundEmailStagingSelector.RoutingReads` shape), plus the same
 * treatment for the `Database.update` here if the write then refuses — never `without sharing`
 * on either whole class. The same warning, with the same mechanism, is on the selector method.
 *
 * @see ExtractAddressQueueable.cls (the U2 call-for-offers branch — the only caller)
 * @see OpportunitySelector.selectCallForOffersTargetsByIds (the SYSTEM_MODE read)
 */
public with sharing class CallForOffersStampService {

    /**
     * `Opportunity.Listing_Broker_Name__c` is `Text(120)`, not 255.
     *
     * ⚠ THE DESTINATION LENGTH IS CARRIED HERE ON PURPOSE, AND IT IS NOT REDUNDANT. Both of
     * today's inbound routes already clip to 120 — `LLMExtractionParser` on the way in, and
     * `ExtractAddressQueueable.demoteBodyBroker` when U1 moves a body-named broker into the
     * listing-contact slot — so a 121-character name cannot presently reach this method. That
     * is a property of the CALLERS, not of this service, and the moment it is relied on it
     * becomes a `STRING_TOO_LONG` on a live deal the first time a new caller appears.
     *
     * ⚠ CORRECTED 2026-08-10 (review finding W1). This Javadoc used to justify itself by "this
     * class also accepts the U1-resolved ENVELOPE sender name as a fallback, which has never
     * passed through the parser's clip". That fallback was REMOVED from
     * `ExtractAddressQueueable.routeCallForOffers` — it let a blast platform's mailbox overwrite
     * a live deal's real listing broker — so the unclipped envelope value no longer reaches
     * here. The clip stays; only its reason changed. Same trap, same reasoning, as
     * `ExtractAddressQueueable.LEN_LISTING_BROKER_NAME`.
     */
    private static final Integer LEN_LISTING_BROKER_NAME = 120;

    /**
     * Active values of `Opportunity.Sale_Process__c`, resolved once per transaction.
     *
     * 🔴 THIS IS THE ONE GUARD THE OTHER STAMPED FIELDS DO NOT NEED, AND IT IS THE MOST
     * LIKELY WAY A CORRECT-LOOKING IMPLEMENTATION OF THIS FIELD BREAKS IN PRODUCTION.
     * `Sale_Process__c` is a RESTRICTED picklist (`<restricted>true</restricted>`, four values:
     * Off-Market / On-Market Listing / Call for Offers / Auction). An off-list value does NOT
     * fail at compile time — it fails the DML at runtime with
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`. ⚠ `allOrNone = false` limits that to the ONE
     * row, so it does not take the statement down; what it DOES take down is that deal's
     * deadline and listing-broker stamp in the same row, reported as a refusal that reads like
     * an approval lock. Guarding AT SOURCE — dropping the value rather than pushing it — is what
     * keeps a bad picklist value from costing a deal the rest of its stamp.
     *
     * ⚠ THE PARSER'S EXISTING GUARD IS NOT THIS GUARD, AND THE DIFFERENCE IS THE WHOLE POINT.
     * `LLMExtractionParser.parseProperty` already validates `sale_process` against
     * **`Lead.Sale_Process__c`** (it is parsing a value bound for a Lead). This writes
     * **`Opportunity.Sale_Process__c`** — a DIFFERENT picklist that merely happens to be
     * byte-identical today. The moment the two drift, the parser's guard passes a value this
     * field rejects, and nothing else in the chain would notice.
     *
     * `getDescribe()` is a DESCRIBE, not a query: it consumes no SOQL limit, so this cannot move
     * the class's pinned `1 SOQL / <=1 DML` budget. Same mechanism, same reasoning, as
     * `LeadConvertService.saleProcessValues()` — which describe-guards this very field for this
     * very reason. Deliberately NOT a hardcoded list: a value deactivated in Setup must stop
     * being written without a deploy.
     */
    private static Set<String> saleProcessValuesCache;

    /**
     * TEST-ONLY SEAM #3 — replaces the live picklist describe with a caller-supplied set.
     *
     * 🔴 IT EXISTS BECAUSE THE DESCRIBE GUARD IS OTHERWISE UNFALSIFIABLE. Every value that can
     * reach `buildChange` has already been validated against `Lead.Sale_Process__c` by
     * `LLMExtractionParser`, and the two picklists are byte-identical today — so no input
     * reachable through the real pipeline can be off-list, the guard never fires, and no test
     * can distinguish "the guard works" from "there is no guard". Injecting a set that OMITS a
     * value the caller then supplies makes the drop OBSERVABLE, which is the only way this guard
     * is covered at all. (Same problem and same remedy as the `LeadConvertService` and
     * `PropertyAssetService` describe-guard tests.)
     *
     * ⚠ A PLAIN FIELD PLUS AN ACCESSOR METHOD, NEVER THE LAZY STATIC-PROPERTY IDIOM
     * (`private static Set<String> x { get { if (x == null) ... return x; } set; }`). That idiom
     * is widely cited and is INFINITE RECURSION in Apex once the getter body references the
     * property itself — a runtime failure no compile step catches. This shape has no such edge.
     *
     * NEVER set this outside a test class.
     */
    @TestVisible
    private static Set<String> simulateSaleProcessValues = null;

    /**
     * @return The active values of `Opportunity.Sale_Process__c`; memoized per transaction, and
     *         overridden wholesale by `simulateSaleProcessValues` when a test has supplied one.
     */
    private static Set<String> saleProcessValues() {
        if (simulateSaleProcessValues != null) {
            return simulateSaleProcessValues;
        }
        if (saleProcessValuesCache == null) {
            Set<String> values = new Set<String>();
            for (Schema.PicklistEntry entry
                    : Opportunity.Sale_Process__c.getDescribe().getPicklistValues()) {
                if (entry.isActive()) {
                    values.add(entry.getValue());
                }
            }
            saleProcessValuesCache = values;
        }
        return saleProcessValuesCache;
    }

    /**
     * TEST-ONLY SEAM #1 — makes `stamp` THROW before doing anything.
     *
     * 🔴 IT EXISTS BECAUSE THE FAILURE IT MODELS IS THE ONE SAFETY PROPERTY OF THE WHOLE
     * TRANCHE. If anything in this service escaped as an exception,
     * `ExtractAddressQueueable`'s call-for-offers branch would fall through to `execute()`'s
     * catch, `finish()` would NEVER RUN, the `Task` would never be logged, the RFC Message-ID
     * would never be recorded — and a platform redelivery would re-run the ENTIRE pipeline. The
     * branch's own `try/catch` is what prevents that, and this seam is the only way to prove it
     * fires, because every real input to this service is clipped, sanitized or de-duplicated by
     * design and none of them can be made to throw.
     *
     * ⚠ IT THROWS RATHER THAN PERFORMING A FAILING DML, and that is deliberate — the same
     * decision, for the same reason, as `ExtractAddressQueueable.forceRouteFailure`: a seam that
     * wrote a deliberately-invalid row would put DML somewhere this class's contract does not
     * describe. The message NAMES the records it was asked to stamp, so the assertion that
     * `Error__c` identifies the deal is testing the real error channel rather than a placeholder.
     *
     * NEVER set this outside a test class.
     */
    @TestVisible private static Boolean simulateStampFailure = false;

    /**
     * TEST-ONLY SEAM #2 — replaces the selector read with a caller-supplied snapshot.
     *
     * 🔴 IT EXISTS BECAUSE THE PRODUCTION REFUSAL CANNOT BE MANUFACTURED IN `@isTest`. The
     * refusal this class is built around is `ENTITY_IS_LOCKED`: a deal sitting under
     * `Underwriting_Approval` or `LOI_Approval`, both `recordEditability = AdminOnly`, which
     * `AccessLevel.SYSTEM_MODE` does NOT unlock. There is no way to put a record into that state
     * from a test here, and asserting a `StatusCode` this repo has never captured is exactly the
     * mistake recorded for the converted-Lead lookup trap.
     *
     * A DELETED record produces a genuine `Database.SaveResult` failure through the IDENTICAL
     * code path — but only if the row was still readable when the decision was taken, which is
     * precisely what a lock does and a delete does not (the selector simply would not return it).
     * This seam supplies that snapshot, so the `Database.update`, the `SaveResult` loop, the
     * partial-success behaviour and `describeRefusal` are all REAL. Nothing about the write is
     * faked; only the read is.
     *
     * Same precedent as `EmailThreadAdopterService`'s `AdoptionWriter`: seam the thing the
     * platform will not do, assert the DECISION through the real code.
     *
     * NEVER set this outside a test class.
     */
    @TestVisible private static List<Opportunity> simulateReadResult = null;

    /** One deal to stamp, and the values to stamp on it. Any field may be null, which means
     *  "this email said nothing about it" and never "clear it". */
    public class StampRequest {
        /** The matched Opportunity. Required; a null or non-Opportunity Id is dropped. */
        public Id recordId;
        /** `offer_due_date` for the property that matched this deal, or null. */
        public Date offerDueDate;
        /** The listing broker's display name, or null. Clipped to 120 here. */
        public String listingBrokerName;
        /** The listing broker's address, or null. Sanitized to a valid 80-char Email here. */
        public String listingBrokerEmail;
        /**
         * `sale_process` for the property that matched this deal, or null. LAST-WINS, and
         * DESCRIBE-GUARDED against the live `Opportunity.Sale_Process__c` picklist before it is
         * written — see `saleProcessValues()` and `buildChange`.
         */
        public String saleProcess;
        /**
         * The day this call-for-offers email reached DPEG. LAST-WINS like the deadline.
         *
         * ⚠ PER EMAIL, NOT PER PROPERTY — the caller sets the SAME value on every request built
         * from one message. See the class header for why, and for what the caller derives it
         * from. It is deliberately typed `Date`, matching `Offer_Due_Date__c`: the two are read
         * side by side in one table row and a DateTime beside a Date renders as two different
         * kinds of fact.
         */
        public Date callForOffersReceivedDate;
    }

    /**
     * What the call actually did. FOUR disjoint and EXHAUSTIVE populations — every requested
     * Id lands in exactly one of them, and the caller needs all four: `stamped` drives nothing
     * today but proves the write happened, `unchanged` is what makes idempotency observable,
     * `refusals` is the only record of an approval lock, and `missing` is the only record of a
     * deal that could not be READ BACK at all.
     *
     * ⚠ `missing` WAS ADDED BECAUSE THE OTHER THREE WERE NOT EXHAUSTIVE, AND THE GAP WAS
     * SILENT. A requested Id the selector does not return fell out of all three populations
     * while the caller's outcome label still read `— deal updated` — a stamp that provably
     * never happened, reported as a success, with `refusals` empty. It is the same failure
     * shape this class exists to avoid, one layer earlier.
     *
     * 🔴 IT IS ALSO THE CHANNEL FOR THE PRIVATE-OWD RESIDUAL, AND `refusals` COULD NEVER HAVE
     * BEEN. If `Opportunity` OWD is ever narrowed to Private, the `with sharing` read in
     * `OpportunitySelector.selectCallForOffersTargetsByIds` returns ZERO ROWS for a pipeline
     * principal who owns no deals — so the `Database.update` is never attempted, there is no
     * `SaveResult`, and therefore no refusal to record. Only a read-side diff can see it. (An
     * earlier version of this class's header claimed that case would surface "as a silent
     * refusal recorded in `refusals`"; that was wrong about the mechanism and is corrected
     * above.)
     *
     * In one transaction, against today's ReadWrite OWD, this list is expected to stay EMPTY —
     * the Ids arrive from `PropertyMatchingService.resolveLiveRecord` moments earlier in the
     * same transaction. A non-empty `missing` means the deal was deleted between the two reads,
     * or that sharing has started filtering this read. Both are real; neither should be silent.
     */
    public class StampResult {
        /** Deals whose update succeeded. */
        public List<Id> stamped = new List<Id>();
        /** Deals skipped because every incoming value already matched (zero DML). */
        public List<Id> unchanged = new List<Id>();
        /** One human-readable line per refused save — record Id, StatusCode and message. */
        public List<String> refusals = new List<String>();
        /** One line per requested deal the read did not return — see this class's Javadoc. */
        public List<String> missing = new List<String>();
    }

    /**
     * Stamp the call-for-offers block onto every matched deal, in ONE bulk read and at most
     * ONE bulk `Database.update(..., false)`.
     *
     * De-duplicates on `recordId` FIRST, because two properties in one email can legitimately
     * fuzzy-match the same registry row and therefore the same deal — and a duplicate Id in a
     * `Database.update` list throws `DUPLICATE_VALUE` ("duplicate id in list") for the WHOLE
     * statement, which `allOrNone = false` does not rescue. Merging is FILL-IF-PRESENT in list
     * order, so the first non-null value for each field wins; the caller supplies requests in
     * its deterministic cluster-key processing order, so the merge is deterministic too.
     *
     * @param requests One entry per matched deal; null/empty-safe, and null entries, null
     *                 `recordId`s and non-Opportunity Ids are all dropped silently (they are
     *                 caller bugs the pipeline must not die on). ⚠ A dropped Id is NOT reported
     *                 as `missing` — `missing` means "asked for, not read back", which is a
     *                 platform condition rather than a caller defect.
     * @return What was stamped, what was already current, every refusal, and every requested
     *         deal the read did not return. Never null.
     * @example
     * CallForOffersStampService.StampResult result =
     *     CallForOffersStampService.stamp(requests);
     */
    public static StampResult stamp(List<StampRequest> requests) {
        StampResult result = new StampResult();

        Map<Id, StampRequest> byRecord = mergeByRecord(requests);
        if (byRecord.isEmpty()) {
            return result;
        }

        if (simulateStampFailure) {
            // TEST-ONLY. See the seam's Javadoc — this proves the caller's try/catch keeps
            // finish() reachable, which is the whole redelivery contract.
            throw new DmlException(
                'Simulated call-for-offers stamp failure for: ' + byRecord.keySet());
        }

        // ONE bulk read. SYSTEM_MODE — see the selector method's header for why the mode and
        // the sharing keyword are argued separately.
        List<Opportunity> current = (simulateReadResult != null)
            ? simulateReadResult
            : OpportunitySelector.selectCallForOffersTargetsByIds(byRecord.keySet());

        List<Opportunity> updates = new List<Opportunity>();
        Set<Id> readBack = new Set<Id>();
        for (Opportunity deal : current) {
            readBack.add(deal.Id);
            Opportunity change = buildChange(deal, byRecord.get(deal.Id));
            if (change == null) {
                // NO-CHANGE SKIP — the idempotency guarantee. Nothing this email carries is
                // new to this deal, so it is dropped from the statement entirely.
                result.unchanged.add(deal.Id);
                continue;
            }
            updates.add(change);
        }

        // WHAT THE READ DID NOT RETURN. Without this, such an Id lands in NO population at all
        // and the caller reports '— deal updated' for a stamp that never happened. See
        // StampResult's Javadoc — this is the only channel that can see a sharing-filtered read,
        // because a filtered read produces no SaveResult and therefore no refusal.
        for (Id requested : byRecord.keySet()) {
            if (!readBack.contains(requested)) {
                result.missing.add('Opportunity ' + requested + ' matched but could not be read '
                    + 'back for stamping (deleted, or filtered by sharing) — nothing was written');
            }
        }

        if (updates.isEmpty()) {
            return result;
        }

        // 🔴 allOrNone = false — see the class header. A deal locked by its own approval must
        // not take its siblings, or the upstream Task and staging stamp, down with it.
        List<Database.SaveResult> saveResults =
            Database.update(updates, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult saveResult = saveResults[i];
            if (saveResult.isSuccess()) {
                result.stamped.add(updates[i].Id);
                continue;
            }
            result.refusals.add(describeRefusal(updates[i].Id, saveResult));
        }
        return result;
    }

    /**
     * Collapse the request list to one entry per Opportunity, merging fill-if-present in list
     * order. Drops null entries, null Ids and any Id that is not an Opportunity — Q1 scoped
     * this feature to Opportunity only, and a Lead Id arriving here would be a caller defect
     * that must not become a `Database.update` failure on a live email.
     *
     * @param requests The raw request list; null-safe.
     * @return Merged requests keyed by Opportunity Id; empty when nothing is usable.
     */
    private static Map<Id, StampRequest> mergeByRecord(List<StampRequest> requests) {
        Map<Id, StampRequest> byRecord = new Map<Id, StampRequest>();
        if (requests == null) {
            return byRecord;
        }
        for (StampRequest request : requests) {
            if (request == null || request.recordId == null
                    || request.recordId.getSObjectType() != Opportunity.SObjectType) {
                continue;
            }
            StampRequest merged = byRecord.get(request.recordId);
            if (merged == null) {
                merged = new StampRequest();
                merged.recordId = request.recordId;
                byRecord.put(request.recordId, merged);
            }
            if (merged.offerDueDate == null) {
                merged.offerDueDate = request.offerDueDate;
            }
            if (String.isBlank(merged.listingBrokerName)) {
                merged.listingBrokerName = request.listingBrokerName;
            }
            if (String.isBlank(merged.listingBrokerEmail)) {
                merged.listingBrokerEmail = request.listingBrokerEmail;
            }
            if (String.isBlank(merged.saleProcess)) {
                merged.saleProcess = request.saleProcess;
            }
            // Fill-if-present like the rest. ⚠ For THIS field the collapse is a formality rather
            // than a decision: the value is per-EMAIL, so every request built from one message
            // carries the identical date and there is nothing for the merge to choose between.
            // It is written in the same shape as its siblings so that a future per-property
            // source (if one ever exists) inherits the same deterministic list-order rule.
            if (merged.callForOffersReceivedDate == null) {
                merged.callForOffersReceivedDate = request.callForOffersReceivedDate;
            }
        }
        return byRecord;
    }

    /**
     * The update row for one deal, or null when nothing would change.
     *
     * Applies the class header's rule per field: a non-null incoming value OVERWRITES, a
     * null one is ignored, and an incoming value EQUAL to the stored one is not a change.
     * Values are clipped, sanitized or describe-guarded to their destination here because this
     * class is the only writer of these five fields in the module — the constraint belongs with
     * the write.
     *
     * @param deal    The stored row, as read by the selector.
     * @param request The merged incoming values for that deal.
     * @return A minimal update row carrying only the changed fields, or null for a no-op.
     */
    private static Opportunity buildChange(Opportunity deal, StampRequest request) {
        if (deal == null || request == null) {
            return null;
        }
        Opportunity change = new Opportunity(Id = deal.Id);
        Boolean changed = false;

        if (request.offerDueDate != null && request.offerDueDate != deal.Offer_Due_Date__c) {
            change.Offer_Due_Date__c = request.offerDueDate;
            changed = true;
        }

        // ═══ Call_For_Offers_Received_Date__c — LAST-WINS, AND IT IS THE DEADLINE'S OWN PAIR
        // (added 2026-08-14) ═══
        // It replaces the derived proxy CallForOffersService used to show in the "Received"
        // column (Broker_First_Seen__c -> CreatedDate), which answers when the DEAL arrived and
        // not when the EMAIL did. The three shared guards are unchanged and are what make this
        // three lines rather than a special case: a null incoming value is never written (an
        // email the caller could derive no arrival date from must not erase one the deal
        // already carries), an already-equal value is not a change (the zero-DML replay
        // guarantee), and requests were merged by recordId before we got here.
        //
        // 🔴 LAST-WINS IS NOT PATTERN-MATCHED OFF THE DEADLINE — it is the STRONGER case of the
        // two. The deadline is last-wins because it CHANGES ("extended to Friday"). This date
        // does not change; a NEW EMAIL simply has a new one. What forces last-wins here is that
        // the two fields describe ONE EMAIL and are read as a pair: fill-if-blank would pin the
        // received date to the first email while the deadline tracked the latest, so the row
        // would report a September deadline received in June. Freezing one half of a pair is how
        // a table that exists to answer "how fresh is this?" starts answering it wrongly.
        // It carries NO describe guard and needs none — unlike Sale_Process__c this is a Date,
        // so there is no value set to be off.
        if (request.callForOffersReceivedDate != null
                && request.callForOffersReceivedDate != deal.Call_For_Offers_Received_Date__c) {
            change.Call_For_Offers_Received_Date__c = request.callForOffersReceivedDate;
            changed = true;
        }

        String name = InboundEmailFieldUtil.clip(request.listingBrokerName, LEN_LISTING_BROKER_NAME);
        if (String.isNotBlank(name) && name != deal.Listing_Broker_Name__c) {
            change.Listing_Broker_Name__c = name;
            changed = true;
        }

        // Sanitized, not merely clipped: Listing_Broker_Email__c is an Email field, so a
        // malformed value is an INVALID_EMAIL_ADDRESS that would refuse the whole row.
        String email = InboundEmailFieldUtil.sanitizeEmail(request.listingBrokerEmail);
        if (String.isNotBlank(email) && email != deal.Listing_Broker_Email__c) {
            change.Listing_Broker_Email__c = email;
            changed = true;
        }

        // ═══ Sale_Process__c — LAST-WINS, AND IT IS THE DEADLINE'S KIND OF FACT, NOT THE
        // LISTING BROKER'S (added 2026-08-12) ═══
        // MEASURED: after a call-for-offers stamp a deal still read Sale_Process__c = 'Off-Market'
        // while the very extraction that produced the stamp returned sale_process = 'Call for
        // Offers'. The deal contradicted what the pipeline knew.
        //
        // 🔴 WHICH OF THIS CLASS'S TWO PER-FIELD RULES APPLIES IS THE WHOLE DECISION, so argue it
        // rather than pattern-match it. The offer deadline is LAST-WINS because it is a fact about
        // THE CAMPAIGN and it genuinely CHANGES ("extended to Friday") — fill-if-blank would
        // freeze the first date and make an extension invisible. The listing broker is not even a
        // FALLBACK because it is a fact about THE TRANSACTION, and a third party's blast is not
        // newer information about who is running DPEG's deal. Sale process is a fact about the
        // CAMPAIGN, in the deadline's class exactly: "this asset is now being sold via a call for
        // offers" describes how the SELLER is running the process, it is the same subject the
        // deadline describes, and it genuinely changes when an off-market deal goes to a marketed
        // campaign. A deal reading 'Off-Market' while this pipeline holds an email announcing a
        // call for offers is actively misleading the deal team, which is the cost of getting this
        // classification wrong in the other direction.
        //
        // 🔴 AND IT CARRIES ONE GUARD NO OTHER STAMPED FIELD NEEDS: Sale_Process__c is a RESTRICTED
        // picklist, so an off-list value is an INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST at DML time
        // that costs this deal its deadline and broker stamp too. The value is checked against the
        // LIVE picklist and DROPPED if absent — never pushed, never checked against a hardcoded
        // list. See saleProcessValues(): the parser's existing guard is against Lead's picklist,
        // not this one. The three shared guards are unchanged — a blank incoming value is never
        // written (an email silent about the process must not erase what the deal knows), an
        // already-equal value is not a change (the zero-DML replay guarantee), and requests were
        // merged by recordId before we got here.
        String saleProcess = request.saleProcess;
        if (String.isNotBlank(saleProcess)
                && saleProcessValues().contains(saleProcess)
                && saleProcess != deal.Sale_Process__c) {
            change.Sale_Process__c = saleProcess;
            changed = true;
        }

        return changed ? change : null;
    }

    /**
     * One durable line describing a refused save — the record, the platform's StatusCode and
     * its message. The StatusCode is included verbatim because the expected one here is
     * `ENTITY_IS_LOCKED` (a deal under its own approval) and a human triaging the staging row
     * needs to be able to tell that apart from a validation-rule refusal without a code read.
     *
     * ⚠ Never assert a specific StatusCode from a test against a lock this repo cannot
     * reproduce — the converted-Lead precedent is that an uncaptured StatusCode becomes an
     * assumption. This method CAPTURES it instead.
     *
     * @param recordId   The deal whose update was refused.
     * @param saveResult The failed save result.
     * @return 'Opportunity <id> stamp refused: <CODE> | <message>'.
     */
    private static String describeRefusal(Id recordId, Database.SaveResult saveResult) {
        List<String> parts = new List<String>();
        for (Database.Error error : saveResult.getErrors()) {
            parts.add(error.getStatusCode() + ' | ' + error.getMessage());
        }
        return 'Opportunity ' + recordId + ' stamp refused: '
            + (parts.isEmpty() ? 'unknown error' : String.join(parts, '; '));
    }
}
