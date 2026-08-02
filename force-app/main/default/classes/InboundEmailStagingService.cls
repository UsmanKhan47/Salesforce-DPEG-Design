/**
 * Broker-Protection inbound-email intake — staging DML layer (staging model). This is
 * the ONLY place an Inbound_Email_Staging__c row is inserted or updated: it keeps the
 * thin boundary handler (EmailToLeadHandler) and the async orchestrator
 * (ExtractAddressQueueable) free of staging DML, per the layering contract.
 *
 * WHY A STAGING RECORD EXISTS AT ALL. Before this model the pipeline inserted a Lead
 * synchronously so the email "could not be lost", which forced a Lead into existence
 * before anything was known about it — including whether it was a reply to an existing
 * deal, a repeat from a broker who had already submitted, or a redelivery of a message
 * already processed. Staging inverts that: the DURABLE artefact is the raw email plus its
 * RFC headers, written synchronously and never deleted, and the Lead is created only by
 * the routing branch that actually needs one. Every terminal state of the async job is
 * written back here (Processed / Error, the outcome label, the routed record Id), so the
 * object doubles as the pipeline's audit trail and its restart point.
 *
 * LAYER — Service (staging write side). Reads delegate to InboundEmailStagingSelector;
 * this class contains NO SOQL of its own.
 *
 * DML MODEL — plain insert/update (system mode), matching the established module pattern
 * (EmailToLeadService, PropertyClaimService). AccessLevel.USER_MODE is intentionally NOT
 * applied: the inbound-email handler runs in an automated context whose "running user" is
 * the Email Service's configured context user, not an interactive user whose FLS is
 * meaningful to enforce on a system-owned audit row. Every write is single-record-shaped
 * (one inbound email == one staging row) and never sits inside a loop.
 *
 * FAIL-SOFT STATUS WRITES — markProcessed / markSkipped / markError swallow their own
 * DmlExceptions. They are the LAST statement of a routing branch that has already
 * committed real work (a Lead, a registry claim, a Task); letting a status-stamp failure
 * throw would replace an accurate "the claim happened" with an unhandled async failure and
 * roll nothing back. A failed stamp leaves the row 'Pending', which is visible and
 * hand-recoverable.
 *
 * @see EmailToLeadHandler.cls (calls createStaging)
 * @see ExtractAddressQueueable.cls (calls getStaging + the three mark* methods)
 * @see InboundEmailStagingSelector.cls (the read side)
 */
