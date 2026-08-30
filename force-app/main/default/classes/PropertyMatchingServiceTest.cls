/**
 * Test class for PropertyMatchingService: the pure normalizeAddress / calculateSimilarity
 * functions plus the selector-backed findMatchingRegistry / findOrphanedRegistry decisions.
 *
 * @author Unit Testing Agent
 */
@isTest
private class PropertyMatchingServiceTest {

    // ── normalizeAddress ─────────────────────────────────────────────────────

    @isTest
    static void normalizeAddress_nullOrBlank_returnsEmptyString() {
        Assert.areEqual('', PropertyMatchingService.normalizeAddress(null), 'Null input should normalize to empty string');
        Assert.areEqual('', PropertyMatchingService.normalizeAddress('   '), 'Blank input should normalize to empty string');
    }

    @isTest
    static void normalizeAddress_punctuationBecomesSpace() {
        String result = PropertyMatchingService.normalizeAddress('123 Main St., Suite #4');
        Assert.areEqual('123 main st suite 4', result, 'Punctuation should be replaced with spaces and the result lowercased');
    }

    @isTest
    static void normalizeAddress_collapsesWhitespaceAndTrims() {
        String result = PropertyMatchingService.normalizeAddress('   100    Main   St   ');
        Assert.areEqual('100 main st', result, 'Runs of whitespace should collapse to one space and the ends should be trimmed');
    }

    // ── calculateSimilarity ──────────────────────────────────────────────────

    @isTest
    static void calculateSimilarity_identicalAddresses_returnsOne() {
        Decimal score = PropertyMatchingService.calculateSimilarity('100 main st', '100 main st');
        Assert.areEqual(1, score, 'Identical token sets should score 1.0');
    }

    @isTest
    static void calculateSimilarity_disjointAddresses_returnsZero() {
        Decimal score = PropertyMatchingService.calculateSimilarity('100 main st', '999 elsewhere ave');
        Assert.areEqual(0, score, 'Completely disjoint token sets should score 0');
    }

    @isTest
    static void calculateSimilarity_blankInput_returnsZero() {
        Assert.areEqual(0, PropertyMatchingService.calculateSimilarity('', '100 main st'), 'Blank first argument should score 0');
        Assert.areEqual(0, PropertyMatchingService.calculateSimilarity('100 main st', null), 'Null second argument should score 0');
        Assert.areEqual(0, PropertyMatchingService.calculateSimilarity(null, null), 'Both blank should score 0');
    }

    @isTest
    static void calculateSimilarity_partialOverlap_returnsExpectedRatio() {
        // A={100,main,st} (3), B={100,main} (2); intersection={100,main}=2, union={100,main,st}=3 -> 2/3 ~= 0.667
        Decimal score = PropertyMatchingService.calculateSimilarity('100 main st', '100 main');
        Assert.isTrue(score >= 0.66 && score <= 0.67,
            'Partial token overlap (2 of 3 union tokens shared) should score approximately 2/3 (~0.667); got ' + score);
    }

    @isTest
    static void calculateSimilarity_orderAndDuplicateInsensitive() {
        Decimal score = PropertyMatchingService.calculateSimilarity('100 main st', 'main st 100');
        Assert.areEqual(1, score, 'Token order should not affect the score (tokens compared as sets)');
    }

    // ── deriveClusterKey (W4) ─────────────────────────────────────────────────
    // Coarse lock-partition bucket key = street number + first alphabetic street
    // token; deliberately coarser than the exact Property_Key__c so fuzzy variants
    // of the same address co-locate under one FOR UPDATE lock (see the class-header
    // race note). All inputs here are already-normalized strings (from
    // normalizeAddress), matching deriveClusterKey's own documented contract.

    @isTest
    static void deriveClusterKey_blankInput_returnsEmptyString() {
        Assert.areEqual('', PropertyMatchingService.deriveClusterKey(null), 'Null input should derive to an empty cluster key');
        Assert.areEqual('', PropertyMatchingService.deriveClusterKey('   '), 'Blank (whitespace) input should derive to an empty cluster key');
    }

    @isTest
    static void deriveClusterKey_numberPlusStreetToken_derivesCoarseBucket() {
        String normalized = PropertyMatchingService.normalizeAddress('123 Main Street Unit 4');
        String key = PropertyMatchingService.deriveClusterKey(normalized);
        Assert.areEqual('123 main', key,
            'The bucket should be the street number plus the FIRST alphabetic street-name token, ignoring the unit suffix');
    }

