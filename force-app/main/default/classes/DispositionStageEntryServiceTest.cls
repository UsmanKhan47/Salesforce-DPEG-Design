/**
 * @description Tests DispositionStageEntryService — the auto-create behind
 * DispositionTrigger / DispositionTriggerHandler (decisions D15/Q3, D16.2, D19.1). THREE stages,
 * three children:
 *
 *   `NDA` -> NDA__c (Party_Role__c = 'Buyer')   Tranche 3A
 *   `LOI` -> LOI__c (Disposition_LOI)           Tranche 3B fix pass (review C1)
 *   `PSA` -> Contract_Review__c (Disposition_PSA) Tranche 3C fix pass (review C1)
 *
 * ── WHAT EACH GROUP OF TESTS IS FOR ─────────────────────────────────────────
 *   STAGE ENTRY      it fires on entry, on BOTH insert and update, and on nothing else.
 *   SHAPE            the created child is on the right record type at that record type's own
 *                    starting value, parented to the disposition, with the ACQUISITION parent
 *                    left blank — separate facts, separate assertions.
 *   IDEMPOTENCY      never a second child of one type. ⚠ The NDA key is Party_Role__c = 'Buyer'
 *                    (a BROKER NDA deliberately does NOT suppress); the LOI and PSA keys are
 *                    simple presence. That difference is tested, not assumed.
 *   DEFERRED STAMP   Primary_NDA__c is written by a Queueable, after commit — and the LOI and PSA
 *                    blocks enqueue NOTHING, which is asserted rather than left to inspection.
 *   BULK             251 records through the REAL trigger, per stage.
 *
 * ── 🔴 WHY THE LOI AND PSA BLOCKS HAVE NO QUEUEABLE, PINNED BY A TEST ───────
 * `Disposition__c` has exactly one Primary_* lookup (`Primary_NDA__c`), so those two blocks have
 * no parent write and therefore nothing to defer. `loiAndPsaAutoCreateEnqueueNothing` is what
 * stops a future change adding a Queueable "for symmetry" — a job that does nothing would still
 * assert to the next reader that an approval-lock hazard exists on that path, which is the exact
 * inherited-justification mistake review W1 caught in DispositionNdaStampQueueable.
 *
 * ── 🔴 WHAT THIS SUITE CANNOT PROVE, SAID OUT LOUD ──────────────────────────
 * THE APPROVAL LOCK IS NOT REPRODUCED. No test in this repo runs a live approval process, and
 * `Disposition__c` is the entry object of three of them. The whole reason the parent stamp is
 * deferred to DispositionNdaStampQueueable is that an INLINE write throws ENTITY_IS_LOCKED while
 * an approval is pending — and an inline write would pass every test below. So these tests pin
 * the WIRING (the stamp lands, asynchronously) and NOT the reason the wiring is shaped that way.
 * The identical honest limit is recorded on OpportunityReviewServiceTest.loiRecordCreatesOnStageEntry,
 * whose feature reached production before the lock was discovered. Do not read a green run here as
 * licence to inline the stamp.
 *
 * ── ⚠ GOVERNOR ASSERTIONS ARE ON THE SUPPRESSION PATH, DELIBERATELY ─────────
 * `NDA_Signed_Rollup` is an after-save flow on NDA__c that maintains the disposition's two NDA
 * counters, so ANY test that actually creates an NDA measures this service's queries PLUS that
 * flow's. Pinning a number there would make this suite red every time a parallel declarative
 * change touched the flow — a false alarm about the wrong component. The precise budget assertion
 * is therefore made on the path where the service reads and then RETURNS (every disposition
 * already has its buyer NDA): exactly ONE query and ZERO DML for 251 records, which is the
 * property that matters — cost independent of record count. The creation path is proven bulk-safe
 * the direct way: 251 records through the trigger simply cannot complete if there is SOQL in a
 * loop.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * Trigger-driven, so the `.claude/rules/bulk-test-rule.md` per-transaction-singleton exemption
 * does NOT apply and a literal 251-record test exists (251 forces a SECOND trigger chunk, which
 * is the whole point of the number).
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls
 * @see force-app/main/default/classes/DispositionNdaStampQueueable.cls
 * @see force-app/main/default/classes/OpportunityReviewServiceTest.cls (the acquisitions twin)
 * @author Salesforce Developer
 */
@isTest
private class DispositionStageEntryServiceTest {

    private static final Integer BULK_N = 251;
    private static final String NDA_STAGE = 'NDA';
    private static final String LOI_STAGE = 'LOI';
    private static final String PSA_STAGE = 'PSA';
    private static final String READINESS_STAGE = 'Disposition Readiness';
    /** An On_Market stage used purely as "somewhere else to be" in re-entry tests. */
    private static final String LISTING_STAGE = 'Active Listing';

