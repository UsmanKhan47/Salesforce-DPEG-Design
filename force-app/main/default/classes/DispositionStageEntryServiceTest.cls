/**
 * @description Tests DispositionStageEntryService — the auto-create behind
 * DispositionTrigger / DispositionTriggerHandler (decisions D15/Q3, D16.2, D19.1, D28/Q3). FOUR
 * stages, four children:
 *
 *   `NDA`            -> NDA__c (Party_Role__c = 'Buyer',     Tranche 3A
 *                              Broker__c per record type)   + broker stamp 2026-08-21
 *   `LOI`            -> LOI__c (Disposition_LOI)             Tranche 3B fix pass (review C1)
 *   `PSA`            -> Contract_Review__c (Disposition_PSA) Tranche 3C fix pass (review C1)
 *   `Active Listing` -> Broker_Listing__c + the marketing clock   Tranche 5B
 *
 * ⚠ THE FOURTH IS THE ONLY ONE THAT ALSO USES A BEFORE-SAVE CONTEXT. `stampListingDates` writes
 * `Disposition__c.Listing_Date__c` in memory during the user's own save; the other three blocks
 * have no equivalent and must not grow one. Its tests are in their own section at the end of this
 * file, with the fixture trap that makes the obvious version of them vacuous written out in full.
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
 *   BROKER STAMP     (2026-08-21) `NDA__c.Broker__c` is resolved from a DIFFERENT SOURCE per
 *                    record type, an unresolvable broker never blocks the NDA, and the extra read
 *                    sits AFTER the idempotency early return. Its own section, with its own
 *                    statement of what is unbuildable in this org and therefore untested. Every
 *                    assertion there is "the RIGHT broker" — a wrong one satisfies "is it set?".
 *
 * ── 🔴 WHY THE LOI AND PSA BLOCKS HAVE NO QUEUEABLE, PINNED BY A TEST ───────
 * `Disposition__c` has exactly one Primary_* lookup (`Primary_NDA__c`), so those two blocks have
 * no parent write and therefore nothing to defer. `loiAndPsaAutoCreateEnqueueNothing` is what
 * stops a future change adding a Queueable "for symmetry" — a job that does nothing would still
 * assert to the next reader that an approval-lock hazard exists on that path, which is the exact
 * inherited-justification mistake review W1 caught in DispositionNdaStampQueueable.
 *
 * ── 🔴 ONE TEST DOES NOT RUN AS THE ADMIN, AND THAT IS WHY IT EXISTS ────────
 * `loiStampsTheDispositionTypeForARecordTypeBlindPrincipal` (added 2026-08-25, DISP-0025) runs as
 * a Minimum-Access persona for whom `Disposition_LOI` is `isAvailable() == false`. Every other
 * test here runs as the admin test-running user, for whom every record type is available — which
 * is precisely why the production stamp defect was unreachable by this suite until that fixture
 * existed. Read its Javadoc before changing anything about the record-type stamp: it is also the
 * experiment that settles whether `AccessLevel.SYSTEM_MODE` DML enforces record-type visibility,
 * a question `OpportunityReviewService`'s header has carried as UNDETERMINED since 2026-08-09.
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
     * 🔴 RETRACTED 2026-08-19 (flow redesign) — `All_NDAs_Signed_Before_Progression` DROPPED its
     * `RecordType.DeveloperName = 'Off_Market'` term and now blocks BOTH record types from
     * CHANGING stage into Release Materials / Active Listing / Offer Selection / LOI / PSA /
     * Closing / Sale Closes unless every non-Declined NDA on the disposition is Signed. The
     * retracted sentence — "The rule is Off_Market-scoped, so an on-market row is exempt" — is
     * quoted rather than deleted because it is exactly what a future reader would assume. Every
     * caller of this helper that then performs a real `update` DML into one of those stages must
     * call `signBuyerNdaOn(disposition.Id)` first (see that method) or the VR refuses the
     * transition for a reason that has nothing to do with the service under test. An INSERT
     * straight at a gated stage is still exempt — the rule is `ISCHANGED`-only, deliberately, so
     * the off-market insert-path tests below remain inert.
     */
    private static Disposition__c onMarketAtReadiness() {
        return TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
    }

    /**
     * ⚠ ADDED FOR THE 2026-08-19 FLOW REDESIGN. `All_NDAs_Signed_Before_Progression` dropped its
     * `RecordType.DeveloperName = 'Off_Market'` term and now blocks BOTH record types from moving
     * into Release Materials, Active Listing, Offer Selection, LOI, PSA, Closing or Sale Closes
     * unless every non-Declined NDA on the disposition is Signed (BLANKVALUE(NDA_Count__c,0) = 0
     * still blocks a disposition with NO NDA at all). Every test in this file that jumps a FRESH
     * on-market disposition straight from Readiness to one of those stages via a real `update`
     * DML — as opposed to `insert`, which the rule's ISCHANGED-only guard deliberately exempts —
     * must sign a buyer NDA first, or the validation rule refuses a transition this class exists
     * to test for an unrelated reason. Off-market fixtures already needed this; on-market ones
     * did not until this redesign.
     *
     * Inserted directly at 'Signed' rather than walked through 'Prepare' -> ... -> 'Signed' —
     * NDA_Signed_Rollup is `RecordAfterSave` / `CreateAndUpdate`, so it fires on the insert either
     * way and there is nothing for this class to prove about the NDA's own walk.
     */
    private static void signBuyerNdaOn(Id dispositionId) {
        // Promoted to TestDataFactory.signBuyerNdaOn (2026-08-19) so ContractExecutionServiceTest
        // can reuse the identical fixture. Kept as a thin delegate here so every existing call
        // site in this file needs no change.
        TestDataFactory.signBuyerNdaOn(dispositionId);
    }

    /** Bulk twin of signBuyerNdaOn — ONE insert for the whole set, never one per record. */
    private static void signBuyerNdasOn(List<Disposition__c> dispositions) {
        // Promoted to TestDataFactory.signBuyerNdasOn (2026-08-19) — see signBuyerNdaOn above.
        TestDataFactory.signBuyerNdasOn(dispositions);
    }

    /**
     * ⚠ `Broker__c` WAS ADDED TO THIS SELECT ON 2026-08-21 with the broker stamp. Every existing
     * caller ignores it; widening a test-local read costs nothing and saves a parallel helper.
     */
    private static List<NDA__c> ndasOn(Id dispositionId) {
        return [
            SELECT Id, Status__c, Party_Role__c, RecordTypeId, Disposition__c, Broker__c
            FROM NDA__c
            WHERE Disposition__c = :dispositionId
        ];
    }

    private static List<LOI__c> loisOn(Id dispositionId) {
        return [
            SELECT Id, Stage__c, RecordTypeId, Disposition__c, Opportunity__c, Selected_Offer__c
            FROM LOI__c
            WHERE Disposition__c = :dispositionId
        ];
    }

    private static List<Contract_Review__c> contractReviewsOn(Id dispositionId) {
        return [
            SELECT Id, Negotiation_Status__c, Stage__c, RecordTypeId, Disposition__c, Opportunity__c,
                   Selected_Offer__c
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
        Assert.areEqual('Prepare', created[0].Status__c,
            'The NDA must start at the FIRST step of the Disposition_NDA sequence. ⚠ 2026-08-25: '
            + 'this expected "Not Sent" until the user removed that value from the record type in '
            + 'Setup AND cleared the type\'s default, so there is no record-type default left to '
            + 'assert against — DispositionStageEntryService.DISPOSITION_NDA_INITIAL_STATUS is now '
            + 'the ONLY declaration of the entry state, and this assertion is its only pin. '
            + '"Pending" is the ACQUISITION '
            + 'starting value and is restricted off this record type. ⚠ 2026-08-21: this message '
            + 'used to end "but record-type picklist restriction is UI-only, so Apex DML would '
            + 'accept it silently and produce an NDA that RecordStageAdvanceService cannot '
            + 'advance." NDA__c.Status__c is a RESTRICTED value set, whose record-type subset DML '
            + 'DOES enforce, so the wrong constant fails the insert with an opaque '
            + 'INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST — surfaced from a stage change the user '
            + 'never connected to an NDA. This assertion is what turns that into a named failure.');
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
     * 🔴 RETRACTED 2026-08-19 (flow redesign) — "The stage used here is on the ON_MARKET path on
     * purpose. Moving an OFF_MARKET disposition to Disposition Offer / LOI / PSA / Closing /
     * Completed is blocked by All_NDAs_Signed_Before_Progression when no signed NDA exists, so a
     * 'some other stage' fixture built on the off-market path would fail for a reason that has
     * nothing to do with this service." That sentence is retracted, not deleted, because it is
     * exactly what a future reader would assume. `All_NDAs_Signed_Before_Progression` now gates
     * BOTH record types (see `onMarketAtReadiness`'s own header), and `Disposition Offer` /
     * `Completed` are RETIRED values pending manual Setup deletion — neither belongs in a live
     * fixture. `BOV Outreach` below is not gated at all, on either record type, so the on-market
     * `update` needs no signed NDA first; `offMarket`'s own `Title_Company__c` edit never touches
     * the stage, so it is exempt for an unrelated, still-true reason.
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
     * The production stamp is deliberately GUARDED (see the service header: an unguarded stamp
     * throws INVALID_CROSS_REFERENCE_KEY and would roll the user's own stage change back for every
     * user until post-deploy gate T-A1 runs). This test is where the softness ends, and it
     * re-reads RecordTypeId from the DATABASE because a creation that SUCCEEDED is not evidence
     * the type landed.
     *
     * ⚠ CHANGED 2026-08-25 (DISP-0025): that guard is `isActive()`, not `isAvailable()` — it no
     * longer asks whether the RUNNING USER can see the type. This test is unaffected because it
     * runs as the admin, for whom both answers are the same; the paragraph below still describes
     * the OLD diagnosis of a null and is corrected in the assertion message itself. The persona
     * that CAN tell the two guards apart is
     * `loiStampsTheDispositionTypeForARecordTypeBlindPrincipal`.
     *
     * ⚠ EXPECT THIS RED UNTIL T-A1. Deploying objects/NDA__c/recordTypes/ is NOT enough — a
     * record type assigned to no profile resolves a real Id and is available to nobody,
     * administrators included (Modify All Data is an OBJECT permission and confers no record-type
     * access). And the failure it names is not cosmetic here: a Master-type DISPOSITION NDA seeds
     * at 'Prepare' (⚠ 'Not Sent' until 2026-08-25), falls back to the ACQUISITION sequence, and that map has no such entry
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
            'The auto-created NDA must carry the Disposition_NDA record type. ⚠ 2026-08-25: a NULL '
            + 'value here now means the type is ABSENT or INACTIVE — the guard is isActive(), so '
            + 'record-type VISIBILITY no longer suppresses the stamp (that was DISP-0025). Until '
            + 'that date it meant "resolved a real Id but is not AVAILABLE to the running user, '
            + 'so the deliberate isAvailable() guard in DispositionStageEntryService silently '
            + 'no-opped — that is post-deploy gate T-A1 not having run". Either way the NDA is '
            + 'FUNCTIONALLY DEAD (Prepare has no hop on the fallback acquisition sequence — nor '
            + 'did "Not Sent", the seed this said until 2026-08-25). Do '
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
     * 🔴 NDA-ON-`On_Market` IS NEW TERRITORY (2026-08-19 flow redesign, design DEV-19) — NOT A
     * COPY-PASTE OF THE OFF-MARKET BULK TEST ABOVE. Before this redesign `NDA` was an Off_Market-
     * only stage value (the "NDA and Disposition Offer are off-market stage values ONLY" doctrine
     * — see Disposition_Stage__c's own XML comment for the retraction), so a broker-listed sale
     * never reached this block at all. The redesigned on-market path now reads
     * `... Broker Selection -> NDA -> Release Materials -> Active Listing ...`, so an on-market
     * sale collects a buyer NDA exactly as a direct one does. `openBuyerNdas` keys on the STAGE
     * VALUE alone and has never carried a record-type criterion (see NDA_STAGE's own comment), so
     * this test proves that claim rather than assuming it — a future change that "helpfully" added
     * an On_Market guard would silently strip the buyer NDA from every broker-listed sale, and
     * only a real on-market walk through the trigger would notice.
     *
     * Readiness -> NDA is NOT one of `All_NDAs_Signed_Before_Progression`'s gated target stages
     * (that OR list starts at Release Materials), so this transition needs no pre-signed NDA —
     * unlike every LOI / PSA / Active Listing fixture elsewhere in this file.
     */
    @isTest
    static void bulkStageEntryAt251OpensOneNdaEachOnMarket() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
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
            'Every one of the 251 ON-MARKET dispositions must get exactly one NDA — 251 spans TWO '
            + 'trigger chunks, so a total of 200 here would mean the second chunk was dropped');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM NDA__c WHERE Disposition__c IN :dispositions AND Party_Role__c = 'Buyer'],
            'All 251 must be BUYER NDAs, same idempotency key as the off-market path');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :dispositions AND Primary_NDA__c != NULL],
            'The deferred stamp must reach all 251 on-market dispositions too — the Queueable does '
            + 'not branch on record type');
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
    // `NDA` STAGE — THE BROKER STAMP (2026-08-21)
    //
    // 🔴 WHAT THESE TESTS EXIST TO CATCH, AND WHY THE SUITE ABOVE DID NOT CATCH IT. Until
    // 2026-08-21 `openBuyerNdas` set Disposition__c / Status__c / Party_Role__c and NOTHING ELSE,
    // and every assertion above is about one of those three. `NDA__c.Broker__c` — the field that
    // REPLACED the buyer as the NDA counterparty in the same month — was simply never written, and
    // an entire green suite said so. Measured in usman-dpeg: NDA-0115, auto-created on DISP-0019,
    // shipped with Broker__c = null. THE FALSIFIERS BELOW ARE ALL "the right broker", NEVER "a
    // broker": a stamp that resolved the WRONG contact would satisfy any not-null assertion, and on
    // a bulk chunk a cross-wired map is exactly the defect that produces 251 non-null wrong answers.
    //
    // ── THE TWO SOURCES, AND WHY EACH NEEDS ITS OWN TEST ────────────────────────────────────────
    //   Off_Market -> Disposition__c.Broker__c          (in memory, on Trigger.new, zero queries)
    //   On_Market  -> the `Selected` BOV_Submission__c's Broker__c   (one selector read per chunk)
    // They are not two spellings of one thing. `Broker_Lookup_Is_Off_Market_Only` is an ACTIVE
    // validation rule that REFUSES Disposition__c.Broker__c on an on-market row, so the on-market
    // branch cannot be a fallback of the off-market one — `onMarketIgnoresTheDispositionsOwnBroker‑
    // Lookup` below is the falsifier that pins that, and it is the one test here that must be
    // driven by DIRECT INVOCATION rather than through the trigger, because the state it needs
    // (an on-market record carrying a broker lookup) is one the platform will not let a test SAVE.
    //
    // ── ⚠ WHAT IS DELIBERATELY NOT TESTED, SAID OUT LOUD ───────────────────────────────────────
    //   A `Selected` SUBMISSION WITH A NULL `Broker__c`. The selector filters those out with
    //   `AND Broker__c != NULL`, and that predicate defends a LEGACY population — rows created
    //   before `Broker_Required_On_Submission` existed. That rule is now active and unconditional
    //   (`ISBLANK(Broker__c)`), so no test in this org can BUILD such a row: every insert path is
    //   refused. The predicate is therefore unfalsifiable here by construction, not untested by
    //   oversight. Do not delete it on the strength of "no test covers it".
    //
    //   TWO `Selected` SUBMISSIONS ON ONE DISPOSITION. `BovSubmissionSelectionGuardService` is a
    //   before-context trigger guard that refuses precisely that save, so the ordering / first-wins
    //   determinism in `resolveBrokers` likewise cannot be reached from a test. It is argued from
    //   the total ORDER BY at the selector rather than pinned here.
    // ═════════════════════════════════════════════════════════════════════════

    /** An OFF-MARKET disposition at Readiness whose broker lookup names `broker`. */
    private static Disposition__c offMarketWithBroker(Id brokerContactId) {
        Disposition__c d = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        d.Broker__c = brokerContactId;
        insert d;
        return d;
    }

    /**
     * Attaches one BOV submission to `dispositionId` at `status`, pointed at `brokerContactId`.
     *
     * ⚠ Built through `TestDataFactory.createBovSubmission(..., false)` and mutated rather than
     * hand-constructed: `Broker_Required_On_Submission` and `BOV_Amount_Required_On_Submission`
     * are both ACTIVE and unconditional, so a bare `new BOV_Submission__c(...)` here would be
     * refused for reasons that have nothing to do with the broker stamp.
     */
    private static BOV_Submission__c bovOn(Id dispositionId, Id brokerContactId, String status) {
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(dispositionId, false);
        sub.Broker__c = brokerContactId;
        sub.Submission_Status__c = status;
        insert sub;
        return sub;
    }

    /** The On_Market record type Id, read back off a saved fixture rather than described again. */
    private static Id onMarketRecordTypeId(Id dispositionId) {
        return [SELECT RecordTypeId FROM Disposition__c WHERE Id = :dispositionId].RecordTypeId;
    }

    // ── OFF-MARKET: the disposition's own broker lookup ──────────────────────

    @isTest
    static void offMarketNdaCarriesTheDispositionsBrokerContact() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarketWithBroker(broker.Id);

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        List<NDA__c> created = ndasOn(disposition.Id);
        Assert.areEqual(1, created.size(), 'Still exactly one buyer NDA — the stamp adds a column, '
            + 'never a record');
        Assert.areEqual(broker.Id, created[0].Broker__c,
            'The auto-created NDA must carry the OFF-MARKET disposition\'s own Broker__c. This is '
            + 'the field that replaced Buyer__c as the NDA counterparty on 2026-08-21 and that '
            + 'this creation path was silently leaving null.');
    }

    /**
     * 🔴 THE UNRESOLVABLE CASE, AND IT IS A REQUIREMENT RATHER THAN AN EDGE. An off-market
     * disposition can legitimately reach the `NDA` stage before anyone has appointed a broker.
     * The NDA must still be created — auto-create's job is that the record EXISTS. A change that
     * "helpfully" refused or threw here would roll back the user's own stage change (the insert is
     * allOrNone = true) over a field a human fills in five seconds from the related list.
     */
    @isTest
    static void offMarketNdaWithNoBrokerIsStillCreatedUnstamped() {
        Disposition__c disposition = offMarketAtReadiness();   // no Broker__c

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        List<NDA__c> created = ndasOn(disposition.Id);
        Assert.areEqual(1, created.size(),
            'An unresolvable broker must NOT block the NDA — the record existing matters more than '
            + 'it being complete, and a refusal here would roll back the stage change itself');
        Assert.isNull(created[0].Broker__c,
            'With nothing to resolve, Broker__c stays null. Anything else means a broker was '
            + 'fabricated from a source this path is not entitled to read.');
    }

    // ── ON-MARKET: the Selected BOV submission's broker ──────────────────────

    @isTest
    static void onMarketNdaCarriesTheSelectedBovSubmissionsBroker() {
        Disposition__c disposition = onMarketAtReadiness();
        Contact appointed = TestDataFactory.createBrokerContact(null, true);
        bovOn(disposition.Id, appointed.Id, 'Selected');

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        List<NDA__c> created = ndasOn(disposition.Id);
        Assert.areEqual(1, created.size(), 'Exactly one buyer NDA on the on-market path too');
        Assert.areEqual(appointed.Id, created[0].Broker__c,
            'On an ON-MARKET disposition the broker comes from the Selected BOV submission. '
            + 'Disposition__c.Broker__c is null here by ENFORCEMENT — Broker_Lookup_Is_Off_Market_'
            + 'Only refuses a value there — so this is the only source that exists.');
    }

    /**
     * 🔴 THE `Submission_Status__c = 'Selected'` PREDICATE, PINNED. A disposition mid-outreach
     * carries several `Backup` submissions and no Selected one; resolving a broker from any of them
     * would appoint someone nobody chose, silently, on a legal document. Without this test a
     * selector that dropped the status term would pass every assertion above.
     */
    @isTest
    static void onMarketNdaIgnoresBackupSubmissions() {
        Disposition__c disposition = onMarketAtReadiness();
        Contact notAppointed = TestDataFactory.createBrokerContact(null, true);
        bovOn(disposition.Id, notAppointed.Id, 'Backup');

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        List<NDA__c> created = ndasOn(disposition.Id);
        Assert.areEqual(1, created.size(), 'The NDA is still created — an un-appointed broker is '
            + 'the NORMAL state of a disposition still running its BOV outreach');
        Assert.isNull(created[0].Broker__c,
            'A Backup submission must NOT be resolved as the appointed broker. Only a Selected '
            + 'one is the appointment.');
    }

    @isTest
    static void onMarketNdaWithNoSubmissionsAtAllIsStillCreatedUnstamped() {
        Disposition__c disposition = onMarketAtReadiness();

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        List<NDA__c> created = ndasOn(disposition.Id);
        Assert.areEqual(1, created.size(),
            'No BOV submissions at all must not block the NDA');
        Assert.isNull(created[0].Broker__c, 'Nothing to resolve, so nothing is stamped');
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE FALSIFIER FOR THE SIMPLIFICATION SOMEONE WILL EVENTUALLY PROPOSE: "just read
     *    Disposition__c.Broker__c first and fall back to the BOV." IT LOOKS EQUIVALENT AND IS NOT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * That version passes every other test in this section, because `Broker_Lookup_Is_Off_Market_
     * Only` keeps `Disposition__c.Broker__c` null on every on-market row that can be SAVED — so
     * the fallback would always fire and always look right. The day the rule is relaxed, or a
     * record type is changed on an existing row, or an API caller writes both, the "fallback"
     * silently becomes the PRIMARY and the NDA names a broker who was never appointed to this sale.
     *
     * ⚠ DIRECT INVOCATION, NOT THE TRIGGER, AND THAT IS FORCED BY THE PLATFORM. The state this
     * test needs — an on-market disposition whose broker lookup is populated — is exactly the state
     * the validation rule refuses to persist, so it CANNOT be built with DML. An in-memory
     * `Disposition__c` passed straight into the service reproduces what `Trigger.new` would carry
     * without ever being saved. The disposition itself is real (the NDA's lookup needs a real
     * parent); only the broker on the in-memory copy is synthetic.
     */
    @isTest
    static void onMarketNdaIgnoresTheDispositionsOwnBrokerLookup() {
        Disposition__c disposition = onMarketAtReadiness();
        Contact appointed = TestDataFactory.createBrokerContact(null, true);
        Contact decoy = TestDataFactory.createBrokerContact(null, true);
        bovOn(disposition.Id, appointed.Id, 'Selected');
        Assert.areNotEqual(appointed.Id, decoy.Id,
            'The two fixture brokers must be different Contacts or this test cannot fail');

        List<Disposition__c> newList = new List<Disposition__c>{
            new Disposition__c(
                Id = disposition.Id,
                RecordTypeId = onMarketRecordTypeId(disposition.Id),
                Disposition_Stage__c = NDA_STAGE,
                Broker__c = decoy.Id          // the state the validation rule forbids saving
            )
        };
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>{
            disposition.Id =>
                new Disposition__c(Id = disposition.Id, Disposition_Stage__c = READINESS_STAGE)
        };

        Test.startTest();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Test.stopTest();

        List<NDA__c> created = ndasOn(disposition.Id);
        Assert.areEqual(1, created.size(), 'One NDA');
        Assert.areEqual(appointed.Id, created[0].Broker__c,
            'On the ON_MARKET record type the Selected BOV submission is the ONLY source. A '
            + 'lookup-first-then-fall-back-to-the-BOV implementation returns the decoy here and '
            + 'passes every other test in this section.');
    }

    /**
     * The complement, and it pins the branch in the other direction: the record type — NOT the
     * presence of a value — is what selects the source. An OFF-MARKET disposition that somehow has
     * a Selected BOV submission must still take its broker from its own lookup.
     *
     * ⚠ This shape is reachable in production: `BOV_Submission__c` carries no record-type criterion
     * of its own, so nothing stops a row being parented to an off-market disposition. Only the
     * `Disposition_Stage__c` value set keeps `BOV Outreach` on-market-only, and a value set is not
     * a constraint on a CHILD object.
     */
    @isTest
    static void offMarketNdaIgnoresASelectedBovSubmission() {
        Contact appointed = TestDataFactory.createBrokerContact(null, true);
        Contact bovBroker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarketWithBroker(appointed.Id);
        bovOn(disposition.Id, bovBroker.Id, 'Selected');
        Assert.areNotEqual(appointed.Id, bovBroker.Id,
            'The two fixture brokers must be different Contacts or this test cannot fail');

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = NDA_STAGE);
        Test.stopTest();

        Assert.areEqual(appointed.Id, ndasOn(disposition.Id)[0].Broker__c,
            'On the OFF_MARKET record type the disposition\'s own Broker__c wins. A BOV-first '
            + 'implementation returns the submission\'s broker here.');
    }

    // ── BULK — 251 through the REAL trigger, both record types ───────────────

    /**
     * 251 OFF-MARKET dispositions, 251 DIFFERENT brokers, and the assertion is a per-record MATCH
     * rather than a count of non-nulls.
     *
     * 🔴 DISTINCT BROKERS ARE THE WHOLE POINT. A cross-wired map — the classic two-collection bulk
     * defect, where row i gets row j's value — produces 251 non-null, wrong answers and satisfies
     * every "is it populated" assertion. With one shared broker Contact it would also satisfy a
     * per-record equality assertion, which is why the fixture builds 251 of them in a single insert.
     */
    @isTest
    static void bulkOffMarketAt251StampsEachDispositionsOwnBroker() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(BULK_N, null, true);
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        Map<Id, Id> expectedBrokerByDisposition = new Map<Id, Id>();
        for (Integer i = 0; i < BULK_N; i++) {
            dispositions[i].Broker__c = brokers[i].Id;
        }
        insert dispositions;
        List<Disposition__c> moves = new List<Disposition__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            expectedBrokerByDisposition.put(dispositions[i].Id, brokers[i].Id);
            moves.add(new Disposition__c(Id = dispositions[i].Id, Disposition_Stage__c = NDA_STAGE));
        }

        Test.startTest();
        update moves;
        Test.stopTest();

        List<NDA__c> created = [
            SELECT Id, Disposition__c, Broker__c FROM NDA__c WHERE Disposition__c IN :dispositions
        ];
        Assert.areEqual(BULK_N, created.size(),
            'One NDA each across BOTH trigger chunks — 251 forces a second firing');
        for (NDA__c nda : created) {
            Assert.areEqual(expectedBrokerByDisposition.get(nda.Disposition__c), nda.Broker__c,
                'Every NDA must carry ITS OWN disposition\'s broker. A single mismatch here is a '
                + 'cross-wired map, which a not-null assertion would have passed.');
        }
    }

    /**
     * The on-market twin: 251 dispositions, 251 Selected BOV submissions, 251 distinct brokers,
     * resolved through the selector in ONE query per trigger chunk.
     *
     * ⚠ THE FIXTURE BUILDS ITS SUBMISSIONS IN ONE `createBovSubmissions(BULK_N, null, false)` CALL
     * AND RE-PARENTS THEM, rather than calling `createBovSubmission(d.Id, ...)` 251 times. The
     * single-record overload resolves `bovBrokerContactIdsFor(1)`, which returns the SHARED
     * `defaultBrokerContact()` every time — so 251 calls would produce 251 submissions naming the
     * SAME broker, and the per-record match below would be vacuous (every expected value equal to
     * every actual one). The bulk overload creates 251 distinct brokers in one insert.
     */
    @isTest
    static void bulkOnMarketAt251StampsEachDispositionsSelectedBroker() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        List<BOV_Submission__c> submissions =
            TestDataFactory.createBovSubmissions(BULK_N, null, false);
        Map<Id, Id> expectedBrokerByDisposition = new Map<Id, Id>();
        List<Disposition__c> moves = new List<Disposition__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            submissions[i].Disposition__c = dispositions[i].Id;
            submissions[i].Submission_Status__c = 'Selected';
            expectedBrokerByDisposition.put(dispositions[i].Id, submissions[i].Broker__c);
            moves.add(new Disposition__c(Id = dispositions[i].Id, Disposition_Stage__c = NDA_STAGE));
        }
        insert submissions;   // built in the loop, inserted once — never DML in a loop
        Assert.areEqual(BULK_N, new Set<Id>(expectedBrokerByDisposition.values()).size(),
            'The 251 expected brokers must be 251 DISTINCT Contacts, or a cross-wired map would '
            + 'pass the per-record assertion below');

        Test.startTest();
        update moves;
        Test.stopTest();

        List<NDA__c> created = [
            SELECT Id, Disposition__c, Broker__c FROM NDA__c WHERE Disposition__c IN :dispositions
        ];
        Assert.areEqual(BULK_N, created.size(), 'One NDA each, across both trigger chunks');
        for (NDA__c nda : created) {
            Assert.areEqual(expectedBrokerByDisposition.get(nda.Disposition__c), nda.Broker__c,
                'Every NDA must carry the broker off ITS OWN disposition\'s Selected submission');
        }
    }

    /**
     * 🔴 THE PLACEMENT FALSIFIER, AND IT IS THE ONE ASSERTION IN THIS SECTION THAT IS EXACT.
     * `resolveBrokers` is called AFTER the idempotency early return, so a chunk of 251 ON-MARKET
     * dispositions that all already have their buyer NDA must still cost EXACTLY ONE query — the
     * idempotency read — and ZERO DML. Moving the resolution above the early return (the obvious
     * "resolve everything up front" refactor) makes this report 2, for 251 rows that are never
     * written.
     *
     * ⚠ NO BOV SUBMISSIONS ARE BUILT HERE ON PURPOSE. The extra query would be issued on the
     * strength of the entrants being on-market, not on the strength of a submission existing, so
     * the fixture does not need one and 251 unnecessary submissions would only add noise.
     *
     * The service is invoked DIRECTLY so the measurement contains this service and nothing else —
     * the same reason `suppressionPathCostsOneQueryAndNoDmlAt251` does, and the reason both stay on
     * the suppression path: any test that actually CREATES an NDA also measures the
     * `NDA_Signed_Rollup` flow's queries and could not be exact.
     */
    @isTest
    static void onMarketSuppressionPathStillCostsExactlyOneQueryAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        Id onMarketRtId = onMarketRecordTypeId(dispositions[0].Id);
        List<NDA__c> existing = new List<NDA__c>();
        for (Disposition__c d : dispositions) {
            existing.addAll(TestDataFactory.createDispositionNdas(1, d.Id, false));
        }
        insert existing;   // built in the loop, inserted once — never DML in a loop

        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : dispositions) {
            newList.add(new Disposition__c(
                Id = d.Id,
                RecordTypeId = onMarketRtId,
                Disposition_Stage__c = NDA_STAGE
            ));
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
            'EXACTLY ONE query for 251 SUPPRESSED on-market dispositions. A 2 here means the '
            + 'broker resolution moved ahead of the idempotency early return and is now paying for '
            + 'rows that are never inserted.');
        Assert.areEqual(0, dmlUsed,
            'Zero DML — the broker stamp adds a COLUMN to an insert this block already performed, '
            + 'never a statement of its own');
    }

    /**
     * The creation path's cost, asserted as a BOUND rather than a number, and the bound is the
     * honest shape of the claim rather than a weakening of it.
     *
     * WHY NOT EXACT: this chunk actually inserts 251 NDAs, so `NDA_Signed_Rollup` — an after-save
     * flow on NDA__c that maintains the disposition's two counters — runs inside the measurement.
     * Pinning a number would make this test red every time a parallel declarative change touched
     * that flow, which is a false alarm about the wrong component (the class header makes the same
     * argument for the suppression-path tests above).
     *
     * WHAT IT STILL FALSIFIES, WHICH IS THE PART THAT MATTERS: a resolution issued per record
     * cannot reach this assertion at all — it throws `System.LimitException: Too many SOQL
     * queries: 101` at the 101st disposition. So COMPLETING this test is the SOQL-in-a-loop
     * falsifier, exactly as the 251-row trigger tests above are, and the bound then pins that the
     * service's own contribution is the documented 2 (idempotency + resolution) rather than
     * something that grows.
     */
    @isTest
    static void onMarketCreationPathResolvesBrokersAtConstantQueryCostAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        Id onMarketRtId = onMarketRecordTypeId(dispositions[0].Id);
        List<BOV_Submission__c> submissions =
            TestDataFactory.createBovSubmissions(BULK_N, null, false);
        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            submissions[i].Disposition__c = dispositions[i].Id;
            submissions[i].Submission_Status__c = 'Selected';
            newList.add(new Disposition__c(
                Id = dispositions[i].Id,
                RecordTypeId = onMarketRtId,
                Disposition_Stage__c = NDA_STAGE
            ));
            oldMap.put(
                dispositions[i].Id,
                new Disposition__c(Id = dispositions[i].Id, Disposition_Stage__c = READINESS_STAGE)
            );
        }
        insert submissions;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.isTrue(queriesUsed <= 6,
            'The NDA block costs TWO queries for a whole on-market chunk — the idempotency read '
            + 'and the broker resolution — plus whatever NDA_Signed_Rollup spends on the insert. '
            + 'The bound is loose on purpose (see this method\'s header); what it refuses is a cost '
            + 'that GROWS with the chunk. Measured: ' + queriesUsed);
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM NDA__c WHERE Disposition__c IN :dispositions AND Broker__c != NULL],
            'All 251 NDAs must have been stamped — a query budget met by resolving nothing is not '
            + 'the property being claimed');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 `LOI` STAGE — the sell-side LOI. Tranche 3B fix pass (review C1: before this,
    // NOTHING in the application could create a disposition LOI, by any persona,
    // including an administrator.)
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void enteringTheLoiStageOpensExactlyOneDispositionLoi() {
        Disposition__c disposition = onMarketAtReadiness();
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

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
            + 'starting value and is restricted off this record type. ⚠ 2026-08-21: this message '
            + 'used to end "but record-type picklist restriction is UI-only, so Apex DML would '
            + 'accept it silently"; LOI__c.Stage__c is RESTRICTED and its record-type subset IS '
            + 'enforced by DML (measured on this exact field), so the wrong constant fails the '
            + 'insert outright rather than producing a bad row '
            + '(Draft is acquisition-only, so the disposition sequence has no entry for '
            + 'it. ⚠ This used to say the two LOI value sets are fully disjoint; observation 5 '
            + 'ended that on 2026-08-14 by giving them a shared Under Review, but Draft '
            + 'specifically is still acquisition-only, which is the only part this assertion '
            + 'ever depended on).');
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
     *
     * ⚠ CHANGED 2026-08-25 (DISP-0025): the guard is `isActive()`, not `isAvailable()`. This test
     * runs as the ADMIN, for whom the two guards agree, so it is unchanged and CANNOT distinguish
     * them — `loiStampsTheDispositionTypeForARecordTypeBlindPrincipal` below is the one that can.
     * Keep both: this one pins the happy path, that one pins the persona the defect lived on.
     */
    @isTest
    static void autoCreatedLoiCarriesTheDispositionRecordType() {
        Disposition__c disposition = onMarketAtReadiness();
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

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
            'PRECONDITION FAILED: the auto-created LOI must carry the Disposition_LOI record '
            + 'type. ⚠ 2026-08-25: a NULL value here now means the type is ABSENT or INACTIVE — '
            + 'the guard is isActive(), so record-type VISIBILITY no longer suppresses the stamp. '
            + 'Until that date it meant "resolved a real Id but is not AVAILABLE to the running '
            + 'user, so the deliberate isAvailable() guard in DispositionStageEntryService '
            + 'silently no-opped — that is gate T-A1 (profile record-type assignment) not having '
            + 'run", and that silent no-op is what rolled back an approver\'s save in production '
            + '(DISP-0025). An unstamped LOI is FUNCTIONALLY DEAD: it '
            + 'seeds at "Received", falls back to the ACQUISITION stage sequence, and that map has '
            + 'no "Received" entry, so neither Advance Stage nor either loop action can move it. '
            + 'Do not soften this assertion; run T-A1.');
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE DISP-0025 REGRESSION. THE ONLY TEST IN THIS FILE THAT DOES NOT RUN AS AN ADMIN.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * MEASURED IN PRODUCTION 2026-08-25 — DISP-0025 / OFFER-0012, approver Nikhil Dhanani, FINEST
     * log 07Liw000000I1vJEAS. The Principal persona approves an offer,
     * `DispositionOfferTriggerHandler` moves the parent to `LOI` AS THE APPROVER, and the
     * record-type stamp — then guarded on `isAvailable()` — silently no-opped because that persona
     * had no `recordTypeVisibilities` at all. The LOI was built with no RecordTypeId, landed on the
     * ACQUISITION default type, and `Database.insert` threw
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST … Received: [Stage__c]`, rolling back the approval.
     *
     * 🔴 EVERY OTHER TEST IN THIS FILE RUNS AS THE ADMIN TEST-RUNNING USER, FOR WHOM EVERY RECORD
     * TYPE IS AVAILABLE — so the defect was structurally unreachable by this suite, exactly as
     * `TestDataFactory.createNonOwnerDispositionApprover`'s header says of the DISP-0011 sharing
     * defect. A test that cannot fail on a defect is not a test of it.
     *
     * ── ⚠ WHY IT CALLS THE SERVICE DIRECTLY INSTEAD OF SAVING A RECORD ──────
     * The cascade this reproduces is `update Disposition_Offer__c` -> handler -> parent to `LOI` ->
     * `DispositionTrigger` -> this service. Driving it by DML would require the persona to hold
     * `Disposition_Offer__c` edit, and `DPEG_Disposition_Edit` is the ONLY set in this org that
     * grants it — and it carries a `LOI__c.Disposition_LOI` recordTypeVisibilities entry, which
     * would make `isAvailable()` true and this test vacuous. So the persona is handed the exact
     * two arguments `DispositionTriggerHandler` passes (Trigger.new at `LOI`, Trigger.oldMap at
     * Readiness) and the DML that produces them is left to the tests above, which already pin it.
     *
     * ── 🔴 THE PRECONDITION ASSERTION IS THE POINT, NOT CEREMONY ─────────────
     * `DPEG_Disposition_View` GAINED five recordTypeVisibilities entries on 2026-08-25 as the other
     * half of this fix. Any fixture built on a set that can gain such an entry goes vacuously green
     * the day it does. `isAvailable() == false` is asserted INSIDE `System.runAs` so that a widened
     * permission set reds this test with a fixture message instead of silently retiring it.
     *
     * ── ⚠ IF THIS TEST FAILS, READ THE ERROR BEFORE TOUCHING IT ─────────────
     *   INVALID_CROSS_REFERENCE_KEY ("this ID value isn't valid for the user") — then record-type
     *     visibility IS enforced under `AccessLevel.SYSTEM_MODE`, the 2026-08-09/08-10
     *     measurements generalise beyond a bare `insert`, the `isActive()` change is WRONG, and the
     *     permission-set grant is the only fix. This test is the experiment that settles that
     *     question, which `OpportunityReviewService`'s header has carried as UNDETERMINED since
     *     2026-08-09. Report it; do not soften the assertion.
     *   TypeException "DML operation UPDATE not allowed on Disposition__c" at `Test.stopTest()` —
     *     ⚠ THIS ROW NAMED `DispositionPrimaryChildStampQueueable` UNTIL 2026-08-25, when that
     *     class was deleted with the child-mirror fields. The symptom can still arrive from
     *     `DispositionNdaStampQueueable`, which drains at the same point for the same reason, so
     *     the row is kept with the name corrected rather than removed. It is the FIXTURE, not
     *     the code: no permission set in this org grants `Disposition__c` without also granting
     *     `LOI__c.Disposition_LOI`, so this persona holds none, and the queueable is relying on
     *     `SYSTEM_MODE` lifting object CRUD. Move the assertions ahead of `Test.stopTest()` rather
     *     than widening the persona.
     *   INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY on the Disposition__c Id — the manual share
     *     below is missing or was not committed before the act. That is what this test hit on its
     *     first run (2026-08-25); read the comment on the share insert before changing anything.
     *   The SHARE INSERT ITSELF failing — then this org refuses a share to a grantee with no
     *     object-level read on Disposition__c, and the fixture needs READ from a set carrying no
     *     disposition record types. ⚠ NO SUCH SET EXISTS TODAY (checked 2026-08-25:
     *     DPEG_App_Disposition has zero objectPermissions, DPEG_Transaction_View grants only
     *     Transaction__c and Critical_Date__c, and the only two sets granting Disposition__c both
     *     grant LOI__c.Disposition_LOI). Creating one is a permission-set change, not a test change.
     */
    @isTest
    static void loiStampsTheDispositionTypeForARecordTypeBlindPrincipal() {
        Disposition__c disposition = onMarketAtReadiness();
        User principal = TestDataFactory.createRecordTypeBlindDispositionPrincipal('rtb');

        // 🔴 THE PERSONA MUST SEE THE PARENT, AND THAT IS A SHARING QUESTION, NOT A PERMISSION ONE.
        // MEASURED 2026-08-25 on this test's FIRST run: the LOI insert failed with
        // INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY on the Disposition__c Id. SYSTEM_MODE lifts
        // CRUD and FLS but NEVER sharing; `Disposition__c` is Private OWD; this persona owns nothing
        // and is in no group — so the child's parent lookup pointed at a record it could not see. In
        // production the approver sees it through the *_Principals_R criteria sharing rules, and a
        // manual share is the narrowest fixture equivalent of that.
        // ⚠ A SHARE AND NOT A WIDER PERMISSION SET, DELIBERATELY: every set in this org that grants
        // `Disposition__c` at all (`DPEG_Disposition_View`, `DPEG_Disposition_Edit`) also grants
        // `LOI__c.Disposition_LOI`, which would make isAvailable() TRUE and this test vacuous.
        // Ownership transfer is not an alternative — the persona has no Disposition__c object read,
        // so the reassignment is refused.
        insert new Disposition__Share(
            ParentId = disposition.Id,
            UserOrGroupId = principal.Id,
            AccessLevel = 'Read',
            RowCause = Schema.Disposition__Share.RowCause.Manual
        );

        // The exact pair DispositionTriggerHandler hands the service on the approver's save.
        List<Disposition__c> newDispositions = new List<Disposition__c>{
            new Disposition__c(Id = disposition.Id, Disposition_Stage__c = LOI_STAGE)
        };
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>{
            disposition.Id => new Disposition__c(
                Id = disposition.Id,
                Disposition_Stage__c = READINESS_STAGE
            )
        };

        Test.startTest();
        System.runAs(principal) {
            Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
                .getRecordTypeInfosByDeveloperName()
                .get('Disposition_LOI');
            Assert.isNotNull(info,
                'PRECONDITION FAILED: the LOI__c "Disposition_LOI" record type does not exist in '
                + 'this org. objects/LOI__c/recordTypes/ must deploy BEFORE this class (metadata '
                + 'before Apex). Available: '
                + Schema.SObjectType.LOI__c.getRecordTypeInfosByDeveloperName().keySet());
            Assert.isTrue(info.isActive(),
                'PRECONDITION FAILED: Disposition_LOI is INACTIVE in this org. The service resolves '
                + 'the stamp on isActive(), so an inactive type legitimately yields null and this '
                + 'test would fail for a reason that is not the defect. Activate it.');
            Assert.isFalse(info.isAvailable(),
                'FIXTURE PRECONDITION FAILED — THIS TEST IS NO LONGER SENSITIVE TO DISP-0025. The '
                + 'record-type-blind persona can now SEE Disposition_LOI, so the retired '
                + 'isAvailable() guard would have stamped correctly too and a green run proves '
                + 'nothing. Something granted LOI__c.Disposition_LOI to DPEG_Base_Access or '
                + 'DPEG_Acquisition_View. Rebuild the fixture on a set that cannot carry a '
                + 'disposition record type — see '
                + 'TestDataFactory.createRecordTypeBlindDispositionPrincipal.');

            DispositionStageEntryService.createStageEntryRecords(newDispositions, oldMap);
        }
        Test.stopTest();

        List<LOI__c> created = [
            SELECT Id, Stage__c, RecordType.DeveloperName
            FROM LOI__c
            WHERE Disposition__c = :disposition.Id
        ];
        Assert.areEqual(1, created.size(),
            'Entering the LOI stage must open exactly ONE LOI even when the principal driving the '
            + 'cascade cannot see the record type. ZERO here means the insert threw and the '
            + 'approver\'s stage change rolled back — the DISP-0025 production failure itself.');
        Assert.areEqual('Disposition_LOI', created[0].RecordType.DeveloperName,
            'The auto-created LOI must carry Disposition_LOI even though isAvailable() is FALSE '
            + 'for the running principal. An automation insert made on a principal\'s behalf must '
            + 'not depend on that principal\'s UI record-type visibility; the stamp resolves on '
            + 'isActive(). A null/Master/Acquisition type here means the isAvailable() guard is '
            + 'back in DispositionStageEntryService.recordTypeIdFor.');
        Assert.areEqual('Received', created[0].Stage__c,
            'Stage__c must be Disposition_LOI\'s own seed value. This is the assertion that would '
            + 'have caught DISP-0025 in a test rather than in production: unstamped, the row lands '
            + 'on the acquisition default type, whose restricted value set has no "Received" — so '
            + 'the insert throws INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and takes the approval '
            + 'down with it.');
    }

    @isTest
    static void reEnteringTheLoiStageDoesNotOpenASecondLoi() {
        Disposition__c disposition = onMarketAtReadiness();
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

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
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
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
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
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
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

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
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

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
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

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
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
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
        signBuyerNdaOn(disposition.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        TestDataFactory.createContractReview(null, true); // buy-side, no Disposition__c

        Test.startTest();
        update new Disposition__c(Id = disposition.Id, Disposition_Stage__c = PSA_STAGE);
        Test.stopTest();

        Assert.areEqual(1, contractReviewsOn(disposition.Id).size(),
            'An unrelated ACQUISITION Contract Review must not suppress the disposition PSA');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 NO PARENT STAMP ON THE TWO NEW BLOCKS — the falsifier for "add a Queueable
    // for symmetry"
    //
    // ⚠ THIS SECTION HAS BEEN INVERTED TWICE IN ONE DAY AND THE ARC IS KEPT ON
    // PURPOSE. Original heading and test (`loiAndPsaAutoCreateEnqueueNothing`,
    // asserting `Assert.areEqual(0, jobsUsed)`) were correct while `Disposition__c`
    // had no `Primary_LOI__c` / `Primary_PSA__c`. On 2026-08-25 those lookups were
    // added for the record page's native LOI/PSA Details sections, so there WAS a
    // parent write to defer, and this test was inverted to
    // `loiAndPsaAutoCreateEachEnqueueOneParentStamp` (assert 2). LATER THE SAME DAY
    // the user retired the whole child-mirror field family ("we don't need them");
    // the lookups, the fifteen formula fields, the three Details sections and
    // `DispositionPrimaryChildStampQueueable` were all deleted
    // (manifest/remove-disposition-child-mirrors/), so the ORIGINAL assertion is
    // correct again and has been restored verbatim.
    // 🔴 A SECOND TEST DIED WITH THE CLASS: `primaryChildStampQueueableIsInertOnAnEmptyOrNullMap`
    // covered that Queueable's empty/null constructor guard. It is DELETED, not
    // disabled — there is no class left to cover. The equivalent guard on
    // `DispositionNdaStampQueueable` is still covered by
    // `stampQueueableWithNothingToDoIsANoOp` further up this file; do not confuse
    // the two when reading coverage.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The LOI and PSA blocks enqueue NOTHING, and that is asserted rather than left to inspection.
     *
     * 🔴 THIS IS NOT A PERFORMANCE ASSERTION. It is the falsifier for someone adding a Queueable to
     * these two blocks "for symmetry" with the NDA block. The NDA block's Queueable exists SOLELY
     * because it writes back to the locked parent (`Disposition__c.Primary_NDA__c`), and
     * `SYSTEM_MODE` does not lift an approval lock. `Disposition__c` has exactly ONE `Primary_*`
     * lookup again, so these two blocks have no parent write and therefore nothing to defer — a
     * Queueable here would be a job that does nothing while advertising a hazard that is absent.
     *
     * ⚠ IF THIS GOES RED WITH `jobsUsed == 2`, CHECK WHETHER A `Primary_LOI__c` / `Primary_PSA__c`
     * WAS RE-ADDED BEFORE "FIXING" THE TEST. That exact pair of lookups existed for part of
     * 2026-08-25 and this assertion was legitimately 2 during that window. Re-read
     * `DispositionStageEntryService`'s LOI-block point 3(a) before changing the number in either
     * direction.
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
            'The LOI and PSA blocks must enqueue NOTHING. A non-zero count means a parent stamp '
            + 'was reintroduced — check whether a Primary_LOI__c / Primary_PSA__c lookup came back '
            + 'with it, because a Queueable writing a lookup that does not exist fails silently as '
            + 'an AsyncApexJob and nothing in the UI reports it.');

        Assert.areEqual(1, loisOn(loiEntrant.Id).size(), 'The LOI was still created');
        Assert.areEqual(1, contractReviewsOn(psaEntrant.Id).size(),
            'The Contract Review was still created');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 Selected_Offer__c ON THE CHILD — stamped in the insert, never deferred
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The LOI and the Contract Review each carry a link to the disposition's SELECTED offer, so
     * whoever works the negotiation can open the buyer offer it came from in one click.
     *
     * ⚠ THIS IS A DIFFERENT MECHANISM FROM THE TWO STAMPS ABOVE AND THE TEST IS SEPARATE ON
     * PURPOSE. `Selected_Offer__c` is a field on the CHILD BEING INSERTED, so it is set in the same
     * `Database.insert` and is visible IMMEDIATELY — no Queueable, nothing to drain. If this ever
     * starts needing `Test.stopTest()` to pass, the implementation has drifted into deferring a
     * write that does not need deferring.
     */
    @isTest
    static void autoCreatedLoiAndPsaLinkTheSelectedOffer() {
        Disposition__c loiEntrant = onMarketAtReadiness();
        Disposition__c psaEntrant = onMarketAtReadiness();
        signBuyerNdaOn(loiEntrant.Id);
        signBuyerNdaOn(psaEntrant.Id);

        Disposition_Offer__c loiOffer = TestDataFactory.createDispositionOffer(loiEntrant.Id, false);
        loiOffer.Is_Selected__c = true;
        Disposition_Offer__c psaOffer = TestDataFactory.createDispositionOffer(psaEntrant.Id, false);
        psaOffer.Is_Selected__c = true;
        // A THIRD, DELIBERATELY UNSELECTED offer on the LOI disposition. Without it, a stamp that
        // ignored Is_Selected__c entirely and took "any offer on this disposition" would pass.
        Disposition_Offer__c alsoRan = TestDataFactory.createDispositionOffer(loiEntrant.Id, false);
        insert new List<Disposition_Offer__c>{ loiOffer, psaOffer, alsoRan };

        Test.startTest();
        update new List<Disposition__c>{
            new Disposition__c(Id = loiEntrant.Id, Disposition_Stage__c = LOI_STAGE),
            new Disposition__c(Id = psaEntrant.Id, Disposition_Stage__c = PSA_STAGE)
        };
        Test.stopTest();

        Assert.areEqual(loiOffer.Id, loisOn(loiEntrant.Id)[0].Selected_Offer__c,
            'The auto-created LOI must link the SELECTED offer. The unselected sibling on the same '
            + 'disposition is the falsifier: picking "any offer" would land on either one.');
        Assert.areEqual(psaOffer.Id, contractReviewsOn(psaEntrant.Id)[0].Selected_Offer__c,
            'The auto-created Contract Review must link the selected offer.');
    }

    /**
     * NO SELECTED OFFER IS A NORMAL STATE AND MUST NOT BLOCK THE INSERT. An off-market disposition
     * can reach `LOI` without ever running an offer round.
     *
     * 🔴 THIS IS THE HIGHER-VALUE HALF OF THE PAIR. The stamp is a convenience; the LOI is the
     * record the stage exists for. A guard that refused to create the LOI when the lookup could not
     * be resolved would take down the whole stage entry for the quietest possible reason.
     */
    @isTest
    static void anAutoCreatedLoiWithNoSelectedOfferStillOpensWithABlankLink() {
        Disposition__c entrant = onMarketAtReadiness();
        signBuyerNdaOn(entrant.Id);
        // An offer EXISTS but is not selected — stricter than having no offers at all, because it
        // proves the filter is `Is_Selected__c = true` rather than "are there any rows".
        insert TestDataFactory.createDispositionOffer(entrant.Id, false);

        Test.startTest();
        update new Disposition__c(Id = entrant.Id, Disposition_Stage__c = LOI_STAGE);
        Test.stopTest();

        List<LOI__c> created = loisOn(entrant.Id);
        Assert.areEqual(1, created.size(),
            'The LOI must still be created when no offer is selected. Zero here means an '
            + 'unresolvable link was allowed to refuse the stage entry.');
        Assert.isNull(created[0].Selected_Offer__c,
            'Selected_Offer__c must be blank, not pointed at the unselected offer.');
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
        signBuyerNdasOn(dispositions); // All_NDAs_Signed_Before_Progression now gates On_Market too
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
        signBuyerNdasOn(dispositions); // All_NDAs_Signed_Before_Progression now gates On_Market too
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

    // ═════════════════════════════════════════════════════════════════════════
    // `Active Listing` STAGE — the broker listing + the marketing clock. Tranche 5B (D28/Q3).
    //
    // ⚠ TWO MECHANISMS, TWO CONTEXTS, TESTED SEPARATELY:
    //   stampListingDates      BEFORE insert/update, in-memory, sets Disposition__c.Listing_Date__c
    //   openBrokerListings     AFTER  insert/update, inserts the Broker_Listing__c child
    // They are deliberately not one method — see the service's Javadoc for why the parent write
    // cannot live in the after context and why the child insert cannot live in the before one.
    //
    // 🔴 THE FIXTURE TRAP THAT MAKES THE OBVIOUS TEST VACUOUS: TestDataFactory.createDispositions
    // seeds `Listing_Date__c = Date.today()` on EVERY row. A test that simply moved a factory
    // disposition to Active Listing and asserted `Listing_Date__c == TODAY` would pass whether or
    // not stampListingDates ran at all — it would be asserting the fixture. Every stamp test below
    // therefore NULLS the field first, and `preexistingListingDateIsNotOverwritten` is the
    // matched-pair falsifier that proves the guard is fill-if-blank rather than unconditional.
    // ═════════════════════════════════════════════════════════════════════════

    private static List<Broker_Listing__c> listingsOn(Id dispositionId) {
        return [
            SELECT Id, Disposition__c, List_Date__c, Broker_Firm__c, Listing_Status__c
            FROM Broker_Listing__c
            WHERE Disposition__c = :dispositionId
        ];
    }

    private static Date listingDateOf(Id dispositionId) {
        return [SELECT Listing_Date__c FROM Disposition__c WHERE Id = :dispositionId].Listing_Date__c;
    }

    /** An on-market disposition at Readiness whose marketing clock has NOT started. */
    private static Disposition__c onMarketWithNoListingDate() {
        Disposition__c d = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            false
        );
        d.Listing_Date__c = null;
        insert d;
        return d;
    }

    // ── STAGE ENTRY + THE STAMP ─────────────────────────────────────────────

    /**
     * 🔴 THE PREREQUISITE THE WHOLE TRACTION MONITOR RESTS ON. Before this block existed, nothing
     * created a Broker_Listing__c and nothing wrote Listing_Date__c — and because
     * `Disposition__c.Days_On_Market__c` is `BlankAsZero`, an unset date reads 0 FOREVER rather
     * than null. The clock looked healthy and never ticked.
     */
    @isTest
    static void listingStageEntryOpensOneListingAndStartsTheClock() {
        Disposition__c d = onMarketWithNoListingDate();
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        Assert.isNull(listingDateOf(d.Id),
            'FIXTURE GUARD: the clock must be unstarted before the move, or this test asserts the '
            + 'factory rather than the code');

        Test.startTest();
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);
        Test.stopTest();

        Assert.areEqual(Date.today(), listingDateOf(d.Id),
            'Entering Active Listing must start the 60-day marketing clock');
        List<Broker_Listing__c> listings = listingsOn(d.Id);
        Assert.areEqual(1, listings.size(), 'Exactly one Broker_Listing__c must be opened');
        Assert.areEqual(Date.today(), listings[0].List_Date__c,
            'The child date is COPIED from the parent, not re-derived from Date.today() — so the '
            + 'clock the badge reads and the listing row can never disagree');
        Assert.areEqual('On Track', listings[0].Listing_Status__c,
            'A new listing opens On Track');
    }

    /** A Disposition CREATED at Active Listing is an entry too — the insert path. */
    @isTest
    static void aDispositionCreatedAtActiveListingGetsItsListingAndClock() {
        Disposition__c d = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            false
        );
        d.Listing_Date__c = null;
        d.Disposition_Stage__c = LISTING_STAGE;

        Test.startTest();
        insert d;
        Test.stopTest();

        Assert.areEqual(Date.today(), listingDateOf(d.Id),
            'before-insert must stamp the clock on a row created at Active Listing');
        Assert.areEqual(1, listingsOn(d.Id).size(),
            'after-insert must open the listing on a row created at Active Listing');
    }

    /**
     * 🔴 FILL-IF-BLANK, NOT UNCONDITIONAL. The matched-pair falsifier for the test above: a real
     * listing date entered by a human, or seeded, must survive the stage change. An unconditional
     * stamp would silently overwrite it with "today" and restart the marketing clock.
     */
    @isTest
    static void preexistingListingDateIsNotOverwritten() {
        Date realListingDate = Date.today().addDays(-40);
        Disposition__c d = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            false
        );
        d.Listing_Date__c = realListingDate;
        insert d;
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

        Test.startTest();
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);
        Test.stopTest();

        Assert.areEqual(realListingDate, listingDateOf(d.Id),
            'A real listing date must survive - overwriting it would restart a 40-day-old clock');
        Assert.areEqual(realListingDate, listingsOn(d.Id)[0].List_Date__c,
            'And the child must carry the SAME date, not today');
    }

    /**
     * The selected broker rides across at zero cost — `Selected_Broker__c` is already on
     * Trigger.new, so no query is bought for it. A blank there simply leaves a blank here.
     */
    @isTest
    static void theSelectedBrokerIsCarriedOntoTheNewListing() {
        Disposition__c d = onMarketWithNoListingDate();
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        update new Disposition__c(Id = d.Id, Selected_Broker__c = 'Cushman & Wakefield');

        Test.startTest();
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);
        Test.stopTest();

        Assert.areEqual('Cushman & Wakefield', listingsOn(d.Id)[0].Broker_Firm__c,
            'The broker approved out of BOV Outreach must appear on the listing it produced');
    }

    @isTest
    static void aBlankSelectedBrokerLeavesTheListingBrokerBlankRatherThanFailing() {
        Disposition__c d = onMarketWithNoListingDate();
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too

        Test.startTest();
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);
        Test.stopTest();

        Assert.areEqual(1, listingsOn(d.Id).size(),
            'A disposition with no named broker still gets its listing and its clock');
        Assert.isNull(listingsOn(d.Id)[0].Broker_Firm__c,
            'The firm is simply blank - it is filled by hand or by the broker-change action');
    }

    // ── IT FIRES ON NOTHING ELSE ────────────────────────────────────────────

    @isTest
    static void otherStagesOpenNoListingAndStartNoClock() {
        Disposition__c loiEntrant = onMarketWithNoListingDate();
        Disposition__c psaEntrant = onMarketWithNoListingDate();
        signBuyerNdaOn(loiEntrant.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        signBuyerNdaOn(psaEntrant.Id);

        Test.startTest();
        update new List<Disposition__c>{
            new Disposition__c(Id = loiEntrant.Id, Disposition_Stage__c = LOI_STAGE),
            new Disposition__c(Id = psaEntrant.Id, Disposition_Stage__c = PSA_STAGE)
        };
        Test.stopTest();

        Assert.areEqual(0, listingsOn(loiEntrant.Id).size(), 'LOI entry opens no broker listing');
        Assert.areEqual(0, listingsOn(psaEntrant.Id).size(), 'PSA entry opens no broker listing');
        Assert.isNull(listingDateOf(loiEntrant.Id),
            'Only Active Listing starts the marketing clock');
        Assert.isNull(listingDateOf(psaEntrant.Id),
            'Only Active Listing starts the marketing clock');
    }

    /** A save that does not CHANGE the stage is not an entry — no second listing, no re-stamp. */
    @isTest
    static void anEditWhileAlreadyAtActiveListingIsNotAnEntry() {
        Disposition__c d = onMarketWithNoListingDate();
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);
        Date stampedAt = listingDateOf(d.Id);
        // Rewind the clock behind the service's back, then re-save WITHOUT changing the stage.
        // Assigned after construction, not as a constructor argument, so the null is unambiguously
        // part of the update's field set.
        Disposition__c clear = new Disposition__c(Id = d.Id);
        clear.Listing_Date__c = null;
        update clear;

        Test.startTest();
        update new Disposition__c(Id = d.Id, Title_Company__c = 'Some Other Title Co');
        Test.stopTest();

        Assert.areEqual(1, listingsOn(d.Id).size(),
            'An ordinary edit at Active Listing must not open a second listing');
        Assert.isNull(listingDateOf(d.Id),
            'The stamp is keyed on stage ENTRY, not on presence at the stage - a plain edit must '
            + 'not re-stamp');
        Assert.areEqual(Date.today(), stampedAt, 'Sanity: the original entry did stamp');
    }

    // ── IDEMPOTENCY ─────────────────────────────────────────────────────────

    /**
     * ⚠ THE KEY IS "ANY LISTING ON THIS DISPOSITION", NOT "a listing for this broker" — which is
     * what keeps the broker-change history model reachable. A deliberate broker change APPENDS a
     * second row (BrokerListingSelector already reads `CreatedDate DESC LIMIT 1`); a stage
     * re-entry must not.
     */
    @isTest
    static void anExistingListingSuppressesAutoCreate() {
        Disposition__c d = onMarketWithNoListingDate();
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        Broker_Listing__c preexisting = TestDataFactory.createBrokerListing(d.Id, true);

        Test.startTest();
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);
        Test.stopTest();

        List<Broker_Listing__c> listings = listingsOn(d.Id);
        Assert.areEqual(1, listings.size(),
            'A disposition that already has a listing must not get a second one');
        Assert.areEqual(preexisting.Id, listings[0].Id, 'And it must be the original row');
    }

    @isTest
    static void reEnteringActiveListingNeverOpensASecondListing() {
        Disposition__c d = onMarketWithNoListingDate();
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);

        Test.startTest();
        // 'Offer Selection' — a surviving On_Market stage — stands in for "somewhere else to be".
        // 'Call for Offers' is RETIRED (pending manual Setup deletion) and must not be reintroduced
        // here; the buyer NDA signed above already satisfies All_NDAs_Signed_Before_Progression for
        // this stage, so the transition away and back is exercised for the same reason as before.
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = 'Offer Selection');
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE);
        Test.stopTest();

        Assert.areEqual(1, listingsOn(d.Id).size(),
            'Stepping away and back is not a broker change - still exactly one listing');
        Assert.areEqual(Date.today(), listingDateOf(d.Id),
            'And the marketing clock was never restarted');
    }

    // ── NO QUEUEABLE ────────────────────────────────────────────────────────

    /**
     * 🔴 THE LISTING BLOCK MUST ENQUEUE NOTHING, and the reason is different from the LOI and PSA
     * blocks'. They have no parent write at all. This block DOES have one — `Listing_Date__c` — and
     * it is performed in the BEFORE context precisely so it never becomes a second DML that an
     * approval lock could refuse. A Queueable added here would not merely be redundant: it would
     * reintroduce the D20/W1 residual (a PENDING approval outlives the job, so the async update
     * throws with allOrNone = true and nothing retries) in exchange for nothing.
     */
    @isTest
    static void theListingBlockEnqueuesNothing() {
        Disposition__c d = onMarketWithNoListingDate();
        signBuyerNdaOn(d.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        List<Disposition__c> newList = new List<Disposition__c>{
            new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE)
        };
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>{
            d.Id => new Disposition__c(Id = d.Id, Disposition_Stage__c = READINESS_STAGE)
        };

        Test.startTest();
        Integer jobsBefore = Limits.getQueueableJobs();
        DispositionStageEntryService.createStageEntryRecords(newList, oldMap);
        Integer jobsUsed = Limits.getQueueableJobs() - jobsBefore;
        Test.stopTest();

        Assert.areEqual(0, jobsUsed,
            'The Active Listing block must enqueue NOTHING. Its parent write lives in the BEFORE '
            + 'context, which is what removes the lock hazard a Queueable would exist to work '
            + 'around - and would not actually solve here.');
        Assert.areEqual(1, listingsOn(d.Id).size(), 'The listing was still created');
    }

    // ── BULK ────────────────────────────────────────────────────────────────

    /**
     * 251 forces a SECOND trigger chunk, which is the whole point of the number: a service that
     * queried or DML'd per record could not complete this at all.
     *
     * ⚠ It also proves the BEFORE and AFTER halves stay in step at volume — every one of the 251
     * must have both a started clock and a listing, and the listing's date must equal the parent's.
     */
    @isTest
    static void bulkListingStageEntryAt251OpensOneListingEach() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            false
        );
        for (Disposition__c d : dispositions) {
            d.Listing_Date__c = null;
        }
        insert dispositions;
        signBuyerNdasOn(dispositions); // All_NDAs_Signed_Before_Progression now gates On_Market too
        List<Disposition__c> moves = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            moves.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE));
        }

        Test.startTest();
        update moves;
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Broker_Listing__c WHERE Disposition__c IN :dispositions],
            'Every one of the 251 dispositions must get exactly one listing — 251 spans TWO '
            + 'trigger chunks, so a total of 200 here would mean the second chunk was dropped');
        Assert.areEqual(BULK_N,
            [
                SELECT COUNT() FROM Disposition__c
                WHERE Id IN :dispositions AND Listing_Date__c = TODAY
            ],
            'And all 251 marketing clocks must have started — the before-save half must survive '
            + 'chunking exactly as the after-save half does');
        Assert.areEqual(BULK_N,
            [
                SELECT COUNT() FROM Broker_Listing__c
                WHERE Disposition__c IN :dispositions AND List_Date__c = TODAY
            ],
            'Every child date must match its parent clock');
    }

    /**
     * 🔴 THE GOVERNOR ASSERTION FOR THE LISTING BLOCK, made on the SUPPRESSION path for the reason
     * the class header gives: every disposition already has its listing, so the service reads once
     * and returns without inserting — which keeps every after-save flow out of the measurement and
     * lets the numbers be EXACT rather than "≤ something".
     *
     * The property pinned is COST INDEPENDENT OF RECORD COUNT: one query and zero DML for 251.
     */
    @isTest
    static void listingSuppressionPathCostsOneQueryAndNoDmlAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        List<Broker_Listing__c> existing = new List<Broker_Listing__c>();
        for (Disposition__c d : dispositions) {
            existing.add(TestDataFactory.createBrokerListing(d.Id, false));
        }
        insert existing;   // built in the loop, inserted once — never DML in a loop

        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : dispositions) {
            newList.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE));
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
            'EXACTLY ONE query for 251 dispositions — the listing idempotency read is issued once '
            + 'for the whole collection. Anything above 1 means it moved into the loop; ZERO would '
            + 'mean the Active Listing block stopped running at all.');
        Assert.areEqual(0, dmlUsed,
            'Zero DML when every disposition already has its listing. A non-zero count means the '
            + 'early return after the idempotency filter was lost, and 251 duplicate listings were '
            + 'created.');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Broker_Listing__c WHERE Disposition__c IN :dispositions],
            'Still exactly one listing each — nothing was added');
    }

    /**
     * 🔴 THE BEFORE-CONTEXT COSTS NOTHING, AT ANY VOLUME. `stampListingDates` performs no SOQL, no
     * DML and no enqueue by construction — it is an in-memory assignment — and this is what makes
     * the claim "it is outside the service's stated budget by construction, not by exemption"
     * falsifiable rather than a comment. It is invoked directly so the count contains this method
     * and nothing else.
     */
    @isTest
    static void stampListingDatesCostsNoQueriesNoDmlAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N,
            TestDataFactory.defaultPropertyAsset().Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : dispositions) {
            newList.add(new Disposition__c(Id = d.Id, Disposition_Stage__c = LISTING_STAGE));
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Disposition_Stage__c = READINESS_STAGE));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer jobsBefore = Limits.getQueueableJobs();
        DispositionStageEntryService.stampListingDates(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Integer jobsUsed = Limits.getQueueableJobs() - jobsBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed, 'The before-save stamp must issue no SOQL at any volume');
        Assert.areEqual(0, dmlUsed,
            'The before-save stamp must issue no DML — that is the entire reason it is in the '
            + 'BEFORE context rather than the after one');
        Assert.areEqual(0, jobsUsed, 'And it must enqueue nothing');
        for (Disposition__c d : newList) {
            Assert.areEqual(Date.today(), d.Listing_Date__c,
                'Every one of the 251 must be stamped in memory');
        }
    }

    @isTest
    static void stampListingDatesIsNullAndEmptySafe() {
        DispositionStageEntryService.stampListingDates(null, null);
        DispositionStageEntryService.stampListingDates(new List<Disposition__c>(), null);
        Assert.isTrue(true,
            'Null and empty inputs must return quietly rather than throwing inside a before-save '
            + 'trigger, where the only symptom would be an unsaveable record');
    }
}