    @isTest
    static void deriveClusterKey_fuzzyVariants_mapToTheSameClusterKey() {
        String keyFullWord = PropertyMatchingService.deriveClusterKey(PropertyMatchingService.normalizeAddress('123 Main Street'));
        String keyAbbreviated = PropertyMatchingService.deriveClusterKey(PropertyMatchingService.normalizeAddress('123 Main St'));
        String keyWithUnit = PropertyMatchingService.deriveClusterKey(PropertyMatchingService.normalizeAddress('123 Main Street Unit 4'));

        Assert.areEqual('123 main', keyFullWord, 'The full street-name variant should derive the documented coarse bucket');
        Assert.areEqual(keyFullWord, keyAbbreviated,
            'An abbreviated ("St") variant must derive the SAME cluster key as the full word ("Street") — this is what lets one lock serialise both');
        Assert.areEqual(keyFullWord, keyWithUnit,
            'A unit-suffixed variant must derive the SAME cluster key as the bare street address');
    }

    @isTest
    static void deriveClusterKey_numberNotFirstToken_stillDerivesNumberPlusToken() {
        String normalized = PropertyMatchingService.normalizeAddress('Main Street 123');
        String key = PropertyMatchingService.deriveClusterKey(normalized);
        Assert.areEqual('123 main', key,
            'The number need not be the first token in the string — the bucket is still <number> <firstAlphaToken>');
    }

    @isTest
    static void deriveClusterKey_noNumericToken_fallsBackToFullNormalizedString() {
        String normalized = PropertyMatchingService.normalizeAddress('The Tower Building');
        String key = PropertyMatchingService.deriveClusterKey(normalized);
        Assert.areEqual(normalized, key,
            'With no numeric token derivable, the documented fallback is the full normalized string, unchanged');
    }

    // ── findMatchingRegistry ─────────────────────────────────────────────────

    private static Id createLead() {
        return TestDataFactory.createLead(true).Id;
    }

    @isTest
    static void findMatchingRegistry_blankInput_returnsNull() {
        Assert.isNull(PropertyMatchingService.findMatchingRegistry(null), 'Blank normalized address should return null');
        Assert.isNull(PropertyMatchingService.findMatchingRegistry('   '), 'Blank (whitespace) normalized address should return null');
    }

    @isTest
    static void findMatchingRegistry_exactKeyMatch_returnsWinner() {
        Id winnerId = createLead();
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('100 main st', winnerId, true);

        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findMatchingRegistry('100 main st');
        Test.stopTest();

        Assert.isNotNull(result, 'An exact Property_Key__c match should be found');
        Assert.areEqual(reg.Id, result.Id, 'The exact-match row should be returned without falling through to fuzzy matching');
    }

    @isTest
    static void findMatchingRegistry_fuzzyMatchAboveThreshold_returnsBestCandidate() {
        Id winnerId = createLead();
        // Registered key tokens {100,main,st,houston} (4); query tokens {100,main,st} (3);
        // intersection {100,main,st}=3, union=4 -> 0.75, above the 0.6 threshold.
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('100 main st houston', winnerId, true);

        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findMatchingRegistry('100 main st');
        Test.stopTest();

        Assert.isNotNull(result, 'A fuzzy match at or above the 0.6 similarity threshold should be found');
        Assert.areEqual(reg.Id, result.Id, 'The fuzzy candidate should be the recently-registered similar address');
    }

    @isTest
    static void findMatchingRegistry_belowThreshold_returnsNull() {
        Id winnerId = createLead();
        // tokens {100,main,st} vs {999,elsewhere,ave} -> disjoint, 0.0 similarity.
        TestDataFactory.createPropertyRegistry('999 elsewhere ave', winnerId, true);

        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findMatchingRegistry('100 main st');
        Test.stopTest();

        Assert.isNull(result, 'No candidate clears the similarity threshold, so no match should be returned');
    }

