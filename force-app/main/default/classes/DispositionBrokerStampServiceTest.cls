/**
 * @description Tests DispositionBrokerStampService.stampSelectedBrokerLabel — the off-market
 * broker lookup (design §1.5 / §1.6, added 2026-08-20).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE 251-RECORD MANDATE APPLIES IN FULL — NO EXEMPTION. Recorded here per the service's
 * own class header instruction so review does not have to re-derive it. This is a trigger
 * path (DispositionTriggerHandler.beforeInsert / beforeUpdate) that loops over a collection.
 * The per-transaction-singleton exemption DispositionApprovalServiceTest legitimately claims
 * does NOT apply here, and neither does the ContentPublication carve-out (no content object
 * is involved). See bulkInsert251WithBroker_allStampedThroughTheRealTrigger and
 * bulk251BrokerChanges_costsExactlyOneQueryForTheWholeChunk below.
 * ─────────────────────────────────────────────────────────────────────────────────────
 *
 * ── WHY SOME TESTS CALL THE SERVICE DIRECTLY INSTEAD OF GOING THROUGH insert/update ──
 * The precise "exactly 1 query for 251 changed records" claim is only measurable in isolation:
 * a real 251-row insert/update also fires DispositionStageEntryService and
 * DispositionApprovalAdvanceService in the same trigger, so a query count taken around a real
 * DML statement would include their cost too and could not falsify a regression in THIS
 * service specifically. This mirrors DispositionStageEntryServiceTest's own split between a
 * "251 records through the REAL trigger" test and a "costs exactly N direct-invocation" test —
 * see that class's suppressionPathCostsOneQueryAndNoDmlAt251 for the identical shape.
 *
 * ── EXPECTED-LABEL ARITHMETIC (do not query Contact.Name back — compose it locally) ──
 * Every helper below builds the expected label as `FirstName + ' ' + LastName + SEPARATOR +
 * Broker_Firm__c` rather than re-querying the Contact for its compound `Name` field. `Name` is
 * NOT reliably populated on an in-memory sObject immediately after insert (compound/formula
 * fields need a re-query), but `FirstName`/`LastName` are the literal fields the fixture set,
 * and English-locale `Name` is exactly `FirstName + ' ' + LastName` — the same assumption the
 * service's own class header uses for its 121-character `Name` ceiling.
 *
 * @see force-app/main/default/classes/DispositionBrokerStampService.cls
 * @see force-app/main/default/classes/ContactSelector.cls (selectBrokerLabelsByIds)
 * @see force-app/main/default/classes/DispositionTriggerHandler.cls (the only caller)
 * @author Unit Testing Agent
 */
@isTest
private class DispositionBrokerStampServiceTest {

    private static final Integer BULK_N = 251;

    private static Id assetId() {
        return TestDataFactory.defaultPropertyAsset().Id;
    }

    /** Name + separator + firm, per design §1.5 — composed from literal fields, never re-queried. */
    private static String labelOf(Contact broker) {
        String name = broker.FirstName + ' ' + broker.LastName;
        return String.isBlank(broker.Broker_Firm__c)
            ? name
            : name + DispositionBrokerStampService.SEPARATOR + broker.Broker_Firm__c;
    }

