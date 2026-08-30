/**
 * Tests for BrokerProtectionConfig.
 *
 * Most of this class's accessor lines are already exercised indirectly by
 * PropertyMatchingServiceTest (the fresh-org defaults, the negative-window WARN guard, and the
 * lookback/window clamp — see `effectiveLookback_clampsUpToTheWindow_whenAnAdminMisconfiguresIt`,
 * `effectiveLookback_leavesALegitimatelyLongerLookbackAlone`,
 * `accessors_returnThePreWS5Literals_whenTheConfigRecordIsAbsent` and
 * `negativeWindow_fallsBackToTheDefault_ratherThanInvertingTheCutoff`). This class exists to close
 * the one gap none of those cover: `maxTokens()` is the only accessor with a THIRD code path (a
 * configured value that is neither null nor negative-triggering-a-fallback) — a positive configured
 * value, and a non-positive-but-not-null configured value (its own WARN branch, distinct from the
 * day-count WARN in `resolveDays`). Neither line was ever reached by any existing test.
 *
 * ═══ EXTENDED 2026-08-30 (WS8 review, finding C1) ═══
 * The two confidence accessors were bare null-coalesces — no range guard, no ordering clamp, no
 * WARN — while `confidenceHighMin()` had become the relevance-suppression HARD GATE. The second
 * section below covers `resolveThreshold`, `confidenceHighMin()`'s extra zero refusal,
 * `effectiveConfidenceMediumMin()`'s clamp, and the `LLMExtractionParser` repoint. Its own header
 * block explains why these guards can be proven nowhere else.
 *
 * ═══ BULK VOLUME IS NOT APPLICABLE HERE — DELIBERATE, NOT AN OVERSIGHT ═══
 * `.claude/rules/bulk-test-rule.md` mandates 251 records for triggers, batches, queueables and
 * DML-performing services. This class is none of those — `BrokerProtectionConfig` issues no SOQL
 * and no DML (see its own header, "WHY THERE IS NO SELECTOR"); every method here is a pure
 * arithmetic/string decision over a single injected `Broker_Protection_Config__mdt` row via the
 * `overrideForTest` seam. There is no collection and no loop to force a second batch chunk.
 *
 * ═══ WHY overrideForTest, NOT DML ═══
 * A test cannot insert a `__mdt` row — custom metadata records are not insertable from Apex.
 * `BrokerProtectionConfig.overrideForTest` is the seam built for exactly this (see its own
 * @TestVisible header) and is the only way to exercise a configured value from a test.
 */
@IsTest
private class BrokerProtectionConfigTest {

