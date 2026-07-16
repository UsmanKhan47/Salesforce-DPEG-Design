/**
 * DateTimeBackfillBatchTest — D2 of the 8-DateTime migration.
 *
 * Proves the backfill copies legacy `*_Date__c` values into their `*_DateTime__c`
 * twins at bulk scale, with row-level value equality (the mismatch check that is
 * not expressible in SOQL and so cannot live in the batch's finish()).
 *
 * The genuine pre-D1 fixture is old-set / new-null. TestDataFactory dual-writes
 * both since D1, so each test explicitly nulls the new fields to reconstruct the
 * historical state the backfill exists to repair.
 *
 * Test-harness note: a test method may call Database.executeBatch only ONCE, and
 * start() must return at most one chunk. So the bulk tests pass chunk size 251
 * (all rows in one execute()), and the hard gate is verified via the extracted
 * assertBackfillSafe() rather than through run() (which fans out five batches).
 *
 * Not coverable in-test: the canary-abort THROW. Its precondition — a Work Order
 * at a non-New/Completed status whose OLD stamp is null — is exactly the state
 * Work_Order_Touch_Sync HEALS on every insert/update. Note before-save flows DO
 * fire on Bulk API loads, so a bulk load is NOT the bypass. The only way this
 * state exists is data that PREDATES the flow (or was loaded while it was
 * inactive, or before the field existed). An Apex test always runs with the flow
 * active and so cannot manufacture the state; the canary-abort THROW is verified
 * against real org data before the live run instead.
 *
 * The finish() loud-fail THROW, by contrast, IS covered here: assertComplete()
 * was extracted from finish() precisely so a deliberately-unfinished row can
 * drive its throw without launching a batch — see assertComplete_unfinishedRow_throws().
 */
@IsTest
private class DateTimeBackfillBatchTest {

    private static final Map<String, String> WO_FIELDS = new Map<String, String>{
        'Reported_Date__c'      => 'Reported_DateTime__c',
        'Completed_Date__c'     => 'Completed_DateTime__c',
        'First_Touched_Date__c' => 'First_Touched_DateTime__c'
    };
    private static final Map<String, String> ENTRY_FIELD = new Map<String, String>{
        'Entry_Date__c' => 'Entry_DateTime__c'
    };

    /**
     * Bulk 251: old populated on all three fields, new null. After the batch,
     * every new field equals its old twin and none is null. Chunk size 251 so all
     * rows process in one execute() — a SOQL/DML-in-loop bug would blow limits at
     * 251, which is the property bulk-test-rule.md is protecting.
     */
    @IsTest
    static void backfill251WorkOrders_copiesAllThreeFields() {
        Datetime stamp = System.now().addDays(-10);
        List<Work_Order__c> wos = TestDataFactory.createWorkOrders(251, false);
        for (Work_Order__c w : wos) {
            // Status stays 'New' (factory default) -> both canaries clean.
            w.Reported_Date__c          = stamp;
            w.Completed_Date__c         = stamp;
            w.First_Touched_Date__c     = stamp;
            w.Reported_DateTime__c      = null;   // reconstruct the pre-D1 state
            w.Completed_DateTime__c     = null;
            w.First_Touched_DateTime__c = null;
        }
        insert wos;

        Test.startTest();
        Database.executeBatch(new DateTimeBackfillBatch('Work_Order__c', WO_FIELDS), 251);
        Test.stopTest();

        List<Work_Order__c> after = [
            SELECT Reported_Date__c, Reported_DateTime__c,
                   Completed_Date__c, Completed_DateTime__c,
                   First_Touched_Date__c, First_Touched_DateTime__c
            FROM Work_Order__c
        ];
        Assert.areEqual(251, after.size(), 'All 251 fixture rows present');
        for (Work_Order__c w : after) {
            Assert.areEqual(w.Reported_Date__c, w.Reported_DateTime__c,
                'Reported_DateTime__c must equal its old twin');
            Assert.areEqual(w.Completed_Date__c, w.Completed_DateTime__c,
                'Completed_DateTime__c must equal its old twin');
            Assert.areEqual(w.First_Touched_Date__c, w.First_Touched_DateTime__c,
                'First_Touched_DateTime__c must equal its old twin');
            Assert.isNotNull(w.Reported_DateTime__c, 'No row left unbackfilled');
        }
    }

