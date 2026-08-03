/**
 * 🔴 THE PROMPT-QUALITY REGRESSION GUARD (design C-19 / §3.5). The single most valuable test in
 * the LLM field-extraction change, and the only mechanism that catches R1 before a broker does.
 *
 * ═══ THE RISK THIS EXISTS FOR ═══
 * The first-broker-wins ledger arbitrates on exactly TWO extracted values:
 *   • `broker_email`      — repeat detection and submission attribution;
 *   • `property_address`  — normalized into the unique Property_Registry__c.Property_Key__c.
 * Both came from a tight four-key prompt that has now been replaced by one ~20x larger. A subtly
 * differently-worded address produces a DIFFERENT claim key, and the 0.6 Jaccard fuzzy threshold
 * may or may not rescue it. The failure is INVISIBLE: a competing broker quietly wins a property
 * they lost, or a repeat registers as a fresh claim. No exception, no error row, no failing test
 * — unless this class exists.
 *
 * ═══ WHAT THIS CAN AND CANNOT PROVE — READ BEFORE TRUSTING IT ═══
 * A test cannot call the real model: there is no callout in a test context, and a
 * non-deterministic dependency has no place in a regression suite. So this class does NOT prove
 * "gpt-4o-mini returns the same address under both prompts" — nothing in Apex can. What it pins
 * is everything BETWEEN the model and the ledger, which is where an Apex-side regression would
 * actually live:
 *   1. THE PARSER CONTRACT — for each fixture, the LEGACY four-key response and the ENRICHED
 *      response derived from the same email must produce the IDENTICAL `broker_email` and the
 *      IDENTICAL `PropertyMatchingService.normalizeAddress(property_address)`. Not "a similar
 *      address" — the SAME normalized key, because that key IS the claim identity.
 *   2. THE PROMPT TEXT — the four legacy instructions are asserted verbatim, so an accidental
 *      edit to the claim engine's prompt fails here instead of silently re-keying the registry.
 *   3. THE 40,000-CHARACTER INPUT CLIP (C-15) — asserted not to remove the outermost "From:" /
 *      "Sent:" lines the legacy rules read, which is the ONLY reason clipping is safe at all.
 *
 * ═══ WHERE THE FIXTURE BODIES COME FROM ═══
 * `Inbound_Email_Staging__c` rows are never deleted (the object is the pipeline's audit trail),
 * so `usman-dpeg` holds the raw body and headers of every email this pipeline has processed. The
 * bodies below are anonymised transcriptions of those shapes — auto-forward, manual forward with
 * a quoted original, a multi-property blast, a name-only deal, and an address with heavy
 * punctuation. Adding a fixture when a NEW email shape appears in production is the intended
 * maintenance action, and it costs one entry in `fixtures()`.
 *
 * ⚠ 2026-08-03 — A SIXTH FIXTURE WAS ADDED (intake-rules-v2 / U1): an email whose body names a
 * DIFFERENT contact from the one the envelope carries. That is the maintenance action described
 * above, taken for the first time, and it is purely ADDITIVE — not one of the five entries above
 * changed, and no pin was re-pinned. It matters because it is the shape behind the reported
 * defect: the model reads an offer-submission contact out of the prose and returns them as
 * `broker_email`, so the corpus now carries the case where the model's answer and the envelope
 * disagree. What it pins here is still only the PARSER contract — U1's precedence rule is decided
 * from the envelope, which the model never sees and this corpus does not model.
 *
 * @author Salesforce Technical Architect
 * @see LLMExtractionCalloutService.cls (the prompt constants pinned here)
 * @see LLMExtractionParser.cls (the contract under test)
 */
@isTest
private class ExtractionRegressionFixtureTest {

    /**
     * One historical email shape: the raw body, plus what the model returns for it under each
     * contract. `legacyResponse` is the pre-2026-07-31 four-key JSON; `enrichedResponse` is the
     * new shape carrying the SAME two arbitration values.
     */
    private class Fixture {
        private final String label;
        private final String rawBody;
        private final String legacyResponse;
        private final String enrichedResponse;

        private Fixture(String label, String rawBody, String legacyResponse, String enrichedResponse) {
            this.label = label;
            this.rawBody = rawBody;
            this.legacyResponse = legacyResponse;
            this.enrichedResponse = enrichedResponse;
        }
    }

    /** Legacy four-key response JSON. */
    private static String legacy(String brokerEmail, String address) {
        return JSON.serialize(new Map<String, Object>{
            'broker_name' => 'Jane Broker',
            'broker_email' => brokerEmail,
            'property_address' => address,
            'sent_datetime' => '2026-07-01 10:00:00'
        });
    }

