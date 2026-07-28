/**
 * Broker-Protection inbound-email intake — Lead DML layer (staging model). This is the
 * ONLY place a Lead is inserted in the email-to-lead pipeline: it keeps the thin boundary
 * handler (EmailToLeadHandler) and the async orchestrator (ExtractAddressQueueable)
 * completely free of Lead DML, per the layering contract.
 *
 * WHAT CHANGED WITH THE STAGING MODEL, AND WHY. The previous shape was
 * createLeadAndEnqueue → insert a bare Lead from the envelope → enqueue → update it with
 * the LLM's answers. That forced a Lead into existence before the pipeline knew anything
 * about the email, which made three whole classes of email impossible to handle correctly:
 * a reply inside an existing thread, a repeat from a broker who had already submitted, and
 * a redelivery of a message already processed all produced a junk Lead that then had to be
 * cleaned up by hand. The durable artefact is now Inbound_Email_Staging__c, written
 * synchronously by the handler, so Lead creation can be deferred until the routing tree has
 * decided a Lead is actually warranted.
 *
 * The consequence for this class is that insert-then-update collapses into ONE insert:
 * createLeadFromExtracted is called only after extraction, so the Lead is born complete.
 * That removes a DML statement per email and, more importantly, removes the window in which
 * a Lead existed with envelope-only data.
 *
 * LAYER — Service (Lead write side). No SOQL, no callouts.
 *
 * DML MODEL — plain insert (system mode). This deliberately matches the repo's established
 * service pattern (cf. ContractExecutionService, LeadConvertService, PropertyClaimService):
 * the project has no UnitOfWork class (verified 2026-07-24) and this write is
 * single-record-shaped (one inbound email == at most one Lead), never in a loop.
 * AccessLevel.USER_MODE is intentionally NOT applied — the inbound-email pipeline runs in
 * an automated context with no interactive user's FLS to enforce.
 *
 * @see EmailToLeadHandler.cls (the InboundEmailHandler boundary)
 * @see ExtractAddressQueueable.cls (the async router — the only caller of this class)
 * @see PropertyClaimService.cls (the first-broker-wins claim writer)
 */
