/**
 * Test class for ExtractionScoreUtil — the extraction-completeness score written on the
 * Lead-creation path (Acquisition Observations phase 1, observation 1, 2026-08-14).
 *
 * ExtractionScoreUtil is a pure function over two in-memory DTO values (no SOQL, no DML, no
 * callouts, no describes, no Date.today()), so every test here is a plain in-memory assertion
 * with no fixture, no mock and no Test.startTest()/stopTest() boundary.
 *
 * ═══ WHAT THIS CLASS EXISTS TO FALSIFY ═══
 * A completeness score is unusually easy to write in a way that always passes its own tests and
 * is still wrong, so the five claims below are each pinned by a test that goes RED if the claim
 * breaks — not merely by a happy-path assertion:
 *
 *   1. THE DENOMINATOR IS NINE, AND IT IS THE SIGNED-OFF NINE. Not "nine things"; these nine.
 *      `denominator_isTheNineSignedOffKeys` pins the LIST, not the count, so substituting a key
 *      (say, reinstating one of the six physical-property keys the user CUT at sign-off) fails
 *      here rather than silently re-basing every score in the org.
 *   2. `captured + missing == 9`, ALWAYS. That identity is what makes the denominator
 *      recoverable per record and therefore makes a future change to the list auditable.
 *   3. THE PERCENT IS DECIMAL ARITHMETIC. Apex Integer division TRUNCATES, so `captured / 9 *
 *      100` evaluates to 0 for every score below 9/9 — a total defect that a test using only
 *      0/9 and 9/9 cannot see, because both are correct under truncation.
 *      `score_partialCapture_roundsHalfUpAndDoesNotTruncate` is the test that sees it.
 *   4. NULL AND ZERO ARE DIFFERENT ANSWERS. `notScored` means "there was nothing to score";
 *      a zero means "the model ran and gave us none of the nine". The pair
 *      `score_nullProperty_isNotScored` / `score_blockWithOnlyUnscoredFacts_scoresZeroNotNull`
 *      discriminate in OPPOSITE directions and are worth nothing separately.
 *   5. THE SCORE MEASURES WHAT LANDS ON THE LEAD, NOT WHAT THE MODEL SAID — and `property_address`
 *      is where those two come apart (code review C2, 2026-08-14). The class read the block's RAW
 *      address and counted it captured on exactly the leads whose `Property_Address__c` is blank,
 *      because `ExtractAddressQueueable.claimableAddress` had already nulled a value that does not
 *      normalize. It is now an ARGUMENT, and the pair
 *      `score_rawAddressThatDoesNotNormalize_countsAsMissing` /
 *      `score_resolvedAddressCountsEvenWhenTheBlockIsSilent` discriminate in opposite directions
 *      so the rule reads "use the resolved value", not "distrust the address". Every other fixture
 *      here has a cleanly-normalizing address, which is precisely why nothing caught this before.
 *
 * NO ContentVersion, no ContentNote, no ContentDocument anywhere in this class
 * (`.claude/rules/content-publication-rule.md` is not engaged).
 *
 * BULK: `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not apply, and the reason is
 * recorded here so review does not demand it. This is a pure function over an in-memory DTO with
 * no SOQL, no DML and no trigger/batch/queueable context — there is no batch-chunking behaviour
 * to expose at any volume, and a 251-object loop would prove nothing a single call does not. The
 * rule's own per-transaction-singleton exemption reasoning applies a fortiori: this is not even
 * async. The bulk shape of the PATH this feeds is pinned where it belongs, on
 * EmailToLeadServiceTest / ExtractAddressQueueableTest, against their per-invocation governor
 * budgets — this class costs zero queries and zero statements and so cannot move them.
 *
 * @see ExtractionScoreUtil.cls (the class under test)
 * @see EmailToLeadServiceTest.cls (the fail-soft wrapper and the fields actually landing on the Lead)
 * @see LeadConvertServiceTest.cls (the carry-forward of the three numbers to the Opportunity)
 */
@isTest
private class ExtractionScoreUtilTest {

    /** A listing-broker name that is present, for the two email-level keys. */
    private static final String BROKER_NAME = 'Dana Listing';
    /** A listing-broker email that is present. */
    private static final String BROKER_EMAIL = 'dana@listingfirm.example.invalid';
    /** The one address these fixtures use, on the block AND as the resolved argument. */
    private static final String ADDRESS = '1400 Royal Lane, Dallas TX';

