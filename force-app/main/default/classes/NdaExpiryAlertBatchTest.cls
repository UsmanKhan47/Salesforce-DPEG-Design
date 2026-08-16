/**
 * Tests for `NdaExpiryAlertBatch` — the daily NDA expiry reminder.
 *
 * ── WHAT CAN AND CANNOT BE ASSERTED HERE ────────────────────────────────────
 * 🔴 **A CUSTOM NOTIFICATION CANNOT BE QUERIED IN APEX.** There is no SObject for a delivered
 * notification, so no test in this org can assert that the `Acquisition` queue received anything.
 * `GroupNotifier` carries a `@TestVisible sentCount` static for exactly this reason. What these
 * tests assert instead is the thing that IS observable and IS the design: **the two marker
 * fields**, which are the durable record of what was reminded and the whole mechanism by which a
 * reminder happens once rather than daily.
 *
 * 🔴 **AND THE `without sharing` HALVES CANNOT BE FALSIFIED HERE EITHER — SAYING SO IS PART OF THE
 * COVERAGE.** `NDA__c` is Private OWD with no acquisition sharing rule, but every row these tests
 * create is owned by the running user, and `System.runAs` does not change the ownership of rows
 * created outside its block. Reproducing "a row owned by somebody else, read by a principal with no
 * `viewAllRecords` grant" needs a second real user on a real profile, which this suite cannot
 * guarantee. Both escapes (`NdaSelector.ExpiryAlertReads` for the read,
 * `NdaExpiryAlertBatch.MarkerWrites` for the write) are therefore argued at their declarations and
 * verified by post-deploy gate G2, not pretended to be tested. If they were ever removed, EVERY
 * test in this class would still pass and the job would silently do nothing in production — which
 * is precisely why G2 exists.
 *
 * ── 🔴 WHY MOST TESTS CALL `execute()` DIRECTLY INSTEAD OF `Database.executeBatch` ──────────
 * In a test context a batch does not run when it is submitted — it runs at `Test.stopTest()`. So
 * TWO passes with a data change in between (yesterday's run, then today's) is **unexpressible**
 * through `Database.executeBatch`: both submissions would queue and then run back-to-back at
 * `stopTest`, after every data change had already been made, and the test would silently measure
 * something else entirely. Every sequencing test therefore drives `execute(null, scope)` directly,
 * synchronously, which is the same code path the framework calls.
 *
 * `Database.executeBatch` is still used where the LOCATOR's WIRING is the thing under test — that
 * `start()` returns the real query and that its ORDERING fills the chunk — because that is the half
 * a direct `execute` call skips.
 *
 * ⚠ AMENDED 2026-08-16 (code review S1): this used to say "the LOCATOR ... its ceiling, its filters
 * and its ordering". **A batch test cannot prove the ceiling or the filters**, and claiming it can
 * is how `alertBatchAt251NdasIsBulkSafe` came to carry a proof it could not deliver. A test method
 * executes exactly ONE chunk, so anything the `ORDER BY` sorts past row 200 is unobservable here
 * whether the locator excluded it or merely deferred it. The ceiling and every filter are owned by
 * `NdaSelectorTest`, which reads the locator directly — see
 * `queryExpiryAlerts_appliesTheCeilingButDeliberatelyNoFloor` and its five sibling
 * `queryExpiryAlerts_ignores*` methods. One owner per fact.
 *
 * ⚠ GOVERNOR / OUTCOME COUNTERS are asserted on the batch's own `chunk*` statics, captured INSIDE
 * the transaction. `Test.stopTest()` RESTORES the pre-test governor counters, so a `Limits.*`
 * assertion after it is silently vacuous (the `ExtractAddressQueueable.lastRunQueryCount`
 * precedent). The batch's INSTANCE fields cannot be read at all: `Database.Stateful` serialises the
 * object, so the instance the test handed to `Database.executeBatch` is not the instance that ran.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies (this is a batch) and is met with
 * NO exemption claimed — the per-transaction-singleton exemption was read and does not apply, since
 * `execute` is handed a whole chunk. Note exactly what 251 proves: a test method executes only ONE
 * chunk, so at `SCOPE = 200` a 251-row fixture proves the LOCATOR selects, filters and orders 251
 * rows and that a full 200-row chunk behaves. It does not drive two `execute()` calls, and no test
 * can.
 * ⚠ `.claude/rules/content-publication-rule.md` does not apply: nothing in this feature creates a
 * `ContentVersion`, a `ContentNote` or a `ContentDocument`.
 */
