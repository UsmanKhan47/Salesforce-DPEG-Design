/**
 * Tests for OpportunityStageEntryService — the before-insert / before-update stamp on
 * `Opportunity.Stage_Entry_Date__c` (design §2 ITEM 2).
 *
 * ── THE BULK-TEST RULE APPLIES IN FULL. NO EXEMPTION IS CLAIMED ────────────────────────────
 * `.claude/rules/bulk-test-rule.md` mandates 251 records for anything trigger-driven, and this is
 * trigger-driven on the highest-volume object in the org. The per-transaction-singleton exemption
 * carved out for the Broker Protection async pipeline does NOT apply: this method is invoked once
 * per 200-record DML chunk with the whole chunk in hand, so 251 records genuinely forces a second
 * invocation and genuinely exercises a code path 200 records would not.
 *
 * ── 🔴 HOW THE GOVERNOR ASSERTIONS ARE TAKEN, AND WHY THE OBVIOUS VERSION IS VACUOUS ───────
 * The claim under test is "zero SOQL and zero DML at any record count", because that property is
 * the entire justification for widening a trigger that already routes five services. Two obvious
 * ways to assert it are both worthless here:
 *
 *   ❌ `Limits.getQueries()` read AFTER `Test.stopTest()` — stopTest RESTORES the pre-test
 *      counters, so the reading is of the test's own setup and the assertion passes no matter
 *      what the trigger did. This project has been bitten by exactly that.
 *   ❌ `Limits.getQueries()` read in the test either side of the DML — that measures ALL FIVE of
 *      the other services this trigger routes (NDA creation, review children, the Transactions
 *      handoff, the Property Management handoff, the SharePoint claim), which legitimately query
 *      and write. A regression in THIS service would be invisible inside that noise.
 *
 * So the counters are captured INSIDE the trigger context, in the service's own body, and
 * accumulated across chunks — the device `ExtractAddressQueueable.lastRunQueryCount` /
 * `.lastRunDmlCount` uses. `resetRunCounters()` is called immediately before the measured DML so
 * fixture setup is excluded. These assertions are exact zeros, not ceilings: adding a single
 * `[SELECT ...]` or `update` to the service turns them red, which is the whole point.
 *
 * ── 🔴 WHY EVERY READ OF `Stage_Entry_Date__c` HERE CARRIES `WITH SYSTEM_MODE` ─────────────
 * The field is Metadata-API deployed and, until GATE PS-1 merges its `fieldPermissions` into
 * `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View` / `DPEG_Opportunity_View`, it has ZERO
 * `FieldPermissions` rows for anyone — System Administrator included. Measured on this org:
 * such a field is not FLS-DENIED, it is ABSENT from the running user's schema, and a plain
 * `[SELECT Stage_Entry_Date__c FROM Opportunity]` throws
 * `System.QueryException: No such column`, while the same query with an explicit
 * `WITH SYSTEM_MODE` succeeds. The same applies to DML whose PAYLOAD names the field, which is
 * why the fixture writes below use `Database.update(..., AccessLevel.SYSTEM_MODE)`.
 *
 * ⚠ The SERVICE needs none of that, and that asymmetry is deliberate rather than an oversight: a
 * before-trigger assignment is an in-memory SObject mutation, never a DML payload, so it is not
 * FLS-checked at all. The bulk INSERT test below deliberately uses a PLAIN `insert` for exactly
 * that reason — it is the production shape, and if the plain insert ever started failing on the
 * ungranted field, that test is where it would surface.
 *
 * ── WHY THE RE-ENTRY TEST USES `New` <-> `Dead/Pass` ───────────────────────────────────────
 * Re-entry means returning to a stage the deal has already occupied, which is a BACKWARD move,
 * and `No_Backward_Stage_Movement` is an active rule. It has exactly two openings:
 *   (a) carve-out 1, `LOI` -> `Underwriting` (the LOI final-rejection path), and
 *   (b) `Dead/Pass`, which the rule's CASE expressions map to rank 0, so neither leaving for it
 *       nor returning from it satisfies the rule's `rank > 0` preconditions.
 * (b) is used here because `Underwriting` is one of `DealFolderService.CLAIM_STAGES`, so route
 * (a) would enqueue a SharePoint DealFolderQueueable — machinery entirely unrelated to a date
 * stamp. `New` and `Dead/Pass` are the only two stages present in ALL THREE business processes
 * (Land, Retail, Commercial) that are neither claim stages nor gated on a signed NDA / approved
 * underwriting, and neither one causes `OpportunityReviewService.createReviewRecords` to open a
 * child. That makes this the cheapest honest re-entry available, and it is a real production
 * transition: a deal is passed on and later revived.
 *
 * @see force-app/main/default/classes/OpportunityStageEntryService.cls
 * @see .claude/rules/bulk-test-rule.md
 */