    /** Null/empty-safe per the method's own ApexDoc ("Null/empty-safe"). */
    @isTest
    static void stampSelectedBrokerLabel_nullOrEmptyList_returnsWithoutError() {
        Boolean completedWithoutThrowing = false;

        Test.startTest();
        DispositionBrokerStampService.stampSelectedBrokerLabel(null, null);
        DispositionBrokerStampService.stampSelectedBrokerLabel(new List<Disposition__c>(), null);
        completedWithoutThrowing = true; // reached only if neither call above threw
        Test.stopTest();

        // 🔴 code review Suggestion 3: `Assert.isTrue(true, ...)` was a non-assertion — it always
        // passes regardless of what the two calls above did. The REAL assertion this test makes is
        // "did not throw", so that fact is captured in a flag set only after both calls return, and
        // asserted here rather than left implicit.
        Assert.isTrue(completedWithoutThrowing,
            'Both calls must return without throwing — the guard is a no-op, not an error');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 1 — Broker__c SET, Contact resolves
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void insertWithBroker_stampsNameDashFirm() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        String expected = labelOf(broker);
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        d.Broker__c = broker.Id;

        Test.startTest();
        insert d;
        Test.stopTest();

        Disposition__c after = [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.areEqual(expected, after.Selected_Broker__c,
            'Insert with Broker__c set must stamp Name + " - " + Broker_Firm__c');
    }

    @isTest
    static void insertWithBroker_blankFirm_stampsBareNameNoTrailingSeparator() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.Broker_Firm__c = null;
        insert broker;
        String expected = broker.FirstName + ' ' + broker.LastName;
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        d.Broker__c = broker.Id;

        Test.startTest();
        insert d;
        Test.stopTest();

        Disposition__c after = [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.areEqual(expected, after.Selected_Broker__c,
            'A blank Broker_Firm__c must yield the bare Name — no dangling separator, which '
            + 'would read as truncation on the approval page');
    }

    @isTest
    static void updateBrokerChangeFromAToB_restamps() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(2, null, true);
        Contact brokerA = brokers[0];
        Contact brokerB = brokers[1];
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        d.Broker__c = brokerA.Id;
        insert d;

        Test.startTest();
        d.Broker__c = brokerB.Id;
        update d;
        Test.stopTest();

        Disposition__c after = [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.areEqual(labelOf(brokerB), after.Selected_Broker__c,
            'Changing Broker__c from A to B must RE-STAMP to B — A\'s stale label must not survive');
    }

    /**
     * Maximum-length case (design §1.5's length proof, made real rather than merely argued):
     * FirstName 40 + space + LastName 80 = Name 121; separator 3; Broker_Firm__c 120.
     * 121 + 3 + 120 = 244 <= 255 (Selected_Broker__c's width) — saves untruncated.
     */
    @isTest
    static void maxLengthLabel244Chars_savesUntruncated() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.FirstName = 'F'.repeat(40);
        broker.LastName = 'L'.repeat(80);
        broker.Broker_Firm__c = 'B'.repeat(120);
        insert broker;
        String expected = labelOf(broker);
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        d.Broker__c = broker.Id;

        Test.startTest();
        insert d;
        Test.stopTest();

        Disposition__c after = [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.areEqual(244, expected.length(),
            'Sanity check on the service header\'s own arithmetic: 40 + 1 + 80 + 3 + 120 = 244');
        Assert.areEqual(expected, after.Selected_Broker__c,
            'The full 244-character label must save without truncation — no left(255) exists or is needed');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 2 — Broker__c CLEARED to null
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void updateClearsBrokerToNull_nullsSelectedBrokerTextInTheSameSave() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        d.Broker__c = broker.Id;
        insert d;
        Disposition__c before = [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.isNotNull(before.Selected_Broker__c, 'Precondition: the insert must have stamped a label');

        Test.startTest();
        d.Broker__c = null;
        update d;
        Test.stopTest();

        Disposition__c after = [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.isNull(after.Selected_Broker__c,
            'Clearing Broker__c must null Selected_Broker__c IN THE SAME SAVE — a stale name left '
            + 'behind would put a broker on the approval page and Path step for a disposition that '
            + 'has none');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 3 — Broker__c UNCHANGED — the on-market regression guard
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE MOST VALUABLE TEST IN THIS CLASS. Simulates the on-market chain
     * (BovSubmissionTriggerHandler / BovSubmissionService), which stamps Selected_Broker__c
     * directly and NEVER touches Broker__c. If this service were fill-if-blank, or keyed on
     * anything other than Broker__c changing, it would fight that writer and this test would
     * fail. See the service's own class header, "WHY THIS CANNOT COLLIDE WITH THE ON-MARKET
     * WRITERS".
     */
    @isTest
    static void updateThatDoesNotTouchBroker_leavesSelectedBrokerTextUnchanged() {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        // Broker__c stays null throughout — only off-market rows expose the lookup on the page.

        Test.startTest();
        d.Selected_Broker__c = 'CBRE - Principal Approved'; // the on-market writer's own stamp
        update d; // touches Selected_Broker__c only; Broker__c is null before AND after
        Test.stopTest();

        Disposition__c after = [SELECT Broker__c, Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.isNull(after.Broker__c, 'Broker__c was never touched by this save');
        Assert.areEqual('CBRE - Principal Approved', after.Selected_Broker__c,
            'A write to Selected_Broker__c that does not change Broker__c must survive UNTOUCHED — '
            + 'this is what stops the off-market stamp from fighting the on-market writer');
    }

    /**
     * 🔴 ADDED code review W4, 2026-08-20. `updateThatDoesNotTouchBroker_leavesSelectedBrokerTextUnchanged`
     * above falsifies an UNCONDITIONAL-CLEAR implementation (one that blanks `Selected_Broker__c`
     * whenever `Broker__c` is null) but does nothing to falsify the more likely simplification —
     * keying the "should I stamp?" test on `d.Broker__c != null` instead of on `d.Broker__c` having
     * CHANGED. Both of that test's records leave `Broker__c` null on both sides, so a `!= null`
     * variant would skip them too and this test class would go green while the class header's
     * central budget claim ("a chunk in which no record changed `Broker__c` costs ZERO queries",
     * `DispositionBrokerStampService.cls:72-75`) silently became false for every non-null-broker
     * update in the org — which, since this trigger fires on every `Disposition__c` write, is most
     * of them.
     *
     * This test closes that gap: `Broker__c` is NON-NULL and UNCHANGED across the simulated update,
     * while `Selected_Broker__c` is hand-set to a literal that does NOT match the broker's derived
     * label in the same save — mirroring the on-market collision scenario above, but for the
     * (structurally unreachable today, per the class header's "WHERE THEY WOULD COLLIDE" note)
     * off-market case of a broker being unchanged while the text field is independently touched.
     *
     * Direct invocation (see class header "WHY SOME TESTS CALL THE SERVICE DIRECTLY") so the query
     * count is isolated to this service alone.
     *
     * Would this test fail under an `if (d.Broker__c != null) { stamp }` variant? YES, on BOTH
     * assertions: `d.Broker__c` is non-null, so that variant adds this record to `changed`, issues
     * the Contact query (queriesUsed becomes 1, not 0), and PASS 2 then overwrites the hand-set
     * literal with the broker's freshly-resolved derived label (which does not equal the literal),
     * failing the survival assertion too. That is what makes this a real falsifier rather than a
     * restatement of the test above it.
     */
    @isTest
    static void updateWithBrokerUnchangedNonNull_handSetTextSurvivesAndCostsZeroQueries() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, true);
        String handSetLiteral = 'Hand-Set Literal Distinct From The Derived Label';

        // Simulated before-update trigger context: Broker__c is the SAME non-null Contact on both
        // sides (unchanged), while Selected_Broker__c is independently touched in the same save —
        // the exact shape the real implementation's `d.Broker__c == priorBroker` skip must catch.
        Disposition__c newRow = new Disposition__c(
            Id = d.Id, Broker__c = broker.Id, Selected_Broker__c = handSetLiteral);
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>{
            d.Id => new Disposition__c(Id = d.Id, Broker__c = broker.Id)
        };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionBrokerStampService.stampSelectedBrokerLabel(new List<Disposition__c>{ newRow }, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(handSetLiteral, newRow.Selected_Broker__c,
            'An unchanged non-null Broker__c must leave the record SKIPPED — the hand-set literal '
            + 'must survive untouched, not be overwritten with the broker\'s derived label');
        Assert.areEqual(0, queriesUsed,
            'An unchanged non-null Broker__c must cost ZERO queries — a `!= null` change-key would '
            + 'query here and this assertion is what catches that regression');
    }

    /** The common-case cost proof: an insert naming no broker touches nothing. */
    @isTest
    static void insertWithoutBroker_costsZeroQueriesAndLeavesTextNull() {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        // Broker__c left null; Id is also null (never inserted) — matches the true insert shape.
        List<Disposition__c> newList = new List<Disposition__c>{ d };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionBrokerStampService.stampSelectedBrokerLabel(newList, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'An insert naming no broker is the overwhelmingly common case and must cost ZERO queries');
        Assert.isNull(d.Selected_Broker__c, 'No broker set means no stamp');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 4 — Broker__c SET, Contact does NOT resolve
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Direct invocation, not real DML: the active, non-optional lookup filter on
     * `Disposition__c.Broker__c` would refuse an actual save pointed at a deleted Contact, so this
     * outcome can only be exercised in-memory, as if the Contact vanished between the pick and a
     * save that was already in flight (the sharing/deletion/no-Name cases the service's own
     * ApexDoc treats identically).
     */
    @isTest
    static void brokerSetButContactUnresolvable_leavesSelectedBrokerTextUnchanged() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Id deletedBrokerId = broker.Id;
        delete broker;
        Disposition__c holder = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, true);

        Disposition__c newRow = new Disposition__c(
            Id = holder.Id, Broker__c = deletedBrokerId, Selected_Broker__c = 'Stale Prior Label');
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>{
            holder.Id => new Disposition__c(Id = holder.Id, Broker__c = null)
        };

        Test.startTest();
        DispositionBrokerStampService.stampSelectedBrokerLabel(new List<Disposition__c>{ newRow }, oldMap);
        Test.stopTest();

        Assert.areEqual('Stale Prior Label', newRow.Selected_Broker__c,
            'An unresolvable Contact must leave Selected_Broker__c UNCHANGED, not blanked — '
            + 'blanking is the more destructive direction and a stale string next to a visible '
            + 'lookup is self-healing on the next successful save');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BULK — 251 records. .claude/rules/bulk-test-rule.md applies IN FULL; no exemption.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 251 forces a SECOND trigger chunk (chunks are 200) — a service that queried per record
     * would blow the SOQL limit long before finishing, so COMPLETING this test at all is part of
     * the falsifier. All 251 real, inserted rows must carry the derived label.
     */
    @isTest
    static void bulkInsert251WithBroker_allStampedThroughTheRealTrigger() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        String expected = labelOf(broker);
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        for (Disposition__c d : dispositions) {
            d.Broker__c = broker.Id;
        }

        Test.startTest();
        insert dispositions;
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :dispositions AND Selected_Broker__c = :expected],
            'Every one of the 251 dispositions inserted with Broker__c set must be stamped — 251 '
            + 'spans TWO trigger chunks, so a total below 251 means a chunk was dropped');
    }

    /**
     * 🔴 THE GOVERNOR ASSERTION. The property being pinned is COST INDEPENDENT OF RECORD COUNT:
     * exactly one query for 251 records whose Broker__c all just changed. A future change that
     * moved the Contact read inside the per-record loop would report 251 here (or fail outright
     * well before 251), which is the entire reason this number is 251 and not some smaller value.
     *
     * Invoked DIRECTLY (see class header) so the measurement is isolated to this service alone —
     * no chunking, no sibling automation (stage-entry, the approval semaphore) inflating the count.
     */
    @isTest
    static void bulk251BrokerChanges_costsExactlyOneQueryForTheWholeChunk() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        String expected = labelOf(broker);
        List<Disposition__c> baseline = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, true);

