/**
 * Test class for LLMExtractionParser — one test per validation rule in design §3.4, plus the
 * two response shapes and the confidence banding.
 *
 * WHY THIS CLASS IS PURE UNIT TESTS. The parser is a total function with no SOQL, no DML and no
 * callouts, so every rule can be asserted directly on its output instead of inferred from a
 * routed Lead three classes downstream. That matters because the parser is the ONLY thing
 * standing between an untrusted language-model response and a DML statement: an unvalidated
 * value reaching the restricted `Asset_Type__c` picklist throws
 * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and rolls back a committed claim.
 *
 * NO 251-RECORD BULK TEST, deliberately: the parser has no DML, no SOQL and no per-record loop
 * over SObjects — it processes ONE response per call, bounded by the prompt's 10-property cap.
 * See `.claude/rules/bulk-test-rule.md` (narrowed 2026-07-31) for what replaces the mandate in
 * this module.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes.
 *
 * @author Salesforce Technical Architect
 */
@isTest
private class LLMExtractionParserTest {

    /** Builds a one-property response with `key` set to `value`, as raw JSON. */
    private static String propertyJson(String key, Object value) {
        Map<String, Object> property = new Map<String, Object>{ 'property_address' => '100 Main St' };
        property.put(key, value);
        return JSON.serialize(new Map<String, Object>{
            'properties' => new List<Object>{ property }
        });
    }

