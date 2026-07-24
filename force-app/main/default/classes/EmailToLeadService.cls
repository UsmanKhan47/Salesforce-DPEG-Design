/**
 * Broker-Protection inbound-email intake — Lead DML layer (CHUNK 3). This is the ONLY
 * place a Lead is inserted or updated in the email-to-lead pipeline: it keeps the thin
 * boundary handler (EmailToLeadHandler) and the callout orchestrator
 * (ExtractAddressQueueable) completely free of Lead DML, per the layering contract.
 *
 * LAYER — Service (Lead write side). No SOQL (new Lead(Id=..) needs no query), no
 * callouts. Its two responsibilities are:
 *   1. createLeadAndEnqueue(...) — shape + insert the raw Lead from the inbound email,
 *      then hand off asynchronous LLM extraction / first-broker-wins claiming to
 *      ExtractAddressQueueable.
 *   2. applyExtractedDetails(...) — the single Lead-detail write, called back by the
 *      queueable once the LLM (and regex fallback) have resolved the broker fields.
 *
 * DML MODEL — plain insert/update (system mode). This deliberately matches the repo's
 * established service pattern (cf. ContractExecutionService, LeadConvertService,
 * PropertyClaimService): the project has no UnitOfWork class (verified 2026-07-24) and
 * these writes are single-record-shaped (one inbound email == one Lead), never in a
 * loop. AccessLevel.USER_MODE is intentionally NOT applied — the inbound-email handler
 * runs in an automated/system context with no running user's FLS to enforce.
 *
 * @see EmailToLeadHandler.cls (the InboundEmailHandler boundary that calls createLeadAndEnqueue)
 * @see ExtractAddressQueueable.cls (the async orchestrator that calls applyExtractedDetails)
 * @see PropertyClaimService.cls (the first-broker-wins claim writer)
 */
