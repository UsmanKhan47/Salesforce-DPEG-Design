/**
 * Broker-Protection LLM extraction — the EMAIL-LEVEL result of one extraction call.
 *
 * The typed replacement for the flat four-key `Map&lt;String, String&gt;` that
 * LLMExtractionCalloutService used to return. It carries the email-level identity /
 * classification block, the `properties` array (D1 — one inbound email can pitch many
 * properties), the raw response VERBATIM for the D3 tier-1 store, and the parser's notes.
 *
 * ═══ THE FOUR LEGACY KEYS ARE STILL THE CLAIM ENGINE'S CONTRACT ═══
 * `brokerName` / `brokerEmail` / `sentDatetime` (here) and `propertyAddress` (on each
 * PropertyExtraction) are the SAME four values the pre-2026-07-31 contract carried, and
 * toLegacyMap() re-emits them under their original key names so PropertyClaimService and
 * PropertyMatchingService keep receiving the exact map shape they always have. Their
 * signatures did not change and must not: the first-broker-wins race logic is the hardest-won
 * code in this module, and re-shaping its input to gain nothing would put it at risk for free.
 *
 * ⚠ `broker*` vs `listingBroker*` IS A HARD BOUNDARY. The claim engine reads `brokerEmail`
 * and nothing else. `listingBrokerEmail` is the blast-platform case where the SENDER is not
 * the listing broker (RCM/Crexi-style mailers). Re-pointing the claim engine at the listing
 * broker would silently re-attribute every claim in the ledger.
 *
 * LAYER — DTO. No SOQL, no DML, no callouts.
 *
 * @see LLMExtractionParser.cls (the only producer)
 * @see PropertyExtraction.cls (the per-property half)
 * @see LLMExtractionCalloutService.cls (returns this from extract())
 */
public class LLMExtractionResult {

    /** Closed set for `email_category`; anything else is coerced to 'other'. Public so the
     *  parser's tests and any future dashboard bind to the constant, not a retyped literal. */
    public static final String CATEGORY_OTHER = 'other';

    /**
     * `email_category` value for a MASS-MARKETED call-for-offers campaign — the only category
     * any code branches on. Public for the same reason CATEGORY_OTHER is: intake-rules-v2 added
     * a suppression gate keyed on this exact string
     * (ExtractAddressQueueable.isCallForOffersGated), and a retyped literal in a second class
     * would drift from the parser's closed set without a single test failing.
     */
    public static final String CATEGORY_CALL_FOR_OFFERS = 'call_for_offers';

    // ── raw + diagnostics ────────────────────────────────────────────────────

    /**
     * The model's response content VERBATIM (D3 tier 1) — exactly what goes into
     * Inbound_Email_Staging__c.Extracted_JSON__c before any routing decision is taken, so
     * the extraction survives every branch including the ones that create no Lead. Never
     * null: a degraded or skipped call stores a `{"skipped":"..."}` marker instead, so an
     * empty Extracted_JSON__c is never ambiguous.
     */
    public String rawJson;

    /**
     * Human-readable notes for every value the parser REJECTED — '"$7.1M" is not a valid
     * cap rate', 'asset_type "Hotel" is not an active picklist value', and so on. The
     * writer appends them to Deal_Notes__c under an '-- Extraction notes --' header, which
     * is the whole point of validating rather than trusting: silent data loss becomes
     * something a human sees on the record. Never null.
     */
    public List<String> notes = new List<String>();

    // ── classification / gate inputs ─────────────────────────────────────────

    /**
     * `email_category` — one of the closed set, else 'other'.
     *
     * ⚠ AMENDED 2026-08-03 (intake-rules-v2 / U2). This used to say the value "drives nothing
     * except the gate's explainability". That is no longer true: `call_for_offers` is now the
     * SOLE condition of ExtractAddressQueueable's call-for-offers gate, so this ONE value decides
     * that an email produces no Lead and no claim. The other six categories still branch nowhere.
     * An unrecognised value is coerced to 'other' by the parser, which is the fail-open direction.
     */
    public String emailCategory = CATEGORY_OTHER;

