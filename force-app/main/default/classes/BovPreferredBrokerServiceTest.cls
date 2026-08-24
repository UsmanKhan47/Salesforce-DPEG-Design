/**
 * @description Tests `BovPreferredBrokerService` — the retirement of an outgoing PREFERRED broker
 * when a new one is added: log a `BOV_Broker_Change__c` row, THEN delete the submission, atomically.
 * Added 2026-08-24 with the two-slot selection model.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT THIS SUITE IS ACTUALLY DEFENDING, IN ONE SENTENCE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * That a broker who WAS appointed and is now gone still has a record of having been appointed.
 * `BOV_Submission__c` is `<enableHistory>false</enableHistory>` and the row itself is deleted, so
 * the `BOV_Broker_Change__c` row is the ONLY surviving evidence. Every test here that counts
 * history rows is guarding that, not the delete.
 *
 * ⚠ TWO ASSERTIONS ARE NEEDED FOR EVERY RETIREMENT AND NEITHER IMPLIES THE OTHER: "the outgoing row
 * is gone" and "a history row names it". A version that deleted without logging passes the first;
 * a version that logged without deleting passes the second. They are always asserted together.
 *
 * ── FIXTURES ────────────────────────────────────────────────────────────────────────────────
 * ⚠ PREFERRED ROWS HERE ARE UNQUOTED (no `BOV_Amount__c`), which is the NORMAL shape:
 * `BOV_Amount_Required_On_Submission` is `AND(NOT(Is_Preferred_Broker__c), ISBLANK(BOV_Amount__c))`
 * — the exemption exists precisely so a preferred broker can be recorded without a quote. A
 * preferred row that HAPPENED to carry a winning amount would be appointed by the SCORED path too,
 * so a test built on one cannot tell "the flag won" from "the score won".
 * ⚠ `Broker__c` IS LEFT IN PLACE on every row: `Broker_Required_On_Submission` is
 * `ISBLANK(Broker__c)` and got NO preferred exemption, and it is also what keeps `Broker_Firm__c`
 * (and therefore the history row's surviving Text column) non-blank.
 * ⚠ DISPOSITIONS ARE **PRICED** wherever a scored competitor matters — every `TestDataFactory`
 * disposition leaves `Asking_Price__c` blank, so every BOV under one scores null and any test that
 * needs a real scored winner would otherwise exercise the "nothing is scoreable" branch instead.
 *
 * ⚠ HISTORY IS QUERIED DIRECTLY RATHER THAN THROUGH `BovBrokerChangeSelector`, matching
 * `BovSubmissionServiceTest`: a test of the WRITER must not be able to pass because the READER
 * agrees with it. The selector is `WITH USER_MODE` and these queries are `WITH SYSTEM_MODE`.
 *
 * @see force-app/main/default/classes/BovPreferredBrokerService.cls
 * @see force-app/main/default/classes/BovAutoSelectionServiceTest.cls (the slot assertions)
 */
@isTest
private class BovPreferredBrokerServiceTest {

    private static final Integer BULK_N = 251;
    private static final String SELECTED = 'Selected';
    private static final String BACKUP = 'Backup';
    private static final Decimal ASKING_PRICE = 1500000;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    /** A PRICED disposition — the only fixture on which scored competitors are non-null. */
    private static Disposition__c pricedDisposition() {
        Disposition__c d = TestDataFactory.createPricedDisposition(assetId(), ASKING_PRICE, false);
        d.Disposition_Stage__c = 'BOV Outreach';
        insert d;
        return d;
    }

    /** An UNSAVED, UNQUOTED preferred row — the normal shape. See the class header. */
    private static BOV_Submission__c preferredBov(Id dispositionId) {
        BOV_Submission__c s = TestDataFactory.createBovSubmission(dispositionId, false);
        s.Is_Preferred_Broker__c = true;
        s.BOV_Amount__c = null;
        s.Cap_Rate__c = null;
        s.Commission_Rate__c = null;
        s.Days_To_Market__c = null;
        s.Hist_Success_Rate__c = null;
        return s;
    }

