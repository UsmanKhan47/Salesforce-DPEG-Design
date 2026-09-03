/**
 * Tests for `TransactionStageDomain` - the pure stage-order functions the stage-advancement gate
 * (`TransactionStageGateService`, design `agent-output/design-checklist-cutover-and-stage-gate.md`
 * Part B) depends on to tell forward from backward.
 *
 * layer=test. ZERO SOQL and ZERO DML anywhere in this class except the two N14 cross-check
 * methods, which each perform exactly the one read their own name promises (a describe call is not
 * SOQL). Every other method under test is a pure function over primitives, and Domain Purity
 * (`.claude/rules/apex-layering-rule.md`) means a test needing a database read for anything else
 * would already be testing the wrong class.
 *
 * =============================================================================================
 * N14 - THE CROSS-CHECK. THIS IS THE ONLY THING STANDING BETWEEN A THIRD COPY OF THE STAGE ORDER
 * AND A SILENTLY INVERTED GATE. Read `TransactionStageDomain`'s class header ("THIS IS THE THIRD
 * COPY...") before touching either method below. If this test is ever deleted or weakened, nothing
 * else in the repo would notice `TransactionStageDomain`'s order drifting from either of the other
 * two sources it is pinned against.
 * =============================================================================================
 */
@isTest
private class TransactionStageDomainTest {

    @isTest
    static void stageOrderReturnsTheFiveStagesInAuthoredOrder() {
        List<String> order = TransactionStageDomain.stageOrder();

        Assert.areEqual(
            new List<String>{
                'Open Contract', 'Due Diligence', 'Closing Prep', 'Post-Closing', 'Closed'
            },
            order,
            'The five stages, byte-identical including the hyphen in Post-Closing, in authored order');
    }

    @isTest
    static void stageOrderReturnsADefensiveCopy() {
        List<String> first = TransactionStageDomain.stageOrder();
        first.clear();

        Assert.areEqual(5, TransactionStageDomain.stageOrder().size(),
            'Mutating the returned list must not mutate the backing order - a public static List '
                + 'mutable by every caller in the transaction would not be a gate');
    }

    /**
     * N14, HALF 1. Walks `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE` end to end from the
     * known first stage and compares the walk to `TransactionStageDomain.stageOrder()`.
     *
     * THE SINGLE REVERT THAT TURNS THIS RED: reorder `TransactionStageDomain.ORDER` (e.g. swap
     * `STAGE_CLOSING_PREP` and `STAGE_POST_CLOSING`) without touching
     * `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE`. The walk below is built from the MAP, not
     * copied from a literal, so it cannot be fooled by editing both files identically.
     */
    @isTest
    static void n14_agreesWithRecordStageAdvanceServicesMap() {
        List<String> walked = new List<String>{ 'Open Contract' };
        String current = 'Open Contract';
        while (RecordStageAdvanceService.TRANSACTION_NEXT_STAGE.containsKey(current)) {
            current = RecordStageAdvanceService.TRANSACTION_NEXT_STAGE.get(current);
            walked.add(current);
        }

        Assert.areEqual(walked, TransactionStageDomain.stageOrder(),
            'TransactionStageDomain must agree with RecordStageAdvanceService.TRANSACTION_NEXT_STAGE '
                + 'walked end to end, or the gate and the four Move_to_* quick actions disagree '
                + 'about what "forward" means on the same object');
    }

    /**
     * N14, HALF 2. Compares against the ACTIVE `Transaction__c.Stage__c` describe values, in their
     * authored order (the field is `restricted=true`, `sorted=false`, so authored order is real
     * order per `TransactionStageDomain`'s own header).
     *
     * THE SINGLE REVERT THAT TURNS THIS RED: re-order the `<value>` elements in
     * `objects/Transaction__c/fields/Stage__c.field-meta.xml` (a Setup picklist re-order has the
     * identical effect in a live org) without updating `TransactionStageDomain.ORDER` to match.
     */
    @isTest
    static void n14_agreesWithTheActivePicklistDescribeOrder() {
        List<String> activeValues = new List<String>();
        for (Schema.PicklistEntry entry : Transaction__c.Stage__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                activeValues.add(entry.getValue());
            }
        }

