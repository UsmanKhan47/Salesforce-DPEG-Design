/**
 * Broker-Protection inbound-email intake — Lead DML layer (staging model). This is the
 * ONLY place a Lead is inserted OR deleted in the email-to-lead pipeline: it keeps the thin
 * boundary handler (EmailToLeadHandler) and the async orchestrator (ExtractAddressQueueable)
 * completely free of Lead DML, per the layering contract. Note that PropertyClaimService
 * likewise performs no Lead DML at all as of 2026-07-31 — the duplicate-flag write it used to
 * do is gone — so Lead writes in this module are wholly owned by this class.
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
 * ═══ THE INVARIANT, RESTATED (D1 multi-property, 2026-07-31) ═══
 * This class used to justify its plain single-record DML with the invariant
 * "one inbound email == at most one Lead". THAT INVARIANT IS NOW FALSE and must not be
 * quoted back. The correct statement is:
 *
 *      ONE PROPERTY == AT MOST ONE LEAD. ONE EMAIL CAN PRODUCE N.
 *
 * A broker blast pitching three properties produces up to three Leads and three claims;
 * ExtractAddressQueueable calls createLeadFromExtracted once per property inside its
 * per-property loop.
 *
 * ⚠ THAT LOOP IS DELIBERATE AND MUST NOT BE "BULKIFIED" (C-5). Two routes were considered
 * and both were rejected for concrete reasons, not taste:
 *   • Bulk-inserting all N Leads up front breaks branch (d)'s load-bearing ordering rule
 *     (the registry read runs BEFORE createLead), so it would mint an orphan Lead on every
 *     competing email — exactly the Lead-table pollution the 2026-07-31 change removed.
 *   • A two-pass decide-then-commit is genuinely bulk-shaped but requires splitting claim():
 *     registerWinner needs the Lead Id BEFORE inserting the registry row (a null
 *     Winning_Lead__c means "orphan" in this schema), so the unique-index backstop, orphan
 *     adoption and the isLostRaceAgainst self-match guard would all have to be re-derived
 *     against partial-success DML. That is the most subtle code in the module and the payoff
 *     is zero: N is 1-5 in production and capped at 10.
 * What the loop does NOT relax is the real rule: there is no SOQL or DML inside an inner
 * loop here, and every statement is one-per-property.
 *
 * LAYER — Service (Lead write side). No SOQL, no callouts.
 *
 * DML MODEL — plain insert (system mode). This deliberately matches the repo's established
 * service pattern (cf. ContractExecutionService, LeadConvertService, PropertyClaimService):
 * the project has no UnitOfWork class (verified 2026-07-24).
 * AccessLevel.USER_MODE is intentionally NOT applied — the inbound-email pipeline runs in
 * an automated context with no interactive user's FLS to enforce. Corollary worth stating
 * because it will otherwise be "fixed": the FLS granted on the 19 new Lead fields governs
 * HUMAN visibility and flexipage rendering only. It cannot affect this insert.
 *
 * DML MODEL — plain delete (system mode). Stated separately because a DESTRUCTIVE system-mode
 * DML does not get to inherit the insert's justification: running unrestricted means nothing
 * about the running user's Delete permission or record access can stop it. It is acceptable
 * here only because its blast radius is closed by construction rather than by permissions —
 * deleteLead is reachable from exactly one call site, on exactly one outcome
 * (ClaimOutcome.DUPLICATE_RACE), and the only Id it is ever passed is one this same class
 * minted seconds earlier in the same transaction. It can therefore never reach a Lead the
 * pipeline did not create. Enforcing USER_MODE instead would not add safety — it would make
 * the cleanup fail for the automated context that owns the record — and the surviving
 * Inbound_Email_Staging__c row preserves the email regardless. Any future caller that cannot
 * make the same guarantee must not use this method.
 *
 * @see EmailToLeadHandler.cls (the InboundEmailHandler boundary)
 * @see ExtractAddressQueueable.cls (the async router — the only caller of this class)
 * @see PropertyClaimService.cls (the first-broker-wins claim writer)
 * @see LLMExtractionParser.cls (produces the typed values LeadRequest carries)
 */