    /** An UNSAVED ordinary scored response with an explicit amount. */
    private static BOV_Submission__c scoredBov(Id dispositionId, Decimal amount) {
        BOV_Submission__c s = TestDataFactory.createBovSubmission(dispositionId, false);
        s.BOV_Amount__c = amount;
        return s;
    }

    /**
     * ⚠ `WITH SYSTEM_MODE` IS MANDATORY, NOT BOILERPLATE. `Approval_Pending__c` is granted to
     * NOBODY in this org, so a field with no `FieldPermissions` row anywhere is ABSENT FROM THE
     * RUNNING USER'S SCHEMA and a plain query fails with `No such column`. The same reasoning is
     * recorded at length on `BovAutoSelectionServiceTest.stateOf`; this query does not select that
     * field, but `Is_System_Selected__c` is read-only everywhere and the habit is the safe one.
     */
    private static Map<Id, BOV_Submission__c> stateOf(Id dispositionId) {
        return new Map<Id, BOV_Submission__c>([
            SELECT Id, Submission_Status__c, Is_Preferred_Broker__c, Is_System_Selected__c,
                   Broker__c, Broker_Firm__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH SYSTEM_MODE
        ]);
    }

    private static List<BOV_Broker_Change__c> historyFor(Id dispositionId) {
        return [
            SELECT Id, Outgoing_BOV_Submission__c, Incoming_BOV_Submission__c,
                   Outgoing_Broker__c, Incoming_Broker__c,
                   Outgoing_Broker_Firm__c, Incoming_Broker_Firm__c,
                   Reason__c, Notes__c, Entry_DateTime__c, Logged_By__c
            FROM BOV_Broker_Change__c
            WHERE Disposition__c = :dispositionId
            WITH SYSTEM_MODE
            ORDER BY Entry_DateTime__c DESC, Name DESC
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE CORE BEHAVIOUR — LOG, THEN DELETE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE CENTRAL TEST. Adding a second preferred broker RETIRES the first: the outgoing row is
     * removed from the list AND a history row records the swap.
     */
    @isTest
    static void addingASecondPreferredBroker_retiresTheFirstAndLogsIt() {
        Disposition__c d = pricedDisposition();
        BOV_Submission__c outgoing = preferredBov(d.Id);
        insert outgoing;
        Assert.areEqual(SELECTED, stateOf(d.Id).get(outgoing.Id).Submission_Status__c,
            'precondition: the first preferred broker holds the preferred slot');
        String outgoingFirm = stateOf(d.Id).get(outgoing.Id).Broker_Firm__c;
        Id outgoingBroker = stateOf(d.Id).get(outgoing.Id).Broker__c;

        Test.startTest();
        BOV_Submission__c incoming = preferredBov(d.Id);
        insert incoming;
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = stateOf(d.Id);
        Assert.isNull(after.get(outgoing.Id),
            '🔴 THE OUTGOING PREFERRED ROW IS REMOVED FROM THE LIST. Finding it here — at any '
            + 'status — means the retirement did not run.');
        Assert.areEqual(SELECTED, after.get(incoming.Id).Submission_Status__c,
            'and the new preferred broker holds the slot the outgoing one vacated');
        Assert.isFalse(after.get(incoming.Id).Is_System_Selected__c,
            'without ever being marked as the SYSTEM pick — a preferred broker is a human choice');

        List<BOV_Broker_Change__c> history = historyFor(d.Id);
        Assert.areEqual(1, history.size(),
            '🔴 EXACTLY ONE HISTORY ROW, AND IT IS THE ONLY SURVIVING EVIDENCE THE OUTGOING BROKER '
            + 'WAS EVER APPOINTED. Zero here means a delete that destroyed the record of itself.');
        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 MEASURED 2026-08-24: THE OUTGOING **LOOKUP** IS ALWAYS NULL ON A RETIREMENT ROW, AND
        //    THAT IS WHY THE FIRM TEXT COLUMN IS NOT OPTIONAL. THIS IS THE POINT OF THE FEATURE.
        // ══════════════════════════════════════════════════════════════════════════════════════
        // `Outgoing_BOV_Submission__c` is `deleteConstraint SetNull`, and the row it points at is
        // deleted IN THIS SAME TRANSACTION — so the platform blanks it immediately. The service
        // stamps it anyway (the shared builder does, for the replace path where the row survives),
        // but on this path it can never be read back.
        // ⚠ SO A HISTORY CARD THAT RENDERED ONLY THE LOOKUPS WOULD SHOW AN EMPTY SWAP FOR EVERY
        // PREFERRED-BROKER REPLACEMENT. Asserted as NULL rather than quietly dropped, because "it
        // is null by design" and "nobody stamped it" look identical in a green suite.
        Assert.isNull(history[0].Outgoing_BOV_Submission__c,
            '🔴 THE OUTGOING LOOKUP IS EXPECTED TO BE NULL — SetNull blanked it when the submission '
            + 'was deleted. If this ever returns an Id the delete did not happen, which is a much '
            + 'bigger problem than the assertion.');
        Assert.areEqual(incoming.Id, history[0].Incoming_BOV_Submission__c,
            'and the incoming lookup names the replacement');
        Assert.areEqual(outgoingFirm, history[0].Outgoing_Broker_Firm__c,
            '🔴 THE FIRM SNAPSHOT IS WHAT MAKES THE CARD READABLE AFTER THE ROW IS GONE.');
        Assert.areEqual(outgoingBroker, history[0].Outgoing_Broker__c,
            '🔴 the outgoing BROKER CONTACT lookup DOES survive — it points at a Contact, not at '
            + 'the deleted submission — so between it and the firm Text the card can still name who '
            + 'was replaced');
        Assert.areEqual(BovPreferredBrokerService.REASON_PREFERRED_REPLACED, history[0].Reason__c,
            'the reason is the restricted-picklist value the service names — asserted against the '
            + 'CONSTANT, not a second hand-typed copy, so a change has one place to fail');
        Assert.isTrue(history[0].Notes__c.contains('preferred broker'),
            '🔴 AND THE NOTES SAY IT WAS A PREFERRED BROKER. This is DATA, not decoration: the '
            + 'object has no type column, and the row that carried Is_Preferred_Broker__c has just '
            + 'been deleted, so this sentence is the only place the Broker Replace History card can '
            + 'learn what kind of swap this was.');
        Assert.areEqual(UserInfo.getUserId(), history[0].Logged_By__c,
            'and the actor is recorded');
        Assert.isNotNull(history[0].Entry_DateTime__c, 'and the time');
    }

    /**
     * 🔴 THE FIRST PREFERRED BROKER ON A SALE IS NOT A REPLACEMENT. Nothing is deleted and NO
     * history row is written — inventing a first-appointment row here would put two rows in the
     * card for one event (`BovSubmissionService.replaceSelectedBroker` owns the
     * `Initial Appointment` log for the appointed slot).
     */
    @isTest
    static void theFirstPreferredBroker_retiresNothingAndLogsNothing() {
        Disposition__c d = pricedDisposition();
        BOV_Submission__c scored = scoredBov(d.Id, 1400000);
        insert scored;

        Test.startTest();
        BOV_Submission__c preferred = preferredBov(d.Id);
        insert preferred;
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = stateOf(d.Id);
        Assert.areEqual(2, after.size(),
            'nothing was deleted — a first preferred broker replaces nobody');
        Assert.areEqual(SELECTED, after.get(preferred.Id).Submission_Status__c,
            'the preferred slot is filled');
        Assert.areEqual(SELECTED, after.get(scored.Id).Submission_Status__c,
            '🔴 AND THE SCORED WINNER IS UNTOUCHED. The retirement must never reach across slots — '
            + 'a scored response is not a preferred broker being replaced.');
        Assert.areEqual(0, historyFor(d.Id).size(),
            'and NO history row: there was no swap to record');
    }

    /**
     * 🔴 AN ORDINARY (NON-PREFERRED) SUBMISSION MUST COST NOTHING. The zero-query fast path is what
     * keeps this service invisible to every other feature's tests, and it is the difference between
     * a keyed service and one that re-runs on every save.
     */
    @isTest
    static void anOrdinarySubmissionInsert_costsNoQueriesAndRetiresNothing() {
        Disposition__c d = pricedDisposition();
        BOV_Submission__c preferred = preferredBov(d.Id);
        insert preferred;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovPreferredBrokerService.retireReplacedPreferred(
            new List<BOV_Submission__c>{ scoredBov(d.Id, 1000000) }, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            '🔴 ZERO QUERIES. A chunk in which no row became preferred must return BEFORE the '
            + 'selector call. Queries used: ' + queriesUsed);
        Assert.isNotNull(stateOf(d.Id).get(preferred.Id),
            'and the existing preferred broker is untouched');
        Assert.areEqual(0, historyFor(d.Id).size(), 'and nothing is logged');
    }

    /**
     * THE UPDATE HALF: flagging an EXISTING response as preferred is a replacement too.
     * `Is_Preferred_Broker__c` is granted EDIT on `DPEG_Disposition_Edit`, so this path is reachable
     * from a list view or the API even though the modal only ever inserts.
     */
    @isTest
    static void flaggingAnExistingResponseAsPreferred_retiresTheIncumbentPreferredBroker() {
        Disposition__c d = pricedDisposition();
        BOV_Submission__c outgoing = preferredBov(d.Id);
        BOV_Submission__c candidate = scoredBov(d.Id, 900000);
        // ⚠ `strong` EXISTS SO THAT `candidate` IS **NOT** SELECTED. A candidate that already held
        // the appointed slot would exercise a different path entirely —
        // `surrenderSlotOnFlagChange`, which drops it to Backup before the guard sees it — and the
        // retirement below would be riding on that instead of on the flag change itself. Two
        // separate behaviours, two separate tests; this one is the plain flag-a-Backup-row case.
        BOV_Submission__c strong = scoredBov(d.Id, 1400000);
        insert new List<BOV_Submission__c>{ outgoing, candidate, strong };
        Map<Id, BOV_Submission__c> setup = stateOf(d.Id);
        Assert.areEqual(SELECTED, setup.get(outgoing.Id).Submission_Status__c,
            'precondition: the incumbent preferred broker holds the preferred slot');
        Assert.areEqual(BACKUP, setup.get(candidate.Id).Submission_Status__c,
            'precondition: and the row about to be flagged holds NO slot');

        Test.startTest();
        update new BOV_Submission__c(Id = candidate.Id, Is_Preferred_Broker__c = true);
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = stateOf(d.Id);
        Assert.isNull(after.get(outgoing.Id),
            '🔴 The incumbent is retired on the UPDATE path too. Without the update hook this sale '
            + 'would sit outside the one-preferred-broker invariant with no error anywhere.');
        Assert.areEqual(SELECTED, after.get(candidate.Id).Submission_Status__c,
            'and the newly-flagged row takes the slot');
        Assert.areEqual(1, historyFor(d.Id).size(), 'with the swap recorded');
    }

    /**
     * ⚠ AN ORDINARY SAVE OF AN ALREADY-PREFERRED ROW MUST NOT RETIRE ANYTHING. The trigger key is
     * "BECAME preferred", not "IS preferred" — and the difference is catastrophic exactly once, on
     * the first save after a data load that left two preferred rows: a row a user was merely
     * editing would silently delete its sibling.
     */
    @isTest
    static void resavingAnAlreadyPreferredRow_retiresNothing() {
        Disposition__c d = pricedDisposition();
        BOV_Submission__c olderPreferred = preferredBov(d.Id);
        insert olderPreferred;
        // ⚠ THE UNDELETE GAP IS THE ONLY WAY TO BUILD "TWO PREFERRED ROWS AT REST", because this
        // very service normally prevents it. That is what makes the claim below falsifiable: if the
        // key were "IS preferred" rather than "BECAME preferred", the ordinary save at the bottom
        // would find two rows and silently delete one of them.
        delete olderPreferred;
        BOV_Submission__c current = preferredBov(d.Id);
        insert current;
        undelete olderPreferred;
        Assert.areEqual(2, stateOf(d.Id).size(),
            'PREMISE: two preferred rows exist. If BovSubmissionTrigger ever gains an '
            + 'after-undelete context this line fails FIRST and says why.');

        Test.startTest();
        // An ordinary edit that touches NEITHER the preferred flag NOR any auto-selection change
        // key — the shape of a user correcting a typo on a row they had nothing to do with.
        update new BOV_Submission__c(Id = current.Id, Hist_Success_Rate__c = 55);
        Test.stopTest();

        Assert.areEqual(2, stateOf(d.Id).size(),
            '🔴 NOTHING WAS RETIRED. The trigger key is "BECAME preferred", not "IS preferred" — '
            + 'and this is the save on which the difference is catastrophic: a user editing one row '
            + 'would have silently deleted the other.');
        Assert.areEqual(0, historyFor(d.Id).size(),
            'and nothing was logged, because nothing was replaced');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE SEQUENCE — THE DELETE MUST NOT FIGHT AUTO-SELECTION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 NO INTERIM WINNER. The delete of the outgoing preferred row fires `after delete` ->
     * `BovAutoSelectionService.reselectForDeleted`, which re-ranks the sale. Because the replacement
     * row is ALREADY COMMITTED by then, the preferred slot is filled by the new preferred broker and
     * never by a scored response.
     *
     * ⚠ THE FALSIFIER IS THE **PREFERRED SLOT**, NOT THE COUNT. A scored response IS legitimately
     * Selected here (the appointed slot), so counting Selected rows proves nothing. What would fail
     * under the delete-then-insert sequence is the preferred slot being empty, or held by the
     * scored row.
     */
    @isTest
    static void replacingThePreferredBroker_neverPromotesAnInterimWinner() {
        Disposition__c d = pricedDisposition();
        BOV_Submission__c scored = scoredBov(d.Id, 1400000);
        BOV_Submission__c outgoing = preferredBov(d.Id);
        insert new List<BOV_Submission__c>{ scored, outgoing };

        Test.startTest();
        BOV_Submission__c incoming = preferredBov(d.Id);
        insert incoming;
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = stateOf(d.Id);
        Assert.isNull(after.get(outgoing.Id), 'the outgoing preferred row is gone');
        Assert.areEqual(SELECTED, after.get(incoming.Id).Submission_Status__c,
            '🔴 THE PREFERRED SLOT IS HELD BY THE NEW PREFERRED BROKER, NOT BY A SCORED RESPONSE '
            + 'PROMOTED INTO THE GAP. A Backup here means the after-delete re-rank ran while the '
            + 'slot was genuinely empty — i.e. the retirement happened before the replacement '
            + 'existed.');
        Assert.isTrue(after.get(incoming.Id).Is_Preferred_Broker__c,
            'stated explicitly: the row holding the slot is the PREFERRED one');
        Assert.areEqual(SELECTED, after.get(scored.Id).Submission_Status__c,
            'and the scored winner keeps its own slot throughout — it was never a candidate for '
            + 'the preferred one');
        Assert.isTrue(after.get(scored.Id).Is_System_Selected__c,
            'carrying the system flag, which is what the approval router reads');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 ATOMICITY — THE ONE OUTCOME THIS CLASS MUST MAKE UNREACHABLE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IF THE HISTORY ROW CANNOT BE WRITTEN, THE SUBMISSION IS NOT DELETED. FULL STOP.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * This is the test the whole class is shaped around. A delete that succeeds while the log fails
     * destroys the ONLY record that the broker was ever appointed — `BOV_Submission__c` is
     * `enableHistory false`, and the row itself is gone, so there is nothing in field history and
     * nothing a report can read.
     *
     * ── THE REFUSAL IS A REAL ONE, NOT A MOCK ─────────────────────────────────────────────────
     * `BOV_Broker_Change__c.Outgoing_Broker__c` carries an ACTIVE, NON-OPTIONAL lookup filter on
     * the `Contact.Broker` RECORD TYPE, which the platform enforces on Apex DML. Moving the
     * outgoing broker's Contact onto the `Investor` record type therefore makes the history insert
     * — and ONLY the history insert — impossible. `BovSubmissionService.replaceSelectedBroker`'s
     * header names this same refusal path for the same reason; it is the one production-reachable
     * way this write fails without stubbing anything.
     *
     * ⚠ IT IS ALSO WHY THE ORDER IS LOG-THEN-DELETE RATHER THAN DELETE-THEN-LOG. Under the reverse
     * order this exact fixture would leave the submission deleted and unlogged, and the savepoint
     * would be the only thing standing between the org and a permanent hole in the record.
     *
     * ⚠ THE USER'S OWN SAVE IS ROLLED BACK TOO, AND THAT IS THE INTENDED ANSWER. Swallowing the
     * failure would commit "Add Preferred Broker" with TWO preferred rows on the sale and no record
     * of the swap — a state that looks like success in the UI. Refusing the click leaves the
     * previous preferred broker intact and the action re-attemptable once the Contact is fixed.
     */
    @isTest
    static void aRefusedHistoryInsert_rollsBackAndLeavesTheSubmissionAlive() {
        Disposition__c d = pricedDisposition();

        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 THE OUTGOING ROW NEEDS ITS **OWN** BROKER CONTACT. MEASURED THE HARD WAY 2026-08-24.
        // ══════════════════════════════════════════════════════════════════════════════════════
        // `TestDataFactory.createBovSubmission` (the singular overload) REUSES ONE CACHED broker
        // Contact for the whole transaction — its own header says so. The first version of this
        // fixture moved "the outgoing row's Contact" onto the Investor record type and thereby
        // moved the SHARED one, so the REPLACEMENT row's own insert was refused by
        // `BOV_Submission__c.Broker__c`'s identical lookup filter and the retirement never ran at
        // all. The test still went through its catch block and still asserted the submission had
        // survived, because a save that never happened leaves everything exactly as it was:
        // **A PERFECTLY GREEN-LOOKING TEST OF NOTHING.** Only `lastRunRetirementFailures` being
        // empty gave it away — which is precisely why that assertion is in this test.
        Contact outgoingBroker = TestDataFactory.createBrokerContactWithFirm('CBRE - Outgoing', true);
        BOV_Submission__c outgoing = preferredBov(d.Id);
        outgoing.Broker__c = outgoingBroker.Id;
        insert outgoing;
        Assert.areEqual(SELECTED, stateOf(d.Id).get(outgoing.Id).Submission_Status__c,
            'precondition: the outgoing preferred broker holds the slot');

        // Move ONLY that Contact off the Broker record type — the one thing that makes the history
        // row un-writable while leaving every other save in this test legal.
        Id investorRt = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Contact' AND DeveloperName = 'Investor' LIMIT 1
        ].Id;
        update new Contact(Id = outgoingBroker.Id, RecordTypeId = investorRt);

        Test.startTest();
        Boolean refused = false;
        BOV_Submission__c replacement = preferredBov(d.Id); // the SHARED, still-valid broker Contact
        Assert.areNotEqual(outgoingBroker.Id, replacement.Broker__c,
            '🔴 FIXTURE PRECONDITION: the replacement must NOT share the Contact that was just '
            + 'invalidated, or its own insert is refused and the retirement never runs — see the '
            + 'block above for the green-and-vacuous version of this test.');
        try {
            insert replacement;
            Assert.fail('The retirement must refuse the save rather than delete without logging');
        } catch (DmlException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused,
            '🔴 The Add Preferred Broker save must FAIL. Succeeding here means the retirement '
            + 'swallowed the refusal, which is the silent half-swap the savepoint exists to '
            + 'prevent.');
        Assert.isNotNull(stateOf(d.Id).get(outgoing.Id),
            '🔴 AND THE OUTGOING SUBMISSION IS STILL THERE. This is the assertion the whole class '
            + 'is built around: a delete that outlives its own history row destroys the only '
            + 'evidence the broker was ever appointed.');
        Assert.areEqual(SELECTED, stateOf(d.Id).get(outgoing.Id).Submission_Status__c,
            'still holding its slot, exactly as before the refused click');
        Assert.areEqual(0, historyFor(d.Id).size(),
            'and no half-written history row survives the rollback either');
        Assert.isFalse(BovPreferredBrokerService.lastRunRetirementFailures.isEmpty(),
            '🔴 THE REFUSAL IS REPORTED, NOT SWALLOWED. allOrNone = true leaves no failed '
            + 'SaveResults to inspect, so this list is the ONLY place the platform StatusCode is '
            + 'ever visible. An empty list means the catch block was removed or reordered.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SHARING — THE ROW BEING DESTROYED USUALLY BELONGS TO SOMEBODY ELSE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE FALSIFIER FOR `RetirementWrites`' `without sharing` ESCAPE, on a `Minimum Access`
     * persona who can SEE the outgoing row and cannot EDIT or DELETE it.
     *
     * ⚠ THE PERSONA'S BASE PROFILE MATTERS. `TestDataFactory.createNonOwnerDispositionApprover`
     * builds a `Minimum Access - Salesforce` user carrying the real `DPEG_Disposition_View` set —
     * `viewAllRecords = true`, no `modifyAllRecords`, no `allowDelete`. That combination is the
     * trap: the selector read RETURNS the row and the delete is then refused. A `Standard User`
     * base profile would grant enough by itself to mask the whole thing.
     *
     * ⚠ THE CONTROL IS `lastRunRetirementFailures` BEING EMPTY. Without it, removing the escape
     * would fail with an opaque "expected null, was a record" instead of the actual platform
     * StatusCode.
     */
    @isTest
    static void nonOwnerSaver_retiresAnUnownedPreferredRowAcrossTheSharingBoundary() {
        Disposition__c d = pricedDisposition();
        BOV_Submission__c outgoing = preferredBov(d.Id);   // stays with the ADMIN
        // ⚠ `strong` KEEPS `candidate` OFF THE APPOINTED SLOT, so the flag change below is the
        // only thing driving the retirement.
        BOV_Submission__c candidate = scoredBov(d.Id, 900000);
        BOV_Submission__c strong = scoredBov(d.Id, 1400000);
        insert new List<BOV_Submission__c>{ outgoing, candidate, strong };

        User saver = TestDataFactory.createNonOwnerDispositionApprover('bpb1');
        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 THE SAVER **UPDATES** AN EXISTING ROW; IT DOES NOT INSERT ONE. MEASURED 2026-08-24.
        // ══════════════════════════════════════════════════════════════════════════════════════
        // An insert was tried first and failed with
        // `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY ... 003...` — the broker CONTACT.
        // `Broker_Required_On_Submission` makes every row carry one, `TestDataFactory` creates it
        // with no Account, and an Account-less Contact is visible only to its OWNER whatever the
        // Contact OWD says. So the fixture would have failed on the CONTACT lookup before ever
        // reaching the sharing question this test is about. Transferring one existing row and
        // updating it is the shape `BovAutoSelectionServiceTest`'s non-owner tests already use, and
        // it exercises the identical write.
        update new BOV_Submission__c(Id = candidate.Id, OwnerId = saver.Id);

        System.runAs(saver) {
            Test.startTest();
            Database.update(
                new BOV_Submission__c(Id = candidate.Id, Is_Preferred_Broker__c = true),
                AccessLevel.SYSTEM_MODE);
            Test.stopTest();
        }

        Assert.areEqual(new List<String>(),
            BovPreferredBrokerService.lastRunRetirementFailures,
            '🔴 THE RETIREMENT WAS REFUSED — read the StatusCode above. '
            + 'INSUFFICIENT_ACCESS_OR_READONLY means the `without sharing` escape on '
            + 'RetirementWrites has been removed, or SYSTEM_MODE was assumed to cover sharing. It '
            + 'does not: ARCHITECTURE.md §2 — SYSTEM_MODE bypasses CRUD/FLS ONLY.');
        Assert.isNull(stateOf(d.Id).get(outgoing.Id),
            'the ADMIN-owned outgoing preferred row was deleted by a user who owns neither it nor '
            + 'the disposition — and who is granted no allowDelete on the object either, which is '
            + 'the CRUD half that SYSTEM_MODE covers and sharing is not');
        Assert.areEqual(SELECTED, stateOf(d.Id).get(candidate.Id).Submission_Status__c,
            'and the saver-owned row took the vacated preferred slot');
        Assert.areEqual(1, historyFor(d.Id).size(),
            'and the history row was written by that same user, on an object whose fields carry no '
            + 'permissions for anybody');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BULK — `.claude/rules/bulk-test-rule.md`
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 251 PREFERRED ROWS ACROSS TWO DISPOSITIONS — the bulk rule applied to the retirement path
     * itself, and the proof that the cost is CONSTANT PER CHUNK rather than per record.
     *
     * ⚠ 251 preferred rows on one sale is 250 successive replacements, which is a real (if
     * pathological) data-load shape. The end state is ONE surviving row per disposition and one
     * history row per retirement; the budget is what stops that being 500 DML statements.
     */
    @isTest
    static void bulk251PreferredRows_retireAtConstantCostPerChunk() {
        Disposition__c a = pricedDisposition();
        Disposition__c b = pricedDisposition();
        List<BOV_Submission__c> rows = new List<BOV_Submission__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            rows.add(preferredBov(Math.mod(i, 2) == 0 ? a.Id : b.Id));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert rows; // 251 rows -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(dmlUsed <= 9,
            '🔴 CONSTANT PER CHUNK, NOT PER RECORD, AND IT COVERS BOTH DISPOSITIONS AT ONCE. ONE '
            + 'for the insert plus at most FOUR per chunk (retirement history insert, retirement '
            + 'delete, the delete-cascade re-rank, the selection write). A per-disposition or '
            + 'per-record write would read in the hundreds and exhaust the 150-statement limit. '
            + 'DML used: ' + dmlUsed);
        Assert.isTrue(queriesUsed <= 12,
            'and the query budget is per chunk too. Queries used: ' + queriesUsed);

        for (Disposition__c d : new List<Disposition__c>{ a, b }) {
            List<BOV_Submission__c> survivors = new List<BOV_Submission__c>(
                stateOf(d.Id).values());
            Assert.areEqual(1, survivors.size(),
                'EXACTLY ONE preferred row survives on ' + d.Id + ' — every other one was replaced '
                + 'by the next, across both chunks');
            Assert.areEqual(SELECTED, survivors[0].Submission_Status__c,
                'and it holds the preferred slot');
        }
        Assert.areEqual(BULK_N - 2, [
            SELECT COUNT() FROM BOV_Broker_Change__c
            WHERE Disposition__c IN (:a.Id, :b.Id)
        ], '🔴 ONE HISTORY ROW PER RETIREMENT — 251 rows, two survivors, 249 retirements. A lower '
            + 'count means one chunk deleted without logging, which is the exact failure this '
            + 'feature exists to make impossible.');
    }

    /**
     * NULL / EMPTY INPUT MUST COST NOTHING AND THROW NOTHING — the trigger calls this on every
     * insert and update of the object in the org.
     */
    @isTest
    static void nullAndEmptyInput_returnWithoutQueryingOrThrowing() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovPreferredBrokerService.retireReplacedPreferred(null, null);
        BovPreferredBrokerService.retireReplacedPreferred(new List<BOV_Submission__c>(), null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'Null and empty inputs must cost ZERO queries. Used: ' + queriesUsed);
    }

    /**
     * A PREFERRED ROW WITH NO PARENT HAS NO SIBLINGS, so there is nothing to retire and nothing to
     * query. `Disposition__c` is not required on the object, so this shape is reachable.
     */
    @isTest
    static void aPreferredRowWithNoDisposition_isIgnoredAtZeroCost() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovPreferredBrokerService.retireReplacedPreferred(
            new List<BOV_Submission__c>{ new BOV_Submission__c(Is_Preferred_Broker__c = true) },
            null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A parentless preferred row must not reach the selector. Queries used: ' + queriesUsed);
    }
}