    /**
     * `is_acquisition_related`. NULL means the model did not say — which is NOT the same as
     * false and must never be gated on. The hard gate fires only on an explicit false at
     * HIGH confidence (design §2.3 / C-9).
     */
    public Boolean isAcquisitionRelated;

    /** `confidence` as the model returned it: a number in [0, 1]. Null when absent or
     *  unparseable. Apex — not the model — derives the band from it (C-8). */
    public Decimal confidence;

    /**
     * The Parse_Confidence__c picklist band Apex derived from `confidence`
     * (LLMExtractionParser.BAND_*). Always one of HIGH / MEDIUM / LOW — never null, never
     * an out-of-set value, because Parse_Confidence__c is a RESTRICTED picklist and an
     * invalid value would throw INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and roll back the
     * claim.
     */
    public String confidenceBand = LLMExtractionParser.BAND_LOW;

    /**
     * `category_confidence` as the model returned it: a number in [0, 1]. Null when absent or
     * unparseable. Added 2026-08-03 (intake-rules-v2 / U2, design F3).
     *
     * 🔴 NOTHING GATES ON THIS FIELD, AND THAT IS DELIBERATE — IT IS TUNING DATA.
     * U2's call-for-offers rule is CATEGORICAL: `email_category == 'call_for_offers'` produces no
     * Lead, full stop. This value is parsed anyway because it rides along in `Extracted_JSON__c`
     * on every staging row at zero runtime cost, and it is the ONLY evidence available if that
     * suppression later proves too aggressive: query the gated rows, read the distribution, and a
     * threshold can then be introduced from data instead of from a guess.
     *
     * 🔴 IF A THRESHOLD IS EVER INTRODUCED, GATE ON THIS FIELD AND NEVER ON `confidence`.
     * `confidence` answers "how certain are you of is_acquisition_related"; this answers "how
     * certain are you of email_category". A call-for-offers blast IS acquisition-related, so its
     * `confidence` is HIGH and so is a genuine exclusive's — `confidence` carries no
     * discrimination here at all, and gating on it would produce a guardrail that looks like two
     * independent conditions and behaves as one. ⚠ This paragraph used to cite ARCHITECTURE.md §2's
     * Opportunity deal-action gate and quote it as "membership and the flag are different
     * questions"; **that wording no longer exists** — the 2026-08-12 custom-permission migration
     * retired the `User.*_Driver__c` flag model and §2 now records that argument as MOOT. The
     * ANALOGY is untouched and is the only thing that was ever being borrowed: two conditions that
     * cannot disagree are one condition wearing a second name.
     *
     * ⚠ NO BAND IS DERIVED FROM IT, deliberately. `confidenceBand` exists because
     * Parse_Confidence__c is a RESTRICTED picklist that must never receive an out-of-set value;
     * this number is written to no field at all, so a second band would have no consumer.
     *
     * ⚠ NULL MEANS "the model did not say". Absent, unparseable or out-of-range all resolve to
     * null — never to zero and never clamped upward — so any future gate inherits a fail-open
     * default. A legacy-shape response (the one-line prompt rollback) and an LLM degrade both
     * produce null here.
     */
    public Decimal categoryConfidence;

