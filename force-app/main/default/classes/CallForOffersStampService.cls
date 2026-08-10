/**
 * Broker Protection — THE ONLY CLASS IN THIS MODULE THAT WRITES AN `Opportunity`.
 * Added 2026-08-10, Tranche 4B (decisions D3 / D8 / D26).
 *
 * One inbound call-for-offers email can name several properties; each property that the
 * claim pipeline can match to a CONVERTED winner resolves to a live deal, and this class
 * stamps that deal's call-for-offers block: `Offer_Due_Date__c`, `Listing_Broker_Name__c`
 * and `Listing_Broker_Email__c`. It does nothing else — no stage change, no child record,
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
 * ═══ IDEMPOTENCY IS THE NO-CHANGE SKIP, AND IT IS LOAD-BEARING ═══
 * A record whose stored values ALREADY equal every incoming value is dropped from the update
 * list entirely. That is what makes a platform redelivery — or the same campaign email sent
 * twice — cost ZERO DML rather than churning `LastModifiedDate` on a live deal. It is also
 * why the read exists at all: without it this class could write blind and skip nothing.
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
        }
        return byRecord;
    }

    /**
     * The update row for one deal, or null when nothing would change.
     *
     * Applies the class header's rule per field: a non-null incoming value OVERWRITES, a
     * null one is ignored, and an incoming value EQUAL to the stored one is not a change.
     * Values are clipped/sanitized to their destination here because this class is the only
     * writer of these three fields in the module — the length belongs with the write.
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
