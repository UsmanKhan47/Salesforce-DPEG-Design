/**
 * Broker-Protection inbound-email intake — async orchestrator (CHUNK 3). One instance is
 * enqueued per inbound broker email (by EmailToLeadService.createLeadAndEnqueue). In an
 * async, callout-capable context it: (1) asks the LLM to extract broker/property/timestamp
 * fields, (2) backfills any blank broker name/email from the raw "From:" line via regex,
 * (3) writes the resolved details onto the Lead, and (4) runs the first-broker-wins claim
 * against the Property_Registry__c ledger.
 *
 * LAYER — Queueable orchestrator. It contains NO inline SOQL and NO DML of its own: every
 * database write is delegated to a service (EmailToLeadService for the Lead detail write;
 * PropertyClaimService for the registry / submission writes), and every read is delegated
 * to PropertyMatchingService (which itself reads only through PropertyRegistrySelector).
 * The only external call is via LLMExtractionCalloutService, the dedicated callout wrapper
 * — this class implements Database.AllowsCallouts so that boundary can run here and be
 * mocked via HttpCalloutMock in tests.
 *
 * with sharing is declared for standards conformance (ARCHITECTURE.md §2 / sf-apex
 * hard-stop: every class declares a sharing keyword). It is functionally a no-op here
 * because the class performs no SOQL/DML directly — the classes it delegates to enforce
 * their own sharing.
 *
 * @see EmailToLeadService.cls (enqueues this job; owns the Lead DML it calls back into)
 * @see LLMExtractionCalloutService.cls (the mocked callout boundary)
 * @see PropertyMatchingService.cls / PropertyClaimService.cls (the first-broker-wins engine)
 */
public with sharing class ExtractAddressQueueable implements Queueable, Database.AllowsCallouts {

    /** Extracted-field map keys — the exact contract from LLMExtractionCalloutService. */
    private static final String KEY_BROKER_NAME = 'broker_name';
    private static final String KEY_BROKER_EMAIL = 'broker_email';
    private static final String KEY_PROPERTY_ADDRESS = 'property_address';
    private static final String KEY_SENT_DATETIME = 'sent_datetime';

    /** First "From:" line of a forwarded email — the OUTERMOST/EARLIEST (original broker)
     *  line, consistent with the LLM extraction prompt. Multiline + case-insensitive. */
    private static final Pattern FROM_LINE_PATTERN = Pattern.compile('(?im)^\\s*From:\\s*(.+)$');

    /** Email-address regex used by the regex fallback (matches the LLM's own contract). */
    private static final String EMAIL_REGEX = '[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}';

    /**
     * TEST-ONLY seam. When true, execute() skips the pre-claim registry lookup and forces
     * the claim path so PropertyClaimService's duplicate-value race recovery is reachable
     * from tests. NEVER set this outside a test class — in production it would suppress the
     * cheap "already a winner" short-circuit and always attempt the optimistic insert.
     */
    @TestVisible private static Boolean forceClaimRace = false;

    private final Id leadId;
    private final String textContent;
    private final String imageBase64;
    private final String imageMimeType;
    private final String forwardedByEmail;
    private final String emailSubject;

    /**
     * Capture the immutable job payload for one inbound broker email. All members are
     * final — the job is a self-contained unit of work for a single Lead.
     *
     * @param leadId          The Lead created for this inbound email.
     * @param textContent     Email body text passed to the LLM and to the regex fallback.
     * @param imageBase64     Base64 of an optional inline image (may be null).
     * @param imageMimeType   MIME type for that image (may be null).
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     */
    public ExtractAddressQueueable(Id leadId, String textContent, String imageBase64,
                                   String imageMimeType, String forwardedByEmail, String emailSubject) {
        this.leadId = leadId;
        this.textContent = textContent;
        this.imageBase64 = imageBase64;
        this.imageMimeType = imageMimeType;
        this.forwardedByEmail = forwardedByEmail;
        this.emailSubject = emailSubject;
    }

    /**
     * Extract → backfill → apply → claim. Wrapped in a try/catch so a single bad email
     * (callout failure, unparseable payload, etc.) is logged and swallowed rather than
     * failing the async job: the Lead already exists from the synchronous insert, so the
     * email is never lost — only its enrichment/claim is skipped on error.
     *
     * @param ctx The queueable context (unused; required by the interface).
     */
    public void execute(QueueableContext ctx) {
        try {
            Map<String, String> extracted =
                new LLMExtractionCalloutService().extract(textContent, imageBase64, imageMimeType);

            applyRegexFallback(extracted);
            EmailToLeadService.applyExtractedDetails(leadId, extracted, forwardedByEmail);

            String normalized = PropertyMatchingService.normalizeAddress(extracted.get(KEY_PROPERTY_ADDRESS));
            Datetime submittedOn = parseSentDatetime(extracted.get(KEY_SENT_DATETIME));

            if (String.isBlank(normalized)) {
                // No usable address — the record simply remains a normal Lead, unclaimed.
                return;
            }

            Property_Registry__c existing =
                forceClaimRace ? null : PropertyMatchingService.findMatchingRegistry(normalized);
            if (existing != null) {
                PropertyClaimService.markDuplicate(
                    existing, leadId, extracted, submittedOn, forwardedByEmail, emailSubject);
                return;
            }

            PropertyClaimService.claim(
                leadId, normalized, extracted, submittedOn, forwardedByEmail, emailSubject);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.execute failed: ' + e.getTypeName()
                + ' | ' + e.getMessage()
                + ' | line ' + e.getLineNumber()
                + ' | ' + e.getStackTraceString());
        }
    }

    /**
     * Backfill blank broker_name / broker_email from the raw first "From:" line when the
     * LLM missed them. Only fills blanks — a good LLM answer is never overwritten — and
     * does nothing when there is no text content or when both fields are already present.
     *
     * @param extracted The mutable extracted-field map to backfill in place.
     */
    private void applyRegexFallback(Map<String, String> extracted) {
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
     * Parse the LLM's UTC 'yyyy-MM-dd HH:mm:ss' sent timestamp. Falls back to now() when
     * the value is blank or cannot be parsed, so a missing/garbled timestamp never blocks
     * the claim.
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