    /**
     * `field_confidence` — PER-FIELD extraction confidence, keyed by the response's own JSON
     * key (lower-cased), valued 0–1. Added 2026-08-30 (WS7). Never null; EMPTY is the normal
     * answer for a legacy-shape response, a degraded call, or any model that ignored the key.
     *
     * ⚠ IT ANSWERS A THIRD, DIFFERENT QUESTION. `confidence` is about
     * `is_acquisition_related`; `categoryConfidence` is about `email_category`; this is about
     * whether the model READ each value correctly. None of the three substitutes for another,
     * and this one is the only one that can say "the address is solid but the NOI is a guess".
     *
     * ⚠ EMAIL-LEVEL, NOT PER-PROPERTY, AND THAT IS A DELIBERATE NARROWING. Most of the keys it
     * scores (`noi`, `year_built`, `cap_rate`) live on PropertyExtraction, so a strictly correct
     * model would be one map per property. The prompt therefore asks for ONE object per email
     * carrying the LOWEST confidence for each key across every property, and every Lead the
     * email mints is stamped with it. On the single-property email — the overwhelmingly common
     * shape — the two are identical. On a portfolio email the map is a WORST-CASE summary, which
     * is the conservative direction for something whose only consumer asks a human to re-read
     * the email. Making it per-property is an additive change to PropertyExtraction, not a
     * rewrite of this one; do that if the portfolio case ever needs field-level precision.
     *
     * 🔴 NO BAND AND NO GATE IS DERIVED FROM IT, and it must not acquire one.
     * `Parse_Confidence__c`'s HIGH/MEDIUM/LOW and ExtractAddressQueueable's `>= 0.85`
     * suppression gate both read `confidence` and are UNCHANGED by WS7. The only thing derived
     * here is `lowConfidenceFieldCount` below, which drives a REVIEW LIST VIEW — it suppresses
     * nothing and creates nothing.
     *
     * @see lowConfidenceFieldCount (the filterable half)
     * @see LLMExtractionParser.toFieldConfidence (the only producer; bounded at 60 entries)
     */
    public Map<String, Decimal> fieldConfidence = new Map<String, Decimal>();

    /**
     * How many entries of `fieldConfidence` sit BELOW `LLMExtractionParser.CONFIDENCE_MEDIUM_MIN`
     * — i.e. how many extracted values a human is being asked to check. Added 2026-08-30 (WS7).
     * Becomes `Lead.Low_Confidence_Field_Count__c`, whose `> 0` filter joins the Review Queue's
     * existing `Parse_Confidence__c = LOW` filter with OR.
     *
     * DERIVED BY APEX FROM THE MODEL'S NUMBERS, exactly as `confidenceBand` is, and for the same
     * reason: a threshold that lives in one place is tunable without touching the prompt. Since
     * WS5 that place is `Broker_Protection_Config__mdt.Default.Confidence_Medium_Min__c`, so
     * ONE Setup value moves the MEDIUM band and this count together and they can never disagree.
     *
     * ⚠ ZERO IS AMBIGUOUS BY DESIGN AND THAT IS THE SAFE DIRECTION. It means either "every field
     * scored at or above the threshold" or "the model returned no map at all". Both resolve to
     * "this Lead is not in the per-field review queue", which is correct: an email with no
     * per-field signal has nothing per-field to review, and whole-email doubt is still caught by
     * `Parse_Confidence__c = LOW` on the other side of the OR.
     *
     * ⚠ BOUNDED, BECAUSE ITS DESTINATION IS Number(2,0). The parser caps `fieldConfidence` at 60
     * entries, so this can never exceed 60 and can never reach the field's 99 ceiling — which is
     * why no second clamp exists here. A pathological response cannot throw at DML and roll back
     * a committed claim.
     */
    public Integer lowConfidenceFieldCount = 0;

    // ── broker identity (the forwarding / original broker — claim engine input) ─

    /** `broker_name` — LEGACY KEY. The ORIGINAL broker from the outermost 'From:' line. */
    public String brokerName;

    /** `broker_email` — LEGACY KEY. The claim engine's broker identity. DO NOT REPURPOSE. */
    public String brokerEmail;

    /** `broker_company` — the broker's firm; becomes Lead.Company when non-blank. */
    public String brokerCompany;

    /** `broker_phone` — Lead.Phone. */
    public String brokerPhone;

    /** `broker_mobile` — the broker's cell. ⚠ NOT Lead.MobilePhone: that field does not exist
     *  in this org. EmailToLeadService routes it to Phone (when no office line was extracted)
     *  or to a 'Mobile: ...' line on Deal_Notes__c. */
    public String brokerMobile;

    /** `broker_title` — Lead.Title. */
    public String brokerTitle;

    // ── listing broker (blast platforms: sender != listing broker) ────────────

