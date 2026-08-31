/**
 * Tests for `StageDelayAlertBatch` — the daily stalled-deal reminder.
 *
 * ── WHAT CAN AND CANNOT BE ASSERTED HERE ────────────────────────────────────
 * 🔴 **A CUSTOM NOTIFICATION CANNOT BE QUERIED IN APEX.** There is no SObject for a delivered
 * notification, so no test in this org can assert that the `Acquisition` queue or a deal's owner
 * received anything. `GroupNotifier` carries a `@TestVisible sentCount` static for exactly this
 * reason. What these tests assert instead is the thing that IS observable and IS the design: **the
 * two marker fields**, which are the durable record of what was reminded and the whole mechanism by
 * which a reminder happens once per stage occupancy rather than daily.
 *
 * 🔴 **THE OWNER RECIPIENT IS ASSERTED, BUT ONLY BECAUSE A SEAM WAS ADDED FOR IT.** This class was
 * first written claiming the owner half was unprovable, and that was true of `sentCount` alone: it
 * counts calls, not addressees, so it cannot tell a queue-only send from a queue-plus-owner one.
 * `GroupNotifier.lastSendRecipients` (added 2026-08-31) records the set handed to each `send()`,
 * and `theDealOwnerIsANotificationRecipientAlongsideTheQueue` reads it. The de-duplication and the
 * cross-request no-leak properties of the merge belong to `GroupNotifierTest`, which owns that
 * field. One owner per fact.
 *
 * ⚠ AND ONE THING GENUINELY CANNOT BE TESTED HERE, HAVING BEEN TRIED: a queue-owned deal. The
 * scenario does not exist — `Opportunity` is not queue-ownable and the platform refuses a `00G`
 * `OwnerId` with `FIELD_INTEGRITY_EXCEPTION: Owner ID: id value of incorrect type` (probed against
 * `usman-dpeg` 2026-08-31). The `005` prefix guard written for it was removed as dead code rather
 * than left in with an untestable branch; `StageDelayAlertBatch.buildRequest` records why, and what
 * would bring it back.
 *
 * ── 🔴 WHY MOST TESTS CALL `execute()` DIRECTLY INSTEAD OF `Database.executeBatch` ──────────
 * In a test context a batch does not run when it is submitted — it runs at `Test.stopTest()`. So
 * TWO passes with a data change in between (yesterday's run, then today's) is **unexpressible**
 * through `Database.executeBatch`: both submissions would queue and then run back-to-back at
 * `stopTest`, after every data change had already been made, and the test would silently measure
 * something else entirely. Every sequencing test therefore drives `execute(null, scope)` directly,
 * synchronously, which is the same code path the framework calls — and which is also the only way
 * the injected `Stage_Threshold_Def__mdt` rows are guaranteed to be in scope, since static state is
 * not carried into an asynchronously-executed job.
 *
 * `Database.executeBatch` is used ONCE, where the LOCATOR'S WIRING is the thing under test — that
 * `start()` really calls the selector with a service-computed ceiling. ⚠ It deliberately asserts
 * nothing about the locator's FILTERS: a test method executes exactly ONE chunk, so anything the
 * `ORDER BY` sorts past row 200 is unobservable whether the locator excluded it or merely deferred
 * it. **The filters — `IsClosed = FALSE`, the null-anchor guard and the ceiling — are owned by
 * `OpportunitySelectorTest`**, which reads the locator directly and synchronously. That is where
 * "Dead/Pass and Closed Won are excluded" is proved.
 *
 * ── 🔴 THE THRESHOLDS ARE INJECTED, NEVER READ FROM THE ORG ─────────────────
 * `Stage_Threshold_Def__mdt`'s rows are script-loaded, not deployed (post-deploy step P3), so an
 * org running this suite may legitimately have none — or eight, or eight retuned ones. Every
 * `execute()`-driven test installs its own through `overrideThresholdsForTest`. The single
 * `executeBatch` test cannot (statics do not cross into the async job) and is therefore written to
 * be true at ANY threshold: its fixture is aged 400 days.
 *
 * ── GOVERNOR COUNTERS ───────────────────────────────────────────────────────
 * ⚠ Asserted on the batch's own `chunk*` statics, which are captured INSIDE `execute()`'s own body
 * as a DELTA. `Test.stopTest()` RESTORES the pre-test governor counters, so a `Limits.*` assertion
 * taken after it is silently vacuous (the `ExtractAddressQueueable.lastRunQueryCount` precedent),
 * and a reading taken before it would measure the fixture's own trigger cascade rather than this
 * job. The batch's INSTANCE fields cannot be read at all: `Database.Stateful` serialises the
 * object, so the instance handed to `Database.executeBatch` is not the instance that ran.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies (this is a batch) and is met with
 * NO exemption claimed. Note exactly what 251 proves here: a test method executes only ONE chunk,
 * so a 251-row fixture handed to `execute()` proves a chunk larger than any the framework would
 * build still costs ONE DML statement and a CONSTANT query count. The design brief asked
 * specifically for the constant-governor property to be asserted rather than merely "251 rows
 * produced 251 alerts", and `aChunkOwingNothingCostsZeroDmlAndZeroNotifications` is that assertion.
 * ⚠ `.claude/rules/content-publication-rule.md` does not apply: nothing in this feature creates a
 * `ContentVersion`, a `ContentNote` or a `ContentDocument`.
 *
 * ── ⚠ WHY THE FIXTURES AGE A DEAL WITH A SECOND `update` ────────────────────
 * `Stage_Entry_Date__c` CANNOT be seeded on insert. `OpportunityStageEntryService` runs in
 * `OpportunityReviewTrigger`'s before contexts and overwrites it with `Date.today()` on every stage
 * ENTRY — and an insert is an entry. A second save that leaves `StageName` alone is not a
 * transition (`priorStage == o.StageName` ⇒ `continue`), so the aged value written there survives.
 * That is a property of the prerequisite service, and if it ever became fill-if-blank instead of
 * unconditional these fixtures would still work while the feature silently broke — which is why
 * `OpportunityStageEntryServiceTest` owns that fact and this class only relies on it.
 *
 * ⚠ ALL FIXTURE DML CARRYING THE NEW MARKER FIELDS USES `AccessLevel.SYSTEM_MODE`. Both marker
 * fields and `Stage_Entry_Date__c` are Metadata-API-deployed customs that arrive with NO field
 * permissions for any profile, System Administrator included, and this repo has a recorded incident
 * where a CALLER-BUILT DML payload naming such a field was refused with `fields being
 * inaccessible`. It costs nothing here and removes a failure mode that has nothing to do with what
 * is being tested.
 */