    /** Enriched response carrying the same two arbitration values plus the new field set. */
    private static String enriched(String brokerEmail, String address) {
        return JSON.serialize(new Map<String, Object>{
            'email_category' => 'acquisition_deal',
            'is_acquisition_related' => true,
            'confidence' => 0.93,
            'broker_name' => 'Jane Broker',
            'broker_email' => brokerEmail,
            'broker_company' => 'Brokerfirm LLC',
            'sent_datetime' => '2026-07-01 10:00:00',
            'deal_summary' => 'Stabilised asset, strong in-place rents.',
            'properties' => new List<Object>{
                new Map<String, Object>{
                    'property_address' => address,
                    'asset_type' => 'Retail',
                    'guidance_price' => 7100000,
                    'cap_rate' => 6.75
                }
            }
        });
    }

    /** The corpus. Each entry is a real email SHAPE the pipeline has already processed. */
    private static List<Fixture> fixtures() {
        return new List<Fixture>{
            new Fixture(
                'auto-forward, plain address',
                'From: Jane Broker <jane@brokerfirm.example.invalid>\n' +
                'Sent: Monday, July 1, 2026 10:00 AM\n' +
                'To: acquisitions@dpeg.example.invalid\n' +
                'Subject: 1400 Royal Lane\n\n' +
                'Pleased to present 1400 Royal Lane, Dallas TX 75229.',
                legacy('jane@brokerfirm.example.invalid', '1400 Royal Lane, Dallas TX 75229'),
                enriched('jane@brokerfirm.example.invalid', '1400 Royal Lane, Dallas TX 75229')),
            new Fixture(
                'manual forward, quoted original',
                'From: Employee <employee@dpeg.example.invalid>\n' +
                'Sent: Tuesday, July 2, 2026 08:15 AM\n\n' +
                '-----Original Message-----\n' +
                'From: Sam Agent <sam@listingco.example.invalid>\n' +
                'Sent: Monday, July 1, 2026 4:42 PM\n' +
                'Subject: Off-market: 220 Bass Pro Dr\n\n' +
                '220 Bass Pro Dr., Garland, TX is available off-market.',
                legacy('sam@listingco.example.invalid', '220 Bass Pro Dr., Garland, TX'),
                enriched('sam@listingco.example.invalid', '220 Bass Pro Dr., Garland, TX')),
            new Fixture(
                'address with heavy punctuation and a suite number',
                'From: Pat Broker <pat@creco.example.invalid>\n' +
                'Sent: Wednesday, July 3, 2026 09:00 AM\n\n' +
                'See attached for 100 Main St., Suite #4, Houston, TX 77002.',
                legacy('pat@creco.example.invalid', '100 Main St., Suite #4, Houston, TX 77002'),
                enriched('pat@creco.example.invalid', '100 Main St., Suite #4, Houston, TX 77002')),
            new Fixture(
                'blast platform, sender is not the listing broker',
                'From: deals@blastplatform.example.invalid\n' +
                'Sent: Thursday, July 4, 2026 07:30 AM\n\n' +
                'New listing: 3500 Commerce St, Fort Worth TX. Listed by Alex Lister.',
                legacy('deals@blastplatform.example.invalid', '3500 Commerce St, Fort Worth TX'),
                enriched('deals@blastplatform.example.invalid', '3500 Commerce St, Fort Worth TX')),
            new Fixture(
                'name-only deal, no street address',
                'From: Dana Broker <dana@brokerfirm.example.invalid>\n' +
                'Sent: Friday, July 5, 2026 11:00 AM\n\n' +
                'Confidential: the Royal Inn portfolio is coming to market.',
                legacy('dana@brokerfirm.example.invalid', ''),
                enriched('dana@brokerfirm.example.invalid', '')),
            // ── FIXTURE 6, ADDED 2026-08-03 (intake-rules-v2 / U1, design D-5) ──────────────
            //
            // ADDED, NOT RE-PINNED. The header above names this as the corpus's INTENDED
            // maintenance action — "adding a fixture when a NEW email shape appears in production
            // ... costs one entry in fixtures()" — and it is additive by construction: the five
            // entries above are untouched, so every existing assertion sees exactly what it saw
            // before, and nameOnlyFixture_producesNoClaimKeyAndThereforeNoClaim's fixtures()[4]
            // index still resolves to the same fixture.
            //
            // 🔴 THE SHAPE IS THE ONE THE REPORTED DEFECT ARRIVED IN: the body names an
            // OFFER-SUBMISSION CONTACT at a large firm, so the model returns that person as
            // `broker_email` even though somebody else sent the email. Every fixture above happens
            // to name the actual sender, which is exactly why this failure class went
            // unrepresented in the corpus while it was producing Leads for the wrong broker.
            //
            // What it pins here is the PARSER contract only, like every other entry: both response
            // shapes must still yield the identical broker_email and the identical normalized
            // claim key. U1 is deliberately NOT exercised through this corpus — it decides from
            // the ENVELOPE, which the model never sees and a response fixture cannot express, so
            // the model's answer here is the body-named contact under BOTH contracts and it is
            // ExtractAddressQueueable that substitutes the sender afterwards. Keeping that
            // separation is the point: if these two responses ever diverge, the defect is in the
            // parser, not in U1.
            new Fixture(
                'body names a different contact from the sender',
                'Hi team,\n\n' +
                'A contact passed this along — 1750 Preston Rd, Plano TX 75093 is quietly available.\n' +
                'The listing contact is Mark Stern at JLL Capital Markets, ' +
                'mark.stern@jll.example.invalid, 214-555-0100.\n\n' +
                'Thanks,\n' +
                'Usman',
                legacy('mark.stern@jll.example.invalid', '1750 Preston Rd, Plano TX 75093'),
                enriched('mark.stern@jll.example.invalid', '1750 Preston Rd, Plano TX 75093'))
        };
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 1. THE CLAIM-KEY INVARIANT — the assertion the whole change hangs on.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void enrichedContract_producesTheIdenticalClaimKeyAsTheLegacyContract() {
        Test.startTest();
        for (Fixture fixture : fixtures()) {
            LLMExtractionResult legacyResult = LLMExtractionParser.parse(fixture.legacyResponse);
            LLMExtractionResult enrichedResult = LLMExtractionParser.parse(fixture.enrichedResponse);

            Assert.areEqual(legacyResult.brokerEmail, enrichedResult.brokerEmail,
                'CLAIM ENGINE REGRESSION on fixture "' + fixture.label + '": broker_email drives repeat '
                + 'detection and submission attribution. If it drifts, claims are silently re-attributed.');

            String legacyKey = legacyResult.properties.isEmpty()
                ? ''
                : PropertyMatchingService.normalizeAddress(legacyResult.properties[0].propertyAddress);
            String enrichedKey = enrichedResult.properties.isEmpty()
                ? ''
                : PropertyMatchingService.normalizeAddress(enrichedResult.properties[0].propertyAddress);

            Assert.areEqual(legacyKey, enrichedKey,
                'CLAIM ENGINE REGRESSION on fixture "' + fixture.label + '": the NORMALIZED address IS the '
                + 'unique Property_Key__c. Not "a similar address" — the same key, or a competing broker '
                + 'silently wins a property they lost.');
        }
        Test.stopTest();
    }

    @isTest
    static void everyFixtureWithAnAddress_yieldsANonBlankClaimKey() {
        Test.startTest();
        for (Fixture fixture : fixtures()) {
            LLMExtractionResult result = LLMExtractionParser.parse(fixture.enrichedResponse);
            if (result.properties.isEmpty()) {
                continue; // the name-only fixture legitimately has none
            }
            String address = result.properties[0].propertyAddress;
            if (String.isBlank(address)) {
                continue;
            }
            Assert.isTrue(
                String.isNotBlank(PropertyMatchingService.normalizeAddress(address)),
                'Fixture "' + fixture.label + '" must normalize to a usable claim key; a blank key would '
                + 'collide with every other addressless email on the registry unique index');
        }
        Test.stopTest();
    }

    @isTest
    static void nameOnlyFixture_producesNoClaimKeyAndThereforeNoClaim() {
        Fixture nameOnly = fixtures()[4];

        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse(nameOnly.enrichedResponse);
        Test.stopTest();

        String key = result.properties.isEmpty()
            ? ''
            : PropertyMatchingService.normalizeAddress(result.properties[0].propertyAddress);
        Assert.areEqual('', key,
            'A name-only deal must yield NO claim key: claiming on an address nobody read would write a '
            + 'guess into a permanent, unique-keyed ledger. It routes to branch (c) instead.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2. THE PROMPT ITSELF — pinned verbatim.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void legacyExtractionRules_areStillVerbatim() {
        // These four sentences produced the broker_email / property_address values that every
        // EXISTING Property_Registry__c row is keyed on. An edit here silently re-keys the ledger,
        // so the text is pinned rather than trusted to review.
        String rules = LLMExtractionCalloutService.LEGACY_EXTRACTION_RULES;

        Test.startTest();
        Assert.isTrue(rules.startsWith('You are extracting fields from a FORWARDED email.'),
            'The legacy block must still open with the original sentence');
        Assert.isTrue(rules.contains('The OUTERMOST / EARLIEST "From:" line identifies the ORIGINAL BROKER'),
            'The broker-identity rule is a claim-engine input and must not be paraphrased');
        Assert.isTrue(rules.contains('IGNORE it; never use it for the '),
            'The "ignore the To: line" rule is what stops claims being attributed to the DPEG forwarder');
        Assert.isTrue(rules.contains('property_address is any property address found anywhere in the body.'),
            'The address rule defines the claim key and must not be paraphrased');
        Assert.isTrue(rules.contains('sent_datetime is the OUTERMOST / EARLIEST "Sent:" line'),
            'The send-time rule must not be paraphrased');
        Test.stopTest();
    }

    @isTest
    static void rollbackLever_recomposesTheOriginalFourKeyPrompt() {
        // The documented one-line rollback is
        //   EXTRACTION_INSTRUCTION = LEGACY_EXTRACTION_RULES + LEGACY_RESPONSE_FORMAT;
        // This asserts the second half is still intact, so that lever is real rather than a claim
        // in a comment.
        // `promptRollback`, not `rollback`: ROLLBACK is a reserved word in Apex and will not
        // compile as an identifier (same trap this repo hit with `bulk`).
        String promptRollback = LLMExtractionCalloutService.LEGACY_EXTRACTION_RULES
            + LLMExtractionCalloutService.LEGACY_RESPONSE_FORMAT;

        Test.startTest();
        Assert.isTrue(promptRollback.endsWith('{"broker_name": "", "broker_email": "", "property_address": "", "sent_datetime": ""}.'),
            'The rollback prompt must still end with the exact original four-key response contract');
        Assert.isTrue(promptRollback.contains('Respond ONLY with a single JSON object of exactly these keys'),
            'The retired response-format sentence must survive verbatim, or the rollback lever is fiction');
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 3. THE 40,000-CHARACTER INPUT CLIP (C-15).
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void inputClip_neverRemovesTheOutermostFromAndSentLines() {
        // C-15 clips the body sent to the model. That touches the LEGACY four values, so it is
        // only safe because a forward puts its outermost "From:" / "Sent:" lines at the TOP —
        // which is exactly what this asserts, fixture by fixture, with a body padded far beyond
        // the limit by quoted history.
        String quotedHistory = ''.rightPad(60000, 'q');

        Test.startTest();
        for (Fixture fixture : fixtures()) {
            String padded = fixture.rawBody + '\n\n' + quotedHistory;
            String clipped = InboundEmailFieldUtil.clip(padded, 40000);

            Assert.areEqual(40000, clipped.length(),
                'Fixture "' + fixture.label + '": the body should be clipped to the configured ceiling');
            Assert.isTrue(clipped.startsWith(fixture.rawBody),
                'Fixture "' + fixture.label + '": clipping must preserve the head of the email verbatim — '
                + 'the outermost From:/Sent: lines the legacy rules read live there, and losing them would '
                + 'silently change who a claim is attributed to');
        }
        Test.stopTest();
    }

    @isTest
    static void inputClip_leavesAShortBodyUntouched() {
        Fixture fixture = fixtures()[0];

        Test.startTest();
        String clipped = InboundEmailFieldUtil.clip(fixture.rawBody, 40000);
        Test.stopTest();

        Assert.areEqual(fixture.rawBody, clipped,
            'A body inside the ceiling must be passed through byte-for-byte — the overwhelmingly common case');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 4. BACKWARD COMPATIBILITY (design §7 item 10).
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void legacyResponseShape_stillRoutesThroughTheParserUnchanged() {
        Fixture fixture = fixtures()[0];

        Test.startTest();
        LLMExtractionResult result = LLMExtractionParser.parse(fixture.legacyResponse);
        Test.stopTest();

        Assert.isTrue(result.usedLegacyShape,
            'A four-key response must be recognised as the legacy shape');
        Assert.areEqual(1, result.properties.size(),
            'The legacy shape must synthesize exactly one property, or the rollback lever breaks the claim path');
        Assert.areEqual('1400 Royal Lane, Dallas TX 75229', result.properties[0].propertyAddress,
            'The legacy address must travel verbatim into the synthesized property');
        Assert.areEqual(LLMExtractionParser.BAND_LOW, result.confidenceBand,
            'A legacy response carries no confidence, so it bands LOW and lands in the Review Queue — '
            + 'visible, and never gated away');
    }
}