    @isTest
    static void findMatchingRegistry_orphanRow_isIgnoredByFuzzyMatch() {
        Id winnerId = createLead();
        // Exact-key path would find this if it still had a winner, so null the winner to force
        // the fuzzy path, and confirm the null-winner row still is not treated as a candidate.
        Property_Registry__c orphan = TestDataFactory.createPropertyRegistry('100 main st', winnerId, true);
        orphan.Winning_Lead__c = null;
        update orphan;

        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findMatchingRegistry('100 main st');
        Test.stopTest();

        Assert.isNull(result, 'A registry row with a null winner (orphan) must never be returned as a live match');
    }

    // ── findOrphanedRegistry ─────────────────────────────────────────────────

    @isTest
    static void findOrphanedRegistry_blankInput_returnsNull() {
        Assert.isNull(PropertyMatchingService.findOrphanedRegistry(null), 'Blank normalized address should return null');
        Assert.isNull(PropertyMatchingService.findOrphanedRegistry(''), 'Empty normalized address should return null');
    }

    @isTest
    static void findOrphanedRegistry_orphanExists_returnsIt() {
        Id winnerId = createLead();
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('500 orphan ave', winnerId, true);
        reg.Winning_Lead__c = null;
        update reg;

        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findOrphanedRegistry('500 orphan ave');
        Test.stopTest();

        Assert.isNotNull(result, 'The orphaned row should be found');
        Assert.areEqual(reg.Id, result.Id, 'Returned row should be the orphaned registry');
    }

    @isTest
    static void findOrphanedRegistry_keyHasLiveWinner_returnsNull() {
        Id winnerId = createLead();
        TestDataFactory.createPropertyRegistry('600 claimed ave', winnerId, true);

        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findOrphanedRegistry('600 claimed ave');
        Test.stopTest();

        Assert.isNull(result, 'A key with a live winner is not an orphan');
    }

    @isTest
    static void findOrphanedRegistry_unregisteredKey_returnsNull() {
        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findOrphanedRegistry('700 never registered rd');
        Test.stopTest();

        Assert.isNull(result, 'An unregistered key has no orphan row');
    }

    // ── findBrokerSubmission (REPEAT DETECTION) ──────────────────────────────
    //
    // Added 2026-07-31. This method had NO direct coverage, and the same change that
    // needed these tests also changed its semantics: it used to skip candidates whose
    // Source_Lead__c was null, and it no longer does, because a competing broker gets
    // no Lead and every competing submission now legitimately carries a null source.
    // Skipping them would make a competing broker's follow-up invisible to repeat
    // detection, so each of their re-sends would be re-logged as a brand-new competing
    // claim forever. findBrokerSubmission_nullSourceLead_isReturnedForACompetingBroker
    // is the test that goes red if the filter is ever restored — in this method OR in
    // CompetingBrokerSubmissionSelector, since either one alone reintroduces the bug
    // (see CompetingBrokerSubmissionSelectorTest for the query-side twin).

    private static final String BROKER = 'repeat.detect@example.invalid';

    /**
     * A submission with full control over the four fields repeat detection reads. Built
     * (not inserted) so a test can insert its whole fixture in ONE DML.
     */
    private static Competing_Broker_Submission__c submission(
            Id winningLeadId, Id sourceLeadId, String brokerEmail,
            String rawAddress, Datetime submittedOn) {
        Competing_Broker_Submission__c sub =
            TestDataFactory.createCompetingBrokerSubmission(winningLeadId, false);
        sub.Source_Lead__c = sourceLeadId;
        sub.Is_Winning_Submission__c = (sourceLeadId != null && sourceLeadId == winningLeadId);
        sub.Broker_Email__c = brokerEmail;
        sub.Property_Address_Raw__c = rawAddress;
        sub.Submitted_DateTime__c = submittedOn;
        return sub;
    }

    @isTest
    static void findBrokerSubmission_blankBrokerEmail_returnsNull() {
        Assert.isNull(PropertyMatchingService.findBrokerSubmission(null, '100 main st'),
            'A null broker email cannot identify a repeat');
        Assert.isNull(PropertyMatchingService.findBrokerSubmission('   ', '100 main st'),
            'A blank broker email cannot identify a repeat');
    }

    @isTest
    static void findBrokerSubmission_blankAddress_returnsNull() {
        Assert.isNull(PropertyMatchingService.findBrokerSubmission(BROKER, null),
            'A null property address cannot identify a repeat');
        Assert.isNull(PropertyMatchingService.findBrokerSubmission(BROKER, ''),
            'An empty property address cannot identify a repeat');
    }

