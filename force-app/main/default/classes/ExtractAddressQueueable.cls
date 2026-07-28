/**
 * Broker-Protection inbound-email intake — async router (staging model). One instance is
 * enqueued per inbound broker email by EmailToLeadHandler, carrying the Id of the
 * Inbound_Email_Staging__c row that email was landed on. In an async, callout-capable
 * context it asks the LLM who the broker is and which property they are pitching, then runs
 * the ROUTING TREE that decides what that email actually is — and only then, if at all,
 * creates a Lead.
 *
 * ═══ THE ROUTING TREE ═══
 * Evaluated strictly in order; the first branch that matches wins. The order is not
 * arbitrary — each branch is a reason NOT to do what the branch below it would do.
 *
 *   (a) REPLY      — the email's In-Reply-To / References cite a thread this pipeline has
 *                    already logged. It is a continuation of an existing conversation, so it
 *                    is filed on that conversation's record (following a converted Lead
 *                    through to its live Opportunity). NO Lead is created. This must be first
 *                    because a reply almost always still quotes the original broker and
 *                    property, so every branch below it would happily create a duplicate.
 *   (b) REPEAT     — the same broker has already submitted this same property inside the
 *                    lookback window. It is a follow-up, so it is filed on THEIR existing
 *                    Lead with an audit row. NO new Lead. This precedes the duplicate branch
 *                    because a broker chasing their own submission is not a competing broker
 *                    and must never be flagged as one.
 *   (c) NO-PROPERTY— no usable address could be extracted. A Lead is created so nothing is
 *                    lost, but no claim is attempted: claiming a blank property would poison
 *                    the registry key. This is also where an LLM OUTAGE lands (see DEGRADED
 *                    EXTRACTION below), distinguished only by its outcome label.
 *   (d) DUPLICATE  — the property is already claimed by a DIFFERENT broker. A Lead is created
 *                    and flagged against the winner, with a competing-submission audit row.
 *   (e) WINNER     — nobody has claimed this property. A Lead is created and takes the claim
 *                    under the cluster lock.
 *
 * Every branch ends the same way: log the email as a Task (carrying both RFC threading keys,
 * which is what makes branch (a) possible for the NEXT email) and stamp the staging row with
 * the outcome, the routed record, and a timestamp.
 *
 * ═══ IDEMPOTENCY ═══
 * Two guards, before any work: a staging row already marked 'Processed' is never re-run, and
 * an RFC Message-ID already present on a Task means the platform is redelivering a message
 * that was already routed. A BLANK Message-ID skips only the second guard and proceeds
 * normally — some forwarding paths strip the header, and refusing those emails would be far
 * worse than reprocessing a rare duplicate.
 *
 * ═══ DEGRADED EXTRACTION (LLM OUTAGE) ═══
 * A CalloutException from the LLM boundary — a 429, a 5xx, a timeout — is NOT a failure of
 * this pipeline, it is the absence of one optional input. It is therefore caught at the
 * callout itself and DEGRADES rather than aborts: extraction becomes an empty map, the regex
 * fallback still recovers the broker's name and email from the raw "From:" line, and routing
 * proceeds normally. Because the regex fallback never yields a property address, the
 * degraded path can only ever reach branch (a) or branch (c) — so a real Lead is always
 * created (or an existing thread correctly reused) and the broker is never silently dropped
 * because OpenAI was rate-limiting. The staging row records OUTCOME_NO_PROPERTY_LLM_DOWN so
 * outage-degraded Leads are distinguishable from genuinely addressless emails and can be
 * re-extracted by hand.
 *
 * The alternative — treating the outage as an error and stamping Status 'Error' — left the
 * email on a staging row with no Lead, no Task, no notification and no claim: an
 * indistinguishable-from-lost broker submission caused by a transient third-party 429.
 *
 * ═══ LAYER ═══
 * Queueable orchestrator. It contains NO SOQL and NO DML of its own — every read goes through
 * a service (InboundEmailStagingService, PropertyMatchingService, InboundEmailActivityService)
 * and every write through the service that owns that object (EmailToLeadService for the Lead,
 * PropertyClaimService for the registry/submissions, InboundEmailActivityService for the Task,
 * InboundEmailStagingService for the staging row). The only external call is via
 * LLMExtractionCalloutService, the dedicated callout wrapper — this class implements
 * Database.AllowsCallouts so that boundary can run here and be mocked via HttpCalloutMock.
 *
 * `with sharing` is declared for standards conformance (ARCHITECTURE.md §2). It is functionally
 * a no-op here because the class performs no SOQL/DML directly — the classes it delegates to
 * enforce their own sharing.
 *
 * ═══ ERROR MODEL ═══
 * execute() swallows every REMAINING exception rather than letting the job fail (the callout
 * boundary is handled separately — see DEGRADED EXTRACTION). The email is already
 * durable on the staging row, so nothing is lost; the failure is written back to that row
 * (Status 'Error' plus the full stack trace) ALONGSIDE whatever outcome had already been
 * reached, so a Task-insert failure after a successful claim is recorded as both, not as a
 * blanket failure. Re-throwing would instead hand the platform an async failure with no
 * record of the work that did commit.
 *
 * @see EmailToLeadHandler.cls (creates the staging row and enqueues this job)
 * @see LLMExtractionCalloutService.cls (the mocked callout boundary)
 * @see PropertyMatchingService.cls / PropertyClaimService.cls (the first-broker-wins engine)
 */