@isTest
private class NdaExpiryAlertBatchTest {

    private static final Integer BULK_N = 251;

    /** The field set the locator produces, so a direct `execute()` call gets the same shape. */
    private static List<NDA__c> scopeFor(Set<Id> ndaIds) {
        return [
            SELECT Id, Name, Opportunity__c, Counterparty_Name__c, Status__c,
                   NDA_Expiry_Date__c, NDA_Alert_Last_Interval__c, NDA_Alert_Expiry_Date__c
            FROM NDA__c
            WHERE Id IN :ndaIds
            ORDER BY NDA_Expiry_Date__c ASC, Id ASC
        ];
    }

    private static List<NDA__c> scopeFor(Id ndaId) {
        return scopeFor(new Set<Id>{ ndaId });
    }

    /** Load an NDA's two marker fields back from the database. */
    private static NDA__c marker(Id ndaId) {
        return [
            SELECT Id, NDA_Expiry_Date__c, NDA_Alert_Last_Interval__c, NDA_Alert_Expiry_Date__c
            FROM NDA__c WHERE Id = :ndaId
        ];
    }

    /**
     * One SIGNED acquisition NDA expiring `days` from today, with a blank marker.
     *
     * ⚠ Creating the Opportunity also auto-creates one NDA (`OpportunityReviewService.ensureNda`),
     * at `Pending` with NO expiry date — so it is invisible to the locator on two separate counts
     * and never disturbs these assertions.
     */
    private static NDA__c signedNdaExpiringIn(Integer days) {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createSignedNdas(1, opp.Id, false)[0];
        nda.NDA_Expiry_Date__c = Date.today().addDays(days);
        nda.Counterparty_Name__c = 'Acme Holdings LLC';
        insert nda;
        return nda;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE MARKER — what is stamped, and when
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void anNdaInsideTheLadderIsRemindedAndMarked() {
        NDA__c nda = signedNdaExpiringIn(3);

        Test.startTest();
        new NdaExpiryAlertBatch().execute(null, scopeFor(nda.Id));
        Test.stopTest();

        NDA__c after = marker(nda.Id);
        Assert.areEqual(5, after.NDA_Alert_Last_Interval__c,
            'Three days out sits in the 5 rung, and that rung is what gets stamped');
        Assert.areEqual(nda.NDA_Expiry_Date__c, after.NDA_Alert_Expiry_Date__c,
            'and the SNAPSHOT of the expiry it was computed against — without this a later '
            + 'extension can never re-arm the ladder');
        Assert.areEqual(1, NdaExpiryAlertBatch.chunkNotified, 'One notification went out');
        Assert.areEqual(1, NdaExpiryAlertBatch.chunkStamped, 'and one marker was written');
        Assert.areEqual(1, NdaExpiryAlertBatch.chunkDmlStatements,
            'in ONE DML statement — the claim is constancy, not the row count');
    }

    @isTest
    static void aSecondRunOnTheSameDayIsAGenuineNoOp() {
        // 🔴 THE FAILURE THE WHOLE MARKER DESIGN EXISTS TO PREVENT: "the team gets the same
        // reminder every day and stops reading them". Asserted on ZERO SENDS, not merely on the
        // marker being unchanged — an implementation that re-sent and re-stamped the SAME value
        // would leave the marker identical and pass a weaker test.
        NDA__c nda = signedNdaExpiringIn(3);
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        Test.startTest();
        batch.execute(null, scopeFor(nda.Id));
        Integer sentAfterFirstPass = GroupNotifier.sentCount;
        batch.execute(null, scopeFor(nda.Id));
        Test.stopTest();

        Assert.areEqual(0, NdaExpiryAlertBatch.chunkOwed,
            'The second pass must decide nothing is owed');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkNotified, 'so it sends nothing');
        Assert.areEqual(sentAfterFirstPass, GroupNotifier.sentCount,
            'and the notifier is never even reached');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkDmlStatements,
            'and it issues NO DML at all — that is what makes a daily job on a quiet pipeline free');
        Assert.areEqual(5, marker(nda.Id).NDA_Alert_Last_Interval__c, 'The marker is unchanged');
    }

    @isTest
    static void eachRungFiresExactlyOnceAsTheExpiryApproaches() {
        NDA__c nda = signedNdaExpiringIn(5);
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        Test.startTest();
        // Day one: five days out -> the 5 rung.
        batch.execute(null, scopeFor(nda.Id));
        Assert.areEqual(5, marker(nda.Id).NDA_Alert_Last_Interval__c, 'the 5 rung fires first');

        // The clock cannot be moved, so move the DATE instead — and move the SNAPSHOT with it, so
        // this test measures the rung ladder rather than accidentally measuring the re-arm rule
        // (which has its own test below).
        NDA__c reDated = new NDA__c(
            Id = nda.Id,
            NDA_Expiry_Date__c = Date.today().addDays(2),
            NDA_Alert_Expiry_Date__c = Date.today().addDays(2)
        );
        update reDated;

        batch.execute(null, scopeFor(nda.Id));
        Test.stopTest();

        Assert.areEqual(2, marker(nda.Id).NDA_Alert_Last_Interval__c,
            'then the 2 rung — strictly smaller, so exactly two reminders per expiry date');
    }

    /**
     * 🔴 THE END-TO-END FALSIFIER FOR DROPPING `NDA_Alert_Expiry_Date__c`. `NdaExpiryServiceTest`
     * pins the pure rule; this pins that the batch actually WRITES the snapshot and actually reads
     * it back. Without the field this NDA is reminded about twice and then never again, silently.
     */
    @isTest
    static void extendingTheExpiryReArmsTheWholeLadder() {
        NDA__c nda = signedNdaExpiringIn(1);
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        Test.startTest();
        batch.execute(null, scopeFor(nda.Id));
        Assert.areEqual(2, marker(nda.Id).NDA_Alert_Last_Interval__c,
            'one day out fires the smallest rung, after which nothing smaller exists');

        // The counterparty asks for an extension and someone edits the date. Nothing about that
        // edit knows this feature exists — which is the whole point of the snapshot.
        update new NDA__c(Id = nda.Id, NDA_Expiry_Date__c = Date.today().addDays(4));

        batch.execute(null, scopeFor(nda.Id));
        Test.stopTest();

        NDA__c after = marker(nda.Id);
        Assert.areEqual(5, after.NDA_Alert_Last_Interval__c,
            '🔴 The moved expiry re-arms the ladder and the 5 rung fires again. Delete the '
            + 'snapshot field and this assertion becomes FALSE and stays false, permanently and '
            + 'silently, on exactly the NDAs someone cared enough about to extend');
        Assert.areEqual(Date.today().addDays(4), after.NDA_Alert_Expiry_Date__c,
            'and the snapshot moves to the new expiry');
    }

    @isTest
    static void anAlreadyExpiredNdaGetsExactlyOneCatchUpReminder() {
        // The locator deliberately has NO FLOOR, and this is why that is safe: an NDA whose expiry
        // passed before it was ever reminded about genuinely is owed its one reminder, and the
        // monotone marker is what stops it becoming a daily one.
        NDA__c nda = signedNdaExpiringIn(-30);
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        Test.startTest();
        batch.execute(null, scopeFor(nda.Id));
        Integer firstPassNotified = NdaExpiryAlertBatch.chunkNotified;
        batch.execute(null, scopeFor(nda.Id));
        Test.stopTest();

        Assert.areEqual(1, firstPassNotified, 'The overdue NDA is reminded about once');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkNotified, 'and never again');
        Assert.areEqual(2, marker(nda.Id).NDA_Alert_Last_Interval__c,
            'it sits in the smallest rung, which is terminal');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 🔴 SEND FIRST, STAMP SECOND
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE BRANCH THAT `GroupNotifier.notifyWithOutcome` EXISTS FOR. A notification is not
     * transactional, so stamping a marker for a reminder that never went out loses it FOREVER and
     * SILENTLY. Pointing `RECIPIENT_GROUP` at a group that does not exist is the only way to make
     * a send fail on demand — which is why that static is deliberately not `final`.
     */
    @isTest
    static void aFailedSendIsNotStampedSoTheReminderIsRetriedTomorrow() {
        NDA__c nda = signedNdaExpiringIn(3);
        String realGroup = NdaExpiryAlertBatch.RECIPIENT_GROUP;
        NdaExpiryAlertBatch.RECIPIENT_GROUP = 'A_Group_That_Does_Not_Exist';

        Test.startTest();
        new NdaExpiryAlertBatch().execute(null, scopeFor(nda.Id));
        Test.stopTest();
        NdaExpiryAlertBatch.RECIPIENT_GROUP = realGroup;

        Assert.areEqual(1, NdaExpiryAlertBatch.chunkOwed, 'The reminder was owed');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkNotified, 'but nothing was sent');
        Assert.areEqual(1, NdaExpiryAlertBatch.chunkSendFailures, 'the failure is counted');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkStamped, 'and NOTHING was stamped');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkDmlStatements,
            'no DML statement is even issued when every send failed');
        Assert.isNull(marker(nda.Id).NDA_Alert_Last_Interval__c,
            '🔴 The marker stays blank, so tomorrow\'s pass reminds again. Stamp-then-send would '
            + 'have left a marker claiming a reminder that never happened');
    }

    /**
     * 🔴 THE OTHER HALF OF SEND-THEN-STAMP, AND A DIFFERENT FAILURE SHAPE FROM THE DUPLICATE-Id
     * TEST BELOW. `aChunkWhoseWorkFailsIsFailSoftAndDoesNotAbortTheRun` forces a WHOLE-STATEMENT
     * failure (duplicate Id), which the outer `catch` in `execute` swallows before the per-row
     * `Database.SaveResult` loop inside `stampMarkers` is ever reached. This test forces the
     * PER-ROW failure that loop exists to report: delete the NDA out from under its own pending
     * marker write, so `Database.update(toStamp, false, AccessLevel.SYSTEM_MODE)` returns one
     * FAILED `SaveResult` rather than throwing.
     *
     * The reminder must still have gone out — `GroupNotifier.notifyWithOutcome` ran while the NDA
     * still existed — and it is this exact gap (sent but not marked) the class header §2 names as
     * NOISY-not-silent: the NDA re-reminds on the next pass rather than being lost forever.
     */
    @isTest
    static void aStampThatFailsIsSentButNotMarkedRatherThanThrowing() {
        NDA__c nda = signedNdaExpiringIn(2);
        List<NDA__c> scope = scopeFor(nda.Id);
        delete nda;

        Test.startTest();
        // Must NOT throw out of execute() — the fail-soft catch exists so one bad row cannot take
        // the whole chunk down, and a batch has no Finalizer to report it otherwise.
        new NdaExpiryAlertBatch().execute(null, scope);
        Test.stopTest();

        Assert.areEqual(1, NdaExpiryAlertBatch.chunkOwed, 'the reminder was still owed');
        Assert.areEqual(1, NdaExpiryAlertBatch.chunkNotified,
            'and SENT — the NDA still existed when GroupNotifier.notifyWithOutcome ran');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkStamped,
            'but the marker write failed because the NDA no longer exists, and the failure is '
            + 'COUNTED rather than silently assumed successful');
        Assert.areEqual(1, NdaExpiryAlertBatch.chunkDmlStatements,
            'one DML statement was still issued for this chunk — it simply failed for this row');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GUARDS, BUDGET AND FAIL-SOFT
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void nullAndEmptyScopesAreSafeAndCostNothing() {
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        Test.startTest();
        batch.execute(null, null);
        batch.execute(null, new List<NDA__c>());
        Test.stopTest();

        Assert.areEqual(0, NdaExpiryAlertBatch.chunkEvaluated, 'Nothing is evaluated');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkDmlStatements, 'and no DML is issued');
    }

    @isTest
    static void aChunkOwingNothingCostsZeroDmlAndZeroNotifications() {
        // Every NDA in the chunk is outside the ladder. This is the ordinary shape of a quiet day,
        // and zero-of-everything is what makes running the job daily free.
        NDA__c far = signedNdaExpiringIn(90);
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        Test.startTest();
        Integer sentBefore = GroupNotifier.sentCount;
        batch.execute(null, scopeFor(far.Id));
        Test.stopTest();

        Assert.areEqual(1, NdaExpiryAlertBatch.chunkEvaluated, 'It was looked at');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkOwed, 'but nothing is owed 90 days out');
        Assert.areEqual(sentBefore, GroupNotifier.sentCount, 'so nothing is sent');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkDmlStatements, 'and no DML is issued');
        Assert.isNull(marker(far.Id).NDA_Alert_Last_Interval__c, 'and no marker is written');
    }

    @isTest
    static void aNullRowInTheChunkIsSkippedRatherThanKillingTheChunk() {
        NDA__c nda = signedNdaExpiringIn(2);
        List<NDA__c> scope = scopeFor(nda.Id);
        scope.add(null);

        Test.startTest();
        new NdaExpiryAlertBatch().execute(null, scope);
        Test.stopTest();

        Assert.areEqual(1, NdaExpiryAlertBatch.chunkEvaluated,
            'The null row is skipped without being counted');
        Assert.areEqual(2, marker(nda.Id).NDA_Alert_Last_Interval__c,
            'and its real neighbour is still processed');
    }

    @isTest
    static void aChunkWhoseWorkFailsIsFailSoftAndDoesNotAbortTheRun() {
        // 🔴 A BATCH HAS NO FINALIZER, so a failure inside `execute` is recorded in the chunk's own
        // catch or nowhere. This drives the shape ARCHITECTURE.md records as the sharpest one: the
        // SAME Id twice in one `Database.update`, which throws `DUPLICATE_VALUE` for the WHOLE
        // statement — and `allOrNone = false` does NOT rescue it (measured for
        // `CallForOffersStampService`, which merges by Id for exactly this reason).
        //
        // ⚠ THE ASSERTIONS ARE DELIBERATELY THE ONES THAT HOLD WHICHEVER WAY THE PLATFORM
        // RESOLVES IT. What must be true either way is that the chunk does not take the run down
        // with it and that the NDAs stay in the locator for the next pass. The exact
        // throw-versus-partial-failure behaviour is a platform property this suite must not pin, and
        // pretending to would be worse than saying so.
        NDA__c original = signedNdaExpiringIn(2);
        List<NDA__c> scope = scopeFor(original.Id);
        scope.add((NDA__c) scope[0].clone(true, true, true, true)); // same Id, same values

        Test.startTest();
        // Must NOT throw out of execute() — the fail-soft catch is what stops one bad chunk
        // aborting the remaining ones.
        new NdaExpiryAlertBatch().execute(null, scope);
        Test.stopTest();

        Assert.areEqual(2, NdaExpiryAlertBatch.chunkEvaluated,
            'Both rows were evaluated before anything failed');
        Assert.areEqual(2, NdaExpiryAlertBatch.chunkOwed, 'and both were judged owed a reminder');
        // The NDA is either unmarked (the statement threw and the catch ran) or marked (a partial
        // success). It must never be left in a state that makes the run stop, which is what the
        // absence of an escaping exception above proves.
        Assert.isNotNull(marker(original.Id).Id, 'and the NDA still exists, still in the locator');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE LOCATOR, END TO END — and the 251-row bulk mandate
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * 251 signed acquisition NDAs inside the ladder, driven through the REAL locator.
     *
     * `.claude/rules/bulk-test-rule.md`, no exemption claimed. ⚠ What 251 proves here is the
     * LOCATOR — that it selects, filters and orders 251 rows and that a full 200-row chunk
     * behaves. A test method executes only ONE chunk, so this does NOT drive two `execute()`
     * calls, and no test can.
     *
     * ⚠ They share ONE parent Opportunity on purpose: 251 Opportunities would cost 251 auto-created
     * NDAs and 251 `Primary_NDA__c` stamps in the fixture, which measures the fixture rather than
     * this job. The discriminator under test is `Opportunity__c != NULL`, not which deal it points
     * at.
     */
    @isTest
    static void alertBatchAt251NdasIsBulkSafe() {
        // 251 NDAs: 200 inside the ladder (they must remind), 51 past the ceiling (they must not).
        //
        // ⚠ THIS FIXTURE DOES **NOT** PROVE THE LOCATOR'S CEILING, AND THE COMMENT HERE USED TO
        // CLAIM IT DID — corrected 2026-08-16 (code review S1). The retracted claim, verbatim:
        // "🔴 MIXING BOTH POPULATIONS IS WHAT PROVES THE LOCATOR'S CEILING AND THE IN-MEMORY LADDER
        // AGREE — a fixture of 251 identical NDAs would pass even with no ceiling at all."
        // It cannot: the locator is `ORDER BY NDA_Expiry_Date__c ASC`, so the 51 past-ceiling rows
        // ALWAYS sort last, and a test method runs exactly ONE chunk (SCOPE = 200). Delete the
        // `NDA_Expiry_Date__c <= :ceiling` predicate entirely and this method still passes, with
        // every assertion below returning the identical number — the 51 rows would simply sit in a
        // second chunk that never executes. A comment asserting a proof the fixture cannot deliver
        // is worse than no comment, because it stops the next reader looking for the real one.
        //
        // 🔴 THE REAL FALSIFIER FOR THE CEILING IS
        // `NdaSelectorTest.queryExpiryAlerts_appliesTheCeilingButDeliberatelyNoFloor`, which reads
        // the locator directly and so is not masked by chunking. THERE IS NO COVERAGE GAP HERE;
        // there was only a misattributed one. Do not "strengthen" this fixture to chase the
        // ceiling — one owner per fact.
        //
        // What the two populations DO buy is cheap and worth keeping: they make the 200/251 split
        // in the assertions meaningful (the ordering is what fills the chunk with exactly the
        // in-ladder rows), so an ORDER BY regression shows up here as a wrong `chunkOwed`.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        List<NDA__c> ndas = TestDataFactory.createSignedNdas(BULK_N, opp.Id, false);
        for (Integer i = 0; i < ndas.size(); i++) {
            ndas[i].NDA_Expiry_Date__c = (i < 200)
                ? Date.today().addDays(Math.mod(i, 6))   // 0-5 days out: inside the ladder
                : Date.today().addDays(20 + i);          // well past the TODAY+5 ceiling
        }
        insert ndas;

        Test.startTest();
        Database.executeBatch(new NdaExpiryAlertBatch(), NdaExpiryAlertBatch.SCOPE);
        Test.stopTest();

        // ⚠ The locator orders by expiry ASCENDING, so the 200 in-ladder rows sort first and fill
        // exactly one SCOPE = 200 chunk. A test method runs ONE chunk, so that chunk is what is
        // measured — see the class header. This is what 251 proves here, and it is not "251 rows
        // were processed".
        Assert.areEqual(200, NdaExpiryAlertBatch.chunkEvaluated,
            'One chunk is exactly SCOPE rows');
        Assert.areEqual(200, NdaExpiryAlertBatch.chunkOwed,
            'and every one of them is inside the ladder and owed its first reminder');
        Assert.areEqual(200, NdaExpiryAlertBatch.chunkNotified, 'all sent');
        Assert.areEqual(200, NdaExpiryAlertBatch.chunkStamped,
            'and all stamped in ONE bulk DML — a per-record update would blow the 150-statement '
            + 'limit long before reaching 200');
        Assert.areEqual(1, NdaExpiryAlertBatch.chunkDmlStatements,
            'ONE statement for 200 rows: the constancy is the claim');

        Assert.areEqual(200,
            [SELECT COUNT() FROM NDA__c WHERE NDA_Alert_Last_Interval__c != NULL],
            'Exactly the chunk that ran is marked, and nothing outside it. ⚠ This does NOT prove '
            + 'the locator\'s ceiling — the 51 remaining rows are unmarked because they sorted into '
            + 'a second chunk no test method executes, which is equally true if the ceiling is '
            + 'removed. See this method\'s header; the ceiling is owned by NdaSelectorTest');
        Assert.areEqual(200,
            [SELECT COUNT() FROM NDA__c WHERE NDA_Alert_Expiry_Date__c != NULL],
            'and every marked row carries its snapshot — the two fields are written together or '
            + 'the re-arm rule silently stops working');
    }

    @isTest
    static void aSecondFullPassAt251StampsNothingNewAndSendsNothing() {
        // Idempotency at volume. If the marker rule regressed, a daily job would send 251
        // notifications every single day — the failure mode the design names in words.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        List<NDA__c> ndas = TestDataFactory.createSignedNdas(BULK_N, opp.Id, false);
        for (NDA__c nda : ndas) {
            nda.NDA_Expiry_Date__c = Date.today().addDays(4);
        }
        insert ndas;
        Set<Id> ndaIds = new Map<Id, NDA__c>(ndas).keySet();
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        // ⚠ BOTH passes run INSIDE start/stop, deliberately: `Test.startTest()` resets the governor
        // counters, so putting the expensive first pass outside it would spend the fixture's CPU
        // budget on 251 notifications and make this test flaky for a reason unrelated to what it
        // measures. Two sequential direct `execute()` calls are also the only way to express
        // "yesterday's run, then today's" — see the class header.
        Test.startTest();
        batch.execute(null, scopeFor(ndaIds));
        Assert.areEqual(BULK_N, NdaExpiryAlertBatch.chunkStamped,
            'PRECONDITION: the first pass reminds and marks all 251');
        Integer sentBefore = GroupNotifier.sentCount;
        batch.execute(null, scopeFor(ndaIds));
        Test.stopTest();

        Assert.areEqual(0, NdaExpiryAlertBatch.chunkOwed, 'Nothing is owed on the second pass');
        Assert.areEqual(sentBefore, GroupNotifier.sentCount, 'so not one notification is sent');
        Assert.areEqual(0, NdaExpiryAlertBatch.chunkDmlStatements, 'and no DML is issued');
    }

    @isTest
    static void finishSummarisesWithoutThrowing() {
        // `finish` is a debug line by design — the durable record lives on the marker fields, which
        // are queryable and reportable, unlike a static or a log line. This covers it and pins that
        // it is side-effect free.
        NdaExpiryAlertBatch batch = new NdaExpiryAlertBatch();

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        batch.finish(null);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, dmlUsed, 'finish() writes nothing');
    }

    @isTest
    static void scopeIsTheInheritedCallForOffersValue() {
        // 🔴 THE INHERITANCE IS THE CLAIM. SCOPE here is not an independent measurement — it is
        // CallForOffersAlertBatch's, taken because the measured cost model
        // (6.0 ms + 0.22 ms x |recipients| per send) is a property of the notification API and not
        // of the object being alerted on. If the two ever diverge, someone changed one without the
        // argument that governs both.
        Assert.areEqual(CallForOffersAlertBatch.SCOPE, NdaExpiryAlertBatch.SCOPE,
            'SCOPE is inherited from CallForOffersAlertBatch with a citation, not re-measured — '
            + 'read NdaExpiryAlertBatch header §1 before changing either');
    }
}