    /** An off-market disposition parked at Disposition Readiness — the state before NDA entry. */
    private static Disposition__c offMarketAtReadiness() {
        return TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            true
        );
    }

    /**
     * An ON-MARKET disposition parked at Disposition Readiness.
     *
     * 🔴 THE LOI AND PSA TESTS USE THIS ONE, AND THE CHOICE IS FORCED RATHER THAN ARBITRARY.
     * `All_NDAs_Signed_Before_Progression` blocks an OFF-market disposition from CHANGING stage
     * into `Disposition Offer` / `LOI` / `PSA` / `Closing` / `Completed` unless every NDA on it is
     * signed — so an off-market fixture would fail for a reason that has nothing to do with this
     * service. The rule is `RecordType.DeveloperName = 'Off_Market'`-scoped, so an on-market row is
     * exempt, and `LOI` / `PSA` are exposed on BOTH record types (verified in
     * objects/Disposition__c/recordTypes/), so this is the same code path a sell-side deal takes.
     * The off-market half is covered separately, on the INSERT path, where the VR is
     * ISCHANGED-gated and therefore inert.
     */
    private static Disposition__c onMarketAtReadiness() {
        return TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
    }

    private static List<NDA__c> ndasOn(Id dispositionId) {
        return [
            SELECT Id, Status__c, Party_Role__c, RecordTypeId, Disposition__c
            FROM NDA__c
            WHERE Disposition__c = :dispositionId
        ];
    }

    private static List<LOI__c> loisOn(Id dispositionId) {
        return [
            SELECT Id, Stage__c, RecordTypeId, Disposition__c, Opportunity__c
            FROM LOI__c
            WHERE Disposition__c = :dispositionId
        ];
    }

    private static List<Contract_Review__c> contractReviewsOn(Id dispositionId) {
        return [
            SELECT Id, Negotiation_Status__c, Stage__c, RecordTypeId, Disposition__c, Opportunity__c
            FROM Contract_Review__c
            WHERE Disposition__c = :dispositionId
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // STAGE ENTRY
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void enteringTheNdaStageOpensExactlyOneBuyerNda() {
        Disposition__c disposition = offMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        List<NDA__c> created = ndasOn(disposition.Id);
        Assert.areEqual(1, created.size(),
            'Entering the NDA stage opens exactly ONE NDA — the buyer\'s (D19.1). A broker NDA is '
            + 'added by hand from the related list, because the system cannot know in advance '
            + 'whether a broker introduced the buyer.');
        Assert.areEqual('Buyer', created[0].Party_Role__c,
            'Party_Role__c must be Buyer — it is both the business rule (D19.1) and this '
            + 'service\'s idempotency key');
        Assert.areEqual('Not Sent', created[0].Status__c,
            'The NDA must start at Disposition_NDA\'s own default. "Pending" is the ACQUISITION '
            + 'starting value and is restricted off this record type — but record-type picklist '
            + 'restriction is UI-only, so Apex DML would accept it silently and produce an NDA '
            + 'that RecordStageAdvanceService cannot advance.');
        Assert.areEqual(disposition.Id, created[0].Disposition__c,
            'The NDA must be parented to the disposition that opened it');
    }

    /**
     * A Disposition can legitimately be CREATED at the NDA stage — the seed scripts and this
     * tranche's own test surface do it, and All_NDAs_Signed_Before_Progression is ISCHANGED-only
     * precisely so they can. Handling insert as well as update is what stops "the NDA exists on
     * records made one way and not the other".
     */
    @isTest
    static void creatingADispositionAlreadyAtTheNdaStageAlsoOpensTheNda() {
        Disposition__c disposition = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        disposition.Disposition_Stage__c = NDA_STAGE;

        Test.startTest();
        insert disposition;
        Test.stopTest();

        Assert.areEqual(1, ndasOn(disposition.Id).size(),
            'An after-INSERT at the NDA stage must open the NDA too — insert is stage entry');
    }

    /**
     * The complement, and the one that keeps this trigger cheap for the whole org: an ordinary
     * save that does not touch the stage must do nothing at all.
     *
     * ⚠ The stage used here is on the ON_MARKET path on purpose. Moving an OFF_MARKET disposition
     * to Disposition Offer / LOI / PSA / Closing / Completed is blocked by
     * All_NDAs_Signed_Before_Progression when no signed NDA exists, so a "some other stage"
     * fixture built on the off-market path would fail for a reason that has nothing to do with
     * this service.
     */
    @isTest
    static void otherStageChangesAndPlainEditsOpenNothing() {
        Disposition__c onMarket = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        Disposition__c offMarket = offMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = onMarket.Id, Disposition_Stage__c = 'BOV Outreach');
        update new Disposition__c(Id = offMarket.Id, Title_Company__c = 'Renamed Title Co');
        Test.stopTest();

        Assert.areEqual(0, ndasOn(onMarket.Id).size(),
            'A stage change to something other than NDA must open nothing');
        Assert.areEqual(0, ndasOn(offMarket.Id).size(),
            'An edit that leaves the stage alone must open nothing. This is also what makes the '
            + 'deferred Primary_NDA__c stamp\'s own update a no-op rather than a recursion.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // RECORD TYPE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 UNCONDITIONAL BY DESIGN — DO NOT WRAP IN `if (isAvailable()) { ... }`.
     *
     * The production stamp is deliberately GUARDED on isAvailable() (see the service header: an
     * unguarded stamp throws INVALID_CROSS_REFERENCE_KEY and would roll the user's own stage
     * change back for every user until post-deploy gate T-A1 runs). This test is where the
     * softness ends, and it re-reads RecordTypeId from the DATABASE because a creation that
     * SUCCEEDED is not evidence the type landed.
     *
     * ⚠ EXPECT THIS RED UNTIL T-A1. Deploying objects/NDA__c/recordTypes/ is NOT enough — a
     * record type assigned to no profile resolves a real Id and is available to nobody,
     * administrators included (Modify All Data is an OBJECT permission and confers no record-type
     * access). And the failure it names is not cosmetic here: a Master-type DISPOSITION NDA seeds
     * at 'Not Sent', falls back to the ACQUISITION sequence, and that map has no 'Not Sent' entry
     * — so the record cannot be advanced or declined at all.
     */
    @isTest
    static void autoCreatedNdaCarriesTheDispositionRecordType() {
        Disposition__c disposition = offMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        Schema.RecordTypeInfo dispositionInfo = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get('Disposition_NDA');
        Assert.isNotNull(dispositionInfo,
            'PRECONDITION: the NDA__c "Disposition_NDA" record type does not exist in this org. '
            + 'objects/NDA__c/recordTypes/ must deploy BEFORE this class (metadata before Apex). '
            + 'Available: '
            + Schema.SObjectType.NDA__c.getRecordTypeInfosByDeveloperName().keySet());

        Assert.areEqual(dispositionInfo.getRecordTypeId(), ndasOn(disposition.Id)[0].RecordTypeId,
            'The auto-created NDA must carry the Disposition_NDA record type. A NULL value here '
            + 'means the record type resolved a real Id but is not AVAILABLE to the running user, '
            + 'so the deliberate isAvailable() guard in DispositionStageEntryService silently '
            + 'no-opped — that is post-deploy gate T-A1 not having run, and the resulting NDA is '
            + 'FUNCTIONALLY DEAD (Not Sent has no hop on the fallback acquisition sequence). Do '
            + 'not soften this assertion; run T-A1.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // IDEMPOTENCY
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void reEnteringTheNdaStageDoesNotOpenASecondNda() {
        Disposition__c disposition = offMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        // Leave and come back — the shape a user produces by correcting a mis-click.
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = READINESS_STAGE);
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        Assert.areEqual(1, ndasOn(disposition.Id).size(),
            'Re-entering the stage must not open a second NDA. Both guards should hold here — the '
            + 'stage-ENTRY test and the Party_Role__c = Buyer idempotency read.');
    }

    @isTest
    static void anExistingBuyerNdaSuppressesAutoCreate() {
        Disposition__c disposition = offMarketAtReadiness();
        // A buyer NDA added by hand BEFORE the stage was entered.
        TestDataFactory.createDispositionNda(disposition.Id, true);

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        Assert.areEqual(1, ndasOn(disposition.Id).size(),
            'A buyer NDA that already exists suppresses auto-create — the user who added it early '
            + 'must not end up with two');
    }

    /**
     * 🔴 THE OTHER HALF OF THE IDEMPOTENCY ARGUMENT, and the reason the key is the ROLE and not
     * "any NDA on this disposition". A broker NDA is added by hand when a broker introduced the
     * buyer; if it suppressed auto-create, the user who added it first would silently never get
     * the BUYER's NDA — and All_NDAs_Signed_Before_Progression would then release the disposition
     * on a signed broker NDA alone, with no buyer NDA anywhere.
     *
     * Without this test, anExistingBuyerNdaSuppressesAutoCreate would pass just as happily against
     * an "any NDA" implementation.
     */
    @isTest
    static void anExistingBrokerNdaDoesNotSuppressTheBuyerNda() {
        Disposition__c disposition = offMarketAtReadiness();
        NDA__c brokerNda = TestDataFactory.createDispositionNda(disposition.Id, false);
        brokerNda.Party_Role__c = 'Introducing Broker';
        insert brokerNda;

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        List<NDA__c> all = ndasOn(disposition.Id);
        Assert.areEqual(2, all.size(),
            'A broker NDA must NOT suppress the buyer NDA — the suppression key is '
            + 'Party_Role__c = Buyer, not "has any NDA" (D19.1)');
        Integer buyers = 0;
        for (NDA__c nda : all) {
            if ('Buyer'.equals(nda.Party_Role__c)) {
                buyers++;
            }
        }
        Assert.areEqual(1, buyers, 'Exactly one BUYER NDA exists after auto-create');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE DEFERRED PARENT STAMP
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Primary_NDA__c is written by DispositionNdaStampQueueable, which is why the assertion sits
     * AFTER Test.stopTest() — that is when a Queueable enqueued inside the test block runs.
     *
     * ⚠ See the class header: this pins the WIRING, not the reason for it. In production the
     * disposition can be LOCKED by one of its three approvals at the moment the NDA is created,
     * and an inline write would throw ENTITY_IS_LOCKED — SYSTEM_MODE lifts CRUD and FLS but never
     * a lock. No test here reproduces that, so an inlined stamp would pass this test and fail in
     * production, exactly as it did on the LOI path.
     */
    @isTest
    static void primaryNdaIsStampedByTheQueueableAfterCommit() {
        Disposition__c disposition = offMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Assert.isNull(
            [SELECT Primary_NDA__c FROM Disposition__c WHERE Id = :disposition.Id].Primary_NDA__c,
            'The stamp must NOT have happened inline. If this is already populated the write was '
            + 'moved back into the trigger transaction, which is the change that throws '
            + 'ENTITY_IS_LOCKED under a pending approval.');
        Test.stopTest();

        Disposition__c stamped =
            [SELECT Primary_NDA__c FROM Disposition__c WHERE Id = :disposition.Id];
        Assert.areEqual(ndasOn(disposition.Id)[0].Id, stamped.Primary_NDA__c,
            'Primary_NDA__c must point at the auto-created NDA once the Queueable has run — it is '
            + 'how the disposition page and downstream automation resolve the NDA to act on');
    }

    /**
     * The Queueable's own empty/null guard. It is unreachable from the service (which enqueues
     * only after a non-empty insert), so it is driven directly — an async NullPointerException
     * surfaces only as a failed AsyncApexJob nobody watches, which is why the guard exists at all.
     */
    @isTest
    static void stampQueueableWithNothingToDoIsANoOp() {
        Test.startTest();
        System.enqueueJob(new DispositionNdaStampQueueable(null));
        System.enqueueJob(new DispositionNdaStampQueueable(new Map<Id, Id>()));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Disposition__c WHERE Primary_NDA__c != NULL],
            'An empty or null payload must write nothing and must not throw');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BULK — 251 records through the REAL trigger
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 251 forces a SECOND trigger chunk (chunks are 200), which is the entire reason for the
     * number: a service that queried or DML'd per record would blow the SOQL or DML limit long
     * before finishing, so COMPLETING this test at all is the SOQL-in-a-loop falsifier. The
     * assertions then pin that every one of the 251 got its NDA, not just the first chunk.
     */
    @isTest
    static void bulkStageEntryAt251OpensOneNdaEach() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            true
        );
        List<Disposition__c> moves = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            moves.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = NDA_STAGE));
        }

        Test.startTest();
        update moves;
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM NDA__c WHERE Disposition__c IN :dispositions],
            'Every one of the 251 dispositions must get exactly one NDA — 251 spans TWO trigger '
            + 'chunks, so a total of 200 here would mean the second chunk was dropped');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM NDA__c WHERE Disposition__c IN :dispositions AND Party_Role__c = 'Buyer'],
            'All 251 must be BUYER NDAs');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :dispositions AND Primary_NDA__c != NULL],
            'The deferred stamp must reach all 251 — one Queueable per trigger chunk, each '
            + 'carrying its whole chunk, never one job per record');
    }

    /**
     * 🔴 THE GOVERNOR ASSERTION, MADE ON THE SUPPRESSION PATH ON PURPOSE (see the class header):
     * every disposition already has its buyer NDA, so the service reads once and returns without
     * inserting — which keeps NDA_Signed_Rollup out of the measurement and lets the numbers be
     * EXACT rather than "≤ something".
     *
     * The property being pinned is COST INDEPENDENT OF RECORD COUNT: one query and zero DML for
     * 251 records. A future change that moved the idempotency read inside the loop would report
     * 251 here (or, more likely, fail outright at 101), and one that dropped the early return
     * would report DML.
     *
     * The service is invoked DIRECTLY rather than through the trigger so the measurement contains
     * this service and nothing else — no chunking, no sibling automation.
     */
    @isTest
    static void suppressionPathCostsOneQueryAndNoDmlAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            true
        );
        List<NDA__c> existing = new List<NDA__c>();
        for (Disposition__c d : dispositions) {
            existing.addAll(TestDataFactory.createDispositionNdas(1, d.Id, false));
        }
        insert existing;   // built in the loop, inserted once — never DML in a loop

        // A synthetic trigger context: the stage has just moved from Readiness to NDA on all 251.
        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : dispositions) {
            newList.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = NDA_STAGE));
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Disposition_Stage__c = READINESS_STAGE));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 dispositions — the idempotency read is issued once for the '
            + 'whole collection. Anything above 1 means it moved into the loop.');
        Assert.areEqual(0, dmlUsed,
            'Zero DML when every disposition already has its buyer NDA. A non-zero count means '
            + 'the early return after the idempotency filter was lost, and 251 duplicate NDAs '
            + 'were created.');
        Assert.areEqual(BULK_N, [SELECT COUNT() FROM NDA__c WHERE Disposition__c IN :dispositions],
            'Still exactly one NDA each — nothing was added');
    }

    /**
     * The cheapest and most common path in the org: a Disposition save that does not touch the
     * stage. It must cost NOTHING — no query, no DML, no enqueue — because this trigger now fires
     * on every single Disposition write, including the two the feature itself causes (the
     * NDA_Signed_Rollup counter update and the Primary_NDA__c stamp).
     */
    @isTest
    static void aSaveThatDoesNotChangeTheStageCostsNothingAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            true
        );
        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : dispositions) {
            newList.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = READINESS_STAGE));
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Disposition_Stage__c = READINESS_STAGE));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A save with no stage change must not query. This path runs on EVERY Disposition '
            + 'write in the org, including the ones this feature causes itself.');
        Assert.areEqual(0, dmlUsed, 'A save with no stage change must not write');
    }

    /**
     * The handler's own dispatch, driven through a real trigger. It exists so a future change that
     * routes the wrong context (or drops one) is caught here rather than by the absence of an NDA
     * in some unrelated suite.
     */
    @isTest
    static void triggerHandlerRoutesBothContexts() {
        Test.startTest();
        // after INSERT at the NDA stage
        Disposition__c inserted = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        inserted.Disposition_Stage__c = NDA_STAGE;
        insert inserted;
        // after UPDATE into the NDA stage
        Disposition__c updated = offMarketAtReadiness();
        update new Disposition__c(Id = updated.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        Assert.areEqual(1, ndasOn(inserted.Id).size(), 'afterInsert must route to the service');
        Assert.areEqual(1, ndasOn(updated.Id).size(), 'afterUpdate must route to the service');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 `LOI` STAGE — the sell-side LOI. Tranche 3B fix pass (review C1: before this,
    // NOTHING in the application could create a disposition LOI, by any persona,
    // including an administrator.)
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void enteringTheLoiStageOpensExactlyOneDispositionLoi() {
        Disposition__c disposition = onMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE);
        Test.stopTest();

        List<LOI__c> created = loisOn(disposition.Id);
        Assert.areEqual(1, created.size(),
            'Entering the LOI stage opens exactly ONE disposition LOI. Zero here is the review C1 '
            + 'state: the Path step, the two loop quick actions, the counter-offer card and the '
            + 'record-type-scoped allow-lists all sit downstream of a record nothing can create.');
        Assert.areEqual('Received', created[0].Stage__c,
            'The LOI must start at Disposition_LOI\'s own default. "Draft" is the ACQUISITION '
            + 'starting value and is restricted off this record type — but record-type picklist '
            + 'restriction is UI-only, so Apex DML would accept it silently and produce an LOI '
            + 'whose stage is off its own value set, which RecordStageAdvanceService could never '
            + 'advance (the two LOI value sets are fully disjoint).');
        Assert.areEqual(disposition.Id, created[0].Disposition__c,
            'The LOI must be parented to the disposition that opened it');
        Assert.isNull(created[0].Opportunity__c,
            'Opportunity__c must stay BLANK. A populated acquisition parent would make the row '
            + 'look buy-side to CounterOfferService.isSaleSide\'s fallback leg — which is the leg '
            + 'that decides the Buyer/Seller vocabulary for every row until gate T-A1 runs.');
    }

    /**
     * The OFF-MARKET half, taken on the INSERT path deliberately.
     *
     * ⚠ `All_NDAs_Signed_Before_Progression` is `ISCHANGED(Disposition_Stage__c)`-gated, and
     * ISCHANGED is false on insert — so creating an off-market disposition already at `LOI` is the
     * only way to reach this block off-market without first signing an NDA. It proves two things at
     * once: the LOI block is NOT scoped to a record type (both types expose the stage), and insert
     * counts as stage entry here exactly as it does for the NDA.
     */
    @isTest
    static void creatingAnOffMarketDispositionAtTheLoiStageAlsoOpensTheLoi() {
        Disposition__c disposition = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        disposition.Disposition_Stage__c = LOI_STAGE;

        Test.startTest();
        insert disposition;
        Test.stopTest();

        Assert.areEqual(1, loisOn(disposition.Id).size(),
            'An OFF-market disposition entering LOI must get its LOI too. A block scoped to the '
            + 'On_Market record type would silently strip the negotiation record from every '
            + 'direct sale, and an after-INSERT that did not route would strip it from every '
            + 'disposition created at this stage by a data load.');
    }

    /**
     * 🔴 UNCONDITIONAL BY DESIGN — DO NOT WRAP IN `if (isAvailable()) { ... }`. Same contract as
     * autoCreatedNdaCarriesTheDispositionRecordType: the production stamp is guarded (an unguarded
     * one throws INVALID_CROSS_REFERENCE_KEY and rolls the user's stage change back for every user
     * until gate T-A1 runs), so this is where the softness ends. It re-reads RecordTypeId from the
     * DATABASE because a creation that SUCCEEDED is not evidence the type landed.
     */
    @isTest
    static void autoCreatedLoiCarriesTheDispositionRecordType() {
        Disposition__c disposition = onMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE);
        Test.stopTest();

        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get('Disposition_LOI');
        Assert.isNotNull(info,
            'PRECONDITION FAILED: the LOI__c "Disposition_LOI" record type does not exist in this '
            + 'org. objects/LOI__c/recordTypes/ must deploy BEFORE this class (metadata before '
            + 'Apex). Available: '
            + Schema.SObjectType.LOI__c.getRecordTypeInfosByDeveloperName().keySet());

        Assert.areEqual(info.getRecordTypeId(), loisOn(disposition.Id)[0].RecordTypeId,
            'PRECONDITION FAILED (post-deploy gate T-A1): the auto-created LOI must carry the '
            + 'Disposition_LOI record type. A NULL value here means the type resolved a real Id '
            + 'but is not AVAILABLE to the running user, so the deliberate isAvailable() guard in '
            + 'DispositionStageEntryService silently no-opped — that is gate T-A1 (profile '
            + 'record-type assignment) not having run. The resulting LOI is FUNCTIONALLY DEAD: it '
            + 'seeds at "Received", falls back to the ACQUISITION stage sequence, and that map has '
            + 'no "Received" entry, so neither Advance Stage nor either loop action can move it. '
            + 'Do not soften this assertion; run T-A1.');
    }

    @isTest
    static void reEnteringTheLoiStageDoesNotOpenASecondLoi() {
        Disposition__c disposition = onMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE);
        // Leave and come back — the shape a user produces by correcting a mis-click.
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LISTING_STAGE);
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE);
        Test.stopTest();

        Assert.areEqual(1, loisOn(disposition.Id).size(),
            'Re-entering the stage must not open a second LOI. Both guards should hold here — the '
            + 'stage-ENTRY test and the presence idempotency read.');
    }

    /**
     * A hand-created LOI suppresses auto-create.
     *
     * ⚠ THE FIXTURE IS BUILT WITHOUT A RECORD TYPE GUARANTEE ON PURPOSE. TestDataFactory guards
     * its stamp on isAvailable(), so before gate T-A1 this row lands on MASTER — and it must STILL
     * suppress. An idempotency read scoped to the Disposition_LOI record type would miss it and
     * mint a duplicate, which is precisely why the selector query keys on the Disposition__c
     * lookup and not on RecordTypeId.
     */
    @isTest
    static void anExistingDispositionLoiSuppressesAutoCreate() {
        Disposition__c disposition = onMarketAtReadiness();
        TestDataFactory.createDispositionLoi(disposition.Id, true);

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE);
        Test.stopTest();

        Assert.areEqual(1, loisOn(disposition.Id).size(),
            'An LOI that already exists on this disposition suppresses auto-create — including a '
            + 'MASTER-type one, which is what every hand-created row is until gate T-A1 runs');
    }

    /**
     * ⚠ AN ACQUISITION LOI ON THE SAME ORG MUST NOT SUPPRESS ANYTHING, and this is the test that
     * makes the "presence" key mean "presence ON THIS DISPOSITION". Without it, an idempotency read
     * that had drifted to `SELECT Id FROM LOI__c` (or that filtered on the wrong lookup) would pass
     * every other test in this section.
     */
    @isTest
    static void anAcquisitionLoiElsewhereDoesNotSuppressTheDispositionLoi() {
        Disposition__c disposition = onMarketAtReadiness();
        TestDataFactory.createLoi(null, true); // buy-side, no Disposition__c

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE);
        Test.stopTest();

        Assert.areEqual(1, loisOn(disposition.Id).size(),
            'An unrelated ACQUISITION LOI must not suppress the disposition LOI — the idempotency '
            + 'key is "this disposition already has one", not "an LOI exists"');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 `PSA` STAGE — the sell-side Contract Review. Tranche 3C fix pass (review C1).
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void enteringThePsaStageOpensExactlyOneDispositionContractReview() {
        Disposition__c disposition = onMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = PSA_STAGE);
        Test.stopTest();

        List<Contract_Review__c> created = contractReviewsOn(disposition.Id);
        Assert.areEqual(1, created.size(),
            'Entering the PSA stage opens exactly ONE disposition Contract Review. Zero here is '
            + 'the review C1 state — and everything 3C built (the gate split, the sharing rules, '
            + 'the version log, ContractExecutionService\'s disposition arm) is downstream of it.');
        Assert.areEqual('Initial Draft', created[0].Negotiation_Status__c,
            'The PSA must start at Disposition_PSA\'s own default — our legal issues the first '
            + 'draft on a sale');
        Assert.areEqual('PSA Drafting', created[0].Stage__c,
            '🔴 Stage__c is a DERIVED PROJECTION and this service must NEVER write it: the '
            + 'before-save flow Contract_Review_Stage_Sync recomputes it from '
            + 'Negotiation_Status__c, so a direct write commits and is silently discarded. This '
            + 'assertion proves the derivation ran from the status we DID set. If it is red, check '
            + 'that Contract_Review_Stage_Sync is Active in this org before changing any code.');
        Assert.areEqual(disposition.Id, created[0].Disposition__c,
            'The Contract Review must be parented to the disposition that opened it');
        Assert.isNull(created[0].Opportunity__c,
            '🔴 Opportunity__c must stay BLANK, and here that is load-bearing rather than tidy: '
            + 'ContractExecutionService.handleExecution runs its two arms off the two parent '
            + 'LOOKUPS through independent ifs, so a row carrying both would, on execution, stamp '
            + 'an Opportunity and arm a Day-0 Transaction fan-out for a deal nobody is buying.');
    }

    /** The OFF-MARKET half on the INSERT path — see the LOI twin for why the VR forces this shape. */
    @isTest
    static void creatingAnOffMarketDispositionAtThePsaStageAlsoOpensTheContractReview() {
        Disposition__c disposition = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        disposition.Disposition_Stage__c = PSA_STAGE;

        Test.startTest();
        insert disposition;
        Test.stopTest();

        Assert.areEqual(1, contractReviewsOn(disposition.Id).size(),
            'An OFF-market disposition entering PSA must get its Contract Review too — the stage '
            + 'is on BOTH record types and the block is deliberately not record-type-scoped');
    }

    /** 🔴 UNCONDITIONAL BY DESIGN — see autoCreatedLoiCarriesTheDispositionRecordType. */
    @isTest
    static void autoCreatedContractReviewCarriesTheDispositionRecordType() {
        Disposition__c disposition = onMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = PSA_STAGE);
        Test.stopTest();

        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get('Disposition_PSA');
        Assert.isNotNull(info,
            'PRECONDITION FAILED: the Contract_Review__c "Disposition_PSA" record type does not '
            + 'exist in this org. objects/Contract_Review__c/recordTypes/ must deploy BEFORE this '
            + 'class (metadata before Apex). Available: '
            + Schema.SObjectType.Contract_Review__c.getRecordTypeInfosByDeveloperName().keySet());

        Assert.areEqual(info.getRecordTypeId(), contractReviewsOn(disposition.Id)[0].RecordTypeId,
            'PRECONDITION FAILED (post-deploy gate T-A1): the auto-created Contract Review must '
            + 'carry the Disposition_PSA record type. 🔴 THIS ONE FAILS THE QUIETEST OF THE THREE '
            + 'AND IS THEREFORE THE ONE MOST WORTH KEEPING. Both PSA record types expose the same '
            + 'four Negotiation_Status__c values, so a Master-type disposition PSA advances '
            + 'perfectly and every toast is right — it is wrong only about which PERSONA may drive '
            + 'it (RecordStageAdvanceService picks DEAL_DRIVER vs DISPOSITION_DRIVER off the '
            + 'record type), so the sale\'s own persona simply cannot advance it and nothing '
            + 'reports why. Do not soften this assertion; run T-A1.');
    }

    @isTest
    static void reEnteringThePsaStageDoesNotOpenASecondContractReview() {
        Disposition__c disposition = onMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = PSA_STAGE);
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE);
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = PSA_STAGE);
        Test.stopTest();

        Assert.areEqual(1, contractReviewsOn(disposition.Id).size(),
            'Re-entering the stage must not open a second Contract Review');
        Assert.areEqual(1, loisOn(disposition.Id).size(),
            'And the LOI opened on the way past is itself opened exactly once — this walk crosses '
            + 'two auto-create stages, so it also proves the two blocks do not interfere');
    }

    @isTest
    static void anExistingDispositionContractReviewSuppressesAutoCreate() {
        Disposition__c disposition = onMarketAtReadiness();
        TestDataFactory.createDispositionContractReview(disposition.Id, true);

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = PSA_STAGE);
        Test.stopTest();

        Assert.areEqual(1, contractReviewsOn(disposition.Id).size(),
            'A Contract Review that already exists on this disposition suppresses auto-create — '
            + 'including a MASTER-type one, which is what every hand-created row is until T-A1');
    }

    /** The cross-object complement of the LOI twin — see it for why this matters. */
    @isTest
    static void anAcquisitionContractReviewElsewhereDoesNotSuppressTheDispositionPsa() {
        Disposition__c disposition = onMarketAtReadiness();
        TestDataFactory.createContractReview(null, true); // buy-side, no Disposition__c

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = PSA_STAGE);
        Test.stopTest();

        Assert.areEqual(1, contractReviewsOn(disposition.Id).size(),
            'An unrelated ACQUISITION Contract Review must not suppress the disposition PSA');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 NO PARENT STAMP ON THE TWO NEW BLOCKS — the falsifier for "add a
    // Queueable for symmetry"
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The NDA block enqueues DispositionNdaStampQueueable because it writes back to
     * `Disposition__c.Primary_NDA__c` and SYSTEM_MODE does not lift an approval lock. The LOI and
     * PSA blocks have NOTHING to write back — `Primary_NDA__c` is the only Primary_* lookup on the
     * object — so they must enqueue nothing at all.
     *
     * 🔴 THIS IS NOT A PERFORMANCE ASSERTION. A Queueable that exists and does nothing would tell
     * the next reader that an approval-lock hazard has been handled on this path, when in fact the
     * hazard is absent (no parent write; `LOI` and `PSA` are not any approval's entry stage; none
     * of the three approvals performs a field update at all). Review W1 caught exactly that shape
     * of inherited, untrue justification in DispositionNdaStampQueueable's own header.
     *
     * The service is invoked DIRECTLY so the count contains this service and nothing else.
     */
    @isTest
    static void loiAndPsaAutoCreateEnqueueNothing() {
        Disposition__c loiEntrant = onMarketAtReadiness();
        Disposition__c psaEntrant = onMarketAtReadiness();

        List<Disposition__c> newList = new List<Disposition__c>{
            new Disposition__c(Id = loiEntrant.Id, Disposition_Stage__c = LOI_STAGE),
            new Disposition__c(Id = psaEntrant.Id, Disposition_Stage__c = PSA_STAGE)
        };
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>{
            loiEntrant.Id => new Disposition__c(Id = loiEntrant.Id, Disposition_Stage__c = READINESS_STAGE),
            psaEntrant.Id => new Disposition__c(Id = psaEntrant.Id, Disposition_Stage__c = READINESS_STAGE)
        };

        Test.startTest();
        Integer jobsBefore = Limits.getQueueableJobs();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Integer jobsUsed = Limits.getQueueableJobs() - jobsBefore;
        Test.stopTest();

        Assert.areEqual(0, jobsUsed,
            'The LOI and PSA blocks must enqueue NOTHING. A non-zero count means a Queueable was '
            + 'added "for symmetry" with the NDA block — but Disposition__c has no Primary_LOI__c '
            + 'and no Primary_Contract__c, so there is no parent write to defer and its presence '
            + 'would assert a hazard that is not there.');
        Assert.areEqual(1, loisOn(loiEntrant.Id).size(), 'The LOI was still created');
        Assert.areEqual(1, contractReviewsOn(psaEntrant.Id).size(),
            'The Contract Review was still created');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BULK — 251 records through the REAL trigger, per new stage
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 251 forces a SECOND trigger chunk (chunks are 200), which is the entire reason for the
     * number: a service that queried or DML'd per record would blow the SOQL or DML limit long
     * before finishing, so COMPLETING this test at all is the SOQL-in-a-loop falsifier.
     */
    @isTest
    static void bulkLoiStageEntryAt251OpensOneLoiEach() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        List<Disposition__c> moves = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            moves.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = LOI_STAGE));
        }

        Test.startTest();
        update moves;
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM LOI__c WHERE Disposition__c IN :dispositions],
            'Every one of the 251 dispositions must get exactly one LOI — 251 spans TWO trigger '
            + 'chunks, so a total of 200 here would mean the second chunk was dropped');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM LOI__c WHERE Disposition__c IN :dispositions AND Stage__c = 'Received'],
            'All 251 must open at the disposition record type\'s own starting stage');
    }

    @isTest
    static void bulkPsaStageEntryAt251OpensOneContractReviewEach() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        List<Disposition__c> moves = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            moves.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = PSA_STAGE));
        }

        Test.startTest();
        update moves;
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Contract_Review__c WHERE Disposition__c IN :dispositions],
            'Every one of the 251 dispositions must get exactly one Contract Review');
        Assert.areEqual(BULK_N,
            [
                SELECT COUNT() FROM Contract_Review__c
                WHERE Disposition__c IN :dispositions AND Negotiation_Status__c = 'Initial Draft'
            ],
            'All 251 must open at Initial Draft');
    }

    /**
     * 🔴 THE GOVERNOR ASSERTION FOR THE LOI BLOCK, MADE ON THE SUPPRESSION PATH ON PURPOSE, for
     * the reason the class header gives: every disposition already has its LOI, so the service
     * reads once and returns without inserting — which keeps every after-save flow out of the
     * measurement and lets the numbers be EXACT rather than "≤ something".
     *
     * The property being pinned is COST INDEPENDENT OF RECORD COUNT: one query and zero DML for
     * 251 records. A future change that moved the idempotency read inside the loop would report
     * 251 here (or, more likely, fail outright at 101), and one that dropped the early return
     * would report DML.
     */
    @isTest
    static void loiSuppressionPathCostsOneQueryAndNoDmlAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        List<LOI__c> existing = new List<LOI__c>();
        for (Disposition__c d : dispositions) {
            existing.addAll(TestDataFactory.createDispositionLois(1, d.Id, false));
        }
        insert existing;   // built in the loop, inserted once — never DML in a loop

        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : dispositions) {
            newList.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = LOI_STAGE));
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Disposition_Stage__c = READINESS_STAGE));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 dispositions — the LOI idempotency read is issued once for '
            + 'the whole collection. Anything above 1 means it moved into the loop. ZERO would '
            + 'mean the LOI block stopped running at all.');
        Assert.areEqual(0, dmlUsed,
            'Zero DML when every disposition already has its LOI. A non-zero count means the early '
            + 'return after the idempotency filter was lost, and 251 duplicate LOIs were created.');
        Assert.areEqual(BULK_N, [SELECT COUNT() FROM LOI__c WHERE Disposition__c IN :dispositions],
            'Still exactly one LOI each — nothing was added');
    }

    /**
     * 🔴 ONE QUERY PER STAGE ENTERED, NEVER ONE PER RECORD AND NEVER ONE COMBINED READ. Three
     * dispositions, one entering each target stage, all three already carrying their child — so
     * every block reads and returns.
     *
     * This is the test that pins the SHAPE of the three-block restructure. Two regressions it
     * catches that nothing else does: a change that merged the three reads into one polymorphic
     * query (which cannot exist — they are three objects) would report fewer than 3, and a change
     * that dropped a block's early return would report DML on a chunk where every child already
     * exists. It also proves the three blocks are INDEPENDENT: a chunk carrying all three stages
     * runs all three, rather than the first match winning.
     */
    @isTest
    static void aMixedChunkQueriesOncePerStageAndWritesNothingWhenAllChildrenExist() {
        Disposition__c ndaEntrant = offMarketAtReadiness();
        Disposition__c loiEntrant = onMarketAtReadiness();
        Disposition__c psaEntrant = onMarketAtReadiness();
        TestDataFactory.createDispositionNda(ndaEntrant.Id, true);          // Party_Role__c 'Buyer'
        TestDataFactory.createDispositionLoi(loiEntrant.Id, true);
        TestDataFactory.createDispositionContractReview(psaEntrant.Id, true);

        List<Disposition__c> newList = new List<Disposition__c>{
            new Disposition__c(Id = ndaEntrant.Id, Disposition_Stage__c = NDA_STAGE),
            new Disposition__c(Id = loiEntrant.Id, Disposition_Stage__c = LOI_STAGE),
            new Disposition__c(Id = psaEntrant.Id, Disposition_Stage__c = PSA_STAGE)
        };
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : newList) {
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Disposition_Stage__c = READINESS_STAGE));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(3, queriesUsed,
            'EXACTLY THREE queries — one idempotency read per stage present in the chunk, each '
            + 'issued once for its whole collection. Fewer means a block stopped running; more '
            + 'means a read moved into a loop.');
        Assert.areEqual(0, dmlUsed,
            'Every child already exists, so all three blocks must return before writing');
        Assert.areEqual(1, ndasOn(ndaEntrant.Id).size(), 'No second NDA');
        Assert.areEqual(1, loisOn(loiEntrant.Id).size(), 'No second LOI');
        Assert.areEqual(1, contractReviewsOn(psaEntrant.Id).size(), 'No second Contract Review');
    }
}