public with sharing class EmailToLeadService {

    /** Placeholder Company for a Lead born from an email (Company is a required Lead field). */
    private static final String COMPANY_PLACEHOLDER = 'Unknown - Via Email';

    /** LeadSource stamped on every email-intake Lead — the pipeline's provenance marker. */
    private static final String LEAD_SOURCE = 'Email-to-Lead';

    /** Initial Lead Status for a freshly intaken email Lead. */
    private static final String STATUS_NEW = 'New';

    /** LastName fallback when neither the LLM nor the envelope yields a sender name. */
    private static final String DEFAULT_LAST_NAME = 'Unknown';

    /** Extracted-field map keys — the exact contract produced by LLMExtractionCalloutService. */
    private static final String KEY_BROKER_NAME = 'broker_name';
    private static final String KEY_BROKER_EMAIL = 'broker_email';
    private static final String KEY_PROPERTY_ADDRESS = 'property_address';

    /** Destination field lengths — Lead.Description is a 32k LongTextArea, the rest Text(255). */
    private static final Integer LEN_TEXT = 255;
    private static final Integer LEN_DESCRIPTION = 32000;

    /** Standard Lead name field lengths. */
    private static final Integer LEN_FIRST_NAME = 40;
    private static final Integer LEN_LAST_NAME = 80;

    /**
     * Insert the Lead for one inbound broker email, complete on the first write.
     *
     * PRECEDENCE — the LLM's answer beats the envelope, and the envelope beats nothing:
     *   • Name  — `broker_name` when extracted, else the envelope display name, else
     *             LastName 'Unknown' (LastName is required).
     *   • Email — `broker_email` when extracted, else the envelope From address.
     * This ordering matters because on a MANUALLY forwarded email the envelope describes the
     * INTERNAL person who forwarded it, not the broker; only the LLM (reading the quoted
     * original inside the body) knows who the broker actually is. On an auto-forwarded email
     * the envelope is the broker, and the LLM agrees — so the same rule is right either way.
     *
     * Values are clipped and addresses sanitized (InboundEmailFieldUtil) before DML: the raw
     * body can exceed Description's 32k limit and an LLM "email" can be a display name, and
     * either one would otherwise throw and abort the routing transaction.
     *
     * @param extracted        LLM-extracted fields (broker_name, broker_email,
     *                         property_address, ...); a null map is treated as empty.
     * @param fromName         Envelope display name — the name fallback.
     * @param fromAddress      Envelope From address — the email fallback.
     * @param emailSubject     Inbound subject → Email_Subject__c.
     * @param rawBody          Raw email body → Description.
     * @param forwardedByEmail The monitored inbox that forwarded the email →
     *                         Forwarded_By_Email__c; applied only when it is a valid address.
     * @return The Id of the inserted Lead.
     * @throws DmlException when the Lead insert fails; the caller records it on the staging
     *         row's Error__c and the email is recoverable from that row.
     * @example
     * Id leadId = EmailToLeadService.createLeadFromExtracted(
     *     extracted, staging.From_Name__c, staging.From_Address__c,
     *     staging.Subject__c, staging.Raw_Body__c, staging.Forwarded_By__c);
     */
    public static Id createLeadFromExtracted(Map<String, String> extracted, String fromName,
                                             String fromAddress, String emailSubject,
                                             String rawBody, String forwardedByEmail) {
        Map<String, String> fields = (extracted == null) ? new Map<String, String>() : extracted;

        Lead lead = new Lead();

        String brokerName = fields.get(KEY_BROKER_NAME);
        applyName(lead, String.isNotBlank(brokerName) ? brokerName : fromName);

        String brokerEmail = InboundEmailFieldUtil.sanitizeEmail(fields.get(KEY_BROKER_EMAIL));
        lead.Email = (brokerEmail != null)
            ? brokerEmail
            : InboundEmailFieldUtil.sanitizeEmail(fromAddress);

        lead.Company = COMPANY_PLACEHOLDER;
        lead.LeadSource = LEAD_SOURCE;
        lead.Status = STATUS_NEW;
        lead.Email_Subject__c = InboundEmailFieldUtil.clip(emailSubject, LEN_TEXT);
        lead.Description = InboundEmailFieldUtil.clip(rawBody, LEN_DESCRIPTION);

        String propertyAddress = fields.get(KEY_PROPERTY_ADDRESS);
        if (String.isNotBlank(propertyAddress)) {
            lead.Property_Address__c = InboundEmailFieldUtil.clip(propertyAddress, LEN_TEXT);
        }

        String forwardedBy = InboundEmailFieldUtil.sanitizeEmail(forwardedByEmail);
        if (forwardedBy != null) {
            lead.Forwarded_By_Email__c = forwardedBy;
        }

        insert lead;
        return lead.Id;
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
     * + parts[1] form threw an index-out-of-bounds on a trailing space (which bounced the
     * whole email and lost the Lead) and blanked the required LastName on a double space.
     *
     * Both parts are clipped to the standard Lead name lengths (FirstName 40, LastName 80).
     * That is not cosmetic: `broker_name` is LLM output and has been observed to come back as
     * a whole signature block, which would throw STRING_TOO_LONG and roll back the routing
     * transaction. A truncated broker name is trivially fixable by hand; a rolled-back claim
     * is not.
     *
     * @param lead    The Lead to stamp.
     * @param rawName The broker / sender name; may be null, blank, or multi-token.
     */
    private static void applyName(Lead lead, String rawName) {
        String cleaned = (rawName == null) ? '' : rawName.trim();
        if (String.isBlank(cleaned)) {
            lead.LastName = DEFAULT_LAST_NAME;
            return;
        }

        List<String> parts = cleaned.split('\\s+');
        if (parts.size() == 1) {
            lead.LastName = InboundEmailFieldUtil.clip(parts[0], LEN_LAST_NAME);
            return;
        }

        lead.FirstName = InboundEmailFieldUtil.clip(parts[0], LEN_FIRST_NAME);
        parts.remove(0);
        lead.LastName = InboundEmailFieldUtil.clip(String.join(parts, ' '), LEN_LAST_NAME);
    }
}
