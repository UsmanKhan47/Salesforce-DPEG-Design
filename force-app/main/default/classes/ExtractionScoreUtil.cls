/**
 * Broker-Protection LLM extraction — EXTRACTION-COMPLETENESS SCORING (observation 1, 2026-08-14).
 *
 * Answers one question, for one property, at Lead-creation time: "of the deal-process facts we
 * ask the model for, how many did it actually give us?" The answer lands on the Lead as
 * `Extraction_Score_Pct__c` / `Fields_Captured_Count__c` / `Fields_Missing_Count__c`, and is
 * carried to the Opportunity at conversion by LeadConvertService.
 *
 * The score exists so an analyst can tell, at a glance and from a list view, WHICH leads need
 * chasing. A low score is not a defect report about the model — it is a work queue.
 *
 * ═══ 🔴 THE DENOMINATOR IS NINE. IT IS A NAMED CONSTANT LIST. IT IS SIGNED OFF. ═══
 * Signed off 2026-08-14 (spec §0.0 / requirements §1 O4). SCORED_KEYS below is that list
 * verbatim and IS the denominator; nothing here describes a field set, and nothing may.
 *
 *   property_name        property_address       guidance_price
 *   guidance_cap_rate    offer_due_date         sale_process
 *   listing_broker_name  listing_broker_email   listing_status
 *
 * Three exclusions are load-bearing and each has a different reason:
 *
 *   1. THE SIX PHYSICAL-PROPERTY KEYS — `building_sf`, `noi`, `unit_count`, `occupancy`,
 *      `year_built`, `asset_type` — WERE CUT BY THE USER at sign-off. A land deal legitimately
 *      has no building SF and no NOI, so scoring against them would report a COMPLETE
 *      extraction as a poor one, on exactly the deal type this pipeline sees most often.
 *   2. THE CLASSIFICATION KEYS — `is_acquisition_related`, `confidence`, `email_category`,
 *      `category_confidence` — measure WHAT KIND OF EMAIL THIS IS, not how much was extracted.
 *      Folding them in repeats the mistake `Extraction_Score_Pct__c`'s own field comment
 *      forbids: a confident, correctly-classified email can be almost empty of deal facts, and
 *      an unconfident one can be complete. This score and `Parse_Confidence__c` are different
 *      questions and neither implies the other.
 *   3. ANYTHING THE PIPELINE IS FORBIDDEN TO WRITE — specifically `Property__c.Lot_Size__c`,
 *      which LeadConvertService's `buildProperty` documents as never written (it is SQUARE FEET
 *      from the Offering Memorandum; we hold acres only, and deriving one from the other is
 *      forbidden). Counting a field the pipeline may never fill would put a permanent ceiling
 *      under 100% and make every score in the org wrong by a constant.
 *
 * ⚠ NEVER DERIVE THE DENOMINATOR FROM A DESCRIBE. Spec §2.2 is explicit about why: a
 * describe-based denominator silently re-bases the meaning of every historical score the day
 * someone adds a field. Because BOTH counts are stored, `captured + missing` recovers the
 * denominator PER RECORD — so a future change to this list is auditable rather than silent.
 * That property is the reason two counts are stored instead of the percent alone; do not
 * "simplify" the schema down to the percent.
 *
 * ═══ WHAT "NOT SCORED" MEANS, AND WHY IT IS NULL RATHER THAN ZERO ═══
 * `notScored()` returns nulls, never zeros. A `0` is a CLAIM — "the model ran and found none of
 * the nine" — whereas a null says "there was nothing here to score". They must not be confused,
 * because the first is a lead to chase and the second is usually not.
 *
 * A null is produced in exactly two situations, and BOTH of them are degraded paths named in
 * requirements §1 O4 property 5:
 *   • THERE IS NO PROPERTY BLOCK AT ALL (`property == null`) — the LLM-DOWN path. The routing
 *     tree's branch (c) creates a Lead from the envelope alone when extraction degraded, and
 *     scoring that 0/9 would put a real "chase this" signal on a lead about which the model was
 *     never consulted.
 *   • THE BLOCK STATES NOTHING (`hasNoExtractedValues()`) — the structurally-empty property
 *     object measured on 2026-08-12 (see PropertyExtraction's own header). Same argument.
 * The CALL-FOR-OFFERS GATE, the third path O4 names, creates no Lead at all, so it is vacuous
 * here — recorded only so a reader does not go looking for a branch that cannot exist.
 *
 * 🔴 AN `OUTCOME_NO_ADDRESS` LEAD IS DELIBERATELY SCORED FOR REAL, AND THIS IS THE ONE
 * JUDGEMENT IN THIS CLASS A REVIEWER MIGHT WANT TO OVERRULE. Since the 2026-08-12 fix,
 * `ExtractAddressQueueable.firstProperty` skips a property object that states nothing, so an
 * addressless Lead ALWAYS carries a block with real facts in it — a name, a price, an NOI.
 * Nulling its score would blank the number for precisely the population the score exists to
 * queue up; a real 4/9 = 44% says "mostly there, go get the address", which is the useful
 * answer. So "a null score on the degraded paths is correct" is implemented as "null when there
 * is nothing to score", and an addressless-but-populated block is not that case.
 *
 * 🔴 AND THAT POPULATION IS WHY `property_address` IS AN ARGUMENT RATHER THAN A DTO READ
 * (code review C2, fixed 2026-08-14). Until the fix this class read `property.propertyAddress`
 * and counted it CAPTURED on exactly these leads — the raw value is non-blank, but
 * `ExtractAddressQueueable.claimableAddress` had already resolved it to null because it does not
 * normalize, so `Lead.Property_Address__c` is BLANK. They scored one point high and their
 * `Fields_Missing_Count__c` did not name the address, so the queue built to chase a missing
 * address ranked them "mostly complete". The defence above is only honest because the score now
 * counts the address as MISSING; see score()'s own comment.
 *
 * ═══ KNOWN, ACCEPTED PROPERTIES OF THE SIGNED-OFF LIST ═══
 * Neither is a defect and neither may be "fixed" here — the list is a business decision and
 * changing it re-bases every score in the org.
 *   • A RANGE-PRICED DEAL SCORES `guidance_price` AS MISSING. The extraction prompt fills
 *     `guidance_price_low` / `_high` and leaves `guidance_price` null for a quoted range (the
 *     same rule that deliberately leaves `Opportunity.Asking_Price__c` null — see
 *     LeadConvertService.applyDealFields). The signed-off list names `guidance_price`, so the
 *     score reads one point lower on those deals. Adding a low/high fallback would make the
 *     denominator no longer literally the nine keys.
 *   • MOST EMAILS CANNOT REACH 9/9. `listing_broker_*` are populated only when the SENDER IS
 *     NOT THE LISTING BROKER — the blast-platform shape, or U1's demotion of a body-named
 *     broker. On the ordinary email where the sender IS the broker they are correctly blank, so
 *     a flawless extraction scores 7/9 = 78%. The score is a RANKING signal across leads, not
 *     an absolute grade of the model.
 *
 * ═══ FAIL-SOFT ═══
 * This class is TOTAL by construction — every member it reads is a nullable field on a DTO and
 * there is no arithmetic that can divide by zero (DENOMINATOR is a non-empty literal list). The
 * mandatory fail-soft wrapper (spec §1 constraint 7: "the inbound email pipeline must never be
 * made to throw") therefore lives at the CALL SITE, in
 * EmailToLeadService.applyExtractionScore, which is the transaction that owns the broker's
 * email. `simulateScoreFailure` exists so that wrapper's catch branch is FALSIFIABLE rather
 * than merely asserted — see its own comment.
 *
 * LAYER — Utility. Pure functions: no SOQL, no DML, no callouts, no describes, no
 * `Date.today()`. `with sharing` is declared for ARCHITECTURE.md §2 conformance and is
 * functionally a no-op. Costs nothing at runtime, so it does not move
 * ExtractAddressQueueable's or EmailToLeadService's pinned governor budgets.
 *
 * @see EmailToLeadService.cls (the only production caller; owns the fail-soft wrapper)
 * @see LeadConvertService.cls (carries the three fields to the Opportunity at conversion)
 * @see PropertyExtraction.cls (seven of the nine keys live here)
 * @see LLMExtractionResult.cls (the other two — listing_broker_name / listing_broker_email)
 */
