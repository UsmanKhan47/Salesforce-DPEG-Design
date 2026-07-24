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
}