public with sharing class ExtractAddressQueueable implements Queueable, Database.AllowsCallouts {

    /** Extracted-field map keys — the exact contract from LLMExtractionCalloutService. */
    private static final String KEY_BROKER_NAME = 'broker_name';
    private static final String KEY_BROKER_EMAIL = 'broker_email';
    private static final String KEY_PROPERTY_ADDRESS = 'property_address';
    private static final String KEY_SENT_DATETIME = 'sent_datetime';

    /**
     * Inbound_Email_Staging__c.Outcome__c labels — one per routing-tree branch. PUBLIC on
     * purpose: these strings are the pipeline's reporting contract (they are what an admin
     * filters an Inbound Email Staging list view on), so tests and any future dashboard bind
     * to the constant rather than re-typing the literal.
     */
    public static final String OUTCOME_DUPLICATE_DELIVERY = 'Duplicate Delivery (skipped)';
    public static final String OUTCOME_REPLY = 'Reply Thread';
    public static final String OUTCOME_REPEAT = 'Repeat';
    public static final String OUTCOME_NO_PROPERTY = 'New Lead (no property)';
    /** Branch (c) reached because the LLM was unreachable, not because the email had no
     *  address. Kept distinct from OUTCOME_NO_PROPERTY on purpose: these are the only Leads
     *  worth re-extracting once the outage clears, and an admin needs to be able to list
     *  exactly them. */
    public static final String OUTCOME_NO_PROPERTY_LLM_DOWN = 'New Lead (no property) — LLM unavailable';
    public static final String OUTCOME_DUPLICATE = 'Competing Duplicate';
    public static final String OUTCOME_WINNER = 'New Lead (winner)';
    public static final String OUTCOME_UNCLAIMED = 'New Lead (unclaimed)';

    /** Inbound_Email_Staging__c.Status__c value that means "already fully routed". */
    private static final String STATUS_PROCESSED = 'Processed';

    /** First "From:" line of a forwarded email — the OUTERMOST/EARLIEST (original broker)
     *  line, consistent with the LLM extraction prompt. Multiline + case-insensitive. */
    private static final Pattern FROM_LINE_PATTERN = Pattern.compile('(?im)^\\s*From:\\s*(.+)$');

    /** Email-address regex used by the regex fallback (matches the LLM's own contract). */
    private static final String EMAIL_REGEX = '[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}';

    /**
     * TEST-ONLY seam. When true, execute() skips the pre-claim registry lookup in branch (d)
     * and forces the claim path so PropertyClaimService's duplicate-value race recovery is
     * reachable from tests. NEVER set this outside a test class — in production it would
     * suppress the cheap "already a winner" short-circuit and always attempt the optimistic
     * insert.
     */
    @TestVisible private static Boolean forceClaimRace = false;

    private final Id stagingId;
    private final String imageBase64;
    private final String imageMimeType;

    /**
     * The staging row, loaded at the top of execute(). Mutable (not final) because it is
     * fetched during execution, not supplied to the constructor: the Queueable payload stays
     * small — three primitives — instead of serialising a whole SObject with a 131k body.
     */
    private Inbound_Email_Staging__c staging;

    /**
     * The record routing resolved and the label for how it got there. Held as members, not
     * locals, so the catch block can report a PARTIAL success: if the claim committed and the
     * Task insert then failed, the staging row records both the outcome reached and the error.
     */
    private Id routedRecordId;
    private String routedOutcome;

    /**
     * Capture the immutable job payload for one inbound broker email.
     *
     * The image is passed as a constructor argument rather than read from the staging row
     * because base64 image data exceeds any text field — the staging object deliberately
     * records only Has_Image__c / Image_Mime_Type__c, and the bytes are needed exactly once,
     * by the vision call in this job.
     *
     * @param stagingId     The Inbound_Email_Staging__c row created for this inbound email.
     * @param imageBase64   Base64 of an optional inline image (may be null).
     * @param imageMimeType MIME type for that image (may be null).
     */
    public ExtractAddressQueueable(Id stagingId, String imageBase64, String imageMimeType) {
        this.stagingId = stagingId;
        this.imageBase64 = imageBase64;
        this.imageMimeType = imageMimeType;
    }

    /**
     * Load → guard → extract → route → log → stamp. See the class header for the routing tree
     * and the error model.
     *
     * @param ctx The queueable context (unused; required by the interface).
     */
    public void execute(QueueableContext ctx) {
        staging = InboundEmailStagingService.getStaging(stagingId);
        if (staging == null) {
            // The row was hard-deleted between the synchronous insert and this async run.
            // There is nothing left to route and nothing left to stamp.
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.execute: staging record ' + stagingId + ' not found.');
            return;
        }

        try {
            if (STATUS_PROCESSED.equals(staging.Status__c)) {
                // The platform re-ran a job whose row is already terminal. Re-routing would
                // mint a second Lead for one email.
                System.debug(LoggingLevel.WARN,
                    'ExtractAddressQueueable.execute: staging ' + stagingId
                    + ' is already Processed; skipping re-run.');
                return;
            }

            if (InboundEmailActivityService.isAlreadyLogged(staging.Message_Id__c)) {
                InboundEmailStagingService.markSkipped(stagingId, OUTCOME_DUPLICATE_DELIVERY);
                return;
            }

            // DEGRADED EXTRACTION — the callout is caught HERE, not by the outer handler,
            // so an LLM outage costs the email its address rather than its existence.
            // Deliberately narrow: only CalloutException (non-200, timeout, connection
            // failure) degrades; a parsing/JSON failure inside extract() is a defect in our
            // own contract and still escapes to the error handler below.
            Boolean llmUnavailable = false;
            Map<String, String> extracted = null;
            try {
                extracted = new LLMExtractionCalloutService()
                    .extract(staging.Raw_Body__c, imageBase64, imageMimeType);
            } catch (CalloutException ce) {
                llmUnavailable = true;
                System.debug(LoggingLevel.WARN,
                    'ExtractAddressQueueable.execute: LLM extraction unavailable for staging '
                    + stagingId + ' — degrading to the regex fallback. ' + ce.getMessage());
            }
            if (extracted == null) {
                // Defensive: the degraded path, and any future contract change that lets
                // extract() return null, must both arrive at the fallback with a usable map.
                extracted = new Map<String, String>();
            }
            applyRegexFallback(extracted);

            String normalized =
                PropertyMatchingService.normalizeAddress(extracted.get(KEY_PROPERTY_ADDRESS));
            Datetime submittedOn = parseSentDatetime(extracted.get(KEY_SENT_DATETIME));

            route(extracted, normalized, submittedOn, llmUnavailable);

            InboundEmailActivityService.logInboundEmail(
                routedRecordId, staging.Subject__c, staging.Raw_Body__c,
                staging.Message_Id__c, staging.In_Reply_To__c, staging.References__c);

            InboundEmailStagingService.markProcessed(stagingId, routedRecordId, routedOutcome);
        } catch (Exception e) {
            String errorText = e.getTypeName() + ' | ' + e.getMessage()
                + ' | line ' + e.getLineNumber() + ' | ' + e.getStackTraceString();
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.execute failed for staging ' + stagingId + ': ' + errorText);
            // routedRecordId / routedOutcome carry whatever routing achieved BEFORE the
            // failure, so a successful claim followed by a failed Task insert is recorded as
            // both rather than discarded.
            InboundEmailStagingService.markError(stagingId, routedRecordId, routedOutcome, errorText);
        }
    }

    /**
     * The routing tree. Sets `routedRecordId` / `routedOutcome` in place rather than returning
     * a value, so that a failure in a LATER step (the Task insert) can still report which
     * branch had already committed its work.
     *
     * @param extracted      LLM-extracted fields, already regex-backfilled.
     * @param normalized     Normalized property address; blank means none could be extracted.
     * @param submittedOn    The email's original send time.
     * @param llmUnavailable True when the LLM callout failed and `extracted` holds only what
     *                       the regex fallback recovered. Affects the OUTCOME LABEL ONLY —
     *                       never which branch is taken.
     */
    private void route(Map<String, String> extracted, String normalized, Datetime submittedOn,
                       Boolean llmUnavailable) {
        String fromAddress = staging.From_Address__c;
        String forwardedBy = staging.Forwarded_By__c;
        String emailSubject = staging.Subject__c;

        // (a) REPLY — a continuation of a thread already logged. No Lead.
        Id priorRecord = PropertyMatchingService.findRecordByReplyHeaders(
            staging.In_Reply_To__c, staging.References__c);
        if (priorRecord != null) {
            routedRecordId = PropertyMatchingService.resolveLiveRecord(priorRecord);
            routedOutcome = OUTCOME_REPLY;
            return;
        }

        // (b) REPEAT — the same broker, the same property, again. Reuse their Lead.
        // Two lookups because the broker can be identified two ways and either may be the
        // one that was recorded last time: the LLM's answer (right for a manual forward,
        // where the broker is only inside the quoted body) and the envelope From (right for
        // an auto-forward, where the broker IS the sender). The second is skipped when it
        // would repeat the first.
        String brokerEmail = extracted.get(KEY_BROKER_EMAIL);
        Competing_Broker_Submission__c prior =
            PropertyMatchingService.findBrokerSubmission(brokerEmail, normalized);
        if (prior == null && String.isNotBlank(fromAddress) && !fromAddress.equalsIgnoreCase(brokerEmail)) {
            prior = PropertyMatchingService.findBrokerSubmission(fromAddress, normalized);
        }
        if (prior != null) {
            PropertyClaimService.logRepeatSubmission(
                prior.Winning_Lead__c, prior.Source_Lead__c, extracted, submittedOn,
                forwardedBy, emailSubject);
            routedRecordId = PropertyMatchingService.resolveLiveRecord(prior.Source_Lead__c);
            routedOutcome = OUTCOME_REPEAT;
            return;
        }

        // (c) NO-PROPERTY — keep the Lead, attempt no claim. A blank key would collide with
        // every other addressless email on the registry's unique index.
        //
        // This is also the LLM-outage landing point, and necessarily so: the regex fallback
        // backfills only broker_name / broker_email, so a degraded extraction ALWAYS leaves
        // `normalized` blank and can never reach branches (d) or (e). Only the label differs
        // — claiming on an address nobody actually read would be a guess written to a
        // permanent, unique-keyed ledger.
        if (String.isBlank(normalized)) {
            routedRecordId = createLead(extracted);
            routedOutcome = (llmUnavailable == true) ? OUTCOME_NO_PROPERTY_LLM_DOWN : OUTCOME_NO_PROPERTY;
            return;
        }

        // (d) DUPLICATE — a different broker already holds this property. The cheap read
        // avoids taking the cluster lock for a claim that is already settled; claim() re-checks
        // under the lock, so this short-circuit can only ever be an optimisation, never the
        // authority.
        Property_Registry__c existing =
            forceClaimRace ? null : PropertyMatchingService.findMatchingRegistry(normalized);
        Id leadId = createLead(extracted);
        if (existing != null) {
            PropertyClaimService.markDuplicate(
                existing, leadId, extracted, submittedOn, forwardedBy, emailSubject);
            routedRecordId = leadId;
            routedOutcome = OUTCOME_DUPLICATE;
            return;
        }

        // (e) WINNER — unclaimed property. claim() reports what it actually did (a concurrent
        // claim can win between the read above and the lock), so the outcome recorded is the
        // truth rather than this branch's optimistic assumption.
        PropertyClaimService.ClaimOutcome claimed = PropertyClaimService.claim(
            leadId, normalized, extracted, submittedOn, forwardedBy, emailSubject);
        routedRecordId = leadId;
        routedOutcome = toOutcomeLabel(claimed);
    }

    /**
     * Create the Lead for this email from the extracted fields plus the staged envelope.
     * A single call site's worth of parameter marshalling, kept here so each routing branch
     * reads as one line.
     *
     * @param extracted LLM-extracted fields.
     * @return The Id of the inserted Lead.
     */
    private Id createLead(Map<String, String> extracted) {
        return EmailToLeadService.createLeadFromExtracted(
            extracted, staging.From_Name__c, staging.From_Address__c,
            staging.Subject__c, staging.Raw_Body__c, staging.Forwarded_By__c);
    }

    /**
     * Map a claim result onto its staging outcome label.
     *
     * @param claimed What PropertyClaimService.claim actually did.
     * @return The matching Outcome__c label.
     */
    private static String toOutcomeLabel(PropertyClaimService.ClaimOutcome claimed) {
        if (claimed == PropertyClaimService.ClaimOutcome.WINNER) {
            return OUTCOME_WINNER;
        }
        return (claimed == PropertyClaimService.ClaimOutcome.DUPLICATE)
            ? OUTCOME_DUPLICATE
            : OUTCOME_UNCLAIMED;
    }

    /**
     * Backfill blank broker_name / broker_email from the raw first "From:" line when the LLM
     * missed them. Only fills blanks — a good LLM answer is never overwritten — and does
     * nothing when there is no body text or when both fields are already present.
     *
     * @param extracted The mutable extracted-field map to backfill in place.
     */
    private void applyRegexFallback(Map<String, String> extracted) {
        String textContent = staging.Raw_Body__c;
        if (String.isBlank(textContent)) {
            return;
        }

        Boolean nameBlank = String.isBlank(extracted.get(KEY_BROKER_NAME));
        Boolean emailBlank = String.isBlank(extracted.get(KEY_BROKER_EMAIL));
        if (!nameBlank && !emailBlank) {
            return;
        }

        Matcher fromMatcher = FROM_LINE_PATTERN.matcher(textContent);
        if (!fromMatcher.find()) {
            return;
        }
        String fromLine = fromMatcher.group(1);

        if (emailBlank) {
            Matcher emailMatcher = Pattern.compile(EMAIL_REGEX).matcher(fromLine);
            if (emailMatcher.find()) {
                extracted.put(KEY_BROKER_EMAIL, emailMatcher.group());
            }
        }

        if (nameBlank) {
            String name = stripToName(fromLine);
            if (String.isNotBlank(name)) {
                extracted.put(KEY_BROKER_NAME, name);
            }
        }
    }

    /**
     * Reduce a raw "From:" line to a bare display name: strip any &lt;...&gt; angle-bracket
     * block and any bare email address, drop quote and parenthesis characters, collapse
     * whitespace, and trim.
     *
     * @param fromLine The raw content following "From:".
     * @return The cleaned display name (possibly empty).
     */
    private String stripToName(String fromLine) {
        return fromLine
            .replaceAll('<[^>]*>', ' ')
            .replaceAll(EMAIL_REGEX, ' ')
            .replaceAll('["\'()]', ' ')
            .replaceAll('\\s+', ' ')
            .trim();
    }

    /**
     * Parse the LLM's UTC 'yyyy-MM-dd HH:mm:ss' sent timestamp. Falls back to now() when the
     * value is blank or cannot be parsed, so a missing/garbled timestamp never blocks the
     * claim.
     *
     * @param raw The raw sent_datetime string (may be blank).
     * @return The parsed GMT Datetime, or now() on blank/parse failure.
     */
    private Datetime parseSentDatetime(String raw) {
        if (String.isNotBlank(raw)) {
            try {
                return Datetime.valueOfGmt(raw.trim());
            } catch (Exception e) {
                System.debug(LoggingLevel.DEBUG,
                    'ExtractAddressQueueable.parseSentDatetime: unparseable sent_datetime "'
                    + raw + '" — defaulting to now(). ' + e.getMessage());
            }
        }
        return Datetime.now();
    }
}
