/**
 * Broker-Protection LLM extraction — the JSON→typed-value COERCION layer.
 *
 * Turns one raw model response into an LLMExtractionResult: a typed, validated,
 * DML-safe object graph. It is the contract; the prompt is only a hint. Everything the
 * model returns is treated as untrusted text until a rule here accepts it.
 *
 * ═══ THREE PROPERTIES THIS CLASS GUARANTEES ═══
 *   1. IT NEVER THROWS. Every entry point is total: a malformed payload, a missing key, a
 *      string where a number was promised, a 300-character URL — all resolve to a typed
 *      null plus a note. A parser exception here would abort the routing transaction and
 *      lose a broker's claim over a formatting mistake by a language model.
 *   2. A NULL MEANS "the email did not say, or said something unusable" — never "not
 *      parsed yet". Callers can write any non-null value straight to its field.
 *   3. EVERY REJECTION IS RECORDED. LLMExtractionResult.notes accumulates a human-readable
 *      reason for each discarded value, which the writer appends to Deal_Notes__c. That is
 *      the entire point of validating rather than trusting: it converts silent data loss
 *      into something a person sees on the record.
 *
 * ═══ WHY THIS IS A NEW CLASS AND NOT PART OF InboundEmailFieldUtil (C-17) ═══
 * InboundEmailFieldUtil's charter is exactly two functions — clip and sanitizeEmail — and
 * its value is that it is small and obviously correct while serving as THE chokepoint for
 * field-length/format safety across five writers. Adding ~15 typed coercions would dilute
 * that. The two also have different contracts: this class coerces (String/Object → typed)
 * and accumulates notes; the util enforces field safety (typed → DML-safe) and stays the
 * LAST step before DML. Both are pure, so both are directly unit-testable.
 *
 * ═══ 🔴 RESTRICTED PICKLISTS ARE VALIDATED AT RUNTIME, NOT AT COMPILE TIME ═══
 * Apex compiles against a picklist REGARDLESS of its values, so a code-first deploy goes
 * green and then throws INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST on the first Hospitality
 * email — rolling back a real claim. Every closed-set field here is therefore checked
 * against the ACTIVE values read from Schema.describe at runtime (the same defence
 * LeadConvertService.assetTypePicklistValues already uses for Property__c.Asset_Type__c).
 * That is the runtime half of a belt-and-braces pair; the other half is deploying the
 * picklist values before this code.
 *
 * LAYER — Utility. Pure functions: no SOQL, no DML, no callouts. `with sharing` is declared
 * for standards conformance (ARCHITECTURE.md §2) and is functionally a no-op here. The
 * describe calls are schema metadata reads, not data access, and are cached per transaction.
 *
 * @see LLMExtractionResult.cls / PropertyExtraction.cls (the output types)
 * @see LLMExtractionCalloutService.cls (produces the raw content this parses)
 * @see InboundEmailFieldUtil.cls (the field-safety chokepoint that runs after this)
 */
