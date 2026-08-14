/**
 * Broker-Protection LLM extraction — ONE property pitched by an inbound broker email.
 *
 * A pure data carrier produced by LLMExtractionParser from one element of the response's
 * `properties` array. Every numeric/date/picklist member has already been coerced and
 * VALIDATED by the parser, so a non-null value here is safe to write to its destination
 * field and a null means "the email did not say, or said something unusable" — never
 * "not parsed yet". The parser records the reason for every null it produces in
 * LLMExtractionResult.notes, which the writer appends to Deal_Notes__c.
 *
 * ═══ WHY THIS TYPE SORTS ITSELF (the deadlock fix — design §1.2) ═══
 * compareTo orders properties by (clusterKey ASC, normalizedAddress ASC). That total
 * order is LOAD-BEARING, not cosmetic. PropertyClaimService.claim() takes a FOR UPDATE
 * row lock per property and Apex cannot release a row lock before commit, so a queueable
 * claiming N properties holds N locks simultaneously. Two concurrent multi-property emails
 * sharing two properties are a textbook AB-BA deadlock — and Salesforce does not report
 * deadlocks, it reports UNABLE_TO_LOCK_ROW, which acquireClusterLock already swallows into
 * ClaimOutcome.UNCLAIMED with only a System.debug. Broker protection would fail SILENTLY on
 * exactly the multi-property blasts this feature exists to support.
 *
 * Visiting shared clusters in the same relative order in every transaction makes a
 * wait-for cycle impossible: the loser simply blocks on the first shared key and proceeds
 * once the winner commits. Two rules the sort depends on, both easy to get wrong:
 *   1. The keys are derived ONLY from the address
 *      (PropertyMatchingService.deriveClusterKey(normalizeAddress(raw))) — NEVER from the
 *      LLM's array order, which is not stable across transactions.
 *   2. De-duplication happens on normalizedAddress, NEVER on clusterKey. deriveClusterKey
 *      is deliberately coarse ('<number> <firstAlphaToken>'), so two genuinely different
 *      buildings can share a key ('123 Main St, Dallas' and '123 Main St, Houston' both
 *      derive '123 main'). Re-locking the same row inside one transaction is a no-op, so
 *      sharing a key is safe; collapsing on it would silently drop a real property.
 *
 * `normalizedAddress` / `clusterKey` are populated by ExtractAddressQueueable when it
 * builds the work-list, not by the parser — the parser has no routing knowledge and the
 * keys are a routing concern. Both are null on a freshly parsed instance.
 *
 * LAYER — DTO. No SOQL, no DML, no callouts, no platform dependency beyond Date/Decimal.
 *
 * @see LLMExtractionParser.cls (the only producer)
 * @see LLMExtractionResult.cls (the email-level envelope that holds these)
 * @see ExtractAddressQueueable.cls (populates the sort keys and consumes the order)
 */
public class PropertyExtraction implements Comparable {

    // ── identity ─────────────────────────────────────────────────────────────

    /** `property_name` — the marketed name ('Royal Inn'); the matching signal for a
     *  name-only deal that carries no street address. Text(255). */
    public String propertyName;

    /** `property_address` — LEGACY KEY, the claim engine's input, verbatim as extracted.
     *  Normalizing this string produces Property_Registry__c.Property_Key__c, which IS the
     *  claim identity. Do not "clean" it here; normalizeAddress owns that. */
    public String propertyAddress;

    // ── classification (validated against the live picklists at runtime) ─────

    /** `asset_type` — an ACTIVE value of Lead.Asset_Type__c, or null. */
    public String assetType;

    /** `deal_type` — an ACTIVE value of Lead.Deal_Type__c ('Land' / 'Retail'), or null. */
    public String dealType;

    /** `sale_process` — an ACTIVE value of Lead.Sale_Process__c, or null. */
    public String saleProcess;