public with sharing class EmailToLeadService {

    /** Placeholder Company for a Lead born from an email (Company is a required Lead field).
     *  Since the enrichment it is a FALLBACK rather than a constant: the extraction's
     *  `broker_company` wins when present. Never write blank — Company is required.
     *  PUBLIC (was private, 2026-08-02): LeadConvertMatchService reads it to decide that a Lead
     *  carrying this placeholder must NOT match an Account by name — see that class's D1b note. */
    public static final String COMPANY_PLACEHOLDER = 'Unknown - Via Email';

    /** LeadSource stamped on every email-intake Lead — the pipeline's provenance marker. */
    private static final String LEAD_SOURCE = 'Email-to-Lead';

    /** Initial Lead Status for a freshly intaken email Lead. */
    private static final String STATUS_NEW = 'New';

    /** LastName fallback when neither the LLM nor the envelope yields a sender name. */
    private static final String DEFAULT_LAST_NAME = 'Unknown';

    /** Header the parser's rejection notes are filed under on Deal_Notes__c, so a reader can
     *  tell "the model said nothing" from "the model said something we refused to store". */
    private static final String NOTES_HEADER = '-- Extraction notes --';

    /** Destination field lengths — Lead.Description is a 32k LongTextArea, the rest Text(255). */
    private static final Integer LEN_TEXT = 255;
    private static final Integer LEN_DESCRIPTION = 32000;
    private static final Integer LEN_DEAL_NOTES = 32000;
    private static final Integer LEN_ZONING = 100;

    /** Standard Lead field lengths. */
    private static final Integer LEN_FIRST_NAME = 40;
    private static final Integer LEN_LAST_NAME = 80;
    private static final Integer LEN_COMPANY = 255;
    private static final Integer LEN_PHONE = 40;
    private static final Integer LEN_TITLE = 128;

    /**
     * Everything needed to build ONE Lead for ONE property of one inbound email.
     *
     * A DTO rather than a ~25-parameter method signature, following the in-repo
     * InboundEmailStagingService.StagingRequest precedent — whose Javadoc already gives the
     * reason: the fields are mostly optional values of similar types, so positional
     * arguments would be trivially transposable at the call site and would compile while
     * silently writing the wrong thing.
     *
     * Every value may be raw: createLeadFromExtracted clips and sanitizes on the way out.
     */
    public class LeadRequest {

        // ── the LEGACY four (claim-engine values) + envelope fallbacks ────────

        /** `broker_name`; falls back to `fromName`. */
        public String brokerName;
        /** `broker_email`; falls back to `fromAddress`. */
        public String brokerEmail;
        /** The property this Lead is for — VERBATIM as extracted, never normalized. */
        public String propertyAddress;
        /** Envelope display name — the name fallback. */
        public String fromName;
        /** Envelope From address — the email fallback. */
        public String fromAddress;
        /** Inbound subject → Email_Subject__c. */
        public String emailSubject;
        /** Raw email body → Description. */
        public String rawBody;
        /** The monitored inbox that forwarded the email → Forwarded_By_Email__c. */
        public String forwardedByEmail;

        // ── enrichment: broker block ─────────────────────────────────────────

        /** `broker_company` → Company (falls back to COMPANY_PLACEHOLDER). */
        public String brokerCompany;
        /** `broker_phone` → Phone (the office line wins when both numbers are extracted). */
        public String brokerPhone;
        /**
         * `broker_mobile`. ⚠ NOT written to Lead.MobilePhone — that field DOES NOT EXIST in
         * this org (see applyBrokerBlock for the evidence and the Task.Type precedent). It
         * becomes Phone when no office line was extracted, and otherwise a 'Mobile: ...' line
         * on Deal_Notes__c. Kept on the DTO because the LLM still extracts it and a broker
         * signature is frequently cell-only.
         */
        public String brokerMobile;
        /** `broker_title` → Title. */
        public String brokerTitle;
        /** `listing_broker_name` → Listing_Broker_Name__c. NOT a claim-engine value. */
        public String listingBrokerName;
        /** `listing_broker_email` → Listing_Broker_Email__c. NOT a claim-engine value. */
        public String listingBrokerEmail;

        // ── enrichment: the property (already typed + validated by the parser) ─

        /** The typed per-property values; null is tolerated (a no-property Lead). */
        public PropertyExtraction property;

        // ── enrichment: narrative + confidence ───────────────────────────────

        /** `deal_summary` — the narrative half of Deal_Notes__c. */
        public String dealSummary;
        /** Parser rejection notes, appended to Deal_Notes__c under NOTES_HEADER. */
        public List<String> extractionNotes;
        /** Properties from the same email that were NOT routed (no usable address, or
         *  beyond MAX_PROPERTIES). Appended to the FIRST Lead's Deal_Notes__c only, so an
         *  entry the pipeline could not act on is still visible to a human (C-1). */
        public String spilloverNote;
        /** Parse_Confidence__c band, derived by Apex from the model's numeric confidence.
         *  RESTRICTED picklist — only HIGH / MEDIUM / LOW may be passed. */
        public String parseConfidence;
    }

    /**
     * Insert the Lead for one property of one inbound broker email, complete on the first
     * write.
     *
     * PRECEDENCE — the LLM's answer beats the envelope, and the envelope beats nothing:
     *   • Name    — `brokerName` when extracted, else the envelope display name, else
     *               LastName 'Unknown' (LastName is required).
     *   • Email   — `brokerEmail` when extracted, else the envelope From address.
     *   • Company — `brokerCompany` when extracted, else COMPANY_PLACEHOLDER. Never blank.
     * This ordering matters because on a MANUALLY forwarded email the envelope describes the
     * INTERNAL person who forwarded it, not the broker; only the LLM (reading the quoted
     * original inside the body) knows who the broker actually is. On an auto-forwarded email
     * the envelope is the broker, and the LLM agrees — so the same rule is right either way.
     *
     * Values are clipped and addresses sanitized (InboundEmailFieldUtil) before DML: the raw
     * body can exceed Description's 32k limit and an LLM "email" can be a display name, and
     * either one would otherwise throw and abort the routing transaction. The typed numeric,
     * date and picklist values arrive PRE-VALIDATED from LLMExtractionParser and are written
     * as-is — that validation is what keeps a restricted picklist from throwing
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and rolling back a committed claim, and adding
     * a second, divergent rule set here is how the two would drift apart.
     *
     * @param request The assembled values for this Lead; must not be null.
     * @return The Id of the inserted Lead.
     * @throws DmlException when the Lead insert fails; the caller records it on the staging
     *         row's Error__c and the email is recoverable from that row.
     * @example
     * EmailToLeadService.LeadRequest request = new EmailToLeadService.LeadRequest();
     * request.brokerEmail = 'jane@brokerfirm.example.invalid';
     * request.property = extraction.properties[0];
     * Id leadId = EmailToLeadService.createLeadFromExtracted(request);
     */
    public static Id createLeadFromExtracted(LeadRequest request) {
        Lead lead = new Lead();

        applyName(lead, String.isNotBlank(request.brokerName) ? request.brokerName : request.fromName);

        String brokerEmail = InboundEmailFieldUtil.sanitizeEmail(request.brokerEmail);
        lead.Email = (brokerEmail != null)
            ? brokerEmail
            : InboundEmailFieldUtil.sanitizeEmail(request.fromAddress);

        lead.Company = String.isNotBlank(request.brokerCompany)
            ? InboundEmailFieldUtil.clip(request.brokerCompany, LEN_COMPANY)
            : COMPANY_PLACEHOLDER;
        lead.LeadSource = LEAD_SOURCE;
        lead.Status = STATUS_NEW;
        lead.Email_Subject__c = InboundEmailFieldUtil.clip(request.emailSubject, LEN_TEXT);
        lead.Description = InboundEmailFieldUtil.clip(request.rawBody, LEN_DESCRIPTION);

        if (String.isNotBlank(request.propertyAddress)) {
            lead.Property_Address__c = InboundEmailFieldUtil.clip(request.propertyAddress, LEN_TEXT);
        }

        String forwardedBy = InboundEmailFieldUtil.sanitizeEmail(request.forwardedByEmail);
        if (forwardedBy != null) {
            lead.Forwarded_By_Email__c = forwardedBy;
        }

        applyBrokerBlock(lead, request);
        applyPropertyBlock(lead, request.property);

        lead.Parse_Confidence__c = request.parseConfidence;
        String dealNotes = buildDealNotes(request);
        if (String.isNotBlank(dealNotes)) {
            lead.Deal_Notes__c = InboundEmailFieldUtil.clip(dealNotes, LEN_DEAL_NOTES);
        }

        insert lead;
        return lead.Id;
    }

    /**
     * Stamp the broker contact block — the fields describing WHO sent the email, as opposed
     * to what they are selling.
     *
     * ⚠ Lead.MobilePhone DOES NOT EXIST IN THIS ORG. DO NOT ADD IT BACK.
     * This is the SAME class of defect as Task.Type (see InboundEmailActivityService's class
     * header for the full retraction): a newer org template retired the field, but the repo
     * still contains a stale `objects/Lead/fields/MobilePhone.field-meta.xml` snapshot taken
     * from a classic-template org. FieldDefinition in `usman-dpeg` resolves Title / Phone /
     * Website and has NO MobilePhone and NO Fax; a REST insert answers
     * "No such column 'MobilePhone' on sobject of type Lead".
     *
     * The trap is that it COMPILES — the Apex compiler resolves Lead.MobilePhone against the
     * standard object schema, not this org's field set — and then throws at runtime with
     * "fields being inaccessible on Sobject Lead". Because this method stamped it
     * UNCONDITIONALLY, every single Lead insert in the pipeline failed. Trust FieldDefinition,
     * never the repo snapshot; a green run in a classic-template org proves nothing.
     *
     * WHERE THE MOBILE NUMBER GOES INSTEAD. The LLM still extracts `broker_mobile`, and it is
     * still worth having — a broker's signature is frequently cell-only:
     *   • Phone = `brokerPhone`, falling back to `brokerMobile` when the office line is blank,
     *     so a cell-only signature still lands a reachable number on the Lead rather than none;
     *   • when BOTH are present, the office line wins Phone and the mobile is appended to
     *     Deal_Notes__c ("Mobile: ...") by buildDealNotes — visible to the person working the
     *     Lead, which is the whole point of extracting it.
     *
     * `listingBrokerEmail` is sanitized rather than clipped: it is bound to an Email field,
     * where a malformed value throws INVALID_EMAIL_ADDRESS instead of merely truncating.
     *
     * @param lead    The unsaved Lead to stamp.
     * @param request The source values.
     */
    private static void applyBrokerBlock(Lead lead, LeadRequest request) {
        String phone = String.isNotBlank(request.brokerPhone) ? request.brokerPhone : request.brokerMobile;
        lead.Phone = InboundEmailFieldUtil.clip(phone, LEN_PHONE);
        lead.Title = InboundEmailFieldUtil.clip(request.brokerTitle, LEN_TITLE);
        lead.Listing_Broker_Name__c = InboundEmailFieldUtil.clip(request.listingBrokerName, LEN_TEXT);
        lead.Listing_Broker_Email__c = InboundEmailFieldUtil.sanitizeEmail(request.listingBrokerEmail);
    }

    /**
     * Stamp the deal-screening fields from the typed property extraction.
     *
     * @param lead     The unsaved Lead to stamp.
     * @param property The typed property values; null leaves every field unset.
     */
    private static void applyPropertyBlock(Lead lead, PropertyExtraction property) {
        if (property == null) {
            return;
        }
        lead.Property_Name__c = InboundEmailFieldUtil.clip(property.propertyName, LEN_TEXT);
        lead.Asset_Type__c = property.assetType;
        lead.Deal_Type__c = property.dealType;
        lead.Sale_Process__c = property.saleProcess;

        lead.Guidance_Price__c = property.guidancePrice;
        lead.Guidance_Price_Low__c = property.guidancePriceLow;
        lead.Guidance_Price_High__c = property.guidancePriceHigh;
        lead.Guidance_Cap_Rate__c = property.capRate;
        lead.NOI__c = property.noi;
        lead.ADR__c = property.adr;

        lead.Occupancy_Pct__c = property.occupancyPct;
        lead.Building_SF__c = property.buildingSf;
        lead.Unit_Count__c = property.unitCount;
        lead.Lot_Size_Acres__c = property.lotSizeAcres;
        lead.Year_Built__c = property.yearBuilt;
        lead.Year_Renovated__c = property.yearRenovated;
        lead.WALT_Years__c = property.waltYears;

        lead.Zoning__c = InboundEmailFieldUtil.clip(property.zoning, LEN_ZONING);
        lead.Seller_Entity__c = InboundEmailFieldUtil.clip(property.sellerEntity, LEN_TEXT);
        lead.Deal_Room_Link__c = property.dealRoomLink;
        lead.Offer_Due_Date__c = property.offerDueDate;
    }

    /**
     * Compose Deal_Notes__c from up to three parts, in reading order: the model's narrative,
     * the properties this email carried that were NOT routed, and the parser's rejection
     * notes.
     *
     * The last two are the whole reason the parser accumulates notes instead of silently
     * nulling values, and the reason C-1 keeps unaddressable properties rather than minting
     * junk Leads for them: both turn an invisible data loss into a line a human reads on the
     * record they are already working.
     *
     * @param request The source values.
     * @return The composed notes, or null when there is nothing to say.
     */
    private static String buildDealNotes(LeadRequest request) {
        List<String> sections = new List<String>();
        if (String.isNotBlank(request.dealSummary)) {
            sections.add(request.dealSummary.trim());
        }
        // Both numbers extracted: Phone took the office line, so the mobile would otherwise be
        // dropped — Lead.MobilePhone does not exist in this org (see applyBrokerBlock). Putting
        // it here keeps it in front of whoever works the Lead instead of only in Extracted_JSON__c.
        if (String.isNotBlank(request.brokerPhone) && String.isNotBlank(request.brokerMobile)) {
            sections.add('Mobile: ' + request.brokerMobile.trim());
        }
        if (String.isNotBlank(request.spilloverNote)) {
            sections.add(request.spilloverNote.trim());
        }
        if (request.extractionNotes != null && !request.extractionNotes.isEmpty()) {
            sections.add(NOTES_HEADER + '\n' + String.join(request.extractionNotes, '\n'));
        }
        return sections.isEmpty() ? null : String.join(sections, '\n\n');
    }

    /**
     * Delete a Lead this pipeline created moments earlier, in the SAME transaction.
     *
     * WHY A LEAD IS EVER DELETED — the LOST-RACE path, and only that path. Branch (e) of the
     * routing tree creates a Lead first and then asks PropertyClaimService.claim() to register
     * it. Under the cluster lock the claim can discover a winner that this job's own pre-read
     * did not see (a genuinely concurrent submission), which makes the broker a COMPETING
     * broker after the fact — and as of 2026-07-31 a competing broker gets no Lead at all,
     * only a Competing_Broker_Submission__c against the winner. The Lead that was already
     * inserted is therefore not a record of anything; leaving it would reintroduce exactly the
     * duplicate-flagged Lead this change removes, including its collision with org-level Lead
     * duplicate rules on Email (DUPLICATES_DETECTED rolls back the whole transaction and the
     * email's Task is silently lost).
     *
     * UNCHANGED BY THE MULTI-PROPERTY WORK: a lost race is still per-property, one at a time,
     * so this stays single-record-shaped and is called at most once per property.
     *
     * SAFETY — the caller must invoke this ONLY on the explicit ClaimOutcome.DUPLICATE_RACE
     * signal, never on UNCLAIMED: an UNCLAIMED Lead is a legitimate broker submission that
     * merely failed to take the lock, and deleting it would destroy real work. The email
     * itself is never at risk either way — the raw body and every RFC header remain on the
     * Inbound_Email_Staging__c row, which is never deleted, and the email's Task is logged on
     * the WINNING Lead after this returns.
     *
     * Source_Lead__c on any submission already pointing at this Lead is cleared automatically
     * by the lookup's SetNull delete constraint, which is precisely the shape a competing
     * broker's submission is supposed to have.
     *
     * @param leadId The Lead to remove; null is a no-op.
     * @throws DmlException when the delete fails; the caller records it on the staging row's
     *         Error__c alongside the outcome it had already reached.
     * @example
     * if (claimed == PropertyClaimService.ClaimOutcome.DUPLICATE_RACE) {
     *     EmailToLeadService.deleteLead(leadId);
     * }
     */
    public static void deleteLead(Id leadId) {
        if (leadId == null) {
            return;
        }
        delete new Lead(Id = leadId);
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