public with sharing class EmailToLeadService {

    /** Placeholder Company for a Lead born from an email (Company is a required Lead field). */
    private static final String COMPANY_PLACEHOLDER = 'Unknown - Via Email';

    /** LeadSource stamped on every email-intake Lead — the pipeline's provenance marker. */
    private static final String LEAD_SOURCE = 'Email-to-Lead';

    /** Initial Lead Status for a freshly intaken email Lead. */
    private static final String STATUS_NEW = 'New';

    /** LastName fallback when the inbound email carries no sender display name. */
    private static final String DEFAULT_LAST_NAME = 'Unknown';

    /** Extracted-field map keys — the exact contract produced by LLMExtractionCalloutService. */
    private static final String KEY_BROKER_NAME = 'broker_name';
    private static final String KEY_BROKER_EMAIL = 'broker_email';
    private static final String KEY_PROPERTY_ADDRESS = 'property_address';

    /**
     * Create the raw Lead for an inbound broker email and enqueue asynchronous field
     * extraction + first-broker-wins claiming. The Lead is inserted with only what the
     * envelope already tells us (sender name/address, subject, body); the broker /
     * property details are filled in later by the queueable via applyExtractedDetails.
     *
     * Name derivation: when `fromName` contains a space it is split into
     * FirstName / LastName; a spaceless name becomes LastName; a null name falls back to
     * 'Unknown' (LastName is required). Description is the plain-text body when present,
     * otherwise the HTML body — the same value passed to the queueable as the LLM's
     * text content.
     *
     * @param fromName      Sender display name from the inbound envelope; may be null.
     * @param fromAddress   Sender email address → Lead.Email (and forwardedByEmail seed).
     * @param subject       Inbound email subject → Lead.Email_Subject__c.
     * @param plainTextBody Plain-text body; preferred for Description and LLM text content.
     * @param htmlBody       HTML body; used when there is no plain-text body.
     * @param imageBase64   Base64 of an optional inline image attachment (may be null).
     * @param imageMimeType MIME type for that image (may be null).
     * @return The Id of the inserted Lead.
     * @example
     * Id leadId = EmailToLeadService.createLeadAndEnqueue(
     *     'Jane Broker', 'jane@acme.com', 'FW: 100 Main St',
     *     plainBody, htmlBody, null, null);
     */
    public static Id createLeadAndEnqueue(String fromName, String fromAddress, String subject,
                                          String plainTextBody, String htmlBody,
                                          String imageBase64, String imageMimeType) {
        Lead lead = new Lead();
        if (fromName != null) {
            applyName(lead, fromName);
        } else {
            lead.LastName = DEFAULT_LAST_NAME;
        }
        lead.Email = fromAddress;
        lead.Email_Subject__c = subject;
        lead.Company = COMPANY_PLACEHOLDER;
        lead.LeadSource = LEAD_SOURCE;
        lead.Status = STATUS_NEW;
        lead.Description = plainTextBody != null ? plainTextBody : htmlBody;
        insert lead;

        String textContent = plainTextBody != null ? plainTextBody : htmlBody;
        System.enqueueJob(new ExtractAddressQueueable(
            lead.Id, textContent, imageBase64, imageMimeType, fromAddress, subject
        ));
        return lead.Id;
    }

    /**
     * Apply the LLM- (and regex-fallback-) resolved broker/property fields onto the Lead.
     * This is the ONLY Lead-detail write in the pipeline — the queueable never touches
     * Lead DML itself. Every field is applied only when its extracted value is non-blank,
     * so a partial extraction never blanks out a value that was already correct on insert.
     *
     * @param leadId          The Lead created by createLeadAndEnqueue.
     * @param extracted       Extracted-field map (broker_name, broker_email,
     *                        property_address, ...); a null map is treated as empty.
     * @param forwardedByEmail Internal user who forwarded the broker email; applied when
     *                        non-blank.
     */
    public static void applyExtractedDetails(Id leadId, Map<String, String> extracted, String forwardedByEmail) {
        Map<String, String> fields = (extracted == null) ? new Map<String, String>() : extracted;

        Lead l = new Lead(Id = leadId);

        String brokerName = fields.get(KEY_BROKER_NAME);
        if (String.isNotBlank(brokerName)) {
            applyName(l, brokerName);
        }

        String brokerEmail = fields.get(KEY_BROKER_EMAIL);
        if (String.isNotBlank(brokerEmail)) {
            l.Email = brokerEmail;
        }

        String propertyAddress = fields.get(KEY_PROPERTY_ADDRESS);
        if (String.isNotBlank(propertyAddress)) {
            l.Property_Address__c = propertyAddress;
        }

        if (String.isNotBlank(forwardedByEmail)) {
            l.Forwarded_By_Email__c = forwardedByEmail;
        }

        update l;
    }

    /**
     * Split a raw person name onto a Lead's FirstName / LastName, whitespace-safe:
     *   - null / blank / whitespace-only  -> LastName = 'Unknown' (the required-field default).
     *   - one token                       -> LastName = that token (FirstName untouched).
     *   - two or more tokens              -> FirstName = first token, LastName = ALL remaining
     *                                        tokens joined with a single space (the tail is
     *                                        never dropped, so 'Mary Jane Watson' -> Mary /
     *                                        'Jane Watson').
     *
     * The input is trimmed and split on `\\s+` so a trailing space ('Jane '), a double space
     * ('Jane  Broker'), or any run of whitespace collapses cleanly — the previous split(' ')
     * + parts[1] form threw an index-out-of-bounds on a trailing space (which, via
     * createLeadAndEnqueue on email.fromName, bounced the whole email and lost the Lead) and
     * blanked the required LastName on a double space.
     *
     * @param lead    The Lead to stamp.
     * @param rawName The sender / broker name; may be null, blank, or multi-token.
     */
    private static void applyName(Lead lead, String rawName) {
        String cleaned = (rawName == null) ? '' : rawName.trim();
        if (String.isBlank(cleaned)) {
            lead.LastName = DEFAULT_LAST_NAME;
            return;
        }

        List<String> parts = cleaned.split('\\s+');
        if (parts.size() == 1) {
            lead.LastName = parts[0];
            return;
        }

        lead.FirstName = parts[0];
        parts.remove(0);
        lead.LastName = String.join(parts, ' ');
    }
}