    @isTest
    static void findBrokerSubmission_exactAddressMatch_returnsThatSubmission() {
        Id leadId = createLead();
        Competing_Broker_Submission__c prior =
            submission(leadId, leadId, BROKER, '100 Main St.', Datetime.now().addDays(-2));
        insert prior;

        Test.startTest();
        Competing_Broker_Submission__c result =
            PropertyMatchingService.findBrokerSubmission(BROKER, '100 main st');
        Test.stopTest();

        Assert.isNotNull(result, 'The broker\'s earlier submission for the same property should be found');
        Assert.areEqual(prior.Id, result.Id,
            'Matching is done in memory against the NORMALIZED raw address, so punctuation and casing must not defeat it');
        Assert.areEqual(leadId, result.Source_Lead__c,
            'A winner\'s own submission carries Source_Lead__c — the caller routes the repeat to that Lead');
    }

    @isTest
    static void findBrokerSubmission_nullSourceLead_isReturnedForACompetingBroker() {
        Id winnerLeadId = createLead();
        // The shape branch (d) writes for a competing broker: rolled up under the winner,
        // with NO Lead of their own. Before 2026-07-31 this row was skipped outright.
        Competing_Broker_Submission__c competing =
            submission(winnerLeadId, null, BROKER, '200 Competing Blvd', Datetime.now().addDays(-2));
        insert competing;

        Test.startTest();
        Competing_Broker_Submission__c result =
            PropertyMatchingService.findBrokerSubmission(BROKER, '200 competing blvd');
        Test.stopTest();

        Assert.isNotNull(result,
            'A submission with a null Source_Lead__c must MATCH — it is the normal shape of a competing broker\'s claim, and skipping it would re-log every follow-up as a fresh competing claim forever');
        Assert.areEqual(competing.Id, result.Id, 'The competing broker\'s own earlier row should be the match');
        Assert.isNull(result.Source_Lead__c, 'The matched row genuinely has no source Lead');
        Assert.areEqual(winnerLeadId, result.Winning_Lead__c,
            'Winning_Lead__c must be populated so the caller can route the repeat onto the winning Lead instead');
    }

    @isTest
    static void findBrokerSubmission_fuzzyMatchAboveThreshold_returnsBestCandidate() {
        Id leadId = createLead();
        // Candidate tokens {200,fuzzy,st,houston} (4); query tokens {200,fuzzy,st} (3);
        // intersection 3, union 4 -> 0.75, above the 0.6 threshold and NOT an exact match.
        Competing_Broker_Submission__c near =
            submission(leadId, leadId, BROKER, '200 Fuzzy St Houston', Datetime.now().addDays(-2));
        insert near;

        Test.startTest();
        Competing_Broker_Submission__c result =
            PropertyMatchingService.findBrokerSubmission(BROKER, '200 fuzzy st');
        Test.stopTest();

        Assert.isNotNull(result,
            'Repeat detection reuses the module\'s Jaccard tolerance, so a differently-worded version of the same address still counts as a repeat');
        Assert.areEqual(near.Id, result.Id, 'The above-threshold candidate should be returned');
    }

    @isTest
    static void findBrokerSubmission_belowThreshold_returnsNull() {
        Id leadId = createLead();
        insert submission(leadId, leadId, BROKER, '999 Elsewhere Ave', Datetime.now().addDays(-2));

        Test.startTest();
        Competing_Broker_Submission__c result =
            PropertyMatchingService.findBrokerSubmission(BROKER, '100 main st');
        Test.stopTest();

        Assert.isNull(result,
            'A different property by the same broker is a NEW submission, not a repeat — it must not be matched');
    }