        Assert.areEqual(activeValues, TransactionStageDomain.stageOrder(),
            'TransactionStageDomain must agree with the ACTIVE Transaction__c.Stage__c describe '
                + 'values in their authored order, or a re-order in Setup silently inverts the gate '
                + 'with nothing going red until this test catches it');
    }

    @isTest
    static void ordinalOfResolvesEveryKnownStage() {
        Assert.areEqual(0, TransactionStageDomain.ordinalOf('Open Contract'), 'Open Contract = 0');
        Assert.areEqual(1, TransactionStageDomain.ordinalOf('Due Diligence'), 'Due Diligence = 1');
        Assert.areEqual(2, TransactionStageDomain.ordinalOf('Closing Prep'), 'Closing Prep = 2');
        Assert.areEqual(3, TransactionStageDomain.ordinalOf('Post-Closing'), 'Post-Closing = 3');
        Assert.areEqual(4, TransactionStageDomain.ordinalOf('Closed'), 'Closed = 4');
    }

    @isTest
    static void ordinalOfReturnsNullForUnrecognisedNullBlankAndCaseVariant() {
        Assert.isNull(TransactionStageDomain.ordinalOf('Not A Real Stage'),
            'An unrecognised value must resolve to null, never to a guessed position');
        Assert.isNull(TransactionStageDomain.ordinalOf(null), 'null must be null-safe, not zero');
        Assert.isNull(TransactionStageDomain.ordinalOf(''), 'blank must be null-safe, not zero');
        Assert.isNull(TransactionStageDomain.ordinalOf('post-closing'),
            'Map lookups are case-sensitive - a case variant must not resolve. A restricted '
                + 'picklist cannot store one, so a case mismatch means the caller invented the '
                + 'value, and an invented value must not be trusted to be ordered correctly');
    }

    @isTest
    static void isKnownDistinguishesRecognisedFromUnrecognised() {
        Assert.isTrue(TransactionStageDomain.isKnown('Closed'), 'A recognised terminal stage');
        Assert.isFalse(TransactionStageDomain.isKnown('Not A Real Stage'), 'An invented value');
        Assert.isFalse(TransactionStageDomain.isKnown(null), 'null is not known');
    }

    /**
     * THE SINGLE REVERT THAT TURNS THIS RED: change `isForward` to compare stage LABELS instead of
     * ordinals (e.g. a naive `nextStage > priorStage` string comparison), which would silently
     * invert on any stage whose label does not alphabetically follow its predecessor.
     */
    @isTest
    static void isForwardTrueOnlyForARecognisedForwardMove() {
        Assert.isTrue(TransactionStageDomain.isForward('Open Contract', 'Due Diligence'),
            'Adjacent forward move');
        Assert.isTrue(TransactionStageDomain.isForward('Open Contract', 'Closed'),
            'A SKIP is still forward - Data Loader and the API can produce one and design B2.3 says '
                + 'the gate must still have an opinion, even though RecordStageAdvanceService.advance '
                + 'itself can never produce a skip (no explicit-target allow-list for this object)');
        Assert.isFalse(TransactionStageDomain.isForward('Due Diligence', 'Open Contract'),
            'Backward move must not be forward');
        Assert.isFalse(TransactionStageDomain.isForward('Open Contract', 'Open Contract'),
            'Lateral / unchanged must not be forward');
        Assert.isFalse(TransactionStageDomain.isForward('Not A Real Stage', 'Due Diligence'),
            'Unrecognised prior must fail open, not throw and not guess a position');
        Assert.isFalse(TransactionStageDomain.isForward('Open Contract', 'Not A Real Stage'),
            'Unrecognised next must fail open too');
        Assert.isFalse(TransactionStageDomain.isForward(null, 'Due Diligence'),
            'null prior must fail open - an insert has no prior stage and must never gate');
        Assert.isFalse(TransactionStageDomain.isForward('Open Contract', null),
            'null next must fail open too');
    }

    @isTest
    static void coordinateOfFormatsGroupLetterAndTruncatedSequence() {
        Assert.areEqual('B2', TransactionStageDomain.coordinateOf('B', 2),
            'Group letter plus sequence, no separator');
        Assert.areEqual('H25', TransactionStageDomain.coordinateOf('H2', 5),
            'Group H2 sequence 5 becomes H25 - the documented, deliberate divergence from the '
                + 'design doc\'s illustrative H2:5. Unambiguous because group H2 holds 5 items and '
                + 'group H holds 5, so H25 cannot collide with H item 25');
        Assert.areEqual('B2', TransactionStageDomain.coordinateOf('b', 2),
            'Group letter must be upper-cased regardless of input case');
        Assert.areEqual('A2', TransactionStageDomain.coordinateOf('A', 2.9),
            'A Decimal sequence must be TRUNCATED with intValue(), not rounded - 2.9 becomes 2, '
                + 'not 3. A caller that rounded here would occasionally print a coordinate that '
                + 'does not exist on the real record');
    }

    @isTest
    static void coordinateOfDegradesToNullOnEitherHalfMissing() {
        Assert.isNull(TransactionStageDomain.coordinateOf(null, 2), 'null group letter -> null');
        Assert.isNull(TransactionStageDomain.coordinateOf('', 2), 'blank group letter -> null');
        Assert.isNull(TransactionStageDomain.coordinateOf('B', null), 'null sequence -> null');
    }
}