@isTest
private class StageDelayAlertBatchTest {

    private static final Integer BULK_N = 251;

    /** One active threshold row. */
    private static Stage_Threshold_Def__mdt row(String stageValue, Integer days) {
        return new Stage_Threshold_Def__mdt(
            DeveloperName = 'Stage_' + stageValue.replaceAll('[^A-Za-z0-9]', '_'),
            Stage_Value__c = stageValue,
            Threshold_Days__c = days,
            Is_Active__c = true
        );
    }

    /** The shipped-shape configuration for the stages these fixtures use. */
    private static void installFlat14() {
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 14),
            row('Underwriting', 14)
        });
    }

    /**
     * `count` open deals at stage `New`, aged so they entered the stage `daysAgo` days ago.
     *
     * See the class header for why the age needs a second save. Returns them re-queried in the
     * locator's own field shape.
     */
    private static List<Opportunity> agedDeals(Integer count, Integer daysAgo) {
        List<Opportunity> opps = TestDataFactory.createOpportunities(count, true);
        List<Opportunity> aged = new List<Opportunity>();
        for (Opportunity o : opps) {
            aged.add(new Opportunity(
                Id = o.Id,
                Stage_Entry_Date__c = Date.today().addDays(-1 * daysAgo)
            ));
        }
        Database.update(aged, true, AccessLevel.SYSTEM_MODE);
        return scopeFor(new Map<Id, Opportunity>(opps).keySet());
    }

    private static Opportunity agedDeal(Integer daysAgo) {
        return agedDeals(1, daysAgo)[0];
    }

    /** The field set the locator produces, so a direct `execute()` call gets the same shape. */
    private static List<Opportunity> scopeFor(Set<Id> oppIds) {
        return [
            SELECT Id, Name, StageName, OwnerId, Stage_Entry_Date__c,
                   Stage_Alert_Last_Sent_Date__c, Stage_Alert_Stage__c
            FROM Opportunity
            WHERE Id IN :oppIds
            WITH SYSTEM_MODE
            ORDER BY Stage_Entry_Date__c ASC, Id ASC
        ];
    }

    private static List<Opportunity> scopeFor(Id oppId) {
        return scopeFor(new Set<Id>{ oppId });
    }

    /** Load a deal's two marker fields back from the database. */
    private static Opportunity marker(Id oppId) {
        return [
            SELECT Id, StageName, Stage_Entry_Date__c,
                   Stage_Alert_Last_Sent_Date__c, Stage_Alert_Stage__c
            FROM Opportunity WHERE Id = :oppId
            WITH SYSTEM_MODE
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE MARKER — what is stamped, and when
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aDealUnderItsThresholdIsNotRemindedAndNotMarked() {
        installFlat14();
        Opportunity deal = agedDeal(13);

        Test.startTest();
        Integer sentBefore = GroupNotifier.sentCount;
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Opportunity after = marker(deal.Id);
        Assert.isNull(after.Stage_Alert_Last_Sent_Date__c,
            'Thirteen days into a 14-day threshold is not delayed, so nothing is stamped');
        Assert.isNull(after.Stage_Alert_Stage__c, 'and no stage snapshot is taken');
        Assert.areEqual(1, StageDelayAlertBatch.chunkEvaluated, 'It WAS looked at');
        Assert.areEqual(0, StageDelayAlertBatch.chunkOwed, 'and deliberately not chased');
        Assert.areEqual(sentBefore, GroupNotifier.sentCount, 'so not one notification went out');
        Assert.areEqual(0, StageDelayAlertBatch.chunkDmlStatements,
            'and no DML at all — a chunk that owes nothing must be free');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aDealPastItsThresholdIsRemindedAndBothMarkerHalvesAreWritten() {
        installFlat14();
        Opportunity deal = agedDeal(20);

        Test.startTest();
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Opportunity after = marker(deal.Id);
        Assert.areEqual(Date.today(), after.Stage_Alert_Last_Sent_Date__c,
            'The date half of the marker records when the reminder went out');
        Assert.areEqual('New', after.Stage_Alert_Stage__c,
            'and the SNAPSHOT half records WHICH STAGE it was about — without this a deal that '
            + 'moves on and stalls again is permanently silent');
        Assert.areEqual(1, StageDelayAlertBatch.chunkOwed, 'One deal was owed a reminder');
        Assert.areEqual(1, StageDelayAlertBatch.chunkNotified, 'one notification went out');
        Assert.areEqual(1, StageDelayAlertBatch.chunkStamped, 'and one marker was written');
        Assert.areEqual(1, StageDelayAlertBatch.chunkDmlStatements,
            'in ONE DML statement — the claim is constancy, not the row count');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aSecondRunOnTheSameDayIsAGenuineNoOp() {
        // 🔴 THE FAILURE THE WHOLE MARKER DESIGN EXISTS TO PREVENT: "the team gets the same reminder
        // every day and stops reading them". Asserted on ZERO SENDS, not merely on the marker being
        // unchanged — an implementation that re-sent and re-stamped the SAME value would leave the
        // marker identical and pass a weaker test.
        installFlat14();
        Opportunity deal = agedDeal(20);
        StageDelayAlertBatch batch = new StageDelayAlertBatch();

        Test.startTest();
        batch.execute(null, scopeFor(deal.Id));
        Assert.areEqual(1, StageDelayAlertBatch.chunkStamped, 'PRECONDITION: the first pass marks it');
        Integer sentAfterFirstPass = GroupNotifier.sentCount;
        batch.execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(0, StageDelayAlertBatch.chunkOwed, 'Nothing is owed on the second pass');
        Assert.areEqual(sentAfterFirstPass, GroupNotifier.sentCount,
            'so not one further notification is sent');
        Assert.areEqual(0, StageDelayAlertBatch.chunkDmlStatements, 'and no DML is issued');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aDealThatSitsInTheSameStageForMonthsIsStillRemindedOnlyOnce() {
        // "Once per stage occupancy" is the recorded user decision, and it is NOT "once per 14 days".
        // Simulated by re-running against a marker written 90 days ago while the deal has never
        // moved. If the rule ever became a ladder or a re-notify-after-N-days, this reds.
        installFlat14();
        Opportunity deal = agedDeal(200);
        Database.update(new List<Opportunity>{ new Opportunity(
            Id = deal.Id,
            Stage_Alert_Stage__c = 'New',
            Stage_Alert_Last_Sent_Date__c = Date.today().addDays(-90)
        ) }, true, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Integer sentBefore = GroupNotifier.sentCount;
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(0, StageDelayAlertBatch.chunkOwed,
            'The deal has been stuck for 200 days and reminded once; it is not reminded again');
        Assert.areEqual(sentBefore, GroupNotifier.sentCount, 'no notification');
        Assert.areEqual(Date.today().addDays(-90),
            marker(deal.Id).Stage_Alert_Last_Sent_Date__c,
            'and the original marker is left exactly as it was');

        StageDelayService.clearThresholdOverrideForTest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 🔴 RE-ARMING — the half that makes the marker safe to write at all
    // ═══════════════════════════════════════════════════════════════════════

    // ⚠ BOTH RE-ARM TESTS BUILD THE MARKER STATE DIRECTLY RATHER THAN MOVING THE DEAL THROUGH REAL
    // STAGES, AND THAT IS FORCED RATHER THAN LAZY. This org's Opportunity stage transitions are
    // gated by SIX active validation rules — `NDA_Signed_Before_Deal_Progression`,
    // `Underwriting_Approved_Before_LOI`, `No_Backward_Stage_Movement` and three more — so
    // `New -> Underwriting` needs a signed primary NDA and `Underwriting -> New` is BLOCKED
    // OUTRIGHT as backward movement. A fixture that fought all six would be testing the stage-gate
    // rules, not the marker.
    //
    // 🔴 AND THE DIRECT CONSTRUCTION IS THE STRONGER TEST ANYWAY, BECAUSE IT ISOLATES ONE LEG AT A
    // TIME. A real stage move satisfies BOTH legs at once (the stage differs AND the anchor moved),
    // so it cannot tell which one fired — an implementation with leg B deleted would still pass it.
    // Each test below arranges the marker so that exactly ONE leg can be responsible, and says
    // which. `StageDelayServiceTest` owns the same two facts as pure unit tests; what these add is
    // that the BATCH passes the right four values, in the right order, from the right fields.

    @isTest
    static void aDealThatChangedStageIsRemindedAgainInItsNewStage_legA() {
        // LEG A IN ISOLATION. The deal is at New; the marker is about `Under Review` and was sent
        // only 5 days ago — INSIDE the current occupancy, so leg B is FALSE and cannot be what
        // fires. Only "the marker names a stage the deal has left" can open this.
        installFlat14();
        Opportunity deal = agedDeal(20);
        Database.update(new List<Opportunity>{ new Opportunity(
            Id = deal.Id,
            Stage_Alert_Stage__c = 'Under Review',
            Stage_Alert_Last_Sent_Date__c = Date.today().addDays(-5)
        ) }, true, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(1, StageDelayAlertBatch.chunkOwed,
            'The marker names a stage the deal has left, so it does not suppress the new one. '
            + 'Without leg A, one reminder would silence a deal for the rest of its life however '
            + 'many later stages it got stuck in');
        Assert.areEqual('New', marker(deal.Id).Stage_Alert_Stage__c,
            'and the snapshot moves to the stage the NEW reminder is about');
        Assert.areEqual(Date.today(), marker(deal.Id).Stage_Alert_Last_Sent_Date__c,
            'with a fresh date');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aDealThatReEnteredTheSameStageIsRemindedAgain_legB() {
        // 🔴 LEG B IN ISOLATION, AND IT IS THE CASE A STAGE-ONLY MARKER MISSES ENTIRELY. The marker
        // names `New` and the deal IS at New, so leg A is FALSE. What distinguishes this from an
        // already-reminded deal is only that the anchor moved FORWARD PAST the marker: the reminder
        // went out 40 days ago, and the deal entered its current occupancy of New 20 days ago.
        // That is a deal that left and came back.
        installFlat14();
        Opportunity deal = agedDeal(20);
        Database.update(new List<Opportunity>{ new Opportunity(
            Id = deal.Id,
            Stage_Alert_Stage__c = 'New',
            Stage_Alert_Last_Sent_Date__c = Date.today().addDays(-40)
        ) }, true, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(1, StageDelayAlertBatch.chunkOwed,
            'The entry date is LATER than the marker: this is a NEW occupancy of the SAME stage '
            + 'and it earns its own reminder. Delete leg B and this deal is silent forever');
        Assert.areEqual(Date.today(), marker(deal.Id).Stage_Alert_Last_Sent_Date__c,
            'and the marker date is refreshed to this occupancy');

        StageDelayService.clearThresholdOverrideForTest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE RECIPIENTS — the deal OWNER as well as the Acquisition queue
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void theDealOwnerIsANotificationRecipientAlongsideTheQueue() {
        // 🔴 THE OTHER HALF OF THE RECORDED USER DECISION ("recipients are the deal OWNER and the
        // Acquisition team"), and it was NOT provable until `GroupNotifier.lastSendRecipients` was
        // added — a delivered custom notification has no SObject and `send()` returns void, so
        // `sentCount` alone cannot tell a queue-only send from a queue-plus-owner one.
        //
        // ⚠ The fixture's owner IS the running user, so this cannot distinguish "the owner" from
        // "whoever happens to be in the queue" by identity alone. What it CAN prove, and does, is
        // that the batch put `OwnerId` into `additionalRecipientIds` at all: delete that block in
        // `buildRequest` and `additionalRecipientIds` is null, so the recorded set is the group's
        // members only — which is why the size assertion is here as well as the contains one.
        installFlat14();
        Opportunity deal = agedDeal(20);

        Test.startTest();
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(1, GroupNotifier.lastSendRecipients.size(),
            'ONE send for the deal — the owner rides the queue\'s call rather than earning a '
            + 'second one. See StageDelayAlertBatch header §1 for the arithmetic');
        Assert.isTrue(
            GroupNotifier.lastSendRecipients[0].contains(String.valueOf(deal.OwnerId)),
            'and the deal OWNER is in the recipient set, not just the Acquisition queue');

        StageDelayService.clearThresholdOverrideForTest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SEND-THEN-STAMP
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aFailedSendIsNotStampedSoItIsRetriedRatherThanLost() {
        // 🔴 THE ENTIRE REASON THIS JOB CALLS `notifyWithOutcome` AND NOT `notify`. If it stamped
        // regardless of the outcome, a failed send would be lost FOREVER and the marker would claim
        // it went out. Reproduced by pointing the batch at a group that does not exist — the same
        // shape as post-deploy gate P1 being missed.
        installFlat14();
        Opportunity deal = agedDeal(20);
        String realGroup = StageDelayAlertBatch.RECIPIENT_GROUP;
        StageDelayAlertBatch.RECIPIENT_GROUP = 'No_Such_Group_' + Math.abs(Crypto.getRandomInteger());

        Test.startTest();
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();
        StageDelayAlertBatch.RECIPIENT_GROUP = realGroup;

        Assert.areEqual(1, StageDelayAlertBatch.chunkOwed, 'The deal was owed a reminder');
        Assert.areEqual(0, StageDelayAlertBatch.chunkNotified, 'but nothing could be sent');
        Assert.areEqual(1, StageDelayAlertBatch.chunkSendFailures, 'which is counted');
        Assert.areEqual(0, StageDelayAlertBatch.chunkStamped, 'and NOTHING is stamped');
        Assert.areEqual(0, StageDelayAlertBatch.chunkDmlStatements,
            'no DML at all, so tomorrow\'s pass tries again. NOISY beats SILENT');
        Assert.isNull(marker(deal.Id).Stage_Alert_Stage__c,
            'The marker must stay blank — a marker written for an unsent reminder loses it forever');

        StageDelayService.clearThresholdOverrideForTest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BULK — 251, and the constant-governor property
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aChunkOf251DelayedDealsCostsOneDmlStatementAndOnePassOfQueries() {
        // 🔴 THE CONSTANCY IS THE CLAIM, NOT THE ROW COUNT. 251 is larger than any chunk the
        // framework builds at SCOPE = 200, which is the point: if a future edit moved the update or
        // a lookup inside the loop, this method hits the 150-statement or 100-query ceiling and
        // fails loudly, where a 1-row test would stay green forever.
        installFlat14();
        List<Opportunity> scope = agedDeals(BULK_N, 20);

        Test.startTest();
        new StageDelayAlertBatch().execute(null, scope);
        Test.stopTest();

        Assert.areEqual(BULK_N, StageDelayAlertBatch.chunkEvaluated, 'All 251 were looked at');
        Assert.areEqual(BULK_N, StageDelayAlertBatch.chunkOwed, 'all 251 were owed a reminder');
        Assert.areEqual(BULK_N, StageDelayAlertBatch.chunkNotified, 'all 251 were sent');
        Assert.areEqual(BULK_N, StageDelayAlertBatch.chunkStamped, 'and all 251 were stamped');
        Assert.areEqual(1, StageDelayAlertBatch.chunkDmlStatements,
            'in ONE DML statement for 251 rows — a per-record update would blow the 150-statement '
            + 'limit long before reaching 251');
        Assert.isTrue(StageDelayAlertBatch.chunkQueries <= 5,
            'and a CONSTANT handful of queries, all of them GroupNotifier resolving the queue and '
            + 'the notification type ONCE for the whole chunk (it caches). Measured at '
            + StageDelayAlertBatch.chunkQueries + '. A per-deal query would read 251+ here. The '
            + 'batch itself contributes zero: Stage_Threshold_Def__mdt.getAll() is not SOQL');

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Opportunity WHERE Stage_Alert_Stage__c != NULL WITH SYSTEM_MODE],
            'Every row carries its stage snapshot');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Opportunity WHERE Stage_Alert_Last_Sent_Date__c != NULL WITH SYSTEM_MODE],
            'and its date — the two are written together or the re-arm rule silently stops working');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aChunkOwingNothingCostsZeroDmlAndZeroNotifications() {
        // 🔴 THE PROPERTY THE DESIGN BRIEF ASKED FOR BY NAME, and the one that makes running this
        // daily on a quiet pipeline free. A full 251-row chunk in which nothing is owed must cost
        // NOTHING — not "a bit less". An implementation that issued an empty `update`, or that
        // resolved recipients before deciding whether it needed them, would pass every other test
        // in this class and fail this one.
        installFlat14();
        List<Opportunity> scope = agedDeals(BULK_N, 5);

        Test.startTest();
        Integer sentBefore = GroupNotifier.sentCount;
        new StageDelayAlertBatch().execute(null, scope);
        Test.stopTest();

        Assert.areEqual(BULK_N, StageDelayAlertBatch.chunkEvaluated, 'All 251 were evaluated');
        Assert.areEqual(0, StageDelayAlertBatch.chunkOwed, 'and none of them was owed anything');
        Assert.areEqual(0, StageDelayAlertBatch.chunkDmlStatements, 'ZERO DML');
        Assert.areEqual(0, StageDelayAlertBatch.chunkQueries, 'ZERO queries');
        Assert.areEqual(sentBefore, GroupNotifier.sentCount, 'and ZERO notifications');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aSecondFullPassAt251StampsNothingNewAndSendsNothing() {
        // Idempotency at volume. If the marker rule regressed, a daily job would send 251
        // notifications every single day — the failure mode the design names in words.
        installFlat14();
        List<Opportunity> scope = agedDeals(BULK_N, 20);
        Set<Id> ids = new Map<Id, Opportunity>(scope).keySet();
        StageDelayAlertBatch batch = new StageDelayAlertBatch();

        // ⚠ BOTH passes run INSIDE start/stop, deliberately: `Test.startTest()` resets the governor
        // counters, so putting the expensive first pass outside it would spend the fixture's CPU
        // budget on 251 notifications and make this test flaky for a reason unrelated to what it
        // measures. Two sequential direct `execute()` calls are also the only way to express
        // "yesterday's run, then today's" — see the class header.
        Test.startTest();
        batch.execute(null, scope);
        Assert.areEqual(BULK_N, StageDelayAlertBatch.chunkStamped,
            'PRECONDITION: the first pass reminds and marks all 251');
        Integer sentBefore = GroupNotifier.sentCount;
        batch.execute(null, scopeFor(ids));
        Test.stopTest();

        Assert.areEqual(0, StageDelayAlertBatch.chunkOwed, 'Nothing is owed on the second pass');
        Assert.areEqual(sentBefore, GroupNotifier.sentCount, 'so not one notification is sent');
        Assert.areEqual(0, StageDelayAlertBatch.chunkDmlStatements, 'and no DML is issued');

        StageDelayService.clearThresholdOverrideForTest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // WIRING, AND THE DEGENERATE INPUTS
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void startIsWiredToTheSelectorSoARealPassFindsAndMarksAStalledDeal() {
        // The ONE `Database.executeBatch` test — it proves `start()` really builds the locator from
        // the selector with a service-computed ceiling, which a direct `execute()` call skips
        // entirely.
        //
        // ⚠ NO THRESHOLD OVERRIDE, AND THAT IS FORCED RATHER THAN CHOSEN: static state is not
        // carried into an asynchronously-executed job, so the batch will read whatever the ORG's
        // Stage_Threshold_Def__mdt says — none (the shipped 14-day fallback), or the eight loaded
        // rows, or eight retuned ones. The fixture is therefore aged FOUR HUNDRED DAYS so the
        // assertion holds under any sane configuration.
        //
        // ⚠ It deliberately asserts nothing about the locator's FILTERS — see the class header.
        // `Dead/Pass` and `Closed Won` exclusion is owned by `OpportunitySelectorTest`.
        Opportunity deal = agedDeal(400);

        Test.startTest();
        Database.executeBatch(new StageDelayAlertBatch(), StageDelayAlertBatch.SCOPE);
        Test.stopTest();

        Opportunity after = marker(deal.Id);
        Assert.areEqual('New', after.Stage_Alert_Stage__c,
            'A batch whose start() returned nothing, or the wrong query, would leave this null');
        Assert.areEqual(Date.today(), after.Stage_Alert_Last_Sent_Date__c,
            'and both marker halves are written by the real, framework-driven pass');
    }

    @isTest
    static void anEmptyOrNullChunkIsANoOpRatherThanAThrow() {
        installFlat14();
        StageDelayAlertBatch batch = new StageDelayAlertBatch();

        Test.startTest();
        batch.execute(null, new List<Opportunity>());
        batch.execute(null, null);
        Test.stopTest();

        Assert.areEqual(0, StageDelayAlertBatch.chunkEvaluated,
            'A chunk with nothing in it does no work and throws nothing — the framework can hand '
            + 'one over when the locator empties between start() and execute()');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aDealWithNoStageEntryDateIsSkippedRatherThanTreatedAsBrandNew() {
        // The in-memory half of the un-backfilled-legacy guard (post-deploy step P4). The locator
        // excludes these rows too; this proves the job is still correct if one reaches it — a
        // hand-cleared entry date, or a future caller passing its own scope.
        installFlat14();
        Opportunity deal = agedDeal(20);
        Database.update(new List<Opportunity>{
            new Opportunity(Id = deal.Id, Stage_Entry_Date__c = null)
            }, true, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(1, StageDelayAlertBatch.chunkEvaluated, 'It was looked at');
        Assert.areEqual(0, StageDelayAlertBatch.chunkOwed,
            'but with no anchor there is nothing to measure, so it is not chased');
        Assert.isNull(marker(deal.Id).Stage_Alert_Stage__c, 'and nothing is stamped');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aStageWithNoActiveThresholdIsNeverChasedHoweverStaleItIs() {
        // Belt to the selector's braces, and the mechanism by which `Closed Won` / `Dead/Pass` get
        // no rows in the loader script: a stage the configuration does not name is not chased even
        // if it somehow reaches the chunk.
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('Underwriting', 14)
        });
        Opportunity deal = agedDeal(900);

        Test.startTest();
        Integer sentBefore = GroupNotifier.sentCount;
        new StageDelayAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(0, StageDelayAlertBatch.chunkOwed,
            'Stage New has no active row, so 900 days in it is still not chased');
        Assert.areEqual(sentBefore, GroupNotifier.sentCount, 'and nothing is sent');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void finishSummarisesWithoutThrowing() {
        // `finish` is a debug line by design — the durable record lives on the marker fields, which
        // are queryable and reportable, unlike a log. It is covered because an exception in it
        // would fail the whole job AFTER the reminders had already gone out, and because it reads
        // Stage_Threshold_Def__mdt.getAll() to report the row count, which is the operator's only
        // visible signal that the loader script was never run.
        Test.startTest();
        new StageDelayAlertBatch().finish(null);
        Test.stopTest();
        Assert.isTrue(true, 'finish() completed without throwing');
    }
}
