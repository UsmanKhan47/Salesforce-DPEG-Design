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
}