    /**
     * The configured-positive-value path. `warnOnce` must NOT fire — nothing is wrong with this
     * value, so a WARN here would be a false alarm every time an admin sets a smaller-than-default
     * budget on purpose.
     */
    @isTest
    static void maxTokens_returnsTheConfiguredValue_whenPositive() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Max_Tokens__c = 2048));

        Test.startTest();
        Integer tokens = BrokerProtectionConfig.maxTokens();
        Test.stopTest();

        Assert.areEqual(2048, tokens,
            'A positive configured Max_Tokens__c must be honoured, not overridden by the default');
    }

    /**
     * The non-positive-but-not-null path — the field's own WARN branch, separate from the
     * day-count WARN in `resolveDays`. Zero and a negative value are both "not usable" by the same
     * `<= 0` test, so one representative (0) is enough to prove the branch; the reasoning is
     * identical to a negative token budget (both would make `LLMExtractionCalloutService`'s request
     * body carry a completion cap that cannot produce a response).
     */
    @isTest
    static void maxTokens_fallsBackToTheDefault_whenConfiguredNonPositive() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Max_Tokens__c = 0));

        Test.startTest();
        Integer tokens = BrokerProtectionConfig.maxTokens();
        Test.stopTest();

        Assert.areEqual(4096, tokens,
            'A non-positive Max_Tokens__c is not usable and must fall back to the shipped default '
            + '(was LLMExtractionCalloutService.MAX_TOKENS) rather than sending a callout that '
            + 'cannot produce a response');
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // CONFIDENCE THRESHOLDS (WS8 review, finding C1)
    //
    // 🔴 WHAT THESE TESTS ARE FOR, AND WHY THEY DID NOT EXIST BEFORE. Until WS8 both
    // confidence accessors were bare null-coalesces: every configured number was accepted as
    // typed. That was survivable while they were only display bands, and it stopped being
    // survivable when `Confidence_High_Min__c` became the SUPPRESSION GATE —
    // `is_acquisition_related = false AND confidence >= this value`. Its failure mode has no
    // symptoms at all: no Lead, no registry claim, no exception, no log, just email that
    // stops producing records. Nothing about a suppressed email tells anyone it happened, so
    // these guards can only ever be proven here.
    //
    // ⚠ AND ONLY HERE. `effectiveLookbackDays()`'s own Javadoc states the reason: "WS5 makes
    // both editable in Setup, where NO Apex test can see them, so the pin alone is no longer
    // enforcement at all." A test cannot see what an admin types; it can only prove that the
    // code refuses to act on a bad value. Each test below therefore asserts the RESOLVED
    // value, never the configured one.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /**
     * The legitimate-configured-value path for the gate. A stricter gate is a real and
     * sensible admin choice, and it must pass through untouched — a guard that quietly
     * ignored 0.95 would be worse than no guard, because the org would be running a
     * suppression threshold nobody asked for.
     */
    @isTest
    static void confidenceHighMin_honoursALegitimateConfiguredValue() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 0.95));

        Test.startTest();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Test.stopTest();

        Assert.areEqual(0.95, high,
            'A configured threshold inside (0, 1] must be honoured exactly. Tightening the '
            + 'suppression gate is a legitimate Setup change, not a misconfiguration.');
    }

    /**
     * 1 is the TOP of the valid range and must be accepted — the boundary on the reject side
     * of `> 1`. It means "suppress only on a perfectly confident non-acquisition verdict",
     * which is the most conservative real setting there is. An off-by-one in
     * `resolveThreshold` (`>=` instead of `>`) would silently replace it with 0.85, i.e.
     * would silently make the gate LOOSER than the admin asked for.
     */
    @isTest
    static void confidenceHighMin_acceptsExactlyOne_theTopOfTheRange() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 1));

        Test.startTest();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Test.stopTest();

        Assert.areEqual(1, high,
            'A threshold of exactly 1 is in range and is the strictest legitimate gate; it '
            + 'must NOT be rejected back to the looser 0.85 default');
    }

    /**
     * 🔴 THE CRITICAL CASE. `confidence >= 0` is true for EVERY extraction, including a
     * confidence of 0, so a zero here silently suppresses every email the model marks
     * non-acquisition: no Lead, no registry claim, no exception, no log. `null` already means
     * "not configured, use the default", so 0 cannot be an admin expressing an intent — it is
     * a cleared field or a typo, and it is the single most damaging value this record can
     * hold.
     */
    @isTest
    static void confidenceHighMin_refusesZero_whichWouldSuppressEveryNonAcquisitionEmail() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 0));

        Test.startTest();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Test.stopTest();

        Assert.areEqual(0.85, high,
            'A gate floor of 0 makes "confidence >= floor" unconditionally true and turns the '
            + 'relevance gate into "suppress every non-acquisition email, at any confidence". '
            + 'It must fall back to the shipped 0.85 and WARN.');
    }

    /**
     * A negative is the same catastrophe as zero, reached by a different typo, and it is
     * caught one branch earlier (the range check rather than the zero check). Both branches
     * need their own test or a regression could remove either while the other kept the suite
     * green.
     */
    @isTest
    static void confidenceHighMin_refusesANegative() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = -0.5));

        Test.startTest();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Test.stopTest();

        Assert.areEqual(0.85, high,
            'A negative gate floor is below every possible confidence and suppresses '
            + 'everything, exactly as 0 does; it must fall back to 0.85 and WARN');
    }

    /**
     * Above 1 fails in the OPPOSITE direction and is the reason the guard is a RANGE and not
     * just a negative check (which is all `resolveDays` needs). No model confidence can ever
     * reach 1.5, so the HIGH band — and with it the suppression gate — silently stops firing
     * altogether. Nothing throws; the feature just turns itself off.
     */
    @isTest
    static void confidenceHighMin_refusesAValueAboveOne_whichWouldDisableTheGateEntirely() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 1.5));

        Test.startTest();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Test.stopTest();

        Assert.areEqual(0.85, high,
            'A threshold above 1 is unreachable by any model confidence, so the HIGH band and '
            + 'the suppression gate would both stop firing with nothing logged');
    }

    /**
     * 🔴 THE DELIBERATE ASYMMETRY, PINNED. `0` is refused by `confidenceHighMin()` and
     * ACCEPTED here. It is not an oversight and it must not be "harmonised": on the MEDIUM
     * floor, 0 means "nothing is ever banded LOW", which drives no gate — it only changes
     * `Parse_Confidence__c` and `Low_Confidence_Field_Count__c`, both of which are visible on
     * the record. Rejecting it would overrule a legitimate admin choice.
     *
     * Without this test the two accessors would be free to drift into sharing one rule, and
     * whichever direction that drift took would be silently wrong.
     */
    @isTest
    static void confidenceMediumMin_acceptsZero_unlikeTheGateThreshold() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 0.85,
            Confidence_Medium_Min__c = 0));

        Test.startTest();
        Decimal medium = BrokerProtectionConfig.confidenceMediumMin();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Test.stopTest();

        Assert.areEqual(0, medium,
            'A MEDIUM floor of 0 means "nothing is ever LOW". It drives no gate and must be '
            + 'honoured — the zero refusal belongs to confidenceHighMin() alone.');
        Assert.areEqual(0.85, high,
            'Control: the SAME injected row must leave the gate threshold at its legitimate '
            + 'configured value, so this test cannot pass by both accessors defaulting');
    }

    /**
     * The MEDIUM floor gets the range guard too. It is not the gate, but an out-of-range
     * value still silently mislabels every band on every Lead and mis-counts
     * `Low_Confidence_Field_Count__c`, which is the Review Queue's filter field.
     */
    @isTest
    static void confidenceMediumMin_refusesAnOutOfRangeValue() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_Medium_Min__c = 2));

        Test.startTest();
        Decimal medium = BrokerProtectionConfig.confidenceMediumMin();
        Test.stopTest();

        Assert.areEqual(0.60, medium,
            'A MEDIUM floor of 2 is unreachable by any model confidence and would band every '
            + 'field LOW; it must fall back to the shipped 0.60 and WARN');
    }

    /**
     * 🔴 THE ORDERING CLAMP, AND THE DIRECTION IT MOVES.
     *
     * `medium > high` is incoherent: `LLMExtractionParser.toBand` tests HIGH first, so the
     * MEDIUM band becomes unreachable while `lowConfidenceFieldCount` goes on flagging fields
     * the record itself displays as HIGH. The clamp collapses MEDIUM onto HIGH.
     *
     * ⚠ THE SECOND ASSERTION IS THE POINT OF THIS TEST. `effectiveLookbackDays()` resolves
     * its invariant by RAISING the weaker value; the symmetric move here would be raising
     * HIGH to meet MEDIUM, and that is forbidden — HIGH is the suppression gate, so a mistyped
     * MEDIUM would silently change which emails get suppressed. Asserting only the clamped
     * MEDIUM would leave that mistake free to be made.
     */
    @isTest
    static void effectiveConfidenceMediumMin_clampsDownToTheGate_andNeverMovesTheGate() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 0.80,
            Confidence_Medium_Min__c = 0.90));

        Test.startTest();
        Decimal effectiveMedium = BrokerProtectionConfig.effectiveConfidenceMediumMin();
        Decimal high = BrokerProtectionConfig.confidenceHighMin();
        Decimal rawMedium = BrokerProtectionConfig.confidenceMediumMin();
        Test.stopTest();

        Assert.areEqual(0.80, effectiveMedium,
            'A MEDIUM floor above the HIGH floor must clamp DOWN to the HIGH floor, which '
            + 'empties the MEDIUM band rather than leaving an incoherent pair in force');
        Assert.areEqual(0.80, high,
            'THE CLAMP MUST NOT MOVE THE GATE. Raising Confidence_High_Min__c to 0.90 to meet '
            + 'a mistyped MEDIUM would change which emails are silently suppressed — a clamp '
            + 'doing the exact thing GATE A exists to prevent.');
        Assert.areEqual(0.90, rawMedium,
            'The RAW accessor must still report what the admin typed, so a diagnostic can '
            + 'show configured-versus-used (the configuredLookbackDays() precedent)');
    }

    /**
     * The clamp must NOT fire on a legitimate pair. `medium < high` is the ordinary,
     * shipped-default relationship, and a clamp that flattened them would silently delete the
     * MEDIUM band from every Lead in the org.
     */
    @isTest
    static void effectiveConfidenceMediumMin_leavesALegitimatePairAlone() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 0.85,
            Confidence_Medium_Min__c = 0.50));

        Test.startTest();
        Decimal effectiveMedium = BrokerProtectionConfig.effectiveConfidenceMediumMin();
        Test.stopTest();

        Assert.areEqual(0.50, effectiveMedium,
            'A MEDIUM floor below the HIGH floor is the normal case and must pass through '
            + 'unchanged; clamping it to 0.85 would erase the MEDIUM band');
    }

    /**
     * `medium == high` is the exact boundary between "pass through" and "clamp". It is legal
     * (it simply means the MEDIUM band is empty by the admin's own choice) and must take the
     * pass-through leg, so the clamp's own WARN does not fire on a configuration nobody needs
     * to fix. A `<` instead of `<=` in the comparison would land here and be invisible in
     * every other test in this class.
     */
    @isTest
    static void effectiveConfidenceMediumMin_treatsAnEqualPairAsLegitimate() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 0.75,
            Confidence_Medium_Min__c = 0.75));

        Test.startTest();
        Decimal effectiveMedium = BrokerProtectionConfig.effectiveConfidenceMediumMin();
        Test.stopTest();

        Assert.areEqual(0.75, effectiveMedium,
            'An equal pair satisfies high >= medium and is not a misconfiguration; it must '
            + 'pass through the non-clamping leg');
    }

    /**
     * THE FRESH-ORG CASE FOR THE EFFECTIVE ACCESSOR. "Record absent" is reachable in every
     * newly built org (the Default record is script-loaded, not deployed), and the new
     * accessor must return the pre-WS5 literal exactly like its siblings — otherwise WS8's
     * guards would have changed behaviour in an org that has no configuration at all.
     */
    @isTest
    static void effectiveConfidenceMediumMin_returnsThePreWS5Literal_whenTheRecordIsAbsent() {
        BrokerProtectionConfig.overrideForTest(null);

        Test.startTest();
        Decimal effectiveMedium = BrokerProtectionConfig.effectiveConfidenceMediumMin();
        Test.stopTest();

        Assert.areEqual(0.60, effectiveMedium,
            'Was LLMExtractionParser.CONFIDENCE_MEDIUM_MIN. An org with no config record must '
            + 'band exactly as it did before WS5 and WS8.');
    }

    /**
     * 🔴 THE REPOINT ITSELF. `LLMExtractionParser.CONFIDENCE_MEDIUM_MIN` must resolve from
     * `effectiveConfidenceMediumMin()`, not from the raw accessor — otherwise the clamp
     * proven above exists and the one class that needs it never sees it.
     *
     * ⚠ HOW THIS TEST AVOIDS PASSING VACUOUSLY. Both parser constants are `static final`,
     * resolved once when the class is first loaded in the transaction, so the override must
     * be installed BEFORE the first reference to `LLMExtractionParser` — which is why nothing
     * above touches that class. The HIGH assertion is the CONTROL: it proves the statics were
     * resolved under the injected row (0.80, not the shipped 0.85). If class loading ever
     * moved earlier, that control fails loudly instead of letting the MEDIUM assertion pass
     * on a coincidence.
     */
    @isTest
    static void parserConstants_readTheClampedMediumFloor_notTheRawOne() {
        BrokerProtectionConfig.overrideForTest(new Broker_Protection_Config__mdt(
            Confidence_High_Min__c = 0.80,
            Confidence_Medium_Min__c = 0.90));

        Test.startTest();
        Decimal parserHigh = LLMExtractionParser.CONFIDENCE_HIGH_MIN;
        Decimal parserMedium = LLMExtractionParser.CONFIDENCE_MEDIUM_MIN;
        Test.stopTest();

        Assert.areEqual(0.80, parserHigh,
            'CONTROL — the parser statics must have resolved under the injected row. If this '
            + 'reads 0.85 the class was loaded before overrideForTest ran and the MEDIUM '
            + 'assertion below proves nothing.');
        Assert.areEqual(0.80, parserMedium,
            'CONFIDENCE_MEDIUM_MIN must come from effectiveConfidenceMediumMin(). Reading the '
            + 'raw accessor would put 0.90 here, above CONFIDENCE_HIGH_MIN, making toBand\'s '
            + 'MEDIUM leg unreachable and lowConfidenceFieldCount flag fields the record '
            + 'displays as HIGH.');
    }
}
