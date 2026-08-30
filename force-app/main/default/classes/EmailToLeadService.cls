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
 *
 * EXTENDED 2026-08-10 (IR/Acquisitions segregation, Task 4): createLeadFromExtracted now
 * stamps every minted Lead with the Acquisition_Broker record type via
 * acquisitionBrokerRecordTypeId() — a guarded describe, not a query, so it costs no SOQL and
 * does not move this class's or ExtractAddressQueueable's pinned governor budgets. Without a
 * record-type stamp, once Lead OWD flips to Private (a later task in this plan) an inbound
 * broker Lead would match no sharing rule and become invisible to the Acquisitions team. The
 * helper is public and is also called directly by BrokerPortalService.submitDeal — see the
 * helper's own doc comment for why the guard is load-bearing and must not be removed.
 *
 * EXTENDED 2026-08-14 (Acquisition Observations, phase 1) with two additions, both landing in
 * the SAME insert — no extra DML, no extra SOQL, no extra describe:
 *   • `Listing_Status__c` — the ninth extraction key, stamped by applyPropertyBlock alongside
 *     the other restricted picklists and, like them, written raw because LLMExtractionParser
 *     has already validated it against this field's live active values.
 *   • THE EXTRACTION-COMPLETENESS SCORE — `Extraction_Score_Pct__c` /
 *     `Fields_Captured_Count__c` / `Fields_Missing_Count__c`, computed by ExtractionScoreUtil
 *     from the SAME property block this Lead is being stamped with (never from the email) and
 *     wrapped by applyExtractionScore, which is where the mandatory fail-soft guarantee lives.
 *     🔴 A FAILURE THERE COSTS THE SCORE AND NOTHING ELSE — read applyExtractionScore's own
 *     comment before narrowing its catch or moving the try/catch into ExtractionScoreUtil.
 *
 * EXTENDED 2026-08-30 (WS7, per-field confidence) with a two-field pair — `Field_Confidence_JSON__c`
 * and `Low_Confidence_Field_Count__c` — stamped by applyFieldConfidence in the SAME insert as
 * everything above. NO NEW DML, NO NEW SOQL, NO NEW DESCRIBE: two more assignments on a record
 * this method was already writing.
 *
 * 🔴 IT CHANGES NOTHING ABOUT `Parse_Confidence__c`. That band and ExtractAddressQueueable's
 * `>= 0.85` suppression gate both read the single top-level `confidence` and are byte-identical
 * after WS7. The new pair answers a DIFFERENT question — "which extracted values look shaky" —
 * gates nothing, suppresses nothing, and drives one list-view filter.
 *
 * ═══ EXTENDED 2026-08-30 (WS8) — TWO SEPARATE CHANGES, BOTH IN THE SAME EXISTING INSERT ═══
 *
 * 1. THE INTAKE BROKER LINK — `Broker__c` (-> Contact) and `Broker_Firm__c` (-> Account),
 *    stamped by applyBrokerLink from Ids the CALLER resolved. MATCH ONLY, NEVER CREATE: when the
 *    sender's email resolves to an existing broker Contact both lookups are set; when it does not,
 *    BOTH ARE LEFT BLANK. This class does not create a Contact, does not create an Account, and
 *    does not derive a firm name from the email domain — record creation stays at conversion,
 *    where LeadConvertMatchService and the platform's own convert already own it.
 *    NO NEW DML, NO NEW SOQL, NO NEW QUERY OF ANY KIND HERE: the resolution is one query per
 *    EMAIL, performed once by ExtractAddressQueueable, and this method receives two Ids.
 *
 *    🔴 GUARDED ON isCreateable(), FOR THE MEASURED REASON jsonWritable() DOCUMENTS AT LENGTH.
 *    Both lookups are brand-new Metadata-API-deployed fields, which arrive with FLS for NOBODY —
 *    System Administrator included. An unconditional write to them would not cost the broker link,
 *    it would throw `System.DmlException: Operation failed due to fields being inaccessible on
 *    Sobject Lead` and destroy every inbound email until a permission set catches up. Same trade,
 *    same class, same answer as acquisitionBrokerRecordTypeId() and jsonWritable().
 *
 * 2. `Broker_First__c` IS NOW WRITTEN ON THE EMAIL CHANNEL AT ALL — a carried-over GAP FIX,
 *    not a new feature. Until today this class had ZERO references to that field; only
 *    BrokerPortalService wrote it (from `input.brokerageFirm`), so it was blank for every
 *    genuinely email-born Lead. It holds the brokerage FIRM NAME, and WS6 has just made it the
 *    "Broker" column on five Lead list views, where the org's primary intake channel would have
 *    shown an empty column. (The 23 populated email-born Leads in `usman-dpeg` are SEED DATA and
 *    were masking the gap — they were written by a script, not by this pipeline.)
 *    It is set from `request.brokerCompany` — the SAME value that feeds `lead.Company` — and ONLY
 *    when that value is non-blank, so COMPANY_PLACEHOLDER ('Unknown - Via Email') can never leak
 *    into a broker column. See applyBrokerBlock for why that write is unguarded while the two
 *    lookups above are guarded.
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

    /** Leading text of the Deal_Notes__c line written when extraction scoring FAILED, so a blank
     *  Extraction_Score_Pct__c is never an unexplained blank. `@TestVisible` so the fail-soft
     *  test binds to the constant rather than retyping the wording. */
    @TestVisible
    private static final String SCORE_FAILED_NOTE =
        '-- Extraction score --\nThe extraction-completeness score could not be computed for '
        + 'this lead, so it is blank rather than zero. Nothing else on the record is affected. '
        + 'Reason:';

    /** The Acquisition_Broker record type developer name (IR/Acquisitions segregation). */
    @TestVisible
    private static final String RT_ACQUISITION_BROKER = 'Acquisition_Broker';

    /** Destination field lengths — Lead.Description is a 32k LongTextArea, the rest Text(255). */
    private static final Integer LEN_TEXT = 255;
    private static final Integer LEN_DESCRIPTION = 32000;
    private static final Integer LEN_DEAL_NOTES = 32000;
    private static final Integer LEN_ZONING = 100;
    /** `Field_Confidence_JSON__c` is LongTextArea(32768). The clip is a belt-and-braces backstop,
     *  not the real bound: LLMExtractionParser caps the map at 60 entries, so the serialized
     *  string is ~1.5KB at its worst. */
    private static final Integer LEN_FIELD_CONFIDENCE_JSON = 32768;

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
        /**
         * WS1 (2026-08-30) → `First_Seen_Date__c`. When the EMAIL ARRIVED, not when the routing
         * job ran: `Inbound_Email_Staging__c.Received_DateTime__c` (the RFC `Date:` header) when
         * it was readable, else that row's `CreatedDate`.
         *
         * 🔴 THE CALLER RESOLVES THE FALLBACK, NOT THIS CLASS, AND THERE IS DELIBERATELY NO
         * SECOND ONE HERE. `ExtractAddressQueueable` does it once at the staging load. This class
         * has no staging row to fall back to and inventing one (`Datetime.now()`) would put a
         * second, divergent rule in a second layer — the exact drift the typed-values note on
         * `createLeadFromExtracted` warns about.
         *
         * ⚠ NULL IS TOLERATED AND MEANS "let the platform decide". Leaving it null makes the
         * `Lead_Intake_Stamp` flow stamp `Datetime.now()` on insert, which is the CORRECT and
         * unchanged behaviour for the portal and manual channels. It is only the email channel
         * that now supplies a value — and there it is guaranteed non-null by the caller.
         */
        public Datetime firstSeenDateTime;

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

        /**
         * WS7 (2026-08-30) → `Field_Confidence_JSON__c`. Per-field extraction confidence, keyed
         * by the model's own JSON key, valued 0–1. Serialized to JSON on the way out by
         * `applyFieldConfidence`; null and empty both leave the field blank.
         *
         * ⚠ TYPED, NOT PRE-SERIALIZED, ON PURPOSE. Every other member of this DTO carries the
         * typed value LLMExtractionParser produced and lets this class do the field-safety work
         * on the way out — `createLeadFromExtracted`'s own contract. Passing a String would move
         * the serialization into `ExtractAddressQueueable`, which calls this once PER PROPERTY,
         * so the same map would be serialized up to MAX_PROPERTIES times per email.
         *
         * 🔴 PARSE_CONFIDENCE__C ABOVE IS UNTOUCHED BY THIS. The band and the `>= 0.85`
         * suppression gate still read the single top-level `confidence`. These two members
         * answer a different question and gate nothing.
         */
        public Map<String, Decimal> fieldConfidence;

        /**
         * WS7 (2026-08-30) → `Low_Confidence_Field_Count__c`, Number(2,0). How many
         * `fieldConfidence` entries fall below the WS5 medium threshold — the FILTERABLE half of
         * the pair, because a LongTextArea cannot be used in a list-view filter at all.
         *
         * Derived once per EMAIL by `LLMExtractionParser`, never recomputed here: this DTO is
         * assembled once per PROPERTY, and re-deriving would repeat identical arithmetic up to
         * ten times. Null is tolerated and leaves the field blank; 0 means "nothing to review".
         */
        public Integer lowConfidenceFieldCount;

        // ── the multi-property PORTFOLIO DEAL (2026-08-17) ────────────────────

        /**
         * `Portfolio_Deal__c` — the grouping that holds every Lead this ONE email produced,
         * when the email named two or more addressable properties. NULL on the ordinary
         * single-property email, which is the overwhelmingly common case.
         *
         * ⚠ THIS DTO MEMBER'S NAME STILL SAYS "propertyPackage" AFTER THE 2026-08-18 RENAME
         * (Portfolio Deal rename, phase B4), WHICH REPOINTED THE FIELD IT FEEDS WITHOUT
         * ALTERING THIS CLASS'S PUBLIC SURFACE. `ExtractAddressQueueable` sets it and
         * `EmailToLeadServiceTest` asserts on it; nothing else — no LWC, no Flow, no
         * metadata — so renaming it is a safe follow-up, just one that was out of B4's
         * scope. The assignment below is the authority on what it lands in.
         *
         * 🔴 STAMPED AT INSERT, AND THAT IS THE WHOLE DESIGN (Decision C1). The caller
         * creates the portfolio deal ONCE, before its per-property loop, so every Lead is
         * born carrying the link and NO LEAD IS EVER RE-UPDATED for it — which keeps the
         * grouping's cost to its own single DML rather than one extra statement per
         * property. A `LeadRequest` field is therefore the correct home for it: anything
         * else would mean a second write to a record this method already wrote.
         *
         * ⚠ ADDITIVE AND NULLABLE. Every existing caller that does not set it behaves
         * byte-identically, which is what makes this change invisible to the branches that
         * create a Lead outside the multi-property path (branch (c), the LLM-down path) and
         * to `BrokerPortalService`, which does not use this DTO at all.
         */
        public Id propertyPackageId;

        // ── WS8 (2026-08-30): the INTAKE BROKER LINK, resolved once per EMAIL ─────

        /**
         * `Broker__c` — the EXISTING broker Contact this email's sender already is, or NULL when
         * the sender resolves to no such Contact.
         *
         * 🔴 NULL IS A FIRST-CLASS ANSWER AND MUST STAY ONE. The user decision behind WS8 is
         * "MATCH ONLY at intake": an unmatched sender leaves this blank. Do NOT add a
         * create-the-Contact fallback here or in the caller — creation stays at conversion, where
         * `LeadConvertMatchService` re-asks the same question against the Lead's own Email and the
         * platform's convert mints the Contact under the right Account.
         *
         * ⚠ RESOLVED ONCE PER EMAIL, NOT PER PROPERTY, AND THIS DTO IS THE REASON THAT IS CHEAP.
         * The sender is an EMAIL-level fact; this DTO is assembled once per PROPERTY. The caller
         * memoises the single lookup and assigns the same Id to all N requests, so ten properties
         * cost one SOQL, not ten. See ExtractAddressQueueable.resolveBrokerLink.
         *
         * ⚠ PAIRED WITH brokerFirmAccountId BY CONSTRUCTION. Both come from ONE Contact row
         * (`Id` and `AccountId`) returned by a selector that filters `AccountId != null`, so they
         * are both-set or both-null and can never name a Contact that does not belong to the
         * Account. `LeadConvertMatchService` depends on exactly that.
         */
        public Id brokerContactId;

        /**
         * `Broker_Firm__c` — the brokerage Account that `brokerContactId`'s Contact belongs to, or
         * NULL when there was no match. Never derived from the email domain, never a placeholder,
         * and never read from anywhere but the matched Contact's own `AccountId`. See
         * brokerContactId above for the pairing invariant.
         */
        public Id brokerFirmAccountId;
    }

    /**
     * The Acquisition_Broker record type Id, or null when it does not exist in this org, or
     * is not available to the running user (IR/Acquisitions segregation, Task 4).
     *
     * 🔴 GUARDED ON isAvailable(), AND THAT GUARD IS A FAIL-SOFT BACKSTOP, NOT THE FIX.
     *
     * MEASURED 2026-08-10 (see TestDataFactory.recordTypeId's header for the reproduction):
     * record-type visibility is enforced on Apex DML UNCONDITIONALLY. AccessLevel / SYSTEM_MODE
     * governs CRUD, FLS and sharing — it never governs record-type visibility. A plain `insert`
     * for a principal lacking the record type throws
     * `System.DmlException: INVALID_CROSS_REFERENCE_KEY, Record Type ID`, regardless of DML
     * mode. So the real choice here was never "throws vs. silently unstamped" — it is
     * "throws vs. doesn't set RecordTypeId at all," and only isAvailable() can tell those apart
     * before the DML fires.
     *
     * BOTH callers of this method run as a principal nobody provisions through the UI — the
     * Email Service context user (this class) and the Site guest user (BrokerPortalService).
     * WITHOUT this guard, a provisioning gap on either would not produce an unstamped Lead, it
     * would DESTROY THE INBOUND EMAIL or the guest submission outright: no Lead, no registry
     * claim, no audit row, no bounce. That is the same failure shape as this repo's
     * ContentPublication outage (see ARCHITECTURE.md §2, InboundEmailAttachmentService's class
     * header) — an unconditional write becoming a single point of failure for a transaction
     * that had nothing to do with the write's own purpose.
     *
     * WITH the guard, the same provisioning gap costs an UNSTAMPED Lead — recoverable, and
     * detectable by a later backfill/verify pass. Provisioning is the real fix; this guard only
     * makes verifying it a task rather than an incident.
     *
     * Null remains a legitimate answer for TWO reasons: the record type does not exist in this
     * org at all (routes an inbound email safely in an org where this segregation metadata has
     * not deployed yet), OR it exists but is not available to the running user — in which case
     * the caller leaves RecordTypeId unset and the platform applies whichever default record
     * type is available to that principal. Either way this pipeline must never lose an email
     * over record-type metadata.
     *
     * Reused by BrokerPortalService.submitDeal — do not re-derive this in that class; call this
     * method so both Lead-creating automation paths share one answer.
     *
     * A describe, not a query. It costs no SOQL, which is why it does not move this class's or
     * ExtractAddressQueueable's pinned query budgets.
     *
     * @return The Acquisition_Broker RecordTypeId, or null.
     */
    /**
     * THE ONE RULE FOR "WHICH EMAIL ADDRESS IS THIS BROKER" — extracted 2026-08-30 (WS8) from the
     * expression that was inline in createLeadFromExtracted, with ZERO behaviour change.
     *
     * 🔴 IT WAS PROMOTED BECAUSE A SECOND CALLER NOW NEEDS THE SAME ANSWER, AND A COPY WOULD BE
     * SUBTLY WRONG. `ExtractAddressQueueable` must resolve the sender to an existing broker Contact
     * using the value that will actually land on `Lead.Email`, because `LeadConvertMatchService`
     * matches `Contact.Email = Lead.Email` at conversion — if intake keyed on a different string,
     * the two stages could disagree about who the broker is.
     *
     * The obvious copy is wrong in a way that is easy to miss: that class already carries
     * `senderEmail`, which looks identical but is NOT. `senderEmail` prefers
     * `extraction.brokerEmail` whenever it is merely NON-BLANK; this method prefers it only when it
     * SANITIZES — so an extracted "email" that is really a display name ('Jane at Acme') makes
     * `senderEmail` the display name while `Lead.Email` falls back to the envelope. `senderEmail`
     * is correct for its own purpose (it names the sender on the logged Task) and must not be
     * changed; it is simply the wrong key for a Contact lookup.
     *
     * PRECEDENCE, UNCHANGED: the LLM's `broker_email` beats the envelope, because on a MANUALLY
     * forwarded email the envelope describes DPEG's own coordinator, not the broker. Both sides are
     * sanitized, so a malformed value is a null rather than an INVALID_EMAIL_ADDRESS at DML.
     *
     * @param brokerEmail The LLM-extracted `broker_email`; may be null, blank or malformed.
     * @param fromAddress The envelope From address; may be null, blank or malformed.
     * @return The sanitized address to write to Lead.Email and to key the broker lookup on, or
     *         null when neither value sanitizes.
     */
    public static String resolveBrokerEmail(String brokerEmail, String fromAddress) {
        String extracted = InboundEmailFieldUtil.sanitizeEmail(brokerEmail);
        return (extracted != null) ? extracted : InboundEmailFieldUtil.sanitizeEmail(fromAddress);
    }

    public static Id acquisitionBrokerRecordTypeId() {
        Schema.RecordTypeInfo info = Lead.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(RT_ACQUISITION_BROKER);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
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

        Id acqRt = acquisitionBrokerRecordTypeId();
        if (acqRt != null) {
            lead.RecordTypeId = acqRt;
        }

        applyName(lead, String.isNotBlank(request.brokerName) ? request.brokerName : request.fromName);

        lead.Email = resolveBrokerEmail(request.brokerEmail, request.fromAddress);

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
        // WS7 (2026-08-30) — the PER-FIELD review signal, stamped in THIS insert alongside the
        // whole-email band above. Two more fields on a record already being written: no extra
        // DML, no extra SOQL, no describe.
        applyFieldConfidence(lead, request);
        // WS8 (2026-08-30) — the INTAKE BROKER LINK, stamped in THIS insert from two Ids the caller
        // resolved with ONE query for the whole email. No SOQL here, no DML here, no describe that
        // is not cached per transaction. MATCH ONLY: both Ids are null when the sender is a broker
        // this org has never met, and that is the designed answer, not a gap to fill.
        applyBrokerLink(lead, request);
        // WS1 (2026-08-30) — WHEN THE EMAIL ARRIVED, replacing the flow's Datetime.now() for the
        // email channel only. `Lead_Intake_Stamp` stamps First_Seen_Date__c only when it IsNull,
        // so writing it here is what makes the flow leave it alone; leave it null (every other
        // caller) and the flow behaves exactly as it always has. Assigning null on a brand-new
        // Lead is a no-op, so no guard is needed — the same reasoning Portfolio_Deal__c below
        // and Parse_Confidence__c above already rely on.
        //
        // ⚠ THIS FIELD IS DOWNSTREAM OF TWO OTHERS. `Lead.BP_Expiry__c` is this + 90 days and
        // `Days_in_System__c` counts from it, so an earlier value here moves an email-born
        // Lead's whole 90-day protection window earlier. That is the requested behaviour change.
        lead.First_Seen_Date__c = request.firstSeenDateTime;
        // The multi-property portfolio deal (2026-08-17, Decision C1) — stamped AT INSERT so no Lead is
        // ever re-updated for it. Null on every single-property email, and assigning null is a
        // no-op on a brand-new Lead, so no guard is needed or wanted here (the same reasoning
        // Parse_Confidence__c above and LeadConvertService.applyDealFields both rely on: every
        // field on a record about to be inserted is already empty).
        lead.Portfolio_Deal__c = request.propertyPackageId;
        String scoreNote = applyExtractionScore(lead, request);
        String dealNotes = buildDealNotes(request, scoreNote);
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
     * ⚠ SINCE 2026-08-30 (WS8) THIS METHOD ALSO WRITES `Broker_First__c`, THE BROKERAGE FIRM NAME.
     * That is a gap fix, not an addition: this class had zero references to the field, so it was
     * blank on every email-born Lead while the portal channel populated it. Read the guard comment
     * at the assignment before touching it — the `isNotBlank` test is what keeps the required-field
     * placeholder out of a display column, and it is not interchangeable with `lead.Company`'s
     * fallback two methods up.
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

        // ── WS8 (2026-08-30) — THE BROKERAGE FIRM NAME, WRITTEN ON THIS CHANNEL FOR THE FIRST TIME.
        //
        // 🔴 THE `isNotBlank` GUARD IS THE WHOLE POINT, NOT A NULL CHECK. `lead.Company` above
        // falls back to COMPANY_PLACEHOLDER ('Unknown - Via Email') because Company is a REQUIRED
        // field and must never be blank. Broker_First__c is NOT required, is a display field, and
        // is now the "Broker" column on five Lead list views (WS6) — so mirroring Company here
        // would print 'Unknown - Via Email' into a broker column on every firm-unknown email.
        // A BLANK CELL SAYS "we don't know the firm"; the placeholder says it in a way that looks
        // like data and would be sorted, filtered and reported on as a firm name. Same reasoning
        // LeadConvertMatchService's D1b makes about never Account-MATCHING on that literal.
        //
        // ⚠ SOURCED FROM `brokerCompany`, THE SAME MEMBER THAT FEEDS `lead.Company` — deliberately,
        // so the two cannot drift. It is NOT sourced from the email domain, from
        // `listingBrokerName`, or from the matched Contact's Account name: an inferred firm on a
        // list-view column is worse than a blank, and the matched Account is already carried
        // structurally by `Broker_Firm__c` (see applyBrokerLink).
        //
        // ⚠ UNGUARDED BY DESIGN, UNLIKE THE TWO LOOKUPS IN applyBrokerLink. Broker_First__c is NOT
        // a new field: it has shipped since the portal channel, and `DPEG_Acquisition_Edit` — the
        // set measured on 2026-08-30 as the one granting this pipeline's `Parse_Confidence__c`,
        // `Deal_Notes__c` and `First_Seen_Date__c` — grants it editable today. This write is
        // therefore exactly as exposed as the four unconditional writes already on this path, and
        // `BrokerPortalService` has written it unconditionally on the portal channel all along. A
        // describe guard here would imply a risk that the neighbouring lines already carry.
        if (String.isNotBlank(request.brokerCompany)) {
            lead.Broker_First__c = InboundEmailFieldUtil.clip(request.brokerCompany, LEN_TEXT);
        }
    }

    /**
     * Stamp the WS8 intake broker link — `Broker__c` (the existing broker Contact) and
     * `Broker_Firm__c` (that Contact's brokerage Account).
     *
     * 🔴 MATCH ONLY. NEITHER FIELD IS EVER DERIVED, INFERRED OR CREATED HERE. Both Ids arrive
     * already resolved from ONE query the caller ran for the whole email; when the sender matched
     * nothing, both are null and both fields stay blank. That is the requested behaviour: a blank
     * `Broker__c` means "this broker is not in our system yet", and CREATION HAPPENS AT CONVERSION,
     * not at intake. Do not add a "create the Contact if missing" branch — it would put record
     * creation inside an inbound-email transaction that must be able to fail without minting
     * half a CRM, and it would race the same broker's other emails.
     *
     * 🔴 EACH WRITE IS GUARDED ON isCreateable(), AND THAT IS THE FIX FOR A MEASURED FAILURE —
     * SEE jsonWritable() FOR THE FULL REPRODUCTION. Both fields are new Metadata-API-deployed
     * lookups, so on the day WS8 deploys NO PRINCIPAL CAN WRITE THEM, System Administrator
     * included (ARCHITECTURE.md §2). Measured on `usman-dpeg` 2026-08-30 with WS7's two fields in
     * exactly this state: an unconditional assignment made `insert lead` throw
     * `System.DmlException: Operation failed due to fields being inaccessible on Sobject Lead` and
     * took 42 of 45 test methods with it — 38 of which had nothing to do with the new fields. In
     * production that is not a missing link, it is NO LEAD, NO CLAIM AND NO BOUNCE for every
     * inbound broker email until a permission set catches up.
     * With the guard, a missing grant costs THE LINK AND NOTHING ELSE, and a later backfill can
     * populate what was skipped from the Lead's own Email.
     *
     * ⚠ THE TWO GRANTS ARE ASKED SEPARATELY, NOT AS A PAIR — the same argument countWritable()
     * makes: a permission-set deploy REPLACES its whole `fieldPermissions` block, so "one granted,
     * one not" is a real state, and treating them as one question would throw away the half that
     * was writable. A `Broker__c` with no `Broker_Firm__c` is still useful and is still handled
     * correctly downstream: `LeadConvertMatchService` derives the Account from the Contact's own
     * `AccountId`, not from this field.
     *
     * ⚠ ASSIGNING NULL WOULD BE A NO-OP ON A BRAND-NEW LEAD, so the null checks below are NOT
     * about safety — they are about not paying for a describe on the overwhelmingly common
     * no-match email. The describes are cached per transaction regardless.
     *
     * @param lead    The unsaved Lead to stamp.
     * @param request The source values; `brokerContactId` and `brokerFirmAccountId` are read.
     */
    private static void applyBrokerLink(Lead lead, LeadRequest request) {
        if (request.brokerContactId != null && brokerLinkWritable()) {
            lead.Broker__c = request.brokerContactId;
        }
        if (request.brokerFirmAccountId != null && brokerFirmLinkWritable()) {
            lead.Broker_Firm__c = request.brokerFirmAccountId;
        }
    }

    /** Per-transaction answer for Broker__c; null until first asked. */
    private static Boolean brokerLinkWritableCache;
    /** Per-transaction answer for Broker_Firm__c; null until first asked. */
    private static Boolean brokerFirmLinkWritableCache;

    /**
     * Can the running principal WRITE `Lead.Broker__c`? See applyBrokerLink for the decision and
     * jsonWritable() for the measurement this guard exists because of — the reproduction, the
     * isolation and the blast radius are all recorded there and are not repeated here.
     *
     * ⚠ CACHED PER TRANSACTION, NOT PER CALL, for the same reason its WS7 siblings are:
     * ExtractAddressQueueable reaches this once PER PROPERTY, up to MAX_PROPERTIES times, and a
     * describe is a schema read rather than SOQL — so the pinned QUERY_BUDGET and DML_BUDGET are
     * untouched at any N.
     *
     * 🔴 PROVISIONING IS THE REAL FIX. `Lead.Broker__c` and `Lead.Broker_Firm__c` need Read + Edit
     * on the permission set the intake principal holds (measured 2026-08-30: `DPEG_Acquisition_Edit`)
     * plus Read on the Acquisition VIEW set, or this feature is silently OFF and nothing logs it.
     * That grant is DECLARED to the P8 hub pass and is deliberately NOT made here — no permission
     * set is edited by this change. Verify with FieldPermissions, never with a green deploy.
     *
     * @return True when the field may be written by the running principal.
     */
    private static Boolean brokerLinkWritable() {
        if (brokerLinkWritableCache == null) {
            brokerLinkWritableCache = Schema.SObjectType.Lead.fields.Broker__c.isCreateable();
        }
        return brokerLinkWritableCache;
    }

    /**
     * Can the running principal WRITE `Lead.Broker_Firm__c`? Its twin — see brokerLinkWritable()
     * and, for why the two are asked as separate questions rather than as one, applyBrokerLink.
     *
     * @return True when the field may be written by the running principal.
     */
    private static Boolean brokerFirmLinkWritable() {
        if (brokerFirmLinkWritableCache == null) {
            brokerFirmLinkWritableCache = Schema.SObjectType.Lead.fields.Broker_Firm__c.isCreateable();
        }
        return brokerFirmLinkWritableCache;
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
        // RESTRICTED picklist, and written raw for the same reason Sale_Process__c is: the value
        // arrives PRE-VALIDATED from LLMExtractionParser against this very field's live active
        // values, so a second, divergent rule set here is how the two would drift apart. Null is
        // the designed default — the email said nothing, and a guess is worse than a blank.
        lead.Listing_Status__c = property.listingStatus;

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
     * Stamp the extraction-completeness score (observation 1, 2026-08-14) — and ABSORB any
     * failure in doing so.
     *
     * 🔴 THIS METHOD IS THE MANDATORY FAIL-SOFT WRAPPER, AND IT IS HERE RATHER THAN INSIDE
     * ExtractionScoreUtil ON PURPOSE. Spec §1 constraint 7: "the inbound email pipeline must
     * never be made to throw." THIS transaction is the one that owns something irreplaceable —
     * the broker's Lead and, moments later, their registry claim — so the guarantee has to be
     * expressed at the boundary that would pay for a breach, not inside the pure function that
     * cannot currently breach it. A score is a convenience; a lost claim is not recoverable
     * without a human editing the ledger. Same reasoning shape as
     * ARCHITECTURE.md §2's rule that a ContentVersion insert must never sit inside a
     * transaction whose rollback would lose something irreplaceable.
     *
     * ⚠ `catch (Exception e)`, DELIBERATELY WIDE. A narrower catch would be a claim about which
     * failures are possible, and this repo has twice been wrong about exactly that: a
     * `TypeException` is not a `DmlException` (ApprovalAuditService, 2026-08-05) and a
     * `QueryException` is not either (InboundEmailStagingService.appendDroppedNote). There is
     * nothing this method could usefully do differently per exception type.
     *
     * ⚠ IT CANNOT CATCH AN UNCATCHABLE PLATFORM LIMIT, and nothing here can. SP-R1 measured a
     * heap/CPU `LimitException` escaping a `catch (Exception)` positioned directly around the
     * failing statement. That is not a gap this method can close — it is closed structurally,
     * by the scorer being pure arithmetic over ~9 nullable members with no allocation.
     *
     * ON FAILURE: the three fields are set to NULL — never left half-written, never zeroed —
     * and a note is returned for Deal_Notes__c so the omission is something a human SEES on the
     * record they are already working, rather than an unexplained blank. That is the same
     * "convert silent data loss into a visible line" contract the parser's rejection notes have.
     *
     * 🔴 THE THREE RESOLVED VALUES PASSED ALONGSIDE THE BLOCK ARE THE ONES THIS METHOD WROTE, OR
     * WOULD HAVE. `request.propertyAddress` — NOT `request.property.propertyAddress` — is what
     * createLeadFromExtracted stamps onto `Lead.Property_Address__c` above, and
     * ExtractAddressQueueable.claimableAddress has already nulled it when the raw address does not
     * normalize. Passing the block's raw value instead counts the address as captured on exactly
     * the leads whose address field is blank (code review C2, fixed 2026-08-14). Same rule for the
     * two listing-broker values, which applyBrokerBlock writes from the same request members. If a
     * tenth key is ever added, ask which member the Lead is stamped from before wiring the score.
     *
     * @param lead    The unsaved Lead to stamp.
     * @param request The source values; `property`, `propertyAddress` and the two listing-broker
     *                values are read.
     * @return null on success, or a Deal_Notes__c line explaining why the score is missing.
     */
    private static String applyExtractionScore(Lead lead, LeadRequest request) {
        try {
            ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(
                request.property,
                request.propertyAddress,
                request.listingBrokerName,
                request.listingBrokerEmail);
            lead.Fields_Captured_Count__c = score.capturedCount;
            lead.Fields_Missing_Count__c = score.missingCount;
            lead.Extraction_Score_Pct__c = score.scorePct;
            return null;
        } catch (Exception e) {
            ExtractionScoreUtil.Score blank = ExtractionScoreUtil.notScored();
            lead.Fields_Captured_Count__c = blank.capturedCount;
            lead.Fields_Missing_Count__c = blank.missingCount;
            lead.Extraction_Score_Pct__c = blank.scorePct;
            return SCORE_FAILED_NOTE + ' ' + e.getMessage();
        }
    }

    /**
     * Stamp the WS7 per-field confidence pair (2026-08-30) — the JSON map and the filterable
     * count of its below-threshold entries.
     *
     * 🔴 THERE IS DELIBERATELY NO TRY/CATCH HERE, AND THAT IS AN ARGUMENT RATHER THAN AN
     * OMISSION. `applyExtractionScore` above is wrapped because it calls out to a separate
     * utility doing real arithmetic over nine nullable members. This does one thing —
     * `JSON.serialize` of a `Map<String, Decimal>` — a shape with no reachable throw:
     * serialization only fails on unsupported types, and both type parameters are primitives the
     * serializer handles unconditionally. The one residual hazard is SIZE, and size is bounded
     * TWICE and independently: `LLMExtractionParser` caps the map at 60 entries (~1.5KB
     * serialized) and the clip below caps the string at the field's 32,768. A catch here would
     * be unreachable in every test that could be written for it, which this repo has learned to
     * treat as a defect in its own right rather than as free insurance.
     *
     * ⚠ AN EMPTY MAP WRITES NOTHING, NOT '{}'. A blank field reads as "no per-field signal",
     * which is what an empty map means; a literal `{}` looks like data that says nothing and
     * would show up as content in every report and detail page.
     *
     * ⚠ THE COUNT IS WRITTEN EVEN WHEN THE MAP IS EMPTY, and 0 is the correct answer there — it
     * keeps the Lead OUT of the per-field review queue (`> 0`) while `Parse_Confidence__c = LOW`
     * on the other side of that list view's OR still catches whole-email doubt. Assigning null
     * on a brand-new Lead is a no-op, the same reasoning `Portfolio_Deal__c` relies on.
     *
     * @param lead    The unsaved Lead to stamp.
     * @param request The source values; `fieldConfidence` and `lowConfidenceFieldCount` are read.
     */
    private static void applyFieldConfidence(Lead lead, LeadRequest request) {
        if (jsonWritable() && request.fieldConfidence != null && !request.fieldConfidence.isEmpty()) {
            lead.Field_Confidence_JSON__c = InboundEmailFieldUtil.clip(
                JSON.serialize(request.fieldConfidence), LEN_FIELD_CONFIDENCE_JSON);
        }
        if (countWritable()) {
            lead.Low_Confidence_Field_Count__c = request.lowConfidenceFieldCount;
        }
    }

    /** Per-transaction answer for Field_Confidence_JSON__c; null until first asked. */
    private static Boolean jsonWritableCache;
    /** Per-transaction answer for Low_Confidence_Field_Count__c; null until first asked. */
    private static Boolean countWritableCache;

    /**
     * Can the running principal WRITE Field_Confidence_JSON__c?
     *
     * 🔴 THIS GUARD IS NOT DEFENSIVE PROGRAMMING — IT IS THE FIX FOR A MEASURED, REPRODUCED
     * FAILURE, AND REMOVING IT RE-BREAKS THE WHOLE INBOUND PIPELINE. Measured on `usman-dpeg`,
     * 2026-08-30, by check-only deploy 0Afiw000000TjplCAC: with these two fields deployed and
     * NO FieldPermissions row anywhere, `insert lead` on line ~450 throws
     * `System.DmlException: Operation failed due to fields being inaccessible on Sobject Lead`
     * and 42 of EmailToLeadServiceTest's 45 methods fail. It was isolated: the same tests pass
     * 39/39 against the org, and pass 39/39 with the two FIELDS deployed but not WRITTEN — it is
     * the WRITE that fails, not the field.
     *
     * That matters far beyond a test run. A Metadata-API-deployed field arrives with FLS for
     * nobody, System Administrator included (ARCHITECTURE.md §2). So the DEFAULT state of this
     * org on the day WS7 deploys is "no principal can write these two fields" — and without this
     * guard, that state does not cost the review signal, it DESTROYS EVERY INBOUND BROKER EMAIL
     * at the Lead insert: no Lead, no registry claim, no bounce. This repo has already lost six
     * days to precisely that shape once (see this class's FLS incident history and
     * InboundEmailAttachmentService's header), which is why an unconditional write to a
     * newly-deployed field is not an acceptable pattern here.
     *
     * SAME PRECEDENT, SAME TRADE, SAME CLASS: acquisitionBrokerRecordTypeId()'s isAvailable()
     * guard, twenty lines of argument above, resolves the identical question for RecordTypeId —
     * "throws vs. doesn't set the field at all" — and chooses the recoverable answer. A missing
     * grant here costs the per-field review signal on Leads created before it is fixed, and
     * nothing else; the Lead, the claim and the email all survive, and a later backfill can
     * populate what was skipped.
     *
     * 🔴 PROVISIONING IS STILL THE REAL FIX, AND THIS GUARD ONLY MAKES IT A TASK RATHER THAN AN
     * INCIDENT. `Field_Confidence_JSON__c` and `Low_Confidence_Field_Count__c` need Read + Edit
     * on whichever permission set the intake principal holds — measured 2026-08-30, that is
     * `DPEG_Acquisition_Edit`, which is what grants `Parse_Confidence__c`, `Deal_Notes__c` and
     * `First_Seen_Date__c` today. Until that lands, this feature is silently OFF and nothing
     * logs it. Verify with FieldPermissions, never with a green deploy.
     *
     * ⚠ CACHED PER TRANSACTION, NOT PER CALL. ExtractAddressQueueable calls into this method once
     * PER PROPERTY, up to MAX_PROPERTIES times; the describe is resolved once and reused, so the
     * cost is two describes per transaction whatever the property count. Describes are schema
     * reads, not SOQL — the pinned QUERY_BUDGET and DML_BUDGET are untouched.
     *
     * @return True when the field may be written by the running principal.
     */
    private static Boolean jsonWritable() {
        if (jsonWritableCache == null) {
            jsonWritableCache = Schema.SObjectType.Lead.fields.Field_Confidence_JSON__c.isCreateable();
        }
        return jsonWritableCache;
    }

    /**
     * Can the running principal WRITE Low_Confidence_Field_Count__c? See jsonWritable() for the
     * measurement, the precedent and the provisioning requirement — this is its twin.
     *
     * ⚠ ASKED SEPARATELY, NOT AS A PAIR. A half-granted permission set is a real state (a set
     * deploy REPLACES its whole fieldPermissions block, so one field can be dropped and the other
     * kept), and treating the pair as one question would throw away a signal that was actually
     * writable. The two fields are independently useful to a reviewer.
     *
     * @return True when the field may be written by the running principal.
     */
    private static Boolean countWritable() {
        if (countWritableCache == null) {
            countWritableCache = Schema.SObjectType.Lead.fields.Low_Confidence_Field_Count__c.isCreateable();
        }
        return countWritableCache;
    }

    /**
     * Compose Deal_Notes__c from up to four parts, in reading order: the model's narrative,
     * the properties this email carried that were NOT routed, the parser's rejection notes,
     * and — only ever on a failure — the extraction-score note.
     *
     * The middle two are the whole reason the parser accumulates notes instead of silently
     * nulling values, and the reason C-1 keeps unaddressable properties rather than minting
     * junk Leads for them: both turn an invisible data loss into a line a human reads on the
     * record they are already working. The score note is the same idea applied to the score.
     *
     * @param request   The source values.
     * @param scoreNote The extraction-score failure note, or null when scoring succeeded.
     * @return The composed notes, or null when there is nothing to say.
     */
    private static String buildDealNotes(LeadRequest request, String scoreNote) {
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
        // LAST, so it can never displace a deal fact if Deal_Notes__c is clipped at 32k.
        if (String.isNotBlank(scoreNote)) {
            sections.add(scoreNote.trim());
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