@isTest
private class OpportunityStageEntryServiceTest {

    /**
     * 251, not 200: the platform chunks trigger batches at 200 records, so 251 forces a SECOND
     * invocation of the service in one DML and is what makes a bulkification bug visible.
     * Named BULK_ROWS rather than BULK because `bulk` is a RESERVED WORD in Apex.
     */
    private static final Integer BULK_ROWS = 251;

    /** The stage every factory-built Opportunity starts at; present in all three business processes. */
    private static final String STAGE_NEW = 'New';

    /** Terminal stage. Rank 0 in No_Backward_Stage_Movement, so it can be both left and re-entered. */
    private static final String STAGE_DEAD = 'Dead/Pass';

    /** Required by Rejection_Reason_Required_On_Dead whenever a deal ARRIVES at Dead/Pass. */
    private static final String REASON_OTHER = 'Other';

    /** How far back a fixture backdates the stamp, so "today" is unambiguously a NEW value. */
    private static final Integer BACKDATE_DAYS = 45;

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /**
     * Reads the stamp back. `WITH SYSTEM_MODE` is mandatory while the field has no FLS grant —
     * see the class header.
     *
     * @param oppId The deal.
     * @return Its Stage_Entry_Date__c.
     */
    private static Date entryDateOf(Id oppId) {
        return [
            SELECT Stage_Entry_Date__c FROM Opportunity WHERE Id = :oppId WITH SYSTEM_MODE
        ].Stage_Entry_Date__c;
    }

    /**
     * Reads the stamp back for a whole batch.
     *
     * @param oppIds The deals.
     * @return Id -> Stage_Entry_Date__c.
     */
    private static Map<Id, Date> entryDatesOf(Set<Id> oppIds) {
        Map<Id, Date> byId = new Map<Id, Date>();
        for (Opportunity o : [
            SELECT Id, Stage_Entry_Date__c FROM Opportunity WHERE Id IN :oppIds WITH SYSTEM_MODE
        ]) {
            byId.put(o.Id, o.Stage_Entry_Date__c);
        }
        return byId;
    }

    /**
     * Backdates the stamp WITHOUT touching the stage — which is itself a small proof that a
     * non-stage edit does not re-stamp, since the value survives the save. `AccessLevel.SYSTEM_MODE`
     * is mandatory: the payload names the ungranted field, and a plain update of it fails with
     * "fields being inaccessible".
     *
     * @param oppId The deal.
     * @return The date that was written.
     */
    private static Date backdate(Id oppId) {
        Date backdated = Date.today().addDays(-BACKDATE_DAYS);
        Database.update(
            new Opportunity(Id = oppId, Stage_Entry_Date__c = backdated),
            true,
            AccessLevel.SYSTEM_MODE
        );
        return backdated;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // SINGLE-RECORD BEHAVIOUR
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /**
     * Insert is an ENTRY. `oldMap` is null in before-insert, so a deal created at any stage is
     * entering that stage and gets today's date. This is the path Lead conversion takes
     * (Database.convertLead inserts the Opportunity), so a null stamp here would leave every
     * converted deal invisible to the Item 4 stalled-deal sweep.
     */
    @isTest
    static void insertStampsTodayBecauseCreationIsEntry() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);

        Test.startTest();
        insert o; // plain insert - the production shape, no AccessLevel needed for an in-memory stamp
        Test.stopTest();