    /** `listing_broker_name` — Lead.Listing_Broker_Name__c. NOT a claim-engine input. */
    public String listingBrokerName;

    /** `listing_broker_email` — Lead.Listing_Broker_Email__c. NOT a claim-engine input. */
    public String listingBrokerEmail;

    // ── narrative + timing ───────────────────────────────────────────────────

    /** `sent_datetime` — LEGACY KEY, raw 'yyyy-MM-dd HH:mm:ss' UTC string. Parsed to a
     *  Datetime by the caller (ExtractAddressQueueable.parseSentDatetime), which already
     *  owns the now()-on-failure fallback. */
    public String sentDatetime;

    /** `deal_summary` — the narrative (roof/lien/tenant detail, reported-vs-adjusted NOI,
     *  spillover for properties beyond the cap). Prompt-capped at 800 characters. */
    public String dealSummary;

    /** The properties this email pitches, in the model's original order. Never null; empty
     *  when the response carried no usable property object. */
    public List<PropertyExtraction> properties = new List<PropertyExtraction>();

    /**
     * True when the response carried no `properties` array but DID carry a top-level
     * `property_address` — i.e. the pre-enrichment four-key shape. The parser synthesizes a
     * one-element array in that case, which is what makes reverting
     * LLMExtractionCalloutService's prompt constant a ONE-LINE rollback with no code change
     * (design §3.2). Diagnostic only; nothing routes on it.
     */
    public Boolean usedLegacyShape = false;

    /**
     * An extraction carrying nothing — the shape every degraded path starts from, so a
     * caller never has to null-check its way through the routing tree. `rawJson` is set by
     * the caller to the appropriate `{"skipped":"..."}` marker.
     *
     * @return An LLMExtractionResult with no properties, no broker, and band LOW.
     * @example
     * LLMExtractionResult extraction = LLMExtractionResult.emptyResult();
     */
    public static LLMExtractionResult emptyResult() {
        return new LLMExtractionResult();
    }

    /**
     * Re-emit the four LEGACY keys for one property, in the EXACT map shape
     * PropertyClaimService / PropertyMatchingService / EmailToLeadService have always
     * consumed: `broker_name`, `broker_email`, `property_address`, `sent_datetime`, each
     * present and empty-string-for-absent (never null, never missing).
     *
     * Three of the four are email-level and identical for every property in the email; only
     * `property_address` varies, which is why this takes a property rather than returning
     * one map per email.
     *
     * @param property The property whose address to emit; null yields an empty address.
     * @return A four-key map; values are '' where the extraction had nothing.
     * @example
     * PropertyClaimService.claim(leadId, normalized, extraction.toLegacyMap(property), ...);
     */
    public Map<String, String> toLegacyMap(PropertyExtraction property) {
        return new Map<String, String>{
            'broker_name' => emptyIfNull(this.brokerName),
            'broker_email' => emptyIfNull(this.brokerEmail),
            'property_address' => (property == null) ? '' : emptyIfNull(property.propertyAddress),
            'sent_datetime' => emptyIfNull(this.sentDatetime)
        };
    }

    /**
     * Record a rejected value so it reaches a human on Deal_Notes__c instead of vanishing.
     * Blank notes are ignored, and the list is capped so a pathological response cannot
     * grow the heap or blow past Deal_Notes__c's 32k limit on its own.
     *
     * @param note The human-readable reason a value was discarded.
     */
    public void addNote(String note) {
        if (String.isNotBlank(note) && this.notes.size() < MAX_NOTES) {
            this.notes.add(note);
        }
    }

    /** Upper bound on accumulated notes — 10 properties x ~23 fields could otherwise
     *  produce hundreds of lines for a single junk response. */
    private static final Integer MAX_NOTES = 60;

    /**
     * Null-safe empty-string coercion — the legacy map's documented contract.
     *
     * @param value The value to coerce.
     * @return `value`, or '' when null.
     */
    private static String emptyIfNull(String value) {
        return (value == null) ? '' : value;
    }
}