    /**
     * `listing_status` — an ACTIVE value of Lead.Listing_Status__c ('On Market' / 'Off
     * Market'), or null. Added 2026-08-14 (observation 1).
     *
     * ⚠ IT DEFAULTS TO NULL AND THE PARSER NEVER GUESSES ONE. A wrong On/Off Market is worse
     * than an empty one, because the analyst has no signal that it needs correcting — the
     * field's own metadata comment records that as the reason it carries no `<default>`. A
     * LEGACY-SHAPE response (the one-line prompt rollback) carries no such key at all and
     * therefore parses to null here, so reverting the prompt degrades this to manual entry
     * rather than stranding the feature.
     *
     * ⚠ NOT `sale_process`, and not derivable from it. `sale_process` says HOW the seller is
     * running the process (Off-Market / On-Market Listing / Call for Offers / Auction); this
     * says whether the property is publicly marketed at all. They correlate and they are not
     * the same fact — an Auction can be either — so neither may be inferred from the other.
     *
     * ⚠ NOT `Broker_Listing__c.Listing_Status__c`, which is the DISPOSITION side's
     * On Track / … performance picklist. Nothing may ever map between the two; the Lead
     * field's own metadata comment carries the full note.
     *
     * PER-PROPERTY, deliberately, and it sits here rather than on LLMExtractionResult for the
     * same reason `sale_process` does: a portfolio blast can pitch one off-market asset
     * alongside one that is openly listed, and the routing tree mints one Lead per property.
     */
    public String listingStatus;

    // ── economics ────────────────────────────────────────────────────────────

    /** `guidance_price` — asking price, Currency(18,2). */
    public Decimal guidancePrice;

    /** `guidance_price_low` — bottom of a quoted price RANGE, Currency(18,2). */
    public Decimal guidancePriceLow;

    /** `guidance_price_high` — top of a quoted price RANGE, Currency(18,2). */
    public Decimal guidancePriceHigh;

    /** `cap_rate` — a PERCENTAGE number (6.75 means 6.75%, never 0.0675). */
    public Decimal capRate;

    /** `noi` — net operating income, Currency(18,2). Adjusted NOI when the email quotes both. */
    public Decimal noi;

    /** `occupancy_pct` — a PERCENTAGE number (88.0 means 88%, never 0.88). */
    public Decimal occupancyPct;

    /** `adr` — average daily rate, hospitality only, Currency(10,2). */
    public Decimal adr;

    // ── physical ─────────────────────────────────────────────────────────────

    /** `building_sf` — rentable building area in square feet, Number(18,0). */
    public Decimal buildingSf;

    /** `lot_size_acres` — land area in ACRES. When the email quoted square feet instead,
     *  the parser (never the model) converts by dividing by 43,560. Number(10,2). */
    public Decimal lotSizeAcres;

    /** `unit_count` — apartment units, or hotel keys for hospitality. Number(18,0). */
    public Decimal unitCount;

    /** `year_built` — four-digit year; the parser expands a two-digit '88' to 1988. */
    public Integer yearBuilt;

    /** `year_renovated` — four-digit year; same two-digit expansion as yearBuilt. */
    public Integer yearRenovated;

    /** `walt_years` — weighted average lease term remaining, in years, Number(4,1). */
    public Decimal waltYears;

    /** `zoning` — zoning designation as quoted, Text(100). */
    public String zoning;

    // ── process ──────────────────────────────────────────────────────────────

    /** `seller_entity` — the selling ownership entity, Text(255). */
    public String sellerEntity;

    /** `deal_room_link` — http/https URL to the deal room or OM download. Never clipped:
     *  a truncated URL is a broken link that still looks valid, so an over-long one is
     *  nulled instead. */
    public String dealRoomLink;

    /** `offer_due_date` — the call-for-offers deadline. Relative phrasing ('offers due
     *  TODAY') is resolved by the PROMPT against sent_datetime, never by Apex. */
    public Date offerDueDate;

    // ── routing keys (populated by ExtractAddressQueueable, not by the parser) ─

    /** PropertyMatchingService.normalizeAddress(propertyAddress) — the claim key, and the
     *  de-duplication key for the work-list. Null until the queueable computes it. */
    public String normalizedAddress;

    /** PropertyMatchingService.deriveClusterKey(normalizedAddress) — the lock partition and
     *  the PRIMARY sort key. Null until the queueable computes it. */
    public String clusterKey;