        // A synthetic trigger context: every record's Broker__c just changed from null to the
        // SAME broker Contact (one distinct Id — still must cost exactly one query, not zero and
        // not 251; see selectBrokerLabelsByIds's own bulk proof for the "many distinct Ids" half).
        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : baseline) {
            newList.add(new Disposition__c(Id = d.Id, Broker__c = broker.Id));
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Broker__c = null));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionBrokerStampService.stampSelectedBrokerLabel(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Integer stampedCount = 0;
        for (Disposition__c d : newList) {
            if (expected.equals(d.Selected_Broker__c)) {
                stampedCount++;
            }
        }

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 changed records — the Contact read is issued once for the '
            + 'whole chunk. Anything above 1 means it moved into the per-record loop.');
        Assert.areEqual(BULK_N, stampedCount,
            'All 251 in-memory records must be stamped with the same derived label');
    }

    /**
     * The other half of the constant-cost claim: a chunk in which nothing changed costs NOTHING,
     * even at 251 records — mirrors DispositionStageEntryServiceTest.
     * aSaveThatDoesNotChangeTheStageCostsNothingAt251's identical shape for the sibling
     * before-context stamp.
     */
    @isTest
    static void bulk251NoRecordChangesBroker_costsNothing() {
        List<Disposition__c> baseline = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, true);

        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : baseline) {
            // Every record is "saved" with a field OTHER than Broker__c changing.
            newList.add(new Disposition__c(Id = d.Id, Broker__c = null, Gross_Sale_Proceeds__c = 5000000));
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Broker__c = null));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionBrokerStampService.stampSelectedBrokerLabel(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A save where no record\'s Broker__c changed must cost ZERO queries even at 251 — '
            + 'this trigger fires on every Disposition write in the org');
    }
}