public with sharing class InboundEmailStagingService {

    /** Inbound_Email_Staging__c.Status__c picklist values (restricted value set). */
    private static final String STATUS_PENDING = 'Pending';
    private static final String STATUS_PROCESSED = 'Processed';
    private static final String STATUS_ERROR = 'Error';

    /** Destination field lengths — every inbound value is clipped to these before DML. */
    private static final Integer LEN_LONG_TEXT = 131072;
    private static final Integer LEN_REFERENCES = 32768;
    /** Routed_Record_Ids__c is LongTextArea(32768) — the N-result audit trail. */
    private static final Integer LEN_ROUTED_IDS = 32768;
    private static final Integer LEN_ERROR = 32000;
    private static final Integer LEN_TEXT = 255;
    private static final Integer LEN_RECORD_ID = 18;

    /**
     * The envelope + header payload of one inbound email, as parsed by
     * EmailToLeadHandler. A DTO rather than a twelve-parameter method signature: the
     * fields are all optional strings of the same type, so positional arguments would be
     * trivially transposable at the call site (swapping `messageId` and `inReplyTo` would
     * compile and silently break threading). Every field is clipped by createStaging, so
     * the caller may populate it with raw, unbounded values.
     */
    public class StagingRequest {
        /** Sender display name from the envelope ("Jane Broker"). */
        public String fromName;
        /** Sender address from the envelope. */
        public String fromAddress;
        /** Inbound subject, verbatim (e.g. 'FW: 100 Main St'). */
        public String subject;
        /** Plain-text body when present, else the HTML body. */
        public String rawBody;
        /** Every RFC header the platform exposed, one 'Name: Value' per line. */
        public String rawHeaders;
        /** RFC Message-ID of this email — the idempotency key. */
        public String messageId;
        /** RFC In-Reply-To — the immediate parent message. */
        public String inReplyTo;
        /** RFC References — the full ancestry, whitespace-delimited. */
        public String references;
        /** The monitored inbox that forwarded this email (header-resolved, else the From). */
        public String forwardedBy;
        /** MIME type of the first inline image, when the email carried one. */
        public String imageMimeType;
        /** True when an inline image was found and handed to the async extractor. */
        public Boolean hasImage;
    }

    /**
     * Insert the staging row for one inbound email and return its Id. Called
     * SYNCHRONOUSLY from the Email Service boundary, before anything else happens, so the
     * raw email and its headers are durable no matter what the async job later does.
     * Status is stamped 'Pending'; the queueable moves it to 'Processed' or 'Error'.
     *
     * Every value is clipped to its destination field length and any address is
     * sanitized (InboundEmailFieldUtil), because an over-long subject or a malformed
     * envelope address must never bounce an otherwise-valid broker email.
     *
     * @param request The parsed envelope/header payload; must not be null.
     * @return The Id of the inserted Inbound_Email_Staging__c.
     * @throws DmlException when the staging insert itself fails — the handler catches it
     *         and returns success=false so the platform records the bounce.
     * @example
     * Id stagingId = InboundEmailStagingService.createStaging(request);
     */
    public static Id createStaging(StagingRequest request) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = InboundEmailFieldUtil.clip(request.fromName, LEN_TEXT),
            From_Address__c = InboundEmailFieldUtil.sanitizeEmail(request.fromAddress),
            Subject__c = InboundEmailFieldUtil.clip(request.subject, LEN_TEXT),
            Raw_Body__c = InboundEmailFieldUtil.clip(request.rawBody, LEN_LONG_TEXT),
            Raw_Headers__c = InboundEmailFieldUtil.clip(request.rawHeaders, LEN_LONG_TEXT),
            Message_Id__c = InboundEmailFieldUtil.clip(request.messageId, LEN_TEXT),
            In_Reply_To__c = InboundEmailFieldUtil.clip(request.inReplyTo, LEN_TEXT),
            References__c = InboundEmailFieldUtil.clip(request.references, LEN_REFERENCES),
            Forwarded_By__c = InboundEmailFieldUtil.sanitizeEmail(request.forwardedBy),
            Image_Mime_Type__c = InboundEmailFieldUtil.clip(request.imageMimeType, LEN_TEXT),
            Has_Image__c = request.hasImage == true,
            Status__c = STATUS_PENDING
        );
        insert staging;
        return staging.Id;
    }

    /**
     * Load the staging record for the async job. A thin delegation to
     * InboundEmailStagingSelector so ExtractAddressQueueable keeps its invariant of
     * calling services only and holding no data access of its own.
     *
     * @param stagingId The staging Id the job was enqueued for; null returns null.
     * @return The staging record, or null when it is missing (hard-deleted between the
     *         synchronous insert and the async run).
     */
    public static Inbound_Email_Staging__c getStaging(Id stagingId) {
        return InboundEmailStagingSelector.selectById(stagingId);
    }

    /**
     * The full result of routing ONE inbound email, which since D1 can be N results rather
     * than one. A DTO for the same reason StagingRequest is one: the alternative is a
     * six-parameter stamp whose Id and String arguments are trivially transposable.
     *
     * WHY Result_Record_Id__c IS NOT WIDENED (C-16). It is Text(18) and holds exactly one
     * Id; every existing consumer and the operations runbook read it that way. Rather than
     * break them, it keeps its meaning — the PRIMARY routed record — and the complete
     * N-result mapping lives in the new Routed_Record_Ids__c long text. A single-property
     * email therefore stamps byte-identically to how it always has.
     */
    public class RoutingResult {
        /** The PRIMARY routed record: first WINNER Lead, else first COMPETING winner, else
         *  the REPLY/REPEAT target, else null. */
        public Id resultRecordId;
        /** Outcome__c label. For N = 1 this is today's label unchanged; for N > 1 it is the
         *  'Multi-Property (N): ...' summary. */
        public String outcome;
        /** Routed_Record_Ids__c — one line per routed property, in PROCESSING order:
         *  `&lt;normalized address&gt; | &lt;outcome&gt; | &lt;recordId&gt;`. The only place the full
         *  mapping exists. Null for the single-result branches. */
        public String routedRecordIds;
        /** Property_Count__c — how many properties the extraction FOUND (pre-truncation).
         *  When this exceeds the number of lines in routedRecordIds, the difference IS the
         *  truncation signal. */
        public Integer propertyCount;
        /** Error__c text. Blank means the run succeeded; non-blank stamps Status 'Error'
         *  while still recording whatever routing DID achieve. */
        public String errorText;
    }

    /**
     * Store the raw LLM response on the staging row (D3 tier 1), BEFORE any routing
     * decision is taken.
     *
     * The ordering is the point: written first, the extraction survives every branch —
     * including the ones that create no Lead (reply, repeat, competing, gated) and
     * including an exception thrown later in the transaction. It is written through
     * InboundEmailFieldUtil.clip because an over-long response would otherwise throw
     * STRING_TOO_LONG and take the claim down with it.
     *
     * FAIL-SOFT, like the mark* methods: a failure to persist the audit copy must never
     * cost the email its routing.
     *
     * @param stagingId  The staging row to stamp; null is a no-op.
     * @param extractedJson The model's response verbatim, or a `{"skipped":"..."}` marker
     *                      for the branches that deliberately skip the callout (C-6).
     * @example
     * InboundEmailStagingService.storeExtractedJson(stagingId, extraction.rawJson);
     */
    public static void storeExtractedJson(Id stagingId, String extractedJson) {
        if (stagingId == null) {
            return;
        }
        try {
            update new Inbound_Email_Staging__c(
                Id = stagingId,
                Extracted_JSON__c = InboundEmailFieldUtil.clip(extractedJson, LEN_LONG_TEXT)
            );
        } catch (DmlException de) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.storeExtractedJson: could not store the extraction for staging '
                + stagingId + ': ' + de.getMessage());
        }
    }

    /**
     * Stamp the terminal state for a routing run that may have produced N results.
     * Status is derived from the result: 'Error' when `errorText` is non-blank (the routing
     * that DID succeed is still recorded alongside it), 'Processed' otherwise.
     *
     * @param stagingId The staging row to stamp; null is a no-op.
     * @param result    The routing result; must not be null.
     * @example
     * InboundEmailStagingService.markRouted(stagingId, result);
     */
    public static void markRouted(Id stagingId, RoutingResult result) {
        stamp(stagingId,
            String.isBlank(result.errorText) ? STATUS_PROCESSED : STATUS_ERROR,
            result.resultRecordId, result.outcome, result.errorText,
            result.routedRecordIds, result.propertyCount);
    }

    /**
     * Stamp the terminal SUCCESS state: Status 'Processed', the routing outcome label,
     * the Id of the record the email was routed to, and the processed timestamp.
     *
     * @param stagingId      The staging row to stamp.
     * @param resultRecordId The record the email ended up attached to (Lead, Opportunity,
     *                       Contact, ...); may be null when routing produced no record.
     * @param outcome        The routing outcome label (see ExtractAddressQueueable's OUTCOME_* constants).
     */
    public static void markProcessed(Id stagingId, Id resultRecordId, String outcome) {
        stamp(stagingId, STATUS_PROCESSED, resultRecordId, outcome, null, null, null);
    }

    /**
     * Stamp the terminal SKIPPED state. Used by the Message-ID idempotency check: the
     * email is a redelivery of a message already logged, so no routing runs. Recorded as
     * 'Processed' (the row reached a correct terminal state — nothing was lost) with an
     * outcome label that says it was skipped, because Status__c is a restricted picklist
     * of Pending / Processed / Error with no separate "skipped" value.
     *
     * @param stagingId The staging row to stamp.
     * @param outcome   The skip label (e.g. 'Duplicate Delivery (skipped)').
     */
    public static void markSkipped(Id stagingId, String outcome) {
        stamp(stagingId, STATUS_PROCESSED, null, outcome, null, null, null);
    }

    /**
     * Stamp the terminal ERROR state: Status 'Error' plus the full exception text.
     * `resultRecordId` and `outcome` are still written when routing had already succeeded
     * before the failure (e.g. the claim committed and the Task insert then failed), so
     * the row records BOTH what was achieved and what broke rather than discarding the
     * successful half.
     *
     * @param stagingId      The staging row to stamp.
     * @param resultRecordId The record routing produced before the failure, or null.
     * @param outcome        The outcome reached before the failure, or null.
     * @param errorText      Type, message, line number and stack trace of the failure.
     */
    public static void markError(Id stagingId, Id resultRecordId, String outcome, String errorText) {
        stamp(stagingId, STATUS_ERROR, resultRecordId, outcome, errorText, null, null);
    }

    /**
     * Single update path for all terminal states. Swallows its own DmlException by
     * design — see the FAIL-SOFT note in the class header: this is the last statement of a
     * branch whose real work has already committed, and throwing here would misreport a
     * successful claim as an async failure.
     *
     * @param stagingId       The staging row to stamp; null is a no-op.
     * @param status          Status__c value ('Processed' or 'Error').
     * @param resultRecordId  Result_Record_Id__c (clipped to the field's 18 characters).
     * @param outcome         Outcome__c label.
     * @param errorText       Error__c text, or null on the success paths.
     * @param routedRecordIds Routed_Record_Ids__c — the full N-result audit, or null.
     * @param propertyCount   Property_Count__c — properties found pre-truncation, or null.
     */
    private static void stamp(Id stagingId, String status, Id resultRecordId, String outcome,
                              String errorText, String routedRecordIds, Integer propertyCount) {
        if (stagingId == null) {
            return;
        }
        try {
            update new Inbound_Email_Staging__c(
                Id = stagingId,
                Status__c = status,
                Outcome__c = InboundEmailFieldUtil.clip(outcome, LEN_TEXT),
                Result_Record_Id__c = InboundEmailFieldUtil.clip(
                    resultRecordId == null ? null : String.valueOf(resultRecordId), LEN_RECORD_ID),
                Error__c = InboundEmailFieldUtil.clip(errorText, LEN_ERROR),
                Routed_Record_Ids__c = InboundEmailFieldUtil.clip(routedRecordIds, LEN_ROUTED_IDS),
                Property_Count__c = propertyCount,
                Processed_DateTime__c = Datetime.now()
            );
        } catch (DmlException de) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.stamp: could not stamp staging ' + stagingId
                + ' as "' + status + '": ' + de.getMessage());
        }
    }
}