    /**
     * The activity-object path (single Entry_Date__c -> Entry_DateTime__c),
     * structurally identical to the multi-field WO path but exercised with data.
     */
    @IsTest
    static void backfillActivityObject_copiesEntryDate() {
        Datetime stamp = System.now().addDays(-7);
        Work_Order__c parent = TestDataFactory.createWorkOrders(1, true)[0];
        List<Work_Order_Activity__c> acts = TestDataFactory.createWorkOrderActivities(10, parent.Id, false);
        for (Work_Order_Activity__c a : acts) {
            a.Entry_Date__c     = stamp;
            a.Entry_DateTime__c = null;
        }
        insert acts;

        Test.startTest();
        Database.executeBatch(new DateTimeBackfillBatch('Work_Order_Activity__c', ENTRY_FIELD), 251);
        Test.stopTest();

        for (Work_Order_Activity__c a : [SELECT Entry_Date__c, Entry_DateTime__c FROM Work_Order_Activity__c]) {
            Assert.areEqual(a.Entry_Date__c, a.Entry_DateTime__c, 'Entry_DateTime__c must equal its old twin');
            Assert.isNotNull(a.Entry_DateTime__c, 'No activity left unbackfilled');
        }
    }

    /**
     * The hard gate on canary-clean data: both pre-flight canaries run and
     * assertBackfillSafe() does not throw. (The throw branch is documented as
     * uncoverable in-test — the before-save flow prevents its precondition.)
     */
    @IsTest
    static void assertBackfillSafe_cleanData_doesNotThrow() {
        Datetime stamp = System.now().addDays(-2);
        List<Work_Order__c> wos = TestDataFactory.createWorkOrders(3, false);
        for (Work_Order__c w : wos) {
            w.Reported_Date__c     = stamp;   // Status 'New' -> canaries clean
            w.Reported_DateTime__c = null;
        }
        insert wos;

        Test.startTest();
        DateTimeBackfillBatch.assertBackfillSafe();   // must not throw
        Test.stopTest();
        // Reaching here without exception is the assertion.
        Assert.isNotNull(wos, 'assertBackfillSafe passed on canary-clean data');
    }

    /**
     * The finish() loud-fail: assertComplete() MUST throw when a row still has old
     * populated / new null. A silent partial backfill is how data goes missing, so
     * this is the single most important safety branch. Insert one deliberately-
     * unfinished row (Reported_Date__c set, Reported_DateTime__c null) and assert
     * the throw. Status stays 'New', so Work_Order_Touch_Sync leaves the row alone
     * and the unfinished state survives to be verified.
     */
    @IsTest
    static void assertComplete_unfinishedRow_throws() {
        Datetime stamp = System.now().addDays(-5);
        List<Work_Order__c> wos = TestDataFactory.createWorkOrders(1, false);
        wos[0].Reported_Date__c     = stamp;   // old populated
        wos[0].Reported_DateTime__c = null;    // new null -> deliberately unfinished
        insert wos;

        Test.startTest();
        try {
            DateTimeBackfillBatch.assertComplete('Work_Order__c', WO_FIELDS);
            Assert.fail('assertComplete must throw BackfillAbortException while a row still needs the copy');
        } catch (DateTimeBackfillBatch.BackfillAbortException e) {
            Assert.isTrue(
                e.getMessage().contains('Backfill incomplete on Work_Order__c'),
                'Exception must name the object/field left incomplete; got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    /**
     * Idempotent: rows already migrated (old and new both set) are not matched by
     * start()'s predicate, so execute() never runs and finish() passes clean.
     */
    @IsTest
    static void backfill_idempotent_noOpWhenAlreadyMigrated() {
        Datetime stamp = System.now().addDays(-3);
        List<Work_Order__c> wos = TestDataFactory.createWorkOrders(5, false);
        for (Work_Order__c w : wos) {
            w.Reported_Date__c     = stamp;
            w.Reported_DateTime__c = stamp;   // already migrated
        }
        insert wos;

        Test.startTest();
        Database.executeBatch(new DateTimeBackfillBatch('Work_Order__c', WO_FIELDS), 251);
        Test.stopTest();

        for (Work_Order__c w : [SELECT Reported_Date__c, Reported_DateTime__c FROM Work_Order__c]) {
            Assert.areEqual(stamp, w.Reported_DateTime__c, 'Already-migrated value untouched');
        }
    }
}