    /**
     * The RESOLVED address for a `blockWith(captured)` block — i.e. what
     * ExtractAddressQueueable.claimableAddress would hand the caller, and therefore what
     * Lead.Property_Address__c would carry.
     *
     * Exists because `property_address` is scored from an ARGUMENT, not from the block (code
     * review C2, 2026-08-14). For every fixture here the two agree, which is the ORDINARY case;
     * `score_rawAddressThatDoesNotNormalize_countsAsMissing` is the test where they deliberately
     * DISAGREE, and it is the only one that can see the defect.
     *
     * @param captured The same level passed to blockWith.
     * @return The address at level 2 and above, null below it.
     */
    private static String addressFor(Integer captured) {
        return (captured >= 2) ? ADDRESS : null;
    }

    /**
     * A property block carrying EXACTLY the first `captured` of the seven property-level scored
     * keys, in SCORED_KEYS order.
     *
     * Ordered deliberately so a test can ask for "n of the seven" and get a deterministic set;
     * the two email-level keys (listing_broker_name / listing_broker_email) are supplied
     * separately by the caller because that is where they live. `property_address` is set on the
     * block AND supplied separately by addressFor() — the block copy is what a real extraction
     * carries, the argument is what the score reads.
     *
     * 🔴 `unitCount` IS ALWAYS SET, AND IT IS LOAD-BEARING RATHER THAN DECORATION. Without it,
     * `blockWith(0)` is STRUCTURALLY EMPTY, so score() correctly short-circuits to notScored()
     * and every "0 captured" assertion below would be asserting against nulls. `unit_count` is
     * NOT one of the nine signed-off keys (it is one of the six physical keys the user CUT), so
     * it contributes nothing to the numerator — which is exactly the property needed: the block
     * says something, and none of what it says counts.
     *
     * This was found by running the suite, not by reading it: the first draft omitted it and
     * three tests failed with `Expected: 0, Actual: null` and a NullPointerException.
     *
     * @param captured How many of the seven property-level keys to populate, 0..7.
     * @return The block.
     */
    private static PropertyExtraction blockWith(Integer captured) {
        PropertyExtraction p = new PropertyExtraction();
        p.unitCount = 128;
        if (captured >= 1) { p.propertyName = 'Orion ParkView'; }
        if (captured >= 2) { p.propertyAddress = ADDRESS; }
        if (captured >= 3) { p.guidancePrice = 14000000; }
        if (captured >= 4) { p.capRate = 6.25; }
        if (captured >= 5) { p.offerDueDate = Date.today().addDays(21); }
        if (captured >= 6) { p.saleProcess = 'Call for Offers'; }
        if (captured >= 7) { p.listingStatus = 'On Market'; }
        return p;
    }

    // ── the denominator itself ────────────────────────────────────────────────

    @isTest
    static void denominator_isTheNineSignedOffKeys() {
        // 🔴 PINS THE LIST, NOT THE COUNT. A count-only assertion passes just as happily if
        // someone swaps `listing_status` for `noi` — which would be a business change (the six
        // physical-property keys were CUT by the user at sign-off on 2026-08-14, because a land
        // deal legitimately has no building SF and no NOI) wearing the costume of a refactor.
        // Reordering the list is harmless and deliberately not asserted; substitution is not.
        Assert.areEqual(9, ExtractionScoreUtil.DENOMINATOR,
            'The signed-off denominator is NINE. Changing it re-bases the meaning of every '
            + 'score already stored in the org and is a business decision, not a code change.');

        Set<String> expected = new Set<String>{
            'property_name', 'property_address', 'guidance_price', 'guidance_cap_rate',
            'offer_due_date', 'sale_process', 'listing_broker_name', 'listing_broker_email',
            'listing_status'
        };
        Assert.areEqual(expected, new Set<String>(ExtractionScoreUtil.SCORED_KEYS),
            'The scored keys must be exactly the nine signed off on 2026-08-14. EXCLUDED and '
            + 'must stay excluded: the six physical keys (building_sf, noi, unit_count, '
            + 'occupancy, year_built, asset_type), every classification key '
            + '(is_acquisition_related, confidence, email_category, category_confidence), and '
            + 'anything the pipeline is forbidden to write (Property__c.Lot_Size__c).');

        Assert.areEqual(ExtractionScoreUtil.SCORED_KEYS.size(), ExtractionScoreUtil.DENOMINATOR,
            'DENOMINATOR must be derived from the list, never typed as a literal — otherwise '
            + 'adding a key would change what is counted without changing what it is divided by');
    }

    // ── NOT SCORED: null, never zero ──────────────────────────────────────────