    @isTest
    static void findBrokerSubmission_multipleMatches_returnsTheOldest() {
        Id originalLeadId = createLead();
        Id laterLeadId = createLead();
        // Same broker, same property, twice. The selector returns oldest-first and the exact
        // match short-circuits on the first hit, so the ORIGINAL submission wins — that is
        // what makes the caller route the repeat to the Lead the FIRST email produced rather
        // than to a later follow-up's.
        insert new List<Competing_Broker_Submission__c>{
            submission(originalLeadId, originalLeadId, BROKER, '300 Oldest Way', Datetime.now().addDays(-10)),
            submission(originalLeadId, laterLeadId, BROKER, '300 Oldest Way', Datetime.now().addDays(-1))
        };

        Test.startTest();
        Competing_Broker_Submission__c result =
            PropertyMatchingService.findBrokerSubmission(BROKER, '300 oldest way');
        Test.stopTest();

        Assert.isNotNull(result, 'One of the two same-property submissions should match');
        Assert.areEqual(originalLeadId, result.Source_Lead__c,
            'Oldest-first ordering must return the ORIGINAL submission, not the later repeat');
    }

    @isTest
    static void findBrokerSubmission_differentBroker_returnsNull() {
        Id leadId = createLead();
        insert submission(leadId, leadId, 'someone.else@example.invalid', '400 Other Broker Rd',
            Datetime.now().addDays(-2));

        Test.startTest();
        Competing_Broker_Submission__c result =
            PropertyMatchingService.findBrokerSubmission(BROKER, '400 other broker rd');
        Test.stopTest();

        Assert.isNull(result,
            'A DIFFERENT broker submitting the same property is a competing claim, not a repeat — the two must never be confused');
    }

    @isTest
    static void findBrokerSubmission_outsideLookbackWindow_returnsNull() {
        Id leadId = createLead();
        insert submission(leadId, leadId, BROKER, '500 Stale Ave',
            Datetime.now().addDays(-(PropertyMatchingService.LOOKBACK_DAYS + 10)));

        Test.startTest();
        Competing_Broker_Submission__c result =
            PropertyMatchingService.findBrokerSubmission(BROKER, '500 stale ave');
        Test.stopTest();

        Assert.isNull(result,
            'A submission older than LOOKBACK_DAYS is outside the recency window and must not make a new email a repeat');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // PROTECTION WINDOW (2026-08-17) — findMatchingRegistry's exact leg + findExpiredRegistry
    // ══════════════════════════════════════════════════════════════════════════

    /** Backdate a registration so its claim sits `days` in the past. */
    private static Property_Registry__c backdate(Property_Registry__c registry, Integer days) {
        registry.Registered_DateTime__c = Datetime.now().addDays(-days);
        update registry;
        return registry;
    }

    /** Convert a Lead so its registration reads `IsConverted = true`. */
    private static void convertLead(Id leadId) {
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(leadId);
        lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
        Assert.isTrue(Database.convertLead(lc).isSuccess(), 'The fixture Lead must convert');
    }

    /**
     * 🔴 THE INVARIANT PIN. PROTECTION_WINDOW_DAYS must never exceed LOOKBACK_DAYS.
     *
     * If it did, a claim in the gap would be PROTECTED on the exact-key leg (still inside
     * the protection window) and INVISIBLE on the fuzzy leg (already outside the lookback)
     * — which is exactly the defect the protection window was added to remove, relocated
     * rather than fixed: a re-worded resubmission would win a property that an
     * identically-worded one loses.
     *
     * ⚠ RE-POINTED AT THE ACCESSORS 2026-08-30 (WS5). It used to say the two constants "are
     * held together by this assertion and by nothing else". That is no longer true, and the
     * change is not cosmetic: both values now come from Setup
     * (Broker_Protection_Config__mdt.Default), where NO Apex test can see them, so this
     * assertion alone stopped being enforcement the moment they became configurable. What
     * actually holds them together now is the runtime clamp in
     * BrokerProtectionConfig.effectiveLookbackDays() — proved by
     * effectiveLookback_clampsUpToTheWindow_whenAnAdminMisconfiguresIt below.
     *
     * This test is kept, and asserts the SAME relationship through the accessors, because it
     * still catches the one case the clamp cannot: a future edit that repoints
     * PropertyMatchingService.LOOKBACK_DAYS at the RAW configuredLookbackDays() instead of
     * the clamped accessor. That would silently reopen the gap, and this goes red.
     */
    @isTest
    static void protectionWindow_neverExceedsTheFuzzyLookback() {
        Assert.isTrue(
            BrokerProtectionConfig.effectiveLookbackDays() >= BrokerProtectionConfig.protectionWindowDays(),
            'effectiveLookbackDays (' + BrokerProtectionConfig.effectiveLookbackDays()
            + ') must be >= protectionWindowDays (' + BrokerProtectionConfig.protectionWindowDays()
            + '); otherwise a claim in the gap is protected on the exact path and invisible on the '
            + 'fuzzy path, reintroducing the exact/fuzzy asymmetry');

        Assert.isTrue(
            PropertyMatchingService.LOOKBACK_DAYS >= PropertyMatchingService.PROTECTION_WINDOW_DAYS,
            'The constants this service actually reads must satisfy the invariant too. '
            + 'LOOKBACK_DAYS (' + PropertyMatchingService.LOOKBACK_DAYS + ') must be >= '
            + 'PROTECTION_WINDOW_DAYS (' + PropertyMatchingService.PROTECTION_WINDOW_DAYS
            + '). If this fails while the accessor assertion above passes, LOOKBACK_DAYS has '
            + 'been repointed at the RAW configured value instead of the clamped one.');
    }

    /**
     * 🔴 THE CLAMP. An admin CAN type a violating pair into Setup; the engine must not act
     * on it.
     *
     * This is the test that replaces what the invariant pin above used to provide. Before
     * WS5 a violation could only arrive through a deploy, so a compile-time pin was real
     * enforcement. Now it arrives through a Setup edit that no test can observe, so
     * enforcement had to move into the runtime accessor.
     *
     * ⚠ WHY THE ROW IS INJECTED RATHER THAN INSERTED. A test cannot DML a __mdt row —
     * custom metadata records are not insertable from Apex. BrokerProtectionConfig
     * .overrideForTest is the seam that exists for exactly this, and it is the only way to
     * exercise a misconfiguration that by definition cannot be committed from a test.
     *
     * ⚠ NOT A BULK TEST, AND THAT IS DELIBERATE (.claude/rules/bulk-test-rule.md). There is
     * no collection, no trigger and no DML here — this asserts a pure arithmetic decision on
     * two scalars. 251 rows would exercise no additional code path and prove nothing.
     */
    @isTest
    static void effectiveLookback_clampsUpToTheWindow_whenAnAdminMisconfiguresIt() {
        // Given — a record an admin could really save: lookback SHORTER than the window.
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Protection_Window_Days__c = 90,
            Lookback_Days__c = 30));