public with sharing class ExtractionScoreUtil {

    /**
     * 🔴 THE SIGNED-OFF DENOMINATOR, AS A LIST OF EXTRACTION KEYS. Declared FIRST so
     * DENOMINATOR below can size it — Apex initializes static finals in declaration order.
     *
     * The strings are the LLM response's own key names, not Salesforce field API names, and
     * that is deliberate: this measures how complete the EXTRACTION was, so it is keyed on what
     * was asked of the model. `guidance_cap_rate` is the one place the two vocabularies differ
     * — the response key is `cap_rate` and the destination field is `Guidance_Cap_Rate__c`; the
     * sign-off names it `guidance_cap_rate`, so that is the name recorded here.
     *
     * @TestVisible so a test can pin the list itself, not merely the count — a reordering is
     * harmless but a substitution is not.
     */
    @TestVisible
    private static final List<String> SCORED_KEYS = new List<String>{
        'property_name',
        'property_address',
        'guidance_price',
        'guidance_cap_rate',
        'offer_due_date',
        'sale_process',
        'listing_broker_name',
        'listing_broker_email',
        'listing_status'
    };

    /**
     * NINE. The denominator of every score this class produces, and the value
     * `captured + missing` must always equal.
     *
     * Public so tests and any future reader bind to the constant rather than retyping `9`,
     * which is how the two would drift.
     */
    public static final Integer DENOMINATOR = SCORED_KEYS.size();

    /**
     * TEST SEAM — forces score() to throw, so the caller's mandatory fail-soft catch is
     * FALSIFIABLE instead of merely asserted.
     *
     * This class is total by construction, which is a good property and an awkward one: it
     * means there is no input a test can supply that exercises
     * EmailToLeadService.applyExtractionScore's catch branch. Without this seam that branch
     * would be untested and uncovered, and "the pipeline never throws" would be a claim rather
     * than a pinned behaviour. Same shape and same reason as
     * TransactionActionPermissionService.simulateLookupFailure.
     *
     * Never set outside a test; `@TestVisible` on a private member is what enforces that.
     */
    @TestVisible
    private static Boolean simulateScoreFailure = false;

    /** Thrown only by the simulateScoreFailure seam. Never raised on any production input. */
    public class ExtractionScoreException extends Exception {}

    /**
     * The three numbers written to the Lead (and later carried to the Opportunity).
     *
     * `capturedCount + missingCount == DENOMINATOR` on every scored instance — that identity is
     * what makes the denominator recoverable per record, and it is asserted by the tests rather
     * than left to inspection. On a NOT-SCORED instance all three are null together; there is
     * no state in which some are null and some are not.
     */
    public class Score {

        /** How many of the nine keys the extraction supplied. Null when not scored. */
        public Integer capturedCount;

        /** How many of the nine it did not. Null when not scored. */
        public Integer missingCount;

        /** captured / 9 as a whole percent, 0-100, HALF_UP. Null when not scored. */
        public Integer scorePct;

        /** False when the three values above are all null — see notScored(). */
        public Boolean isScored;

        private Score(Integer captured, Integer missing, Integer pct, Boolean scored) {
            this.capturedCount = captured;
            this.missingCount = missing;
            this.scorePct = pct;
            this.isScored = scored;
        }
    }

    /**
     * Score ONE property block against the nine signed-off keys.
     *
     * 🔴 IT SCORES THE BLOCK THAT WAS STAMPED, NEVER THE EMAIL (requirements §1 O4 property 4).
     * One email can pitch up to ten properties and each produces its own Lead, so the caller
     * passes the SAME PropertyExtraction it is about to write onto this Lead —
     * `properties[0]` on routing branch (c), the routed property on branch (e). Scoring the
     * email while the fields on the record describe one property would produce a number that
     * explains nothing about the record it sits on.
     *
     * 🔴 THREE OF THE NINE ARE PASSED IN ALREADY RESOLVED, AND THAT IS THE WHOLE CONTRACT:
     * THE SCORE MEASURES WHAT LANDED ON THE LEAD, NEVER WHAT THE MODEL SAID.
     *
     *   • `listing_broker_name` / `listing_broker_email` are EMAIL-LEVEL — they live on
     *     LLMExtractionResult, not PropertyExtraction — so they could only ever have been
     *     arguments. Taking them from the caller's resolved request is what makes the score
     *     reflect U1's demotion of a body-named broker into those fields, and the parser's
     *     `sanitizeEmail` having already nulled a malformed address.
     *   • `property_address` IS on the block, and reading it from there was a DEFECT
     *     (code review C2, fixed 2026-08-14). `EmailToLeadService` stamps
     *     `Lead.Property_Address__c` from `request.propertyAddress`, which
     *     `ExtractAddressQueueable.claimableAddress` sets to NULL whenever the raw value does
     *     not normalize — a raw `'###'` or `'—'` is non-blank while its normalized form is
     *     empty. Reading `property.propertyAddress` therefore counted the address as CAPTURED
     *     on precisely the `OUTCOME_NO_ADDRESS` leads whose address field is blank: they scored
     *     one point HIGH, and `Fields_Missing_Count__c` did not name the very thing that was
     *     missing, so the queue that exists to chase a missing address ranked them "mostly
     *     complete". No fixture caught it because every test address normalized cleanly.
     *
     * ⚠ DO NOT "SIMPLIFY" ANY OF THE THREE BACK TO A DTO READ. Each one would compile, pass the
     * arithmetic tests, and silently reintroduce a score that describes the extraction rather
     * than the record it sits on. `score_rawAddressThatDoesNotNormalize_countsAsMissing` is the
     * falsifier for the address leg specifically.
     *
     * TOTAL: null property, null strings, blank strings and whitespace are all handled; nothing
     * here can throw except the explicit test seam.
     *
     * @param property            The property block about to be written to this Lead; null
     *                            yields a NOT-SCORED result.
     * @param propertyAddress     The address about to be written to Lead.Property_Address__c —
     *                            the caller's RESOLVED value, not `property.propertyAddress`;
     *                            may be null.
     * @param listingBrokerName   The listing-broker name about to be written; may be null.
     * @param listingBrokerEmail  The listing-broker email about to be written; may be null.
     * @return A scored Score, or notScored() when there is nothing to score.
     * @throws ExtractionScoreException ONLY when simulateScoreFailure is set by a test.
     * @example
     * ExtractionScoreUtil.Score s = ExtractionScoreUtil.score(
     *     request.property, request.propertyAddress,
     *     request.listingBrokerName, request.listingBrokerEmail);
     * lead.Fields_Captured_Count__c = s.capturedCount;
     */
    public static Score score(
        PropertyExtraction property,
        String propertyAddress,
        String listingBrokerName,
        String listingBrokerEmail
    ) {
        if (simulateScoreFailure) {
            throw new ExtractionScoreException('Simulated extraction-score failure (test seam).');
        }
        // Nothing to score: the LLM-down path (no block at all) and the structurally-empty
        // property object. Null, never zero — see the class header.
        if (property == null || property.hasNoExtractedValues()) {
            return notScored();
        }

        Integer captured = 0;
        // ── the nine keys, in SCORED_KEYS order ──────────────────────────────────────────
        // Kept in the same order as the constant list on purpose: the list is the denominator's
        // definition and this is its evaluation, so a reader can check them off against each
        // other. A key present here and absent there (or vice versa) is the one way the
        // captured count and the denominator can disagree.
        //
        // ⚠ THREE OF THESE READ AN ARGUMENT, NOT `property`. That asymmetry is deliberate and is
        // argued in full above the signature: the argument is what the Lead will carry, and the
        // DTO member is only what the model said. `propertyAddress` is the one that LOOKS like it
        // belongs on the block — it is — and reading it from there was C2.
        captured += counted(String.isNotBlank(property.propertyName));       // property_name
        captured += counted(String.isNotBlank(propertyAddress));             // property_address
        captured += counted(property.guidancePrice != null);                 // guidance_price
        captured += counted(property.capRate != null);                       // guidance_cap_rate
        captured += counted(property.offerDueDate != null);                  // offer_due_date
        captured += counted(String.isNotBlank(property.saleProcess));        // sale_process
        captured += counted(String.isNotBlank(listingBrokerName));           // listing_broker_name
        captured += counted(String.isNotBlank(listingBrokerEmail));          // listing_broker_email
        captured += counted(String.isNotBlank(property.listingStatus));      // listing_status

        return new Score(captured, DENOMINATOR - captured, percentOf(captured), true);
    }

    /**
     * The NOT-SCORED result: three nulls together.
     *
     * Public because the caller's fail-soft catch needs exactly this value, and a second
     * hand-built "all nulls" object in that catch is how the two would drift apart.
     *
     * @return A Score whose three numbers are null and whose isScored is false.
     */
    public static Score notScored() {
        return new Score(null, null, null, false);
    }

    /**
     * captured / DENOMINATOR as a whole percent, HALF_UP.
     *
     * DECIMAL DIVISION, DELIBERATELY. Apex Integer division TRUNCATES, so `captured / 9 * 100`
     * would evaluate to 0 for every score below 9/9 — a silent, total defect that a test using
     * only 0 and 9 would not catch. The tests therefore assert a mid-range value explicitly.
     *
     * @param captured How many keys were supplied, 0..DENOMINATOR.
     * @return 0-100 inclusive.
     */
    private static Integer percentOf(Integer captured) {
        Decimal ratio = Decimal.valueOf(captured) / DENOMINATOR;
        return (ratio * 100).setScale(0, System.RoundingMode.HALF_UP).intValue();
    }

    /**
     * 1 when the key was supplied, 0 when it was not — so the evaluation above reads as the
     * checklist it is, rather than nine if-statements.
     *
     * @param isCaptured Whether the extraction supplied this key.
     * @return 1 or 0.
     */
    private static Integer counted(Boolean isCaptured) {
        return isCaptured ? 1 : 0;
    }
}