    @isTest
    static void score_nullProperty_isNotScored() {
        // The LLM-DOWN path. Routing branch (c) creates a Lead from the envelope alone when
        // extraction degraded, so there is no property block at all. Scoring that 0/9 would put
        // a "chase this broker" signal on a lead the model was never consulted about.
        ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(null, null, BROKER_NAME, BROKER_EMAIL);

        Assert.isFalse(score.isScored, 'A Lead with no property block was not scored');
        Assert.isNull(score.scorePct, 'Not-scored is NULL, never 0 — a 0 is a claim about the extraction');
        Assert.isNull(score.capturedCount, 'All three values are null together; there is no half-scored state');
        Assert.isNull(score.missingCount, 'All three values are null together; there is no half-scored state');
    }

    @isTest
    static void score_structurallyEmptyProperty_isNotScored() {
        // The measured 2026-08-12 artefact: a model response containing ONE property object in
        // which every extracted member is empty ("Team lunch Friday + Q3 expense reports"). It
        // is a structural artefact of the response schema, not a property, so there is nothing
        // to score — same answer as no block at all, reached by a different route.
        PropertyExtraction empty = new PropertyExtraction();
        Assert.isTrue(empty.hasNoExtractedValues(), 'Precondition: the fixture is the empty-object shape');

        ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(empty, null, null, null);

        Assert.isFalse(score.isScored, 'A block that states nothing at all is not scored');
        Assert.isNull(score.scorePct, 'Not-scored is NULL, never 0');
    }

    @isTest
    static void notScored_isTheSingleSourceOfTheAllNullShape() {
        // The caller's fail-soft catch uses this factory rather than hand-building three nulls,
        // so that "not scored" has ONE definition. Pinned so a future edit cannot give the catch
        // a subtly different shape (say, zeros) without a test noticing.
        ExtractionScoreUtil.Score score = ExtractionScoreUtil.notScored();

        Assert.isFalse(score.isScored, 'notScored() is not scored');
        Assert.isNull(score.capturedCount, 'notScored() carries no captured count');
        Assert.isNull(score.missingCount, 'notScored() carries no missing count');
        Assert.isNull(score.scorePct, 'notScored() carries no percent');
    }

    // ── SCORED: zero is a real answer and is NOT null ─────────────────────────

    @isTest
    static void score_blockWithOnlyUnscoredFacts_scoresZeroNotNull() {
        // 🔴 THE OPPOSITE DIRECTION FROM THE TWO NOT-SCORED TESTS ABOVE, AND WORTHLESS WITHOUT
        // THEM. This block SAYS something — 128 units, $868k NOI, built 2001 — so it is not
        // structurally empty and must be scored. But NONE of those three facts is one of the
        // nine signed-off keys, so the honest score is 0/9 = 0%, meaning "the model told us
        // about the building and nothing about the deal": exactly the lead an analyst should
        // chase. If this ever returns null, the score has stopped distinguishing "nothing to
        // score" from "nothing worth scoring", and the work queue loses its most urgent rows.
        PropertyExtraction physicalOnly = new PropertyExtraction();
        physicalOnly.unitCount = 128;
        physicalOnly.noi = 868000;
        physicalOnly.yearBuilt = 2001;

        ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(physicalOnly, null, null, null);

        Assert.isTrue(score.isScored, 'A block stating real facts IS scored, even when none of them counts');
        Assert.areEqual(0, score.capturedCount, 'None of the nine deal-process keys was supplied');
        Assert.areEqual(9, score.missingCount, 'All nine are missing');
        Assert.areEqual(0, score.scorePct, '0% is a CLAIM the model gave us no deal facts, and it is true here');
    }

    // ── SCORED: the arithmetic ────────────────────────────────────────────────

    @isTest
    static void score_everyKeyCaptured_isNineOfNineAtOneHundredPercent() {
        ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(
            blockWith(7), addressFor(7), BROKER_NAME, BROKER_EMAIL);

        Assert.areEqual(9, score.capturedCount, 'All seven property keys plus both listing-broker keys');
        Assert.areEqual(0, score.missingCount, 'Nothing is missing');
        Assert.areEqual(100, score.scorePct, 'Nine of nine is 100%');
    }