        // When
        Test.startTest();
        Integer effective = BrokerProtectionConfig.effectiveLookbackDays();
        Integer configured = BrokerProtectionConfig.configuredLookbackDays();
        Test.stopTest();

        // Then
        Assert.areEqual(30, configured,
            'configuredLookbackDays must report what the admin actually typed, unclamped — it is '
            + 'the only way to tell a clamped org from a correctly-configured one');
        Assert.areEqual(90, effective,
            'The engine must use the WINDOW (90), not the shorter configured lookback (30). '
            + 'Using 30 would leave claims aged 31-90 days protected on the exact path and '
            + 'invisible on the fuzzy path — a re-worded resubmission would win a property that '
            + 'an identically-worded one loses.');
        Assert.isTrue(effective >= BrokerProtectionConfig.protectionWindowDays(),
            'The clamp must restore the invariant, not merely soften the violation');
    }

    /**
     * The clamp must NOT fire when the configuration is legitimate. LOOKBACK_DAYS is allowed
     * to exceed the window — the two answer different questions and may diverge upward on
     * the lookback side (see PropertyMatchingService's header). A clamp that flattened them
     * to equal would silently narrow the fuzzy candidate set.
     */
    @isTest
    static void effectiveLookback_leavesALegitimatelyLongerLookbackAlone() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Protection_Window_Days__c = 90,
            Lookback_Days__c = 180));

        Test.startTest();
        Integer effective = BrokerProtectionConfig.effectiveLookbackDays();
        Test.stopTest();

        Assert.areEqual(180, effective,
            'A lookback LONGER than the window is valid and must pass through unchanged; '
            + 'clamping it down to 90 would silently shrink the fuzzy candidate window');
    }

    /**
     * 🔴 THE FRESH-ORG CASE. The Default record is created by
     * scripts/load-broker-protection-config.apex, NOT by a deploy, so "record absent" is
     * reachable in every newly built org — and measured on usman-dpeg 2026-08-30,
     * getInstance on a missing record returns NULL, not an empty row. A null reaching the
     * arbitration path would take the claim engine down, so every accessor must default.
     *
     * The specific values asserted are the pre-WS5 Apex literals: an org with no config
     * record must behave EXACTLY as it did before this workstream.
     */
    @isTest
    static void accessors_returnThePreWS5Literals_whenTheConfigRecordIsAbsent() {
        BrokerProtectionConfig.overrideForTest(null);

        Test.startTest();
        Integer window = BrokerProtectionConfig.protectionWindowDays();
        Integer lookback = BrokerProtectionConfig.effectiveLookbackDays();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Decimal medium = BrokerProtectionConfig.confidenceMediumMin();
        String modelName = BrokerProtectionConfig.model();
        Decimal temperature = BrokerProtectionConfig.temperature();
        Integer maxTokens = BrokerProtectionConfig.maxTokens();
        String promptOverride = BrokerProtectionConfig.extractionPromptOverride();
        Test.stopTest();

        Assert.areEqual(90, window, 'Was PropertyMatchingService.PROTECTION_WINDOW_DAYS');
        Assert.areEqual(90, lookback, 'Was PropertyMatchingService.LOOKBACK_DAYS');
        Assert.areEqual(0.85, high, 'Was LLMExtractionParser.CONFIDENCE_HIGH_MIN');
        Assert.areEqual(0.60, medium, 'Was LLMExtractionParser.CONFIDENCE_MEDIUM_MIN');
        Assert.areEqual('gpt-4o-mini', modelName, 'Was LLMExtractionCalloutService.MODEL');
        Assert.areEqual(0, temperature, 'Was the inline literal 0 in buildRequestBody');
        Assert.areEqual(4096, maxTokens, 'Was LLMExtractionCalloutService.MAX_TOKENS');
        Assert.isNull(promptOverride,
            'extractionPromptOverride is the ONE accessor allowed to return null — null is its '
            + 'documented "no override" signal, and LLMExtractionCalloutService.resolvePrompt is '
            + 'the enforcement point that turns it back into the shipped prompt');
    }

    /**
     * A NEGATIVE day count must not be honoured. It is not merely odd — it INVERTS the
     * value: Datetime.now().addDays(-(-30)) puts the protection cutoff 30 days in the
     * FUTURE, which expires every live claim in the org at once. That is the precise
     * catastrophe GATE A's risk statement describes, reachable by one Setup typo.
     */
    @isTest
    static void negativeWindow_fallsBackToTheDefault_ratherThanInvertingTheCutoff() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Protection_Window_Days__c = -30,
            Lookback_Days__c = 90));

        Test.startTest();
        Integer window = BrokerProtectionConfig.protectionWindowDays();
        Test.stopTest();

        Assert.areEqual(90, window,
            'A negative window must fall back to the shipped default. Honouring -30 would put '
            + 'the protection cutoff in the FUTURE and release every live claim at once.');
    }


    @isTest
    static void findMatchingRegistry_exactKeyInsideTheWindow_stillReportsTheWinner() {
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('900 fresh claim st', createLead(), true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS - 1);

        Test.startTest();
        Property_Registry__c result = PropertyMatchingService.findMatchingRegistry('900 fresh claim st');
        Test.stopTest();

        Assert.isNotNull(result, 'A claim one day inside the protection window still holds the property');
        Assert.areEqual(reg.Id, result.Id, 'The incumbent registration should be returned');
    }

    @isTest
    static void findMatchingRegistry_exactKeyOutsideTheWindow_reportsNoWinner() {
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('901 stale claim st', createLead(), true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 1);

        Test.startTest();
        Property_Registry__c matched = PropertyMatchingService.findMatchingRegistry('901 stale claim st');
        Property_Registry__c expired = PropertyMatchingService.findExpiredRegistry('901 stale claim st');
        Test.stopTest();

        Assert.isNull(matched,
            'An expired claim must report NO winner — that is what releases the property to the next broker');
        Assert.isNotNull(expired,
            'The same row must be reachable for ADOPTION; without it the unique key becomes unclaimable by anyone');
        Assert.areEqual(reg.Id, expired.Id, 'findExpiredRegistry should return the very row findMatchingRegistry declined');
    }

    @isTest
    static void findMatchingRegistry_expiredClaimWithConvertedWinner_stillReportsTheWinner() {
        Id winnerId = createLead();
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('902 live deal st', winnerId, true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 400);
        convertLead(winnerId);

        Test.startTest();
        Property_Registry__c matched = PropertyMatchingService.findMatchingRegistry('902 live deal st');
        Property_Registry__c expired = PropertyMatchingService.findExpiredRegistry('902 live deal st');
        Test.stopTest();

        Assert.isNotNull(matched,
            'A converted winner is a live deal DPEG is transacting — its claim must not expire');
        Assert.areEqual(reg.Id, matched.Id, 'The converted winner keeps the property');
        Assert.isNull(expired,
            'A converted winner must never be adoptable — that filter is what keeps the adoption update off a converted-Lead lookup');
    }

    /**
     * 🔴 THE P2 FALSIFIER, AT THE DECISION LAYER. One property, TWO wordings, one clock.
     *
     * This is the highest-value test of the protection window, because the defect it pins
     * was never "claims do not expire" — it was that the SAME property produced OPPOSITE
     * answers depending only on how the second broker spelled the address: an identical
     * wording hit the un-windowed exact read and kept the incumbent for ever, while a
     * different wording fell through to the 90-day fuzzy scan and released it.
     *
     * Both wordings must now agree at BOTH ends of the boundary. A future change that
     * re-points the exact leg at `selectByPropertyKeyWithWinner` compiles, deploys and
     * passes every other test in this class — and turns this one red.
     */
    @isTest
    static void exactAndFuzzyWordings_reachTheSameVerdictOnBothSidesOfTheWindow() {
        // 0.8 Jaccard: {100,main,street,houston,tx} vs {100,main,street,houston}.
        String registered = '100 main street houston tx';
        String reworded = '100 main street houston';

        Property_Registry__c inside =
            TestDataFactory.createPropertyRegistry(registered, createLead(), true);
        backdate(inside, PropertyMatchingService.PROTECTION_WINDOW_DAYS - 1);

        Test.startTest();
        Property_Registry__c exactInside = PropertyMatchingService.findMatchingRegistry(registered);
        Property_Registry__c fuzzyInside = PropertyMatchingService.findMatchingRegistry(reworded);

        backdate(inside, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 1);
        Property_Registry__c exactOutside = PropertyMatchingService.findMatchingRegistry(registered);
        Property_Registry__c fuzzyOutside = PropertyMatchingService.findMatchingRegistry(reworded);
        Test.stopTest();

        Assert.isNotNull(exactInside, 'Inside the window, an identically-worded resubmission must find the incumbent');
        Assert.isNotNull(fuzzyInside, 'Inside the window, a re-worded resubmission must find the SAME incumbent');
        Assert.areEqual(exactInside.Id, fuzzyInside.Id,
            'Both wordings must resolve to one registration — two rows for one building is the second half of the defect');

        Assert.isNull(exactOutside, 'Outside the window, an identically-worded resubmission must find no winner');
        Assert.isNull(fuzzyOutside,
            'Outside the window, a re-worded resubmission must ALSO find no winner — the two paths must never disagree');
    }

    @isTest
    static void findExpiredRegistry_blankInput_returnsNull() {
        Assert.isNull(PropertyMatchingService.findExpiredRegistry(null), 'Blank input should return null');
        Assert.isNull(PropertyMatchingService.findExpiredRegistry('   '), 'Blank (whitespace) input should return null');
    }

    @isTest
    static void findExpiredRegistry_orphanRow_returnsNull() {
        Property_Registry__c orphan =
            TestDataFactory.createPropertyRegistry('903 orphan not expired st', createLead(), true);
        backdate(orphan, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 5);
        orphan.Winning_Lead__c = null;
        update orphan;

        Test.startTest();
        Property_Registry__c expired = PropertyMatchingService.findExpiredRegistry('903 orphan not expired st');
        Property_Registry__c orphaned = PropertyMatchingService.findOrphanedRegistry('903 orphan not expired st');
        Test.stopTest();

        // The two adoption legs must stay disjoint: an orphan has NO winner, an expired row
        // has an unconverted one. Overlap would mean two legs racing to adopt the same row.
        Assert.isNull(expired, 'A winner-less row is an orphan, not an expired claim');
        Assert.isNotNull(orphaned, 'It must still be reachable through the ORPHAN leg, which has owned this case since the module shipped');
    }
}