    /**
     * TRUE when the model returned a property OBJECT that states nothing whatsoever — every
     * extracted member null or blank. Such an object is a structural artefact of the response
     * schema, not a property.
     *
     * ═══ WHY THIS EXISTS (defect fix, 2026-08-12) ═══
     * A live internal email ("Team lunch Friday + Q3 expense reports") came back with ONE
     * property object in which every field was empty. `ExtractAddressQueueable.firstProperty`
     * returns the first NON-NULL element, and an empty object is non-null, so branch (c)
     * labelled the resulting Lead `OUTCOME_NO_ADDRESS` ("New Lead (property, no address)") —
     * the population an administrator is meant to CHASE A MISSING ADDRESS for. A team-lunch
     * email sitting in that queue is a defect in the queue, not merely a cosmetic one.
     *
     * 🔴 THE PREDICATE IS "STATES NOTHING AT ALL", DELIBERATELY NOT "HAS NO NAME AND NO
     * ADDRESS", AND THE DIFFERENCE IS A REAL POPULATION. An email that describes a property
     * only by its facts — "128-unit multifamily, 6.2 cap, $14M, seller is a 1031 buyer" —
     * carries no name and no address AND IS EXACTLY WHAT `OUTCOME_NO_ADDRESS` IS FOR. Skipping
     * on name-and-address alone would strip that Lead's whole deal block (FIX 2's
     * `applyPropertyBlock` stamp) and relabel a genuine chase-the-address property as "no
     * property". Requiring EVERY member to be empty is the narrower rule and is the one that
     * matches the observed artefact exactly.
     *
     * ⚠ `normalizedAddress` and `clusterKey` are EXCLUDED on purpose: they are routing keys
     * derived by `ExtractAddressQueueable`, not values the email stated, so counting them would
     * make the answer depend on when the predicate is called.
     *
     * ⚠ IT LIVES ON THE DTO, NOT ON ITS CALLER, so the field list it walks is maintained beside
     * the fields themselves. A new member added above without a line here silently narrows the
     * predicate, which is the one way this can rot — the same reason the parser's own field
     * mapping lives next to these declarations.
     *
     * @return true when the email stated nothing about this property.
     * @example
     * // not a property at all — neither stamp it onto a Lead nor footnote it:
     * if (property.hasNoExtractedValues()) { continue; }
     */
    public Boolean hasNoExtractedValues() {
        return String.isBlank(propertyName)
            && String.isBlank(propertyAddress)
            && String.isBlank(assetType)
            && String.isBlank(dealType)
            && String.isBlank(saleProcess)
            && String.isBlank(listingStatus)
            && String.isBlank(zoning)
            && String.isBlank(sellerEntity)
            && String.isBlank(dealRoomLink)
            && guidancePrice == null
            && guidancePriceLow == null
            && guidancePriceHigh == null
            && capRate == null
            && noi == null
            && occupancyPct == null
            && adr == null
            && buildingSf == null
            && lotSizeAcres == null
            && unitCount == null
            && yearBuilt == null
            && yearRenovated == null
            && waltYears == null
            && offerDueDate == null;
    }

    /**
     * Total order over (clusterKey, normalizedAddress) — the lock-acquisition order that
     * prevents AB-BA deadlocks between concurrent multi-property emails. See the class
     * header for why this is load-bearing.
     *
     * Nulls sort FIRST so an un-keyed instance can never be silently interleaved among
     * keyed ones; in practice the queueable only sorts fully-keyed instances, because the
     * work-list excludes properties whose normalized address is blank.
     *
     * @param other The PropertyExtraction to compare against.
     * @return -1, 0 or 1 per the Comparable contract.
     * @example
     * List&lt;PropertyExtraction&gt; workList = ...; workList.sort(); // cluster-key order
     */
    public Integer compareTo(Object other) {
        PropertyExtraction that = (PropertyExtraction) other;
        Integer byCluster = compareStrings(this.clusterKey, that.clusterKey);
        return (byCluster != 0) ? byCluster : compareStrings(this.normalizedAddress, that.normalizedAddress);
    }

    /**
     * Null-safe String ordering: null sorts before any value, equal values return 0.
     *
     * @param left  First value (may be null).
     * @param right Second value (may be null).
     * @return -1, 0 or 1.
     */
    private static Integer compareStrings(String left, String right) {
        if (left == right) {
            return 0;
        }
        if (left == null) {
            return -1;
        }
        if (right == null) {
            return 1;
        }
        return left.compareTo(right);
    }
}