    @isTest
    static void score_partialCapture_roundsHalfUpAndDoesNotTruncate() {
        // 🔴 THE INTEGER-DIVISION TRAP. `captured / DENOMINATOR * 100` in Apex evaluates to 0
        // for every value below 9/9 because Integer division TRUNCATES. Both 0/9 and 9/9 are
        // CORRECT under that bug, so a suite testing only the extremes would pass while every
        // real lead in the org showed 0%. Two mid-range values, chosen to round in OPPOSITE
        // directions, are what make the bug visible:
        //   4/9 = 44.44... -> 44 (rounds DOWN)
        //   5/9 = 55.55... -> 56 (rounds UP)
        // The pair also pins that the result is rounded rather than floored — a floor would give
        // 55 for the second, which is a plausible-looking wrong answer nobody would notice.
        ExtractionScoreUtil.Score four = ExtractionScoreUtil.score(blockWith(4), addressFor(4), null, null);
        Assert.areEqual(4, four.capturedCount, 'Four of the seven property-level keys were supplied');
        Assert.areEqual(5, four.missingCount, 'Nine minus four');
        Assert.areEqual(44, four.scorePct, '4/9 is 44.44%, which rounds DOWN to 44 — not 0, and not 45');

        ExtractionScoreUtil.Score five = ExtractionScoreUtil.score(blockWith(5), addressFor(5), null, null);
        Assert.areEqual(5, five.capturedCount, 'Five of the seven property-level keys were supplied');
        Assert.areEqual(56, five.scorePct, '5/9 is 55.55%, which rounds UP to 56 — a floor would give 55');
    }

    @isTest
    static void score_capturedPlusMissingAlwaysEqualsTheDenominator() {
        // 🔴 THE IDENTITY THAT MAKES A FUTURE CHANGE TO THE LIST AUDITABLE. Because both counts
        // are stored on the record, `captured + missing` recovers the denominator the score was
        // computed against — so if the nine ever become ten, historical rows still say which
        // basis they used instead of being silently re-based. That property is the entire reason
        // two counts are stored rather than the percent alone; it is asserted across the whole
        // range rather than at one point, because an off-by-one would survive a single sample.
        for (Integer i = 0; i <= 7; i++) {
            ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(blockWith(i), addressFor(i), null, null);
            Assert.areEqual(ExtractionScoreUtil.DENOMINATOR,
                score.capturedCount + score.missingCount,
                'captured + missing must equal the denominator at every capture level (i=' + i + ')');
        }
        // …and again with the two EMAIL-LEVEL keys present, because they are counted by a
        // different code path (method arguments, not DTO members) and could drift alone.
        ExtractionScoreUtil.Score withBroker = ExtractionScoreUtil.score(
            blockWith(0), addressFor(0), BROKER_NAME, BROKER_EMAIL);
        Assert.areEqual(2, withBroker.capturedCount,
            'The two listing-broker keys are counted, and NOTHING in blockWith(0) is — its only '
            + 'populated member is unit_count, which the user cut from the denominator');
        Assert.areEqual(ExtractionScoreUtil.DENOMINATOR,
            withBroker.capturedCount + withBroker.missingCount,
            'The identity holds for the email-level keys too');
    }

    // ── the two EMAIL-LEVEL keys ──────────────────────────────────────────────

    @isTest
    static void score_listingBrokerKeysCountIndependentlyOfTheBlock() {
        // listing_broker_name / listing_broker_email live on LLMExtractionResult, not on the
        // property, and are passed in from the caller's already-resolved request — so the score
        // measures what LANDS ON THE LEAD, including U1's demotion of a body-named broker into
        // those fields and including the parser having already nulled a malformed address.
        // Asserted one at a time so a copy-paste that reads the name twice is visible.
        ExtractionScoreUtil.Score nameOnly = ExtractionScoreUtil.score(
            blockWith(0), addressFor(0), BROKER_NAME, null);
        Assert.areEqual(1, nameOnly.capturedCount, 'listing_broker_name alone counts as one');

        ExtractionScoreUtil.Score emailOnly = ExtractionScoreUtil.score(
            blockWith(0), addressFor(0), null, BROKER_EMAIL);
        Assert.areEqual(1, emailOnly.capturedCount, 'listing_broker_email alone counts as one');
    }

    @isTest
    static void score_blankAndWhitespaceListingBrokerValuesDoNotCount() {
        // A value the Lead does not carry must never be counted as captured. Whitespace is the
        // realistic case: the parser trims, but the caller's value can arrive from several
        // places and String.isNotBlank is what makes ' ' and '' agree with null.
        ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(blockWith(0), null, '   ', '');

        Assert.areEqual(0, score.capturedCount, 'Blank and whitespace-only values are not captures');
        Assert.areEqual(0, score.scorePct, 'Zero of nine is 0%');
    }

    // ── property_address: the RESOLVED value, never the block's raw one (C2) ──