        Assert.areEqual(
            Date.today(),
            entryDateOf(o.Id),
            'Creating a deal is entry into its starting stage, so before-insert must stamp today'
        );
    }

    /**
     * A genuine transition OVERWRITES an existing value. This is the one deliberate divergence
     * from DispositionStageEntryService.stampListingDates, which is fill-if-blank — so this test
     * is what stops someone "harmonising" the two and silently reintroducing a stale clock.
     */
    @isTest
    static void stageChangeOverwritesAnExistingDate() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        insert o;
        Date backdated = backdate(o.Id);
        Assert.areEqual(backdated, entryDateOf(o.Id), 'Fixture precondition: the date is old');

        Test.startTest();
        update new Opportunity(Id = o.Id, StageName = STAGE_DEAD, Rejection_Reason__c = REASON_OTHER);
        Test.stopTest();

        Assert.areEqual(
            Date.today(),
            entryDateOf(o.Id),
            'A stage change must OVERWRITE the old date unconditionally, not preserve it — the '
            + 'semantic is entry, not presence'
        );
    }

    /**
     * A save that does not change the stage must not re-stamp. Without this, every routine edit —
     * an amount correction, an owner change, an approval field update, the after-insert cascade's
     * own NDA stamp — would reset the stalled-deal clock and the Item 4 reminder could never fire.
     */
    @isTest
    static void nonStageEditDoesNotRestamp() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        insert o;
        Date backdated = backdate(o.Id);

        Test.startTest();
        update new Opportunity(Id = o.Id, Amount = 4250000, Description = 'A routine, non-stage edit.');
        Test.stopTest();

        Assert.areEqual(
            backdated,
            entryDateOf(o.Id),
            'Editing anything other than StageName is not a stage entry and must leave the date alone'
        );
    }

    /**
     * 🔴 THE POINT OF THE WHOLE ITEM. A deal that leaves a stage and comes back has ENTERED that
     * stage again, and the clock must restart from the return — not report the deal as having sat
     * there since the first visit.
     *
     * A fill-if-blank implementation passes every other test in this class and fails only this
     * one, which is exactly why it exists. See the class header for why the revival route is
     * `New` -> `Dead/Pass` -> `New`.
     */
    @isTest
    static void reEntryRestartsTheClock() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        insert o;                                  // entry #1 into 'New'
        Date firstVisit = backdate(o.Id);          // pretend it sat there for BACKDATE_DAYS

        // It is passed on...
        update new Opportunity(Id = o.Id, StageName = STAGE_DEAD, Rejection_Reason__c = REASON_OTHER);
        Assert.areEqual(Date.today(), entryDateOf(o.Id), 'Leaving for Dead/Pass is itself an entry');
        Date deadVisit = backdate(o.Id);           // and sat at Dead/Pass for BACKDATE_DAYS

        Test.startTest();
        update new Opportunity(Id = o.Id, StageName = STAGE_NEW); // ...and is REVIVED
        Test.stopTest();

        Date afterRevival = entryDateOf(o.Id);
        Assert.areEqual(
            Date.today(),
            afterRevival,
            'Re-entering a stage the deal previously occupied must RESTART the clock at today'
        );
        Assert.areNotEqual(
            firstVisit,
            afterRevival,
            'The revived deal must not report the date of its FIRST visit to this stage — that is '
            + 'the stale value a fill-if-blank stamp would leave behind'
        );
        Assert.areNotEqual(
            deadVisit,
            afterRevival,
            'Nor may it keep the date it entered Dead/Pass'
        );
    }

    /**
     * A chunk that mixes transitioning and non-transitioning records must touch only the
     * transitioning ones. Proven on the service's own in-context stamp counter rather than by
     * re-querying, so it measures what the service DID rather than what survived the save.
     */
    @isTest
    static void mixedChunkStampsOnlyTheTransitions() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(3, false);
        insert opps;
        for (Opportunity o : opps) {
            backdate(o.Id);
        }

        List<Opportunity> edits = new List<Opportunity>{
            new Opportunity(Id = opps[0].Id, StageName = STAGE_DEAD, Rejection_Reason__c = REASON_OTHER),
            new Opportunity(Id = opps[1].Id, Amount = 123456),
            new Opportunity(Id = opps[2].Id, Description = 'No stage change here either.')
        };

        OpportunityStageEntryService.resetRunCounters();
        Test.startTest();
        update edits;
        Test.stopTest();

        Assert.areEqual(
            1,
            OpportunityStageEntryService.runStampCount,
            'Exactly one of the three records changed stage, so exactly one may be stamped'
        );
        Map<Id, Date> after = entryDatesOf(new Map<Id, Opportunity>(opps).keySet());
        Assert.areEqual(Date.today(), after.get(opps[0].Id), 'The transitioning deal is re-stamped');
        Assert.areEqual(
            Date.today().addDays(-BACKDATE_DAYS),
            after.get(opps[1].Id),
            'The amount-only edit must leave the date untouched'
        );
        Assert.areEqual(
            Date.today().addDays(-BACKDATE_DAYS),
            after.get(opps[2].Id),
            'The description-only edit must leave the date untouched'
        );
    }

    /**
     * Defensive contract: a caller outside a trigger context passing nothing must not throw. The
     * service is public, so this is reachable, and a NullPointerException here would surface as a
     * rolled-back save on an unrelated object.
     */
    @isTest
    static void nullAndEmptyInputsAreNoOps() {
        OpportunityStageEntryService.resetRunCounters();

        Test.startTest();
        OpportunityStageEntryService.stampStageEntryDates(null, null);
        OpportunityStageEntryService.stampStageEntryDates(new List<Opportunity>(), null);
        Test.stopTest();

        Assert.areEqual(
            0,
            OpportunityStageEntryService.runStampCount,
            'Null and empty inputs stamp nothing'
        );
        Assert.areEqual(
            2,
            OpportunityStageEntryService.runChunkCount,
            'Both calls were still entered, so the instrumentation counted both'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // BULK — .claude/rules/bulk-test-rule.md, 251 RECORDS
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /**
     * The service in isolation at BULK_ROWS records, with the governor window taken directly
     * around the call — no trigger, no cascade, nothing else in the measurement.
     *
     * ⚠ The fixture call is HOISTED above the window on purpose. Apex evaluates arguments AFTER
     * the `before` reading is captured, so a factory call left in argument position would be
     * measured as if the service had made it. That has cost this project three off-by-one
     * "failures" in budget assertions before.
     */
    @isTest
    static void directCallAtBulkVolumeIsZeroSoqlZeroDml() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_ROWS, false); // HOISTED
        OpportunityStageEntryService.resetRunCounters();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        OpportunityStageEntryService.stampStageEntryDates(opps, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed, BULK_ROWS + ' records in one call must cost ZERO SOQL');
        Assert.areEqual(0, dmlUsed, BULK_ROWS + ' records in one call must cost ZERO DML');
        Assert.areEqual(
            BULK_ROWS,
            OpportunityStageEntryService.runStampCount,
            'Every record in the collection is an insert-shaped entry and must be stamped'
        );
        for (Opportunity o : opps) {
            Assert.areEqual(
                Date.today(),
                o.Stage_Entry_Date__c,
                'The stamp is written in memory onto every record, including the last one'
            );
        }
    }

    /**
     * Bulk INSERT at BULK_ROWS. Two facts in one test:
     *   1. every deal is stamped across BOTH trigger chunks, and
     *   2. the service itself consumed zero SOQL and zero DML while doing it, measured from
     *      inside the trigger context.
     *
     * 🔴 `runStampCount == BULK_ROWS` is a stronger claim than it looks. The after-insert cascade
     * UPDATES all BULK_ROWS Opportunities again to stamp Primary_NDA__c, which re-enters this
     * service through before-update. Those saves do not change StageName, so they must contribute
     * zero additional stamps — an exact equality here is what proves the cascade's own writes do
     * not reset the clock on every new deal in the org.
     *
     * MEASURED 2026-08-31 in usman-dpeg (validation 0Afiw000000TnDRCA0): runChunkCount = 4 on the
     * insert (2 before-insert chunks + 2 before-update chunks from the cascade re-entering) and
     * runQueryCount = runDmlCount = 0. The assertion stays >= 2 rather than == 4 because 4 is a
     * fact about the CASCADE, not about this service; the exact claims that must never move are
     * the two zeros and runStampCount == BULK_ROWS.
     *
     * A PLAIN `insert` is used deliberately: it is the production shape, and it is the assertion
     * that the in-memory stamp of an FLS-ungranted field does not poison the DML payload.
     */
    @isTest
    static void bulkInsertStampsEveryDealAcrossChunks() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_ROWS, false); // HOISTED
        OpportunityStageEntryService.resetRunCounters();

        Test.startTest();
        insert opps; // one DML, BULK_ROWS rows => at least two before-insert chunks
        Test.stopTest();

        Assert.areEqual(
            0,
            OpportunityStageEntryService.runQueryCount,
            'ZERO SOQL inside the service across every chunk of a ' + BULK_ROWS
            + '-record insert — this is what makes it safe on a trigger that already routes five services'
        );
        Assert.areEqual(
            0,
            OpportunityStageEntryService.runDmlCount,
            'ZERO DML inside the service across every chunk of a ' + BULK_ROWS + '-record insert'
        );
        Assert.isTrue(
            OpportunityStageEntryService.runChunkCount >= 2,
            'A ' + BULK_ROWS + '-record DML must invoke the service at least twice (chunks of 200). '
            + 'It is >= rather than == because the after-insert cascade updates the same deals '
            + 'again, re-entering through before-update. Actual: '
            + OpportunityStageEntryService.runChunkCount
        );
        Assert.areEqual(
            BULK_ROWS,
            OpportunityStageEntryService.runStampCount,
            'Exactly one stamp per deal: the cascade\'s own follow-up updates leave StageName '
            + 'unchanged and must therefore add none'
        );

        Map<Id, Date> stamped = entryDatesOf(new Map<Id, Opportunity>(opps).keySet());
        Assert.areEqual(BULK_ROWS, stamped.size(), 'All ' + BULK_ROWS + ' deals were re-read');
        Integer stampedToday = 0;
        for (Date d : stamped.values()) {
            if (d == Date.today()) {
                stampedToday++;
            }
        }
        Assert.areEqual(
            BULK_ROWS,
            stampedToday,
            'Every one of the ' + BULK_ROWS + ' inserted deals carries today, including the '
            + (BULK_ROWS - 200) + ' in the second chunk'
        );
    }

    /**
     * Bulk UPDATE at BULK_ROWS: every deal moves stage in one DML and every date is OVERWRITTEN.
     *
     * The payload deliberately carries a stale `Stage_Entry_Date__c` on every record, so the
     * overwrite is proved at bulk scale without a second DML statement — the before-trigger has to
     * MEASURED 2026-08-31 in usman-dpeg (validation 0Afiw000000TnDRCA0): runChunkCount = 2 here
     * (200 + 51, with no cascade re-entry — a Dead/Pass transition triggers no downstream
     * Opportunity update), and runQueryCount = runDmlCount = 0.
     *
     * beat a value the caller explicitly supplied. `AccessLevel.SYSTEM_MODE` is required only
     * because that payload names the ungranted field; the production path does not carry it.
     */
    @isTest
    static void bulkStageChangeRestampsAcrossChunks() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_ROWS, false);
        insert opps; // fires the after-insert cascade (BULK_ROWS NDAs) - excluded from the measurement
        Date stale = Date.today().addDays(-BACKDATE_DAYS);
        for (Opportunity o : opps) {
            o.StageName = STAGE_DEAD;
            o.Rejection_Reason__c = REASON_OTHER;
            o.Stage_Entry_Date__c = stale; // the trigger must beat this
        }

        OpportunityStageEntryService.resetRunCounters();
        Test.startTest();
        Database.update(opps, true, AccessLevel.SYSTEM_MODE); // one DML, BULK_ROWS rows
        Test.stopTest();

        Assert.areEqual(
            0,
            OpportunityStageEntryService.runQueryCount,
            'ZERO SOQL inside the service across every chunk of a ' + BULK_ROWS + '-record update'
        );
        Assert.areEqual(
            0,
            OpportunityStageEntryService.runDmlCount,
            'ZERO DML inside the service across every chunk of a ' + BULK_ROWS + '-record update'
        );
        Assert.isTrue(
            OpportunityStageEntryService.runChunkCount >= 2,
            'A ' + BULK_ROWS + '-record update must invoke the service at least twice. Actual: '
            + OpportunityStageEntryService.runChunkCount
        );

        Map<Id, Date> stamped = entryDatesOf(new Map<Id, Opportunity>(opps).keySet());
        Assert.areEqual(BULK_ROWS, stamped.size(), 'All ' + BULK_ROWS + ' deals were re-read');
        Integer restamped = 0;
        for (Date d : stamped.values()) {
            if (d == Date.today()) {
                restamped++;
            }
        }
        Assert.areEqual(
            BULK_ROWS,
            restamped,
            'Every one of the ' + BULK_ROWS + ' deals changed stage, so every one must carry today '
            + 'and none may keep the stale date the payload supplied'
        );
    }
}