    /** Parses a one-property response and returns that property. */
    private static PropertyExtraction parseProperty(String key, Object value) {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson(key, value));
        Assert.areEqual(1, result.properties.size(), 'The fixture should yield exactly one property');
        return result.properties[0];
    }

    // ── response shape ────────────────────────────────────────────────────────

    @isTest
    static void parse_enrichedShape_readsEmailLevelAndProperties() {
        String body = JSON.serialize(new Map<String, Object>{
            'email_category' => 'acquisition_deal',
            'is_acquisition_related' => true,
            'confidence' => 0.92,
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'broker_company' => 'Brokerfirm LLC',
            'sent_datetime' => '2026-07-01 10:00:00',
            'deal_summary' => 'Two-asset portfolio.',
            'properties' => new List<Object>{
                new Map<String, Object>{ 'property_address' => '100 Main St' },
                new Map<String, Object>{ 'property_address' => '200 Oak Ave' }
            }
        });

        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse(body);
        Test.stopTest();

        Assert.areEqual('acquisition_deal', result.emailCategory, 'email_category should be read from the closed set');
        Assert.areEqual(true, result.isAcquisitionRelated, 'is_acquisition_related should be read');
        Assert.areEqual('jane@brokerfirm.example.invalid', result.brokerEmail,
            'broker_email is the claim engine input and must travel untouched');
        Assert.areEqual('Brokerfirm LLC', result.brokerCompany, 'broker_company should be read');
        Assert.areEqual(2, result.properties.size(), 'Both property objects should be parsed');
        Assert.isFalse(result.usedLegacyShape, 'A response carrying a properties array is not the legacy shape');
    }

    @isTest
    static void parse_legacyFourKeyShape_synthesizesOnePropertyAndFlagsIt() {
        // This is the ROLLBACK LEVER made testable: reverting the prompt constant produces
        // exactly this response, and the pipeline must keep working with no other code change.
        String body = JSON.serialize(new Map<String, Object>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Legacy St',
            'sent_datetime' => '2026-07-01 10:00:00'
        });

        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse(body);
        Test.stopTest();

        Assert.areEqual(1, result.properties.size(),
            'A top-level property_address with no properties array must synthesize a one-element array');
        Assert.areEqual('100 Legacy St', result.properties[0].propertyAddress,
            'The synthesized property must carry the legacy address verbatim — it is the claim key');
        Assert.isTrue(result.usedLegacyShape, 'The legacy shape should be flagged for diagnostics');
    }

    @isTest
    static void parse_malformedJson_returnsEmptyResultAndNeverThrows() {
        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse('{"properties": [ truncated mid-obj');
        Test.stopTest();

        Assert.areEqual(0, result.properties.size(), 'An unparseable response must yield no properties');
        Assert.isFalse(result.notes.isEmpty(), 'The parse failure must be recorded as a note, not swallowed');
        Assert.areEqual(LLMExtractionParser.BAND_LOW, result.confidenceBand,
            'A response that could not be parsed cannot be HIGH confidence');
    }

    @isTest
    static void parse_blankResponse_returnsEmptyResultWithNote() {
        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse('');
        Test.stopTest();

        Assert.areEqual(0, result.properties.size(), 'A blank response must yield no properties');
        Assert.isFalse(result.notes.isEmpty(), 'A blank response must be recorded as a note');
    }

    // ── confidence banding (C-8) ──────────────────────────────────────────────

    @isTest
    static void parse_confidenceAtHighThreshold_bandsHigh() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'confidence' => 0.85 }));
        Assert.areEqual(LLMExtractionParser.BAND_HIGH, result.confidenceBand,
            '0.85 is the inclusive lower bound of HIGH — the exact value the hard gate fires on');
    }

    @isTest
    static void parse_confidenceJustBelowHigh_bandsMedium() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'confidence' => 0.84 }));
        Assert.areEqual(LLMExtractionParser.BAND_MEDIUM, result.confidenceBand,
            '0.84 must NOT reach HIGH, or the hard gate would fire one hundredth too early');
    }

    @isTest
    static void parse_lowConfidence_bandsLow() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'confidence' => 0.4 }));
        Assert.areEqual(LLMExtractionParser.BAND_LOW, result.confidenceBand, 'Below 0.60 bands LOW');
    }

    @isTest
    static void parse_missingConfidence_bandsLow() {
        LLMExtractionResult result = LLMExtractionParser.parse('{}');
        Assert.areEqual(LLMExtractionParser.BAND_LOW, result.confidenceBand,
            'A missing confidence must band LOW — never HIGH, which would let the gate suppress a Lead');
    }

    @isTest
    static void parse_confidenceAsLabelString_isAccepted() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'confidence' => 'HIGH' }));
        Assert.areEqual(LLMExtractionParser.BAND_HIGH, result.confidenceBand,
            'A model that returns the old label instead of a number should still band correctly');
    }

    @isTest
    static void parse_outOfRangeConfidence_bandsLowRatherThanClamping() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'confidence' => 4.2 }));
        Assert.areEqual(LLMExtractionParser.BAND_LOW, result.confidenceBand,
            'A nonsense confidence must not be clamped to 1.0 — that would hand the HARD GATE a certainty the model never asserted');
    }

    @isTest
    static void parse_isAcquisitionRelatedAbsent_isNullNotFalse() {
        LLMExtractionResult result = LLMExtractionParser.parse('{}');
        Assert.isNull(result.isAcquisitionRelated,
            '"The model did not say" must stay null: only an EXPLICIT false may ever gate a Lead away');
    }

    // ── category_confidence (intake-rules-v2 / U2) ────────────────────────────
    //
    // ⚠ NOTHING GATES ON THIS FIELD. U2's call-for-offers rule is CATEGORICAL — the category alone
    // decides whether a Lead exists — and this value is parsed purely so it lands in
    // Extracted_JSON__c as TUNING DATA, the only evidence available if that suppression later
    // proves too aggressive. These tests therefore pin a PARSING contract, not a gate.
    //
    // They still matter, and more than they look: if a threshold is ever introduced it must gate
    // on THIS field and never on `confidence`, and it will inherit exactly the coercion asserted
    // below. `confidence` measures certainty about is_acquisition_related, and a call-for-offers
    // blast IS acquisition-related, so `confidence` carries no discrimination here whatsoever.

    @isTest
    static void parse_categoryConfidencePresent_isRead() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'category_confidence' => 0.91 }));
        Assert.areEqual(0.91, result.categoryConfidence,
            'category_confidence must be read as a number and not a band — it is stored for later '
            + 'analysis, so it is the VALUE that has to survive');
    }

    @isTest
    static void parse_categoryConfidenceAbsent_isNull() {
        LLMExtractionResult result = LLMExtractionParser.parse('{}');
        Assert.isNull(result.categoryConfidence,
            '🔴 ABSENT MUST NEVER BE READ AS CERTAIN. Nothing gates on this today, but any future '
            + 'threshold inherits this default — and a null silently read as 1.0 would suppress '
            + 'real broker Leads on a missing key');
    }

    @isTest
    static void parse_categoryConfidenceOutOfRange_isNullNotClamped() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'category_confidence' => 4.2 }));
        Assert.isNull(result.categoryConfidence,
            'A nonsense value must not be clamped to 1.0 — that would record a certainty the model '
            + 'never asserted, and poison the very data this field is kept for');
    }

    @isTest
    static void parse_categoryConfidenceNonNumeric_isNull() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'category_confidence' => 'very high' }));
        Assert.isNull(result.categoryConfidence,
            'A model that answers in prose yields null. Note this deliberately differs from '
            + '`confidence`, which accepts a literal HIGH/MEDIUM/LOW label — that tolerance exists '
            + 'to feed a PICKLIST band, and there is no band here to feed');
    }

    @isTest
    static void parse_confidenceAndCategoryConfidence_areIndependent() {
        // The shape U2 exists for: a blast that is confidently acquisition-related while its
        // CATEGORY is uncertain. The two values must never move together, because that is exactly
        // the confusion that would make someone reach for the wrong one when tuning.
        LLMExtractionResult result = LLMExtractionParser.parse(JSON.serialize(new Map<String, Object>{
            'email_category' => 'call_for_offers',
            'is_acquisition_related' => true,
            'confidence' => 0.99,
            'category_confidence' => 0.40
        }));

        Assert.areEqual(0.99, result.confidence, 'confidence is read from its own key');
        Assert.areEqual(LLMExtractionParser.BAND_HIGH, result.confidenceBand,
            'and still bands HIGH — a blast IS acquisition-related, which is precisely why '
            + 'confidence could never discriminate call_for_offers from a genuine exclusive');
        Assert.areEqual(0.40, result.categoryConfidence,
            'while category_confidence stays LOW and independent');
        Assert.areEqual(LLMExtractionResult.CATEGORY_CALL_FOR_OFFERS, result.emailCategory,
            'and the CATEGORY — the only thing U2 actually reads — is taken from the closed set');
    }

    @isTest
    static void parse_legacyShape_carriesNoCategoryOrCategoryConfidence() {
        // THE ROLLBACK LEVER, from U2's side. Reverting the prompt constant produces exactly this
        // response, and the important half is the CATEGORY: with none present it defaults to
        // 'other', so the gate cannot fire and reverting the prompt DISABLES the suppression
        // rather than stranding it on.
        LLMExtractionResult result = LLMExtractionParser.parse(JSON.serialize(new Map<String, Object>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Legacy St',
            'sent_datetime' => '2026-07-01 10:00:00'
        }));

        Assert.isTrue(result.usedLegacyShape, 'Precondition: this is the legacy four-key shape');
        Assert.areEqual(LLMExtractionResult.CATEGORY_OTHER, result.emailCategory,
            '🔴 THE ROLLBACK IS SAFE BECAUSE OF THIS LINE: no category means "other", which the U2 '
            + 'gate ignores, so a prompt revert can never leave suppression running on responses '
            + 'that cannot express a category');
        Assert.isNull(result.categoryConfidence,
            'and the tuning value is simply absent, as it is on every legacy-shape response');
    }

    // ── currency (§3.4) ───────────────────────────────────────────────────────

    @isTest
    static void parse_currencyWithSuffixM_expandsToMillions() {
        PropertyExtraction property = parseProperty('guidance_price', '$7.1M');
        Assert.areEqual(7100000.00, property.guidancePrice,
            '"$7.1M" must be expanded by APEX — asking the model to do arithmetic is asking it to hallucinate');
    }

    @isTest
    static void parse_currencyWithSuffixK_expandsToThousands() {
        PropertyExtraction property = parseProperty('noi', '450K');
        Assert.areEqual(450000.00, property.noi, '"450K" should expand to 450000');
    }

    @isTest
    static void parse_currencyWithCommasAndSymbol_isCleaned() {
        PropertyExtraction property = parseProperty('guidance_price', '$1,250,000');
        Assert.areEqual(1250000.00, property.guidancePrice, 'Currency symbols and separators should be stripped');
    }

    @isTest
    static void parse_negativeCurrency_isRejectedWithNote() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('guidance_price', '-500000'));
        Assert.isNull(result.properties[0].guidancePrice, 'A negative price must be rejected');
        Assert.isFalse(result.notes.isEmpty(), 'The rejection must leave a note for a human to see on Deal_Notes__c');
    }

    @isTest
    static void parse_nonNumericCurrency_isRejectedWithNote() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('noi', 'Market to Establish'));
        Assert.isNull(result.properties[0].noi, 'An unpriced deal must yield null, not a crash');
        Assert.isFalse(result.notes.isEmpty(), 'The unparseable value must be noted');
    }

    // ── percentage (§3.4) ─────────────────────────────────────────────────────

    @isTest
    static void parse_occupancyAsPercentageNumber_isKept() {
        PropertyExtraction property = parseProperty('occupancy_pct', 88.0);
        Assert.areEqual(88.00, property.occupancyPct,
            'Occupancy 88.0 must survive intact — it also proves the field is Percent(5,2), since (3,2) caps at 9.99');
    }

    @isTest
    static void parse_capRateWithPercentSign_isCleaned() {
        PropertyExtraction property = parseProperty('cap_rate', '6.75%');
        Assert.areEqual(6.75, property.capRate, 'A trailing % should be stripped, not rejected');
    }

    @isTest
    static void parse_percentageAboveOneHundred_isRejected() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('occupancy_pct', 880));
        Assert.isNull(result.properties[0].occupancyPct, 'A percentage above 100 is a mis-parse and must be rejected');
        Assert.isFalse(result.notes.isEmpty(), 'The rejection must be noted');
    }

    @isTest
    static void parse_fractionalOccupancy_isKeptAsIsNotDoubled() {
        // Deliberately NO "if <= 1 assume a fraction" heuristic: 0.9 occupancy is plausible as a
        // fraction AND 0.9% is implausible as a cap rate, so one heuristic cannot serve both.
        PropertyExtraction property = parseProperty('occupancy_pct', 0.9);
        Assert.areEqual(0.90, property.occupancyPct,
            'A value inside 0-100 must be stored verbatim — guessing that it is a fraction would silently corrupt it');
    }

    // ── integers, years, WALT (§3.4) ──────────────────────────────────────────

    @isTest
    static void parse_buildingSfWithCommas_isCleaned() {
        PropertyExtraction property = parseProperty('building_sf', '128,500');
        Assert.areEqual(128500, property.buildingSf, 'Thousands separators should be stripped from integers');
    }

    @isTest
    static void parse_twoDigitYearBuilt_expandsToLastCentury() {
        PropertyExtraction property = parseProperty('year_built', 88);
        Assert.areEqual(1988, property.yearBuilt,
            'Brokers write "88/22"; APEX owns the expansion, pivoting on the current two-digit year');
    }

    @isTest
    static void parse_twoDigitYearRenovated_expandsToThisCentury() {
        PropertyExtraction property = parseProperty('year_renovated', 22);
        Assert.areEqual(2022, property.yearRenovated, '22 is at or below the current two-digit year, so it is 2022');
    }

    @isTest
    static void parse_fourDigitYear_isKept() {
        PropertyExtraction property = parseProperty('year_built', 1974);
        Assert.areEqual(1974, property.yearBuilt, 'A four-digit year should pass through untouched');
    }

    @isTest
    static void parse_implausibleYear_isRejected() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('year_built', 1200));
        Assert.isNull(result.properties[0].yearBuilt, 'A year before 1700 is a mis-parse');
        Assert.isFalse(result.notes.isEmpty(), 'The rejection must be noted');
    }

    @isTest
    static void parse_waltYears_isRoundedToOneDecimal() {
        PropertyExtraction property = parseProperty('walt_years', 7.26);
        Assert.areEqual(7.3, property.waltYears, 'WALT_Years__c is Number(4,1), so the value is rounded to 1 dp');
    }

    // ── lot size conversion (§0.11 / §3.4) ────────────────────────────────────

    @isTest
    static void parse_lotSizeInSquareFeetOnly_isConvertedByApex() {
        String body = JSON.serialize(new Map<String, Object>{
            'properties' => new List<Object>{
                new Map<String, Object>{ 'property_address' => '1 Land Rd', 'lot_size_sf' => 43560 }
            }
        });

        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse(body);
        Test.stopTest();

        Assert.areEqual(1.00, result.properties[0].lotSizeAcres,
            'APEX converts SF to acres (43,560 SF = 1 acre) precisely because the prompt forbids the model from deriving one number from another');
    }

    @isTest
    static void parse_lotSizeInAcres_winsOverSquareFeet() {
        String body = JSON.serialize(new Map<String, Object>{
            'properties' => new List<Object>{
                new Map<String, Object>{
                    'property_address' => '1 Land Rd', 'lot_size_acres' => 2.5, 'lot_size_sf' => 999
                }
            }
        });

        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse(body);
        Test.stopTest();

        Assert.areEqual(2.50, result.properties[0].lotSizeAcres,
            'A stated acreage is what the email said and must beat any conversion');
    }

    // ── date (§3.4) ───────────────────────────────────────────────────────────

    @isTest
    static void parse_offerDueDateInRange_isParsed() {
        Date expected = Date.today().addDays(21);
        String iso = String.valueOf(expected).left(10);
        PropertyExtraction property = parseProperty('offer_due_date', iso);
        Assert.areEqual(expected, property.offerDueDate, 'A plausible yyyy-MM-dd deadline should parse');
    }

    @isTest
    static void parse_offerDueDateFarInFuture_isRejected() {
        String iso = String.valueOf(Date.today().addYears(5)).left(10);
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('offer_due_date', iso));
        Assert.isNull(result.properties[0].offerDueDate,
            'A deadline five years out is a mis-parse of some other date in the email');
        Assert.isFalse(result.notes.isEmpty(), 'The rejection must be noted');
    }

    @isTest
    static void parse_offerDueDateNotADate_isRejected() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('offer_due_date', 'next Friday'));
        Assert.isNull(result.properties[0].offerDueDate,
            'Relative phrasing is the PROMPT\'s job to resolve against sent_datetime; Apex must reject it, not guess');
        Assert.isFalse(result.notes.isEmpty(), 'The rejection must be noted');
    }

    // ── closed-set picklists (§3.4, the restricted-picklist defence) ──────────

    @isTest
    static void parse_assetTypeOutOfSet_isNulledWithNote() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('asset_type', 'Spaceport'));
        Assert.isNull(result.properties[0].assetType,
            'An invented picklist value must never reach DML — a restricted picklist throws and rolls back the claim');
        Assert.isFalse(result.notes.isEmpty(), 'The rejection must be noted');
    }

    @isTest
    static void parse_assetTypeInSet_isKept() {
        PropertyExtraction property = parseProperty('asset_type', 'Retail');
        Assert.areEqual('Retail', property.assetType, 'An active picklist value should pass validation');
    }

    @isTest
    static void parse_assetTypeWrongCase_resolvesToCanonicalValue() {
        PropertyExtraction property = parseProperty('asset_type', 'retail');
        Assert.areEqual('Retail', property.assetType,
            'Case-insensitive matching resolves to the PICKLIST\'S OWN spelling, so it can never produce an invalid value');
    }

    @isTest
    static void parse_dealTypeInSet_isKept() {
        PropertyExtraction property = parseProperty('deal_type', 'Retail');
        Assert.areEqual('Retail', property.dealType, 'Deal_Type__c should validate against its own picklist');
    }

    // ── listing_status (observation 1, 2026-08-14) ────────────────────────────
    //
    // Three tests, and the THIRD is the one that matters. `listing_status` is the ninth
    // extraction key and the ninth term of the extraction score's denominator, so the whole
    // design rests on "absent means blank, never a guess" — the Lead field carries no
    // <default> for exactly that reason. The first two only prove the picklist guard works;
    // the third pins the behaviour a prompt rollback depends on.

    @isTest
    static void parse_listingStatusInSet_isKept() {
        PropertyExtraction property = parseProperty('listing_status', 'Off Market');
        Assert.areEqual('Off Market', property.listingStatus,
            'An active Listing_Status__c value must pass validation and be carried through');
    }

    @isTest
    static void parse_listingStatusNotInSet_isNulledAndNoted() {
        // 🔴 THE DML-SAFETY LEG. Lead.Listing_Status__c is a RESTRICTED picklist, so pushing an
        // off-list answer would throw INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST at the Lead insert
        // — inside the routing transaction, rolling back a claim the broker had already won.
        // 'Pending' is deliberately a value that EXISTS on other picklists in this org but not
        // on this one, which is the realistic shape of a model mistake.
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('listing_status', 'Pending'));

        Assert.isNull(result.properties[0].listingStatus,
            'An off-list listing_status must be DROPPED, never pushed at a restricted picklist');
        Assert.isFalse(result.notes.isEmpty(),
            'The rejection must be noted so it reaches a human on Deal_Notes__c rather than '
            + 'vanishing — that is what distinguishes "the model said nothing" from "the model '
            + 'said something we refused to store"');
    }

    @isTest
    static void parse_legacyShapeCarriesNoListingStatusKey_parsesToBlankWithNoNote() {
        // 🔴 THE ROLLBACK-LEVER LEG. LLMExtractionCalloutService's prompt can be reverted to the
        // pre-enrichment four-key form in ONE line; such a response carries no `listing_status`
        // key at all. That must degrade to MANUAL ENTRY (a blank field an analyst fills in), not
        // to a stranded feature and not to a spurious rejection note — an ABSENT key is not a
        // REJECTED value and the two must stay distinguishable on Deal_Notes__c.
        LLMExtractionResult result = LLMExtractionParser.parse(JSON.serialize(new Map<String, Object>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Main St',
            'sent_datetime' => '2026-08-14 09:00:00'
        }));

        Assert.isTrue(result.usedLegacyShape, 'Precondition: this fixture is the legacy four-key shape');
        Assert.areEqual(1, result.properties.size(), 'The legacy shape synthesizes one property');
        Assert.isNull(result.properties[0].listingStatus,
            'A response that never mentions listing_status must parse to BLANK — the field '
            + 'carries no default precisely so a rollback degrades to manual entry');
        Assert.isTrue(result.notes.isEmpty(),
            'An ABSENT key is not a REJECTED value: noting it would fill Deal_Notes__c with '
            + 'noise on every rolled-back response and hide the notes that mean something');
    }

    // ── URL + text (§3.4) ─────────────────────────────────────────────────────

    @isTest
    static void parse_longUrl_isNulledNotClipped() {
        String longUrl = 'https://deals.example.invalid/' + ''.rightPad(300, 'x');
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('deal_room_link', longUrl));
        Assert.isNull(result.properties[0].dealRoomLink,
            'A clipped URL is a BROKEN URL that still looks valid, so an over-long one is dropped rather than truncated');
        Assert.isFalse(result.notes.isEmpty(), 'The dropped link must be noted');
    }

    @isTest
    static void parse_nonHttpUrl_isRejected() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('deal_room_link', 'ftp://example.invalid/om'));
        Assert.isNull(result.properties[0].dealRoomLink, 'Only http/https links are accepted');
    }

    @isTest
    static void parse_validUrl_isKept() {
        PropertyExtraction property = parseProperty('deal_room_link', 'https://deals.example.invalid/om');
        Assert.areEqual('https://deals.example.invalid/om', property.dealRoomLink, 'A valid https URL should pass');
    }

    @isTest
    static void parse_overLongZoning_isClippedNotDropped() {
        PropertyExtraction property = parseProperty('zoning', ''.rightPad(300, 'z'));
        Assert.areEqual(100, property.zoning.length(),
            'Text is CLIPPED rather than rejected: a shortened zoning code is still useful, and STRING_TOO_LONG would roll back the claim');
    }

    @isTest
    static void parse_malformedListingBrokerEmail_isNulled() {
        String body = JSON.serialize(new Map<String, Object>{
            'listing_broker_email' => 'Jane Broker <not an address>'
        });

        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse(body);
        Test.stopTest();

        Assert.isNull(result.listingBrokerEmail,
            'A display name bound to an Email field would throw INVALID_EMAIL_ADDRESS, so it is sanitized to null');
    }

    @isTest
    static void parse_unknownEmailCategory_fallsBackToOther() {
        LLMExtractionResult result = LLMExtractionParser.parse(
            JSON.serialize(new Map<String, Object>{ 'email_category' => 'spam_probably' }));
        Assert.areEqual(LLMExtractionResult.CATEGORY_OTHER, result.emailCategory,
            'An out-of-set category is coerced to other — it drives nothing but explainability, so it is never worth a note');
    }

    // ── the legacy map projection (the claim engine's contract) ───────────────

    @isTest
    static void toLegacyMap_alwaysCarriesExactlyTheFourKeys() {
        LLMExtractionResult result = LLMExtractionParser.parse(propertyJson('asset_type', 'Retail'));

        Test.startTest();
        Map<String, String> legacy = result.toLegacyMap(result.properties[0]);
        Test.stopTest();

        Assert.areEqual(4, legacy.size(), 'The claim engine contract is exactly four keys — no more, no fewer');
        Assert.areEqual('100 Main St', legacy.get('property_address'),
            'property_address must be the per-property value, since that is what becomes the claim key');
        Assert.areEqual('', legacy.get('broker_email'),
            'An absent value must be an empty string, never null — that is the documented contract');
    }

    @isTest
    static void toLegacyMap_nullProperty_yieldsBlankAddressNotAnException() {
        LLMExtractionResult result = LLMExtractionParser.parse('{"broker_email":"jane@x.invalid"}');

        Test.startTest();
        Map<String, String> legacy = result.toLegacyMap(null);
        Test.stopTest();

        Assert.areEqual('', legacy.get('property_address'), 'A null property must yield a blank address, not an NPE');
        Assert.areEqual('jane@x.invalid', legacy.get('broker_email'), 'The email-level values still travel');
    }
}