    @isTest
    static void score_rawAddressThatDoesNotNormalize_countsAsMissing() {
        // 🔴 THE FALSIFIER FOR CODE REVIEW C2 (2026-08-14). Before the fix this class read
        // `property.propertyAddress` and counted a non-blank raw value as CAPTURED — on precisely
        // the leads whose Property_Address__c is BLANK.
        //
        // The mechanism, end to end:
        //   ExtractAddressQueueable.claimableAddress returns NULL when
        //   PropertyMatchingService.normalizeAddress(raw) is blank ("a raw value of '###' or '—'
        //   is non-blank while its normalized form is empty"), so request.propertyAddress is null;
        //   EmailToLeadService sets Lead.Property_Address__c only from request.propertyAddress,
        //   so the field stays null. That is the OUTCOME_NO_ADDRESS population — routing branch
        //   (c) — which is exactly the population this score exists to queue up for chasing.
        //
        // Scoring it captured put those leads one point HIGH and left the address unnamed in
        // Fields_Missing_Count__c, so the work queue built to chase a missing address ranked them
        // "mostly complete". No pre-existing test saw it: every other fixture address normalizes.
        //
        // This test is the ONLY one where the block's raw address and the resolved argument
        // DISAGREE, and it is what makes the argument-not-DTO decision falsifiable rather than
        // merely commented. A revert to `property.propertyAddress` reds it at 9 / 0 / 100 — the
        // defect's answer, and a perfect-looking one.
        PropertyExtraction rawOnly = blockWith(7);
        rawOnly.propertyAddress = '###';   // non-blank, and normalizes to empty

        ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(
            rawOnly, null, BROKER_NAME, BROKER_EMAIL);   // resolved address: null, as claimableAddress returns

        Assert.isTrue(score.isScored,
            'The block states plenty of other facts, so it IS scored — this is not the '
            + 'nothing-to-score path and must not be confused with it');
        Assert.areEqual(8, score.capturedCount,
            'Eight of the nine were supplied and property_address was NOT: the Lead will carry a '
            + 'blank Property_Address__c, so counting it captured would be a claim about a value '
            + 'the record does not hold');
        Assert.areEqual(1, score.missingCount,
            'The address must be NAMED as missing — that count is what the chase-the-address '
            + 'queue ranks on, and under the defect it read 0');
        Assert.areEqual(ExtractionScoreUtil.DENOMINATOR,
            score.capturedCount + score.missingCount,
            'captured + missing still recovers the denominator on the address-less path');
        Assert.areEqual(89, score.scorePct,
            '8/9 is 88.88%, which rounds to 89 — not the 100% the defect reported for a lead '
            + 'whose single most chaseable field is blank');
    }

    @isTest
    static void score_resolvedAddressCountsEvenWhenTheBlockIsSilent() {
        // The opposite direction, and worth nothing without the test above. What lands on the Lead
        // is the ARGUMENT, so a resolved address counts whatever the block's own member says —
        // pinning that the fix is "read the resolved value", not "distrust the address".
        PropertyExtraction noRaw = blockWith(0);
        Assert.isNull(noRaw.propertyAddress, 'Precondition: the block itself states no address');

        ExtractionScoreUtil.Score score = ExtractionScoreUtil.score(noRaw, ADDRESS, null, null);

        Assert.areEqual(1, score.capturedCount,
            'property_address is captured because the Lead will carry it, which is the only '
            + 'question this score asks');
        Assert.areEqual(8, score.missingCount, 'Nine minus one');
    }

    // ── the fail-soft seam ────────────────────────────────────────────────────

    @isTest
    static void simulateScoreFailure_makesScoreThrow() {
        // The seam exists ONLY so EmailToLeadService's mandatory fail-soft catch is falsifiable:
        // this class is total by construction, so without it there is no input that reaches that
        // catch and "the pipeline never throws" would be an untested claim. Pinned here as well
        // as at the call site so that removing the seam fails in the class that owns it.
        ExtractionScoreUtil.simulateScoreFailure = true;

        Boolean threw = false;
        try {
            ExtractionScoreUtil.score(blockWith(7), addressFor(7), BROKER_NAME, BROKER_EMAIL);
        } catch (ExtractionScoreUtil.ExtractionScoreException e) {
            threw = true;
        }

        Assert.isTrue(threw, 'The seam must raise ExtractionScoreException so the caller catch can be exercised');
    }

    @isTest
    static void simulateScoreFailure_defaultsOffSoProductionIsNeverAffected() {
        // A seam that defaulted ON would disable scoring for every inbound email in the org.
        Assert.isFalse(ExtractionScoreUtil.simulateScoreFailure,
            'The failure seam must default to false; only a test may ever set it');
    }
}