public with sharing class LLMExtractionParser {

    // ─────────────────────────────────────────────────────────────────────────
    // Confidence bands (C-8). The MODEL returns a number 0–1; APEX derives the band.
    // Three reasons, all deliberate: a number is thresholdable and tunable without
    // touching the prompt; models are more consistent producing a number than a
    // self-assessed label; and Apex owning the mapping makes it IMPOSSIBLE to write an
    // out-of-set value into the RESTRICTED Parse_Confidence__c picklist.
    // ─────────────────────────────────────────────────────────────────────────

    /** Parse_Confidence__c value for confidence >= 0.85. Also the hard-gate threshold. */
    public static final String BAND_HIGH = 'HIGH';
    /** Parse_Confidence__c value for confidence in [0.60, 0.85). */
    public static final String BAND_MEDIUM = 'MEDIUM';
    /** Parse_Confidence__c value for confidence < 0.60, or missing/unparseable. */
    public static final String BAND_LOW = 'LOW';

    /** Lower bound of the HIGH band — and the ONLY confidence at which the relevance gate
     *  suppresses a Lead (design §2.3). Tuning the gate happens here, never in the prompt. */
    public static final Decimal CONFIDENCE_HIGH_MIN = 0.85;
    /** Lower bound of the MEDIUM band. */
    public static final Decimal CONFIDENCE_MEDIUM_MIN = 0.60;

    /**
     * `email_category` closed set. An unrecognised value is coerced to 'other' rather than
     * rejected.
     *
     * ⚠ AMENDED 2026-08-03 (intake-rules-v2 / U2): the old comment said the category "drives
     * nothing but explainability, so it is never worth a note". Since U2 that is only true of
     * SIX of the seven values — `call_for_offers` is now the first condition of a gate that can
     * suppress a Lead entirely. Coercing an unrecognised value to 'other' remains right and is
     * the FAIL-OPEN direction (a garbled category can never reach the gate); what changed is
     * that this set is no longer purely diagnostic.
     */
    private static final Set<String> EMAIL_CATEGORIES = new Set<String>{
        'acquisition_deal', LLMExtractionResult.CATEGORY_CALL_FOR_OFFERS, 'reply',
        'system_notification', 'newsletter', 'out_of_office', LLMExtractionResult.CATEGORY_OTHER
    };

    // ── numeric bounds, each matched to its DESTINATION FIELD's precision ─────

    /** Currency(18,2) sanity ceiling. A price above this is a hallucinated digit run. */
    private static final Decimal MAX_CURRENCY = 10000000000000L;
    /** ADR is Currency(10,2) — a tighter ceiling than the other money fields, so it needs
     *  its own bound or an accepted value would still throw at DML. */
    private static final Decimal MAX_ADR = 99999999.99;
    /** Number(18,0) fields (building_sf, unit_count). */
    private static final Decimal MAX_COUNT = 999999999L;
    /** Lot_Size_Acres__c is Number(10,2). */
    private static final Decimal MAX_ACRES = 99999999.99;
    /** WALT_Years__c is Number(4,1). */
    private static final Decimal MAX_WALT = 999.9;
    /** Square feet per acre — the ONLY unit conversion in this pipeline, and it lives in
     *  Apex because asking the model to convert violates the prompt's own
     *  "never derive one number from another" anti-hallucination rule. */
    private static final Decimal SQ_FT_PER_ACRE = 43560;
    /** Oldest plausible construction year. */
    private static final Integer MIN_YEAR = 1700;
    /** Years into the future a construction/renovation year may plausibly sit. */
    private static final Integer YEAR_LOOKAHEAD = 5;
    /** Offer deadlines further out than this are a mis-parse, not a deal. */
    private static final Integer OFFER_DATE_MAX_FUTURE_DAYS = 730;
    /** An offer deadline older than this is a mis-parse of some other date in the email. */
    private static final Integer OFFER_DATE_MAX_PAST_DAYS = 365;

    // ── destination field lengths (text is clipped, never rejected) ──────────

    private static final Integer LEN_PROPERTY_NAME = 255;
    private static final Integer LEN_SELLER_ENTITY = 255;
    private static final Integer LEN_ZONING = 100;
    private static final Integer LEN_LISTING_BROKER_NAME = 120;
    private static final Integer LEN_COMPANY = 255;
    private static final Integer LEN_TITLE = 128;
    private static final Integer LEN_PHONE = 40;
    private static final Integer LEN_URL = 255;
    private static final Integer LEN_DEAL_SUMMARY = 4000;

    /** Per-transaction cache of ACTIVE picklist values, keyed by field name. Describe calls
     *  are cheap but not free, and a 10-property email would otherwise re-describe 30 times. */
    private static final Map<String, Set<String>> PICKLIST_CACHE = new Map<String, Set<String>>();

    /**
     * Parse one raw model response into a typed, validated result. TOTAL — never throws.
     *
     * Tolerates BOTH response shapes on purpose (design §3.2, the rollback lever):
     *   • the NEW shape — email-level keys plus a `properties` array;
     *   • the LEGACY four-key shape — no `properties` array but a top-level
     *     `property_address`, which is synthesized into a one-element array and flagged on
     *     `usedLegacyShape`. This is what makes reverting the prompt constant in
     *     LLMExtractionCalloutService a one-line rollback with no code change.
     *
     * @param rawContent The model's message content, code fences already stripped; blank,
     *                   null and non-JSON are all handled without throwing.
     * @return A fully-populated LLMExtractionResult; `rawJson` always carries `rawContent`
     *         verbatim so the D3 tier-1 store is written even for an unparseable reply.
     * @example
     * LLMExtractionResult extraction = LLMExtractionParser.parse(modelContent);
     */
    public static LLMExtractionResult parse(String rawContent) {
        LLMExtractionResult result = new LLMExtractionResult();
        result.rawJson = rawContent;

        Map<String, Object> root = asObjectMap(rawContent, result);
        if (root.isEmpty()) {
            return result;
        }

        parseEmailLevel(root, result);
        parseProperties(root, result);
        return result;
    }

    /**
     * Deserialize `rawContent` into a JSON object map, or an EMPTY map (plus a note) when
     * it is blank, not JSON, or not a JSON object. This is the only place a JSONException
     * can arise, and swallowing it here is what makes parse() total.
     *
     * @param rawContent The model's message content.
     * @param result     Result to record a note on when the payload is unusable.
     * @return The deserialized map, or an empty map.
     */
    private static Map<String, Object> asObjectMap(String rawContent, LLMExtractionResult result) {
        if (String.isBlank(rawContent)) {
            result.addNote('Extraction returned an empty response.');
            return new Map<String, Object>();
        }
        try {
            Object parsed = JSON.deserializeUntyped(rawContent);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
            result.addNote('Extraction response was valid JSON but not a JSON object.');
        } catch (JSONException je) {
            result.addNote('Extraction response was not valid JSON: ' + je.getMessage());
        }
        return new Map<String, Object>();
    }

    /**
     * Populate the email-level block: classification, confidence band, broker identity,
     * listing broker, send time and narrative.
     *
     * @param root   The deserialized response object.
     * @param result The result to populate in place.
     */
    private static void parseEmailLevel(Map<String, Object> root, LLMExtractionResult result) {
        String category = textOf(root.get('email_category'));
        result.emailCategory = (category != null && EMAIL_CATEGORIES.contains(category.toLowerCase()))
            ? category.toLowerCase()
            : LLMExtractionResult.CATEGORY_OTHER;

        result.isAcquisitionRelated = toBoolean(root.get('is_acquisition_related'));
        result.confidence = toConfidence(root.get('confidence'));
        result.confidenceBand = toBand(root.get('confidence'), result.confidence);
        // `category_confidence` (intake-rules-v2 / U2) reuses toConfidence UNCHANGED — same
        // [0, 1] contract, same never-throws coercion, same null-not-clamped rule. It gets NO
        // band (nothing writes it to a picklist) and NO note on absence (a legacy-shape response
        // legitimately carries no such key).
        // ⚠ NOTHING GATES ON IT. U2's call-for-offers rule is categorical; this value is parsed
        // purely so it lands in Extracted_JSON__c as tuning data — see
        // LLMExtractionResult.categoryConfidence for why that is a decision rather than dead code.
        result.categoryConfidence = toConfidence(root.get('category_confidence'));

        // The four legacy values travel untouched except for whitespace: broker_email and
        // property_address ARE the claim identity, and any "cleaning" here would change it.
        result.brokerName = textOf(root.get('broker_name'));
        result.brokerEmail = textOf(root.get('broker_email'));
        result.sentDatetime = textOf(root.get('sent_datetime'));

        result.brokerCompany = clipped(root.get('broker_company'), LEN_COMPANY);
        result.brokerPhone = clipped(root.get('broker_phone'), LEN_PHONE);
        result.brokerMobile = clipped(root.get('broker_mobile'), LEN_PHONE);
        result.brokerTitle = clipped(root.get('broker_title'), LEN_TITLE);
        result.listingBrokerName = clipped(root.get('listing_broker_name'), LEN_LISTING_BROKER_NAME);
        result.listingBrokerEmail = InboundEmailFieldUtil.sanitizeEmail(textOf(root.get('listing_broker_email')));
        result.dealSummary = clipped(root.get('deal_summary'), LEN_DEAL_SUMMARY);
    }

    /**
     * Populate `properties`, tolerating both response shapes (see parse()).
     *
     * @param root   The deserialized response object.
     * @param result The result to populate in place.
     */
    private static void parseProperties(Map<String, Object> root, LLMExtractionResult result) {
        Object rawProperties = root.get('properties');
        if (rawProperties instanceof List<Object>) {
            for (Object entry : (List<Object>) rawProperties) {
                if (entry instanceof Map<String, Object>) {
                    result.properties.add(parseProperty((Map<String, Object>) entry, result));
                }
            }
            if (!result.properties.isEmpty()) {
                return;
            }
        }

        // LEGACY four-key shape (or a `properties` array that held nothing usable): fall
        // back to the top-level address so the claim engine still gets its input.
        String legacyAddress = textOf(root.get('property_address'));
        if (String.isNotBlank(legacyAddress)) {
            PropertyExtraction legacy = new PropertyExtraction();
            legacy.propertyAddress = legacyAddress;
            result.properties.add(legacy);
            result.usedLegacyShape = true;
        }
    }

    /**
     * Coerce and validate ONE element of the `properties` array. Every rule from design
     * §3.4 is applied here; each rejection lands as a note on `result`.
     *
     * @param raw    One property object from the response.
     * @param result The email-level result, used only to accumulate notes.
     * @return The typed PropertyExtraction (never null; may be entirely empty).
     */
    private static PropertyExtraction parseProperty(Map<String, Object> raw, LLMExtractionResult result) {
        PropertyExtraction property = new PropertyExtraction();

        property.propertyName = clipped(raw.get('property_name'), LEN_PROPERTY_NAME);
        property.propertyAddress = textOf(raw.get('property_address'));

        property.assetType = picklistValue(raw.get('asset_type'), 'asset_type',
            activeValues('Asset_Type__c', Lead.Asset_Type__c), result);
        property.dealType = picklistValue(raw.get('deal_type'), 'deal_type',
            activeValues('Deal_Type__c', Lead.Deal_Type__c), result);
        property.saleProcess = picklistValue(raw.get('sale_process'), 'sale_process',
            activeValues('Sale_Process__c', Lead.Sale_Process__c), result);

        property.guidancePrice = money(raw.get('guidance_price'), 'guidance_price', MAX_CURRENCY, result);
        property.guidancePriceLow = money(raw.get('guidance_price_low'), 'guidance_price_low', MAX_CURRENCY, result);
        property.guidancePriceHigh = money(raw.get('guidance_price_high'), 'guidance_price_high', MAX_CURRENCY, result);
        property.noi = money(raw.get('noi'), 'noi', MAX_CURRENCY, result);
        property.adr = money(raw.get('adr'), 'adr', MAX_ADR, result);

        property.capRate = percentage(raw.get('cap_rate'), 'cap_rate', result);
        property.occupancyPct = percentage(raw.get('occupancy_pct'), 'occupancy_pct', result);

        property.buildingSf = wholeNumber(raw.get('building_sf'), 'building_sf', MAX_COUNT, result);
        property.unitCount = wholeNumber(raw.get('unit_count'), 'unit_count', MAX_COUNT, result);
        property.yearBuilt = year(raw.get('year_built'), 'year_built', result);
        property.yearRenovated = year(raw.get('year_renovated'), 'year_renovated', result);
        property.waltYears = boundedDecimal(raw.get('walt_years'), 'walt_years', MAX_WALT, 1, result);
        property.lotSizeAcres = acres(raw.get('lot_size_acres'), raw.get('lot_size_sf'), result);

        property.zoning = clipped(raw.get('zoning'), LEN_ZONING);
        property.sellerEntity = clipped(raw.get('seller_entity'), LEN_SELLER_ENTITY);
        property.dealRoomLink = url(raw.get('deal_room_link'), result);
        property.offerDueDate = offerDate(raw.get('offer_due_date'), result);

        return property;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Coercion rules — one method per rule in design §3.4.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * MONEY. Accepts a JSON number or a String; strips `$`, commas and whitespace; expands
     * the magnitude suffixes K (10³), M / MM (10⁶) and B (10⁹) — this is where `"$7.1M"`
     * becomes 7100000, and APEX owns it rather than the model, because asking a language
     * model to do arithmetic is asking it to hallucinate. Negatives are rejected (a price
     * is never negative and a leading '-' is far more likely a dash in a range) and so is
     * anything above the destination field's ceiling.
     *
     * @param raw     The raw value.
     * @param label   The JSON key, used in the rejection note.
     * @param ceiling The destination field's maximum.
     * @param result  Note accumulator.
     * @return The rounded 2-dp amount, or null.
     */
    private static Decimal money(Object raw, String label, Decimal ceiling, LLMExtractionResult result) {
        Decimal value = toDecimal(raw, label, result);
        if (value == null) {
            return null;
        }
        if (value < 0) {
            return rejected(label, raw, 'a negative amount', result);
        }
        if (value > ceiling) {
            return rejected(label, raw, 'above the maximum this field can hold', result);
        }
        return value.setScale(2, System.RoundingMode.HALF_UP);
    }

    /**
     * PERCENTAGE. Requires a PERCENTAGE number — 88.0, never 0.88 — which the prompt states
     * explicitly, and rejects anything outside [0, 100].
     *
     * ⚠ There is deliberately NO "if the value is ≤ 1 assume it is a fraction" heuristic. A
     * 0.9% cap rate is implausible, but a 0.9 occupancy FRACTION is not, and the same
     * heuristic cannot be right for both. Guessing would silently corrupt one of them; a
     * null plus a note is honest and recoverable.
     *
     * @param raw    The raw value.
     * @param label  The JSON key, used in the rejection note.
     * @param result Note accumulator.
     * @return The rounded 2-dp percentage, or null.
     */
    private static Decimal percentage(Object raw, String label, LLMExtractionResult result) {
        Decimal value = toDecimal(raw, label, result);
        if (value == null) {
            return null;
        }
        if (value < 0 || value > 100) {
            return rejected(label, raw,
                'outside 0-100 (this field expects a percentage number such as 88.0, not a fraction)', result);
        }
        return value.setScale(2, System.RoundingMode.HALF_UP);
    }

    /**
     * WHOLE NUMBER. Non-negative, rounded to an integer, bounded by the destination field.
     *
     * @param raw     The raw value.
     * @param label   The JSON key, used in the rejection note.
     * @param ceiling The destination field's maximum.
     * @param result  Note accumulator.
     * @return The rounded whole number, or null.
     */
    private static Decimal wholeNumber(Object raw, String label, Decimal ceiling, LLMExtractionResult result) {
        Decimal value = toDecimal(raw, label, result);
        if (value == null) {
            return null;
        }
        if (value < 0 || value > ceiling) {
            return rejected(label, raw, 'outside the range this field can hold', result);
        }
        return value.setScale(0, System.RoundingMode.HALF_UP);
    }

    /**
     * BOUNDED DECIMAL — a non-negative value with a ceiling and a fixed scale (WALT).
     *
     * @param raw     The raw value.
     * @param label   The JSON key, used in the rejection note.
     * @param ceiling The destination field's maximum.
     * @param scale   Decimal places the destination field holds.
     * @param result  Note accumulator.
     * @return The rounded value, or null.
     */
    private static Decimal boundedDecimal(Object raw, String label, Decimal ceiling,
                                          Integer scale, LLMExtractionResult result) {
        Decimal value = toDecimal(raw, label, result);
        if (value == null) {
            return null;
        }
        if (value < 0 || value > ceiling) {
            return rejected(label, raw, 'outside the range this field can hold', result);
        }
        return value.setScale(scale, System.RoundingMode.HALF_UP);
    }

    /**
     * YEAR. Apex owns two-digit normalization — brokers write '88/22' for built/renovated —
     * pivoting on the current two-digit year: at or below it means this century, above it
     * means the last one ('88' → 1988, '22' → 2022). Anything outside 1700 … currentYear+5
     * is rejected as a mis-parse rather than stored.
     *
     * @param raw    The raw value.
     * @param label  The JSON key, used in the rejection note.
     * @param result Note accumulator.
     * @return The four-digit year, or null.
     */
    private static Integer year(Object raw, String label, LLMExtractionResult result) {
        Decimal value = toDecimal(raw, label, result);
        if (value == null) {
            return null;
        }
        Integer candidate = value.setScale(0, System.RoundingMode.HALF_UP).intValue();
        Integer currentYear = Date.today().year();
        if (candidate >= 0 && candidate <= 99) {
            Integer pivot = Math.mod(currentYear, 100);
            Integer century = (candidate <= pivot) ? (currentYear / 100) * 100 : ((currentYear / 100) - 1) * 100;
            candidate = century + candidate;
        }
        if (candidate < MIN_YEAR || candidate > currentYear + YEAR_LOOKAHEAD) {
            rejected(label, raw, 'not a plausible year', result);
            return null;
        }
        return candidate;
    }

    /**
     * LOT SIZE, canonicalized to ACRES. Reports what the email said: when `lot_size_acres`
     * is present it wins; when only `lot_size_sf` is present, APEX converts (÷ 43,560).
     * The model is told never to convert, because converting is deriving one number from
     * another — the exact behaviour the anti-hallucination rules forbid.
     *
     * @param rawAcres     `lot_size_acres`.
     * @param rawSquareFeet `lot_size_sf`.
     * @param result       Note accumulator.
     * @return Acres to 2 dp, or null.
     */
    private static Decimal acres(Object rawAcres, Object rawSquareFeet, LLMExtractionResult result) {
        Decimal value = toDecimal(rawAcres, 'lot_size_acres', result);
        if (value == null) {
            Decimal squareFeet = toDecimal(rawSquareFeet, 'lot_size_sf', result);
            if (squareFeet == null) {
                return null;
            }
            if (squareFeet < 0) {
                return rejected('lot_size_sf', rawSquareFeet, 'a negative area', result);
            }
            value = squareFeet / SQ_FT_PER_ACRE;
        }
        if (value < 0 || value > MAX_ACRES) {
            return rejected('lot_size_acres', rawAcres, 'outside the range this field can hold', result);
        }
        return value.setScale(2, System.RoundingMode.HALF_UP);
    }

    /**
     * OFFER DUE DATE. Strict `yyyy-MM-dd` via Date.valueOf, then a plausibility window:
     * more than two years out, or more than a year stale, is a mis-parse of some other date
     * in the email rather than a real deadline.
     *
     * Relative phrasing ('offers due TODAY') is resolved by the PROMPT against
     * `sent_datetime` and never here — Apex has no reliable notion of the email's local day.
     *
     * @param raw    The raw value.
     * @param result Note accumulator.
     * @return The parsed Date, or null.
     */
    private static Date offerDate(Object raw, LLMExtractionResult result) {
        String text = textOf(raw);
        if (String.isBlank(text)) {
            return null;
        }
        Date parsed;
        try {
            parsed = Date.valueOf(text.trim());
        } catch (Exception e) {
            return (Date) rejectedObject('offer_due_date', raw, 'not a yyyy-MM-dd date', result);
        }
        Date today = Date.today();
        if (parsed > today.addDays(OFFER_DATE_MAX_FUTURE_DAYS) || parsed < today.addDays(-OFFER_DATE_MAX_PAST_DAYS)) {
            return (Date) rejectedObject('offer_due_date', raw, 'not a plausible offer deadline', result);
        }
        return parsed;
    }

    /**
     * URL. Must be http/https and within the destination field's length.
     *
     * ⚠ DELIBERATELY NOT CLIPPED. Every other text value here is truncated to fit, but a
     * truncated URL is a BROKEN link that still looks valid — someone clicks it, lands
     * nowhere, and has no way to tell the value was mangled. Nulling it plus a note keeps
     * the failure visible.
     *
     * @param raw    The raw value.
     * @param result Note accumulator.
     * @return The URL, or null.
     */
    private static String url(Object raw, LLMExtractionResult result) {
        String text = textOf(raw);
        if (String.isBlank(text)) {
            return null;
        }
        String trimmed = text.trim();
        String lowered = trimmed.toLowerCase();
        if (!lowered.startsWith('http://') && !lowered.startsWith('https://')) {
            return (String) rejectedObject('deal_room_link', raw, 'not an http/https URL', result);
        }
        if (trimmed.length() > LEN_URL) {
            return (String) rejectedObject('deal_room_link', raw,
                'longer than the field allows (a clipped URL is a broken URL, so it is dropped rather than truncated)',
                result);
        }
        return trimmed;
    }

    /**
     * CLOSED-SET PICKLIST. Accepts only an ACTIVE value of the destination picklist, read
     * from Schema.describe at RUNTIME (see the class header for why compile-time is no
     * protection). Matching is exact-after-trim first, then case-insensitive — the
     * case-insensitive pass always resolves to the picklist's OWN canonical spelling, so it
     * can raise the hit rate without any possibility of writing an invalid value.
     *
     * @param raw          The raw value.
     * @param label        The JSON key, used in the rejection note.
     * @param activeValues ACTIVE values of the destination picklist.
     * @param result       Note accumulator.
     * @return A canonical picklist value, or null.
     */
    private static String picklistValue(Object raw, String label, Set<String> activeValues,
                                        LLMExtractionResult result) {
        String text = textOf(raw);
        if (String.isBlank(text)) {
            return null;
        }
        String trimmed = text.trim();
        if (activeValues.contains(trimmed)) {
            return trimmed;
        }
        for (String candidate : activeValues) {
            if (candidate.equalsIgnoreCase(trimmed)) {
                return candidate;
            }
        }
        return (String) rejectedObject(label, raw, 'not an available value for this field', result);
    }

    /**
     * ACTIVE values of a Lead picklist, cached per transaction.
     *
     * @param cacheKey Stable cache key (the field's API name).
     * @param field    The field token to describe.
     * @return The set of active values; empty when the field is not a picklist.
     */
    private static Set<String> activeValues(String cacheKey, Schema.SObjectField field) {
        if (PICKLIST_CACHE.containsKey(cacheKey)) {
            return PICKLIST_CACHE.get(cacheKey);
        }
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        PICKLIST_CACHE.put(cacheKey, values);
        return values;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Primitive coercion helpers.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Coerce any JSON scalar to a Decimal: numbers pass through, Strings are cleaned of
     * currency symbols, thousands separators, whitespace and a trailing `%`, and magnitude
     * suffixes are expanded. Everything is routed through String.valueOf so no cast can
     * fail on the Integer/Long/Double/Decimal the JSON deserializer happens to have chosen.
     *
     * @param raw    The raw value.
     * @param label  The JSON key, used in the rejection note.
     * @param result Note accumulator.
     * @return The numeric value, or null when absent or unparseable.
     */
    private static Decimal toDecimal(Object raw, String label, LLMExtractionResult result) {
        if (raw == null) {
            return null;
        }
        String text = String.valueOf(raw).trim();
        if (String.isBlank(text) || 'null'.equalsIgnoreCase(text) || 'n/a'.equalsIgnoreCase(text)) {
            return null;
        }

        String cleaned = text.replaceAll('[\\s,$%]', '').replaceAll('(?i)usd', '');
        if (String.isBlank(cleaned)) {
            return (Decimal) rejectedObject(label, raw, 'not a number', result);
        }

        Decimal multiplier = 1;
        String upper = cleaned.toUpperCase();
        if (upper.endsWith('MM')) {
            multiplier = 1000000L;
            cleaned = cleaned.substring(0, cleaned.length() - 2);
        } else if (upper.endsWith('K')) {
            multiplier = 1000L;
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        } else if (upper.endsWith('M')) {
            multiplier = 1000000L;
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        } else if (upper.endsWith('B')) {
            multiplier = 1000000000L;
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        }

        try {
            return Decimal.valueOf(cleaned) * multiplier;
        } catch (Exception e) {
            return (Decimal) rejectedObject(label, raw, 'not a number', result);
        }
    }

    /**
     * Coerce `is_acquisition_related`. A real Boolean passes through; the strings 'true' and
     * 'false' are accepted (models quote booleans surprisingly often); ANYTHING ELSE returns
     * null, which the gate treats as "the model did not say" — never as false.
     *
     * @param raw The raw value.
     * @return TRUE / FALSE / null.
     */
    private static Boolean toBoolean(Object raw) {
        if (raw instanceof Boolean) {
            return (Boolean) raw;
        }
        String text = textOf(raw);
        if (String.isBlank(text)) {
            return null;
        }
        String trimmed = text.trim();
        if ('true'.equalsIgnoreCase(trimmed)) {
            return true;
        }
        return 'false'.equalsIgnoreCase(trimmed) ? false : null;
    }

    /**
     * Coerce a confidence-shaped value to a number in [0, 1]. A value outside the range, or a
     * non-numeric one, returns null (which bands to LOW) rather than being clamped:
     * clamping a nonsense confidence to 1.0 would hand the HARD GATE a value the model
     * never asserted.
     *
     * SERVES BOTH `confidence` AND `category_confidence` (intake-rules-v2 / U2). One coercion
     * for one contract: both keys are documented to the model as "a number from 0 to 1", and both
     * must fail toward null rather than toward a value the model never asserted. A second, subtly
     * different coercion for the newer key is exactly how the two would drift apart.
     *
     * @param raw The raw value.
     * @return The confidence, or null.
     */
    private static Decimal toConfidence(Object raw) {
        if (raw == null) {
            return null;
        }
        String text = String.valueOf(raw).trim();
        if (String.isBlank(text)) {
            return null;
        }
        try {
            Decimal value = Decimal.valueOf(text);
            return (value >= 0 && value <= 1) ? value : null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Derive the Parse_Confidence__c band. Also accepts a literal 'HIGH' / 'MEDIUM' / 'LOW'
     * straight from the model — tolerance kept for prompt iteration, since a model told to
     * return a number sometimes returns the label it used to return.
     *
     * @param raw        The raw `confidence` value (for the label passthrough).
     * @param confidence The numeric confidence, or null.
     * @return BAND_HIGH / BAND_MEDIUM / BAND_LOW; never null.
     */
    private static String toBand(Object raw, Decimal confidence) {
        if (confidence != null) {
            if (confidence >= CONFIDENCE_HIGH_MIN) {
                return BAND_HIGH;
            }
            return (confidence >= CONFIDENCE_MEDIUM_MIN) ? BAND_MEDIUM : BAND_LOW;
        }
        String text = textOf(raw);
        if (String.isNotBlank(text)) {
            String trimmed = text.trim();
            if (BAND_HIGH.equalsIgnoreCase(trimmed)) {
                return BAND_HIGH;
            }
            if (BAND_MEDIUM.equalsIgnoreCase(trimmed)) {
                return BAND_MEDIUM;
            }
        }
        return BAND_LOW;
    }

    /**
     * Null-safe text extraction. A JSON null, the literal string 'null', and a blank all
     * come back as null so callers never have to test for three empties.
     *
     * @param raw The raw value.
     * @return The trimmed text, or null.
     */
    private static String textOf(Object raw) {
        if (raw == null) {
            return null;
        }
        String text = String.valueOf(raw).trim();
        if (String.isBlank(text) || 'null'.equalsIgnoreCase(text)) {
            return null;
        }
        return text;
    }

    /**
     * Text clipped to its destination field length — the one category that is truncated
     * rather than rejected, because a shortened property name is still useful while a
     * STRING_TOO_LONG DmlException would roll back the claim.
     *
     * @param raw       The raw value.
     * @param maxLength The destination field's length.
     * @return The clipped text, or null.
     */
    private static String clipped(Object raw, Integer maxLength) {
        return InboundEmailFieldUtil.clip(textOf(raw), maxLength);
    }

    /**
     * Record a rejection and return null, typed as Decimal for the numeric rules.
     *
     * @param label  The JSON key.
     * @param raw    The offending value.
     * @param reason Why it was rejected.
     * @param result Note accumulator.
     * @return Always null.
     */
    private static Decimal rejected(String label, Object raw, String reason, LLMExtractionResult result) {
        return (Decimal) rejectedObject(label, raw, reason, result);
    }

    /**
     * Record a rejection and return null. Single place the note wording is composed, so
     * every discarded value reads the same on Deal_Notes__c.
     *
     * @param label  The JSON key.
     * @param raw    The offending value.
     * @param reason Why it was rejected.
     * @param result Note accumulator.
     * @return Always null.
     */
    private static Object rejectedObject(String label, Object raw, String reason, LLMExtractionResult result) {
        result.addNote(label + ' "' + String.valueOf(raw) + '" was ignored: ' + reason + '.');
        return null;
    }
}
