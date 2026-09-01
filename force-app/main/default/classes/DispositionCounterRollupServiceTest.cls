/**
 * Tests for `DispositionCounterRollupService` — the writer behind
 * `Disposition__c.Offers_Received__c` and `Disposition__c.Responses_Received__c`
 * (Tranche 1 item 7, 2026-08-31).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * HOW THE BUDGET IS MEASURED, AND WHY IT IS MEASURED TWICE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `.claude/rules/bulk-test-rule.md` applies IN FULL (251+) — this service is trigger-driven and
 * loops over collections, so no exemption exists and none is claimed. But the rule's demand is
 * "251 rows must not cost 251 queries", and there are two different ways to ask that, with
 * different blind spots. Both are used deliberately:
 *
 *   1. DIRECT-CALL, EXACT. `recalculateOffersFor(251 parent Ids)` -> `areEqual(1, queries)` and
 *      `areEqual(1, dml)`. This is the SERVICE's own contract, isolated from every other consumer
 *      on the two triggers. It is the strongest form and the one that stays meaningful when a
 *      sixth job joins `BovSubmissionTriggerHandler`.
 *      🔴 This is the lesson `BovAutoSelectionServiceTest
 *      .anAssetSaveThatDoesNotChangeThePrice_costsNothing` records after failing in deploy:
 *      *"a trigger-level query count is the wrong instrument for a one-hook contract"* — it
 *      measures every consumer on the trigger, so it fails while naming the wrong one.
 *
 *   2. TRIGGER-LEVEL, EXACT WHERE IT IS DERIVABLE. A real 251-row `insert` with the whole trigger
 *      stack live. This catches what (1) cannot: a routing mistake, a context that was never
 *      wired, or a second call per chunk. Every term is derived in the assertion message.
 *
 * ⚠ EVERY FIXTURE IS BUILT ABOVE `Test.startTest()` AND ABOVE EVERY `Limits` SNAPSHOT. Method
 * ARGUMENTS are evaluated AFTER `Limits.getDmlStatements()` has been read, and
 * `TestDataFactory.createBovSubmission` / `defaultPropertyAsset` both lazily insert on first call.
 * This repo has TWO measured incidents of a governor assertion measuring its own arguments
 * (`BovAutoSelectionServiceTest`, 2026-08-24 and 2026-08-25). Do not inline a fixture call into a
 * measured statement.
 *
 * ⚠ THE FACTORY ASSET CARRIES NO `Target_Sale_Price__c` (removed 2026-08-25, deliberately), so
 * every `BOV_Score__c` here is NULL and `BovAutoSelectionService` appoints nobody and writes
 * nothing. That is what makes the trigger-level numbers below DERIVABLE rather than approximate.
 * 🔴 IF A FUTURE EDIT PRICES THE ASSET, THE BOV BUDGET ASSERTIONS MOVE — and the right response is
 * to re-derive them, not to unprice the asset to make them pass.
 *
 * @see DispositionCounterRollupService
 * @see BovSubmissionSelector (countByDispositionIds)
 * @see DispositionOfferSelector (selectOfferTractionByDispositionIds — the reused offer aggregate)
 */
@isTest
private class DispositionCounterRollupServiceTest {

    private static final Integer BULK_N = 251;

    /**
     * ONE shared `Property_Asset__c` for the whole run — `defaultPropertyAsset()` caches it per
     * transaction. Never `createPropertyAsset(...)` per fixture: at 251 dispositions that would be
     * 502 DML statements before the code under test ran.
     */
    private static Id assetId() {
        return TestDataFactory.defaultPropertyAsset().Id;
    }

    /** A committed disposition at the factory default stage (`Disposition Readiness`). */
    private static Disposition__c disposition() {
        return TestDataFactory.createDisposition(assetId(), true);
    }

    /**
     * Re-reads both counters. Never trust the in-memory fixture — the TRIGGER wrote the parent, so
     * the local copy is stale by construction.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 `WITH SYSTEM_MODE` ON A TEST CLASS'S OWN QUERY, AND IT IS NOT DEFENSIVE PADDING.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `Offers_Received__c` is created by this same tranche and both counters are granted READ-ONLY
     * FLS, in permission sets the deploy-time `RunLocalTests` administrator typically holds NONE
     * of. MEASURED IN THIS ORG, repeatedly: a field with zero `FieldPermissions` rows is not
     * FLS-*denied*, it is ABSENT FROM THE RUNNING USER'S SCHEMA, and a plain unqualified
     * `[SELECT Offers_Received__c ...]` throws `System.QueryException: No such column` — an FLS gap
     * wearing a schema-error costume. It has taken out 14 methods of one class and 42 of another,
     * in tests that had nothing to do with the new field.
     * ⚠ The same reasoning is why every fixture DML in this class that NAMES a counter field uses
     * `AccessLevel.SYSTEM_MODE`. The production service already does
     * (`ParentCounterWrites`), which is the only reason the feature works at all before the
     * permission-set pass lands.
     * 🔴 DO NOT "TIDY" THIS BACK TO A PLAIN SELECT once the grants exist. The grants are read-only
     * on two personas; the test-running user is neither of them.
     */
    private static Disposition__c reread(Id dispositionId) {
        return [
            SELECT Id, Offers_Received__c, Responses_Received__c
            FROM Disposition__c WHERE Id = :dispositionId
            WITH SYSTEM_MODE
        ];
    }

    /** Bulk twin of `reread`. Same `WITH SYSTEM_MODE` argument — read it there. */
    private static Map<Id, Disposition__c> rereadAll(Set<Id> ids) {
        return new Map<Id, Disposition__c>([
            SELECT Id, Offers_Received__c, Responses_Received__c
            FROM Disposition__c WHERE Id IN :ids
            WITH SYSTEM_MODE
        ]);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // OFFERS -> Offers_Received__c
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE `after insert` CONTEXT DID NOT EXIST ON `DispositionOfferTrigger` BEFORE 2026-08-31.
     * This test fails against the old trigger signature, not merely against a missing service.
     */
    @isTest
    static void insertingOffers_countsThemOnTheParent() {
        Disposition__c d = disposition();

        Test.startTest();
        TestDataFactory.createDispositionOffers(3, d.Id, true);
        Test.stopTest();

        Assert.areEqual(3, reread(d.Id).Offers_Received__c,
            'Three offers were logged against the sale, so Offers_Received__c must read 3. A null '
            + 'or 0 here means DispositionOfferTrigger has no after-insert context, or the handler '
            + 'does not route the recompute.');
    }

    /**
     * 🔴 EVERY STATUS COUNTS (design decision D-9). Story 37 keeps Rejected, Countered and
     * Withdrawn offers VISIBLE on the sale, so "offers received" includes them. This is the
     * falsifier for anyone adding a `WHERE Offer_Status__c = ...` predicate to the aggregate — a
     * filter would look like tidying and would silently redefine the number the BA signed off.
     */
    @isTest
    static void offersOfEveryStatusAreCounted_notJustLiveOnes() {
        Disposition__c d = disposition();
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(4, d.Id, false);
        // ⚠ THE EXACT PICKLIST SPELLINGS, TAKEN FROM
        // `objects/Disposition_Offer__c/fields/Offer_Status__c.field-meta.xml`, WHICH IS
        // `<restricted>true</restricted>` — a near-miss like 'Countered' or 'Withdrawn' is refused
        // at DML, not silently accepted. The object has no record types, so no subset can hide a
        // value from this fixture.
        offers[0].Offer_Status__c = 'Received';
        offers[1].Offer_Status__c = 'Rejected';
        offers[2].Offer_Status__c = 'Countered by DPEG';
        offers[3].Offer_Status__c = 'Withdrawn by Buyer';

        Test.startTest();
        insert offers;
        Test.stopTest();

        Assert.areEqual(4, reread(d.Id).Offers_Received__c,
            '🔴 ALL FOUR statuses count. A 1 here means a status filter crept into the aggregate '
            + 'and the counter now answers a different question from the one story 37 asks.');
    }

    /**
     * The decrement — and specifically the case an INCREMENTING counter could never have handled
     * and that a naive recompute still gets wrong.
     *
     * 🔴 DELETING THE **LAST** OFFER PRODUCES NO `GROUP BY` ROW AT ALL. If `applyCounts` iterated
     * the aggregate's keySet instead of the parent-Id set, this disposition would simply be skipped
     * and would read 2 forever. That is the single most likely implementation slip in this service,
     * and this test is the only thing that catches it.
     */
    @isTest
    static void deletingTheLastOffer_drivesTheCounterToZeroRatherThanLeavingItStale() {
        Disposition__c d = disposition();
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(2, d.Id, true);
        Assert.areEqual(2, reread(d.Id).Offers_Received__c, 'precondition: the counter reached 2');

        Test.startTest();
        delete offers;
        Test.stopTest();

        Assert.areEqual(0, reread(d.Id).Offers_Received__c,
            '🔴 A 2 HERE MEANS THE EMPTY-GROUP CASE IS UNHANDLED — the aggregate returns NO ROW for '
            + 'a parent with no children, so a miss must default to 0 rather than being skipped. '
            + 'A counter that can only go up is worse than no counter: it reads as a confident '
            + 'number that contradicts the related list beside it.');
    }

    /** A partial delete decrements to the surviving count, not to zero. */
    @isTest
    static void deletingSomeOffers_leavesTheSurvivingCount() {
        Disposition__c d = disposition();
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(3, d.Id, true);

        Test.startTest();
        delete offers[0];
        Test.stopTest();

        Assert.areEqual(2, reread(d.Id).Offers_Received__c,
            'Two offers survive, so the counter reads 2 — recomputed from the aggregate, not '
            + 'decremented by one from a stored value.');
    }

    /**
     * 🔴 THE UNDELETE CONTEXT DID NOT EXIST ON `DispositionOfferTrigger` BEFORE 2026-08-31 EITHER.
     * A restored offer is an offer the sale has received.
     */
    @isTest
    static void undeletingAnOffer_countsItAgain() {
        Disposition__c d = disposition();
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);
        delete offer;
        Assert.areEqual(0, reread(d.Id).Offers_Received__c, 'precondition: the delete decremented');

        Test.startTest();
        undelete offer;
        Test.stopTest();

        Assert.areEqual(1, reread(d.Id).Offers_Received__c,
            'A restored offer must be counted again. A 0 here means DispositionOfferTrigger has no '
            + 'after-undelete context and a Recycle-Bin restore leaves the counter permanently low '
            + 'with nothing to notice it.');
    }

    /**
     * 🔴 THE REPARENT, AND BOTH SIDES OF IT. A handler that recomputes only `Trigger.new`'s parent
     * leaves the OLD sale permanently one too high — a wrong number on a record nobody was even
     * looking at, which is the hardest kind to notice.
     */
    @isTest
    static void reparentingAnOffer_recomputesBothTheOldAndTheNewSale() {
        // ⚠ `movedFrom`, NOT `from`. 🔴 `from` IS A RESERVED WORD IN APEX and fails to compile with
        // `Unexpected token 'from'` reported on the DECLARATION line, which reads like a syntax
        // error in the type rather than in the identifier.
        Disposition__c movedFrom = disposition();
        Disposition__c onto = disposition();
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(2, movedFrom.Id, true);
        TestDataFactory.createDispositionOffers(1, onto.Id, true);
        Assert.areEqual(2, reread(movedFrom.Id).Offers_Received__c, 'precondition: source has 2');
        Assert.areEqual(1, reread(onto.Id).Offers_Received__c, 'precondition: target has 1');

        Test.startTest();
        update new Disposition_Offer__c(Id = offers[0].Id, Disposition__c = onto.Id);
        Test.stopTest();

        Map<Id, Disposition__c> after = rereadAll(new Set<Id>{ movedFrom.Id, onto.Id });
        Assert.areEqual(1, after.get(movedFrom.Id).Offers_Received__c,
            '🔴 THE SALE THE OFFER LEFT must be recomputed too. A 2 here is the defect: only '
            + 'Trigger.new\'s parent was recounted, so the source keeps counting an offer it no '
            + 'longer has.');
        Assert.areEqual(2, after.get(onto.Id).Offers_Received__c,
            'and the sale it joined gains it.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BOV SUBMISSIONS -> Responses_Received__c
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void insertingSubmissions_countsThemOnTheParent() {
        Disposition__c d = disposition();

        Test.startTest();
        TestDataFactory.createBovSubmissions(3, d.Id, true);
        Test.stopTest();

        Assert.areEqual(3, reread(d.Id).Responses_Received__c,
            'Three brokers responded, so Responses_Received__c must read 3. ⚠ This field had NO '
            + 'writer at all before 2026-08-31 — it was hand-keyed in four seed scripts — so a '
            + 'null here means the recompute is not routed on after-insert.');
    }

    @isTest
    static void deletingTheLastSubmission_drivesTheCounterToZero() {
        Disposition__c d = disposition();
        List<BOV_Submission__c> subs = TestDataFactory.createBovSubmissions(2, d.Id, true);
        Assert.areEqual(2, reread(d.Id).Responses_Received__c, 'precondition: the counter reached 2');

        Test.startTest();
        delete subs;
        Test.stopTest();

        Assert.areEqual(0, reread(d.Id).Responses_Received__c,
            '🔴 The empty-group case again: no GROUP BY row is emitted for a parent with no '
            + 'children, so a miss must default to 0. A 2 here means the decrement is impossible.');
    }

    @isTest
    static void reparentingASubmission_recomputesBothSales() {
        // ⚠ `movedFrom`, NOT `from` — see the offer twin above; `from` is a reserved word in Apex.
        Disposition__c movedFrom = disposition();
        Disposition__c onto = disposition();
        List<BOV_Submission__c> subs = TestDataFactory.createBovSubmissions(2, movedFrom.Id, true);

        Test.startTest();
        update new BOV_Submission__c(Id = subs[0].Id, Disposition__c = onto.Id);
        Test.stopTest();

        Map<Id, Disposition__c> after = rereadAll(new Set<Id>{ movedFrom.Id, onto.Id });
        Assert.areEqual(1, after.get(movedFrom.Id).Responses_Received__c,
            'The sale the response left must be decremented, not only the one it joined.');
        Assert.areEqual(1, after.get(onto.Id).Responses_Received__c,
            'and the sale it joined must be incremented.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE UNDELETE CONTEXT ON BOV_Submission__c — DESIGN DECISION D-5
    // ═════════════════════════════════════════════════════════════════════════════════════
    // `BovSubmissionTrigger` carried a written, argued REFUSAL of `after undelete` from 2026-08-24.
    // The context now exists and the refusal was retracted IN PLACE rather than deleted, because
    // its subject — `BovAutoSelectionService` — is STILL not routed there. The two tests below are
    // the two halves of that decision, and neither is sufficient alone.

    /**
     * HALF ONE: the counter DOES run on undelete.
     */
    @isTest
    static void undeletingASubmission_countsItAgain() {
        Disposition__c d = disposition();
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, true);
        delete sub;
        Assert.areEqual(0, reread(d.Id).Responses_Received__c, 'precondition: the delete decremented');

        Test.startTest();
        undelete sub;
        Test.stopTest();

        Assert.areEqual(1, reread(d.Id).Responses_Received__c,
            'A restored submission is a response the sale received. A 0 here means the '
            + 'after-undelete context was never added, or the handler does not route the counter.');
    }

    /**
     * 🔴 HALF TWO — THE HIGHER-VALUE ONE. THE UNDELETE GAP MUST STILL PRODUCE TWO `Selected` ROWS.
     *
     * Adding `after undelete` to `BovSubmissionTrigger` re-opened a door that was deliberately
     * nailed shut on 2026-08-24: if `BovAutoSelectionService` were routed there, restoring a
     * `Selected` submission onto a sale that has since appointed someone else would SELF-HEAL, and
     * SEVEN things in this repo depend on that state remaining reachable — one production branch
     * (`DispositionApprovalService.MULTIPLE_SELECTED_BOV_MESSAGE`, whose header names undelete as
     * the reason it is a live backstop rather than dead code) plus six test-side entries across
     * four test classes (five `@isTest` methods and one shared fixture helper). Silently repairing
     * it would turn all seven GREEN AND VACUOUS rather than red.
     * ⚠ COUNT CORRECTED 2026-08-31 (Tranche 1 code review, W-3). RETRACTED: "three things in this
     * repo depend on that state remaining reachable — [MULTIPLE_SELECTED_BOV_MESSAGE],
     * `BovSubmissionSelectorTest.twoSelectedViaUndelete`, and
     * `selectSelectedByDispositionId_twoSelected_returnsBOTH` ... would turn all three GREEN AND
     * VACUOUS". The three named were real and are still in the list; four more were missing, and
     * four of the seven build the undelete gap INLINE rather than through the shared helper, so a
     * grep for `twoSelectedViaUndelete` finds none of them. 🔴 THE ENUMERATED LIST LIVES AT
     * `BovAutoSelectionService.reselectForDeleted` AND IS DELIBERATELY NOT RE-COPIED HERE — this
     * partial copy is exactly how the wrong count survived in four files at once.
     *
     * ⚠ THE RECIPE IS COPIED FROM `BovSubmissionSelectorTest.twoSelectedViaUndelete` AND EVERY STEP
     * IS LORE-BEARING. Swap the insert and the undelete and the guard correctly refuses it.
     *
     * ⚠ THE QUERY ASSERTION IS NOT DECORATION — IT IS THE PART THAT CANNOT BE FAKED. The status
     * assertion alone would still pass if `BovAutoSelectionService` were routed here and simply
     * chose to write nothing (both scores are null, so it might). The query count is what proves it
     * was not CALLED: its selection read is unconditional once a parent Id is in play.
     */
    @isTest
    static void undeleteRoutesTheCounterOnly_andLeavesTwoSelectedRowsReachable() {
        Disposition__c d = disposition();

        BOV_Submission__c first = TestDataFactory.createBovSubmission(d.Id, false);
        first.Submission_Status__c = 'Selected';
        insert first;
        delete first;

        BOV_Submission__c second = TestDataFactory.createBovSubmission(d.Id, false);
        second.Submission_Status__c = 'Selected';
        insert second;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        undelete first;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(2, reread(d.Id).Responses_Received__c,
            'Both rows are live again, so the counter reads 2 — the counter is indifferent to '
            + 'Submission_Status__c, which is exactly why it is admissible in this context.');
        Assert.areEqual(2, [
            SELECT COUNT() FROM BOV_Submission__c
            WHERE Disposition__c = :d.Id AND Submission_Status__c = 'Selected'
        ], '🔴 THE TWO-SELECTED STATE MUST SURVIVE. One row here means something SELF-HEALED it — '
            + 'almost certainly BovAutoSelectionService being routed into afterUndelete — and '
            + 'three tests plus one authored refusal elsewhere in this repo have just gone '
            + 'green-and-vacuous. Read BovSubmissionTriggerHandler.afterUndelete\'s standing rule '
            + 'before changing anything.');
        Assert.areEqual(1, queriesUsed,
            '🔴 EXACTLY ONE QUERY IN afterUndelete: the Responses_Received__c aggregate, and '
            + 'nothing else. A SECOND is BovAutoSelectionService\'s selection read, which must not '
            + 'run in this context whether or not it decides to write. This assertion is the only '
            + 'one here that a no-op implementation cannot satisfy. Queries used: ' + queriesUsed);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE ZERO-COST FAST PATH — AND ITS FALSIFIER
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * An update that does not move the `Disposition__c` lookup must cost ZERO queries and ZERO DML.
     *
     * 🔴 THIS IS NOT AN OPTIMISATION TEST. Both triggers fire on EVERY save of their object in the
     * org, and `BovSubmissionTriggerHandlerTest.bulk251ApprovesAtConstantCost` asserts EXACTLY 2
     * queries and 3 DML around a 251-row approval update. If this path ever costs anything, that
     * test goes red — and the correct response is to fix this, never to relax that.
     *
     * ⚠ THE FALSIFIER IS THE WHOLE TEST. A method that was deleted, stubbed or short-circuited at
     * its first line would also report zero. The second call — the SAME method, with the parent
     * genuinely moved — is what makes the zero mean something.
     */
    @isTest
    static void anUpdateThatDoesNotMoveTheParent_costsNothing_andOneThatDoesCosts() {
        Disposition__c d = disposition();
        Disposition__c other = disposition();
        List<BOV_Submission__c> subs = TestDataFactory.createBovSubmissions(2, d.Id, true);

        // 🔴 EVERYTHING THE MEASURED CALLS NEED IS BUILT HERE, ABOVE THE WINDOW. Method arguments
        // are evaluated AFTER the counter is read; this repo has two measured incidents of a
        // governor assertion measuring its own fixture.
        List<BOV_Submission__c> unmovedNew = new List<BOV_Submission__c>();
        Map<Id, BOV_Submission__c> unmovedOld = new Map<Id, BOV_Submission__c>();
        for (BOV_Submission__c s : subs) {
            unmovedNew.add(new BOV_Submission__c(
                Id = s.Id, Disposition__c = d.Id, BOV_Amount__c = 9000000));
            unmovedOld.put(s.Id, new BOV_Submission__c(Id = s.Id, Disposition__c = d.Id));
        }
        List<BOV_Submission__c> movedNew = new List<BOV_Submission__c>{
            new BOV_Submission__c(Id = subs[0].Id, Disposition__c = other.Id)
        };
        Map<Id, BOV_Submission__c> movedOld = new Map<Id, BOV_Submission__c>{
            subs[0].Id => new BOV_Submission__c(Id = subs[0].Id, Disposition__c = d.Id)
        };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        DispositionCounterRollupService.recalculateResponsesForRows(unmovedNew, unmovedOld);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

        Integer queriesBeforeMove = Limits.getQueries();
        DispositionCounterRollupService.recalculateResponsesForRows(movedNew, movedOld);
        Integer queriesOnMove = Limits.getQueries() - queriesBeforeMove;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'ZERO QUERIES: a chunk in which no row changed its Disposition__c must return after one '
            + 'in-memory pass, before any SOQL. Queries used: ' + queriesUsed);
        Assert.areEqual(0, dmlUsed,
            'and ZERO DML — an unchanged parent must not be written.');
        Assert.areEqual(1, queriesOnMove,
            'FALSIFIER: with the parent genuinely moved the SAME method must issue exactly ONE '
            + 'aggregate. Zero here means the assertions above pass because the method does '
            + 'nothing at all. Queries used: ' + queriesOnMove);
    }

    /** Null and empty inputs must cost nothing and throw nothing — both triggers call these on every save. */
    @isTest
    static void nullAndEmptyInputs_costNothingAndThrowNothing() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        DispositionCounterRollupService.recalculateOffersFor(null);
        DispositionCounterRollupService.recalculateOffersFor(new Set<Id>());
        DispositionCounterRollupService.recalculateResponsesFor(null);
        DispositionCounterRollupService.recalculateResponsesFor(new Set<Id>());
        DispositionCounterRollupService.recalculateOffersForRows(null, null);
        DispositionCounterRollupService.recalculateOffersForRows(
            new List<Disposition_Offer__c>(), null);
        DispositionCounterRollupService.recalculateResponsesForRows(null, null);
        DispositionCounterRollupService.recalculateResponsesForRows(
            new List<BOV_Submission__c>(), null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed, 'Null / empty input must cost ZERO queries.');
        Assert.areEqual(0, dmlUsed, 'and ZERO DML.');
    }

    /**
     * A child row with a NULL parent must be ignored, not turned into a write against a null Id.
     * Both lookups are `<required>false</required>`, so this shape is reachable.
     */
    @isTest
    static void rowsWithNoParent_areIgnoredAtZeroCost() {
        List<BOV_Submission__c> parentless = new List<BOV_Submission__c>{
            new BOV_Submission__c(BOV_Amount__c = 1000000)
        };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionCounterRollupService.recalculateResponsesForRows(parentless, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A parentless row puts no Disposition in play, so the service must return before the '
            + 'aggregate. Queries used: ' + queriesUsed);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 BULK — .claude/rules/bulk-test-rule.md, IN FULL (251+)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * THE SERVICE'S OWN CONTRACT, ISOLATED: 251 parent dispositions cost EXACTLY one aggregate and
     * EXACTLY one `Database.update`.
     *
     * 🔴 THIS IS THE ASSERTION THE RULE ACTUALLY ASKS FOR — not "251 rows produced 251 counters",
     * which a per-record implementation satisfies perfectly while exhausting the 100-SOQL and
     * 150-DML limits in production. 251 dispositions each costing one query fails at row 101.
     *
     * ⚠ ONE `Database.update` OF 251 ROWS IS ONE **STATEMENT**. It fires `DispositionTrigger` in
     * two chunks, and both are free: `createStageEntryRecords` is keyed on `Disposition_Stage__c`
     * CHANGING (in an after-update context Trigger.new holds the full committed record, so old and
     * new agree and it continues), and `enqueuePendingAdvances` on `Approval_Advance_Pending__c`
     * transitioning to true. The counter shell touches neither. That is why the numbers below are 1
     * and 1 rather than 1 and 3.
     */
    @isTest
    static void bulk251Parents_costExactlyOneQueryAndOneDmlPerCounter() {
        List<Disposition__c> dispositions =
            TestDataFactory.createDispositions(BULK_N, assetId(), true);
        Set<Id> ids = new Map<Id, Disposition__c>(dispositions).keySet();

        // 🔴 PRE-SEED A WRONG, NON-ZERO VALUE, OR THE END-STATE ASSERTION BELOW IS VACUOUS.
        // `Offers_Received__c` carries `<defaultValue>0</defaultValue>` and the factory sets
        // `Responses_Received__c = 0`, so every one of these 251 rows ALREADY reads 0 before the
        // service runs. Asserting "all 251 read 0" against that proves only that the platform
        // default exists. Seeding 99 first is what makes the assertion a statement about THIS
        // SERVICE — specifically about it iterating the parent-Id set rather than the (empty)
        // aggregate, which is the one implementation slip that would otherwise ship green.
        // ⚠ `AccessLevel.SYSTEM_MODE` because this payload NAMES the two counter fields, which are
        // read-only FLS on both disposition personas and ungranted for the test-running admin. A
        // plain `update` here throws `Operation failed due to fields being inaccessible` —
        // measured in this org more than once, on brand-new fields exactly like these.
        List<Disposition__c> preSeed = new List<Disposition__c>();
        for (Id dispositionId : ids) {
            preSeed.add(new Disposition__c(
                Id = dispositionId, Offers_Received__c = 99, Responses_Received__c = 99));
        }
        Database.update(preSeed, true, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Integer offerQueriesBefore = Limits.getQueries();
        Integer offerDmlBefore = Limits.getDmlStatements();
        DispositionCounterRollupService.recalculateOffersFor(ids);
        Integer offerQueries = Limits.getQueries() - offerQueriesBefore;
        Integer offerDml = Limits.getDmlStatements() - offerDmlBefore;

        Integer responseQueriesBefore = Limits.getQueries();
        Integer responseDmlBefore = Limits.getDmlStatements();
        DispositionCounterRollupService.recalculateResponsesFor(ids);
        Integer responseQueries = Limits.getQueries() - responseQueriesBefore;
        Integer responseDml = Limits.getDmlStatements() - responseDmlBefore;
        Test.stopTest();

        Assert.areEqual(1, offerQueries,
            '🔴 ONE aggregate for 251 dispositions, keyed on the whole Set<Id>. A per-disposition '
            + 'query would read 251 and fail at row 101. Queries used: ' + offerQueries);
        Assert.areEqual(1, offerDml,
            '🔴 ONE Database.update for 251 parents. A per-record write would read 251 and exhaust '
            + 'the 150-statement limit. DML used: ' + offerDml);
        Assert.areEqual(1, responseQueries,
            'and the responses counter has the same contract. Queries used: ' + responseQueries);
        Assert.areEqual(1, responseDml, 'DML used: ' + responseDml);

        // ⚠ NOT MERELY A COST TEST — AND NOT VACUOUS, BECAUSE OF THE 99s SEEDED ABOVE. Every one of
        // the 251 has zero children, so every one must be RESET to 0. This is the whole decrement
        // path: the aggregate returns NOTHING for a childless parent, so a service that iterated
        // `countById.keySet()` instead of the input `Set<Id>` would write nobody and leave 251 rows
        // reading 99 — a counter that can only ever go up.
        Map<Id, Disposition__c> after = rereadAll(ids);
        Integer zeroed = 0;
        for (Disposition__c d : after.values()) {
            if (d.Offers_Received__c == 0 && d.Responses_Received__c == 0) {
                zeroed++;
            }
        }
        Assert.areEqual(BULK_N, zeroed,
            '🔴 ALL 251 must be RESET from 99 to 0. A 0 here means the service iterated the '
            + 'aggregate instead of the input Id set, so a parent whose last child was deleted is '
            + 'skipped and keeps its stale number forever. Rows correctly zeroed: ' + zeroed);
    }

    /**
     * THE TRIGGER-LEVEL TWIN FOR OFFERS: 251 offers in one insert, two trigger chunks.
     *
     * DERIVED, TERM BY TERM — and every term is stated so a future failure names its own cause:
     *   SOQL 2 = one `Offers_Received__c` aggregate PER CHUNK. The two before-context jobs are
     *            free: `DispositionOfferSelectionGuardService` is change-keyed on `Is_Selected__c`
     *            and `DispositionOfferBuyerStampService` on `Buyer__c`, and
     *            `TestDataFactory.createDispositionOffers` sets neither.
     *   DML  3 = ONE for this test's own insert + ONE counter write PER CHUNK.
     */
    @isTest
    static void bulk251OfferInsert_countsAllAtConstantCostPerChunk() {
        Disposition__c d = disposition();
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(BULK_N, d.Id, false);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert offers; // 251 rows -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, reread(d.Id).Offers_Received__c,
            '🔴 ALL 251 must be counted. A 200 here means the SECOND trigger chunk was dropped — '
            + 'and note that an INCREMENTING implementation would also read 251 and would be '
            + 'wrong for a different reason; that is what the delete tests above are for.');
        Assert.areEqual(2, queriesUsed,
            'ONE aggregate PER CHUNK and nothing else — the two before-context jobs are '
            + 'change-keyed on fields this fixture does not set. Queries used: ' + queriesUsed);
        Assert.areEqual(3, dmlUsed,
            'ONE for this test\'s own insert plus ONE counter write PER CHUNK — 251 rows is TWO '
            + 'chunks, so exactly 1 + 2 = 3. A per-record write would read close to 251 and would '
            + 'exhaust the 150-statement limit. DML used: ' + dmlUsed);
    }

    /**
     * THE TRIGGER-LEVEL TWIN FOR SUBMISSIONS, WHICH IS THE BUSIER TRIGGER OF THE TWO.
     *
     * DERIVED, TERM BY TERM:
     *   SOQL <= 8 = per chunk: ONE `BovSubmissionBrokerStampService` Contact read (the factory sets
     *               a distinct `Broker__c` per row, so the stamp's change key IS satisfied), ONE
     *               `BovAutoSelectionService` selection read, ONE `Responses_Received__c`
     *               aggregate. Three per chunk, two chunks, plus headroom.
     *               (`BovSubmissionSelectionGuardService` is free — every fixture row is `Backup`.)
     *   DML  3    = ONE for this test's own insert + ONE counter write PER CHUNK.
     *               🔴 `BovAutoSelectionService` writes NOTHING here, and that is a property of the
     *               fixture, not luck: the shared factory asset carries no `Target_Sale_Price__c`
     *               (deliberately, since 2026-08-25), so every `BOV_Score__c` is null and nothing
     *               is scoreable. If that ever changes this number becomes 5, and the fix is to
     *               re-derive it — not to unprice the asset.
     */
    @isTest
    static void bulk251SubmissionInsert_countsAllAtConstantCostPerChunk() {
        Disposition__c d = disposition();
        List<BOV_Submission__c> subs =
            TestDataFactory.createBovSubmissions(BULK_N, d.Id, false);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert subs; // 251 rows -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, reread(d.Id).Responses_Received__c,
            '🔴 ALL 251 must be counted. A 200 here means the SECOND trigger chunk was dropped.');
        Assert.areEqual(3, dmlUsed,
            'ONE for this test\'s own insert plus ONE counter write PER CHUNK — exactly 1 + 2 = 3. '
            + 'A per-record write would read close to 251. DML used: ' + dmlUsed);
        Assert.isTrue(queriesUsed <= 8,
            'PER-CHUNK CONSTANT BUDGET: broker-stamp Contact read, auto-selection read, and the '
            + 'Responses_Received__c aggregate — three per chunk, two chunks, plus headroom. A '
            + 'per-record query would read close to 251. Queries used: ' + queriesUsed);
    }

    /**
     * 251 offers spread over 251 SEPARATE dispositions — the shape a data load actually takes, and
     * the one where a per-disposition query blows the 100-SOQL limit at row 101.
     */
    @isTest
    static void bulk251OffersAcrossManySales_countsEachOneAtConstantCost() {
        List<Disposition__c> dispositions =
            TestDataFactory.createDispositions(BULK_N, assetId(), true);
        List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();
        for (Disposition__c d : dispositions) {
            offers.add(TestDataFactory.createDispositionOffer(d.Id, false));
        }
        Set<Id> ids = new Map<Id, Disposition__c>(dispositions).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert offers; // 251 rows across 251 parents -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(2, queriesUsed,
            '🔴 ONE aggregate PER CHUNK keyed on the whole Set<Id> of parents, never one per '
            + 'disposition. 251 sales would be 251 queries and would fail at row 101. Queries '
            + 'used: ' + queriesUsed);
        Map<Id, Disposition__c> after = rereadAll(ids);
        Integer counted = 0;
        for (Disposition__c d : after.values()) {
            if (d.Offers_Received__c == 1) {
                counted++;
            }
        }
        Assert.areEqual(BULK_N, counted,
            'Every one of the 251 sales must read exactly 1. A total below 251 means the second '
            + 'trigger chunk was dropped.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 SHARING — DESIGN DECISION D-10. THE ONLY TEST HERE THAT CAN FAIL ON IT.
    // ═════════════════════════════════════════════════════════════════════════════════════
    // ⚠ EVERY TEST ABOVE THIS LINE WOULD PASS AGAINST A `with sharing` VERSION OF THE PARENT WRITE.
    // They run as the admin test user, who OWNS every fixture record, and an owner of an OWD-Private
    // record always holds record-level edit — so the question that fails in production is never
    // asked. `Disposition__c` is `sharingModel = Private` (measured in the object file).
    //
    // The fixture below separates two identities every test above conflates:
    //   PARENT OWNER = the admin test user (an analyst, in production)
    //   RUNNING USER = a Minimum-Access principal carrying DPEG_Disposition_Edit: allowCreate,
    //                  allowEdit and viewAllRecords on Disposition__c, and NO modifyAllRecords.
    // Object-level CRUD is therefore satisfied, so `AccessLevel.SYSTEM_MODE` has nothing left to
    // contribute and the ONLY thing that can still refuse the counter write is RECORD-LEVEL
    // SHARING. A pass here can only be the `without sharing` escape (`ParentCounterWrites`).

    /**
     * 🔴 THE PRECONDITION THAT KEEPS THE TEST BELOW HONEST. Run INSIDE `System.runAs` against
     * `UserInfo.getUserId()`, so it needs no View All Data and cannot answer for the wrong
     * principal.
     *
     * ⚠ `RecordId` MUST BE IN THE SELECT even though nothing reads it — `UserRecordAccess` rejects
     * a query without it at COMPILE time. Do not "tidy" it away.
     * ⚠ AND IT MUST BE `UserRecordAccess`, NEVER A SOQL PROBE. An Apex test class has no sharing
     * keyword, so it runs `without sharing`; `[SELECT COUNT() FROM Disposition__c ...]` inside
     * `System.runAs` returns the row regardless of access and would "prove" the opposite of the
     * truth.
     */
    private static void assertReadableButNotEditable(Id dispositionId) {
        UserRecordAccess access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :dispositionId
        ];
        Assert.isTrue(access.HasReadAccess,
            'FIXTURE PRECONDITION: the saver must be able to READ the parent sale — that is what '
            + 'DPEG_Disposition_Edit.viewAllRecords grants. If this is false the test fails at the '
            + 'read and is not testing the write.');
        Assert.isFalse(access.HasEditAccess,
            '🔴 FIXTURE PRECONDITION: the saver must NOT be able to EDIT the parent sale. This is '
            + 'the entire subject. If it is true, the persona acquired record-level edit from '
            + 'somewhere — modifyAllRecords on DPEG_Disposition_Edit, a role, or a widened '
            + 'Disposition_Team_RW sharing rule — and the assertions below are vacuous. '
            + 'Investigate the org; do NOT delete this assertion.');
    }

    /**
     * 🔴 THE HIGHEST-VALUE TEST IN THIS FILE. It fails RED if `ParentCounterWrites`' `without
     * sharing` is removed, leaving a bare `Database.update(parents, false,
     * AccessLevel.SYSTEM_MODE)` inside the `with sharing` service.
     *
     * WHAT IT PINS: `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing (ARCHITECTURE.md §2). This
     * repo has a MEASURED production incident of exactly that confusion — an approval's parent
     * write failed silently for every approver who did not own the record, `allOrNone = false`
     * swallowed it, and nobody read the `SaveResult`
     * (`DispositionOfferTriggerHandler.ParentAdvanceWrites`, 2026-08-21).
     *
     * ⚠ `lastRunFailures` IS ASSERTED EMPTY *FIRST*, DELIBERATELY. Without it the failure message
     * would be an opaque "expected 2, was 1"; with it, the platform `StatusCode` is in the message.
     * `INSUFFICIENT_ACCESS_OR_READONLY` there means the sharing escape is gone.
     *
     * ⚠ `Database.insert(..., AccessLevel.SYSTEM_MODE)` RATHER THAN A PLAIN `insert`, AND IT DOES
     * NOT WEAKEN THE TEST. The persona has no FLS on every field the factory sets, so a plain
     * insert fails with `fields being inaccessible` before the trigger runs at all — a failure that
     * has nothing to do with the subject. SYSTEM_MODE lifts CRUD/FLS and NEVER sharing, so the
     * parent write under test is still sharing-scoped and still refused unless it escapes. Same
     * idiom, same reason, as `DispositionOfferTriggerHandlerTest`'s non-owner approver tests.
     */
    @isTest
    static void aSaverWhoCannotEditTheSale_stillGetsTheCounterWritten() {
        Disposition__c d = disposition();
        TestDataFactory.createDispositionOffer(d.Id, true);
        Assert.areEqual(1, reread(d.Id).Offers_Received__c, 'precondition: the owner\'s own save counted');

        User saver = TestDataFactory.createNonOwnerDispositionApprover('dcr1');
        Disposition_Offer__c second = TestDataFactory.createDispositionOffer(d.Id, false);

        System.runAs(saver) {
            assertReadableButNotEditable(d.Id);
            Test.startTest();
            Database.insert(second, AccessLevel.SYSTEM_MODE);
            Test.stopTest();
        }

        Assert.areEqual(new List<String>(),
            DispositionCounterRollupService.lastRunFailures,
            '🔴 THE COUNTER WRITE WAS REFUSED. This list carries the platform StatusCode, so read '
            + 'it in the message above rather than guessing. INSUFFICIENT_ACCESS_OR_READONLY means '
            + 'ParentCounterWrites\' `without sharing` escape has been removed or bypassed — '
            + 'SYSTEM_MODE alone cannot satisfy a record-level check.');
        Assert.areEqual(2, reread(d.Id).Offers_Received__c,
            '🔴 A saver who can SEE but not EDIT the sale must still drive its counter. A 1 here is '
            + 'the silent-divergence defect: the offer is committed and visible on the related '
            + 'list while the counter beside it says otherwise, and nothing anywhere errored.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE FAILURE CHANNEL ITSELF — `recordFailures` HAD **ZERO** POSITIVE COVERAGE
    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Added 2026-08-31 (Tranche 1 code review, W-2).
    //
    // Until this test, the BODY of `DispositionCounterRollupService.recordFailures`' loop was
    // unreachable in the entire suite: every `Database.SaveResult` it had ever been handed was a
    // success, so it always fell straight through the `isSuccess()` `continue`. The only
    // assertion on `lastRunFailures` anywhere was
    // `aSaverWhoCannotEditTheSale_stillGetsTheCounterWritten` immediately above, asserting it
    // EMPTY — and a list that can never populate is empty for the wrong reason. A wrong index, a
    // reset in the wrong place, an early return, or `isSuccess()` inverted so successes are
    // recorded and failures skipped, all leave that assertion green while destroying the only
    // channel a refused counter write has. The service's class header says the list "EXISTS TO BE
    // ASSERTED ON"; that claim was itself untested. This test is what makes the one above mean
    // something.
    //
    // ⚠ SCOPE — READ THIS BEFORE ASSUMING THE SIBLING CHANNELS ARE COVERED TOO. The Tranche 1
    // review grouped four "assert the failure list is empty" assertions together, but they are
    // assertions on THREE DIFFERENT LISTS in three different classes, and this test only reaches
    // one of them. Checked 2026-08-31:
    //   ✅ `DispositionCounterRollupService.lastRunFailures` — this test. Was uncovered; is not.
    //   ✅ `BovPreferredBrokerService.lastRunRetirementFailures` — ALREADY had positive coverage:
    //      `BovPreferredBrokerServiceTest.aRefusedHistoryInsert_rollsBackAndLeavesTheSubmission
    //      Alive` asserts `isFalse(...isEmpty())`. Its "assert empty" siblings are falsified.
    //   🔴 `BovAutoSelectionService.lastRunSelectionFailures` — STILL HAS NO POSITIVE TEST. All
    //      three references to it (`BovAutoSelectionServiceTest` lines ~365, ~1277, ~1552) assert
    //      it EMPTY. Its populate path is a `catch` block inside the selection write, NOT this
    //      `recordFailures` shape, so nothing in this file can cover it and no fix here does.
    //      That is a separate, still-open finding — do not read this test as closing it.

    /**
     * A parent Id in play whose `Disposition__c` is in the Recycle Bin — refusal #1 from
     * `recordFailures`' header ("deleting a Disposition SetNulls its children's lookups, so the
     * cascade can put an Id in play whose parent is going away in the same transaction").
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ WHY THIS CALLS THE SERVICE DIRECTLY INSTEAD OF DELETING A PARENT THAT HAS A CHILD OFFER
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The obvious fixture — `insert offer; delete parent;` and let the `SetNull` cascade drive the
     * child's `after update` — rests on TWO platform behaviours this repo has never established:
     *   (a) that clearing a lookup by deleting its parent fires the CHILD's update triggers at
     *       all, and
     *   (b) that the resulting cascade update is not itself refused first by
     *       `Buyer_Required_On_Offer` or `DispositionOfferSelectionGuardService`, which run in the
     *       child's before contexts and would abort the parent delete rather than reach this code.
     * If either is false the test goes red for a reason that has nothing to do with the subject,
     * and if (a) is false it goes red by asserting 0 failures where the branch simply never ran —
     * indistinguishable, from the failure message, from the defect it exists to catch.
     * ⚠ Calling `recalculateOffersFor` directly is NOT a mock and NOT a weakened assertion: it is
     * the same public entry point the cascade uses, the same `applyCounts`, the same
     * `ParentCounterWrites.apply`, and a REAL platform refusal from a REAL `Database.update`
     * against a REAL soft-deleted row. Only the route by which the doomed Id enters
     * `dispositionIds` differs.
     *
     * 🔴 TODO — WHAT A REAL RUN MUST STILL CONFIRM, AND NOBODY HAS RUN THIS. Nothing in Tranche 1
     * has been compiled, deployed or executed; every claim here is derived from source. Two
     * distinct things are outstanding and they are NOT the same question:
     *   1. THAT THIS TEST PASSES — i.e. that `Database.update(..., false, SYSTEM_MODE)` against a
     *      Recycle-Bin row really returns `isSuccess() == false` with StatusCode
     *      `ENTITY_IS_DELETED` rather than throwing, or silently succeeding on the soft-deleted
     *      row. If it throws, the exception escapes `applyCounts` and the correct fix is in the
     *      SERVICE, not here.
     *   2. WHETHER THE SETNULL CASCADE REACHES THIS CODE AT ALL IN PRODUCTION. That is what
     *      `recordFailures`' header asserts as expected-refusal #1, and this test deliberately
     *      does NOT answer it. Someone must delete a `Disposition__c` carrying a live
     *      `Disposition_Offer__c` in a scratch/dev org and check the debug log for the
     *      `STALE COUNTER on Disposition__c` line. If the cascade does NOT fire the child trigger,
     *      expected-refusal #1 is fiction and that header paragraph should be retracted in place.
     *
     * ⚠ THREE PARENTS, NOT TWO, AND THE THIRD IS THE INDEX FALSIFIER. `recordFailures` walks
     * `results[i]` and reports `attempted[i].Id`; a hard-coded index (or a results/attempted
     * mismatch) would still produce the right COUNT, so an assertion on `size()` alone proves
     * nothing about it. With ONE surviving parent and TWO doomed ones, a fixed index yields the
     * same Id twice — caught by the distinct-Id set below — or the survivor's Id — caught by the
     * `isFalse(contains(live.Id))` line. Neither is catchable with a single failing row.
     */
    @isTest
    static void deletedParentsInPlay_areEachReportedWithTheirIdAndStatusCode() {
        Disposition__c live = disposition();
        Disposition__c goneA = disposition();
        Disposition__c goneB = disposition();
        TestDataFactory.createDispositionOffer(live.Id, true);
        Assert.areEqual(1, reread(live.Id).Offers_Received__c,
            'PRECONDITION: the surviving sale really has one offer, so the recompute below has a '
            + 'non-zero answer to write and its success is observable.');

        delete new List<Disposition__c>{ goneA, goneB };

        // Deliberately staled so the SUCCESSFUL half of the batch is observable at the bottom.
        // Without this the survivor would read 1 both before and after and the "the good row still
        // committed" assertion would be vacuous. SYSTEM_MODE because the counter fields carry
        // read-only FLS — the argument is in this class's header.
        Database.update(
            new Disposition__c(Id = live.Id, Offers_Received__c = 99),
            AccessLevel.SYSTEM_MODE
        );

        Test.startTest();
        DispositionCounterRollupService.recalculateOffersFor(
            new Set<Id>{ live.Id, goneA.Id, goneB.Id }
        );
        Test.stopTest();

        List<String> failures = DispositionCounterRollupService.lastRunFailures;
        Assert.areEqual(2, failures.size(),
            '🔴 EXACTLY TWO refusals — one per deleted parent — and the surviving sale must NOT be '
            + 'among them. A 0 here is the defect this whole test exists for: the failure channel '
            + 'never populates, every "assert lastRunFailures is empty" in this repo is vacuous, '
            + 'and a refused counter write is invisible from every surface a person can see. A 3 '
            + 'means the good row was refused too — read the messages. Failures: ' + failures);

        Set<String> namedIds = new Set<String>();
        for (String failure : failures) {
            Assert.isTrue(failure.contains('ENTITY_IS_DELETED'),
                '🔴 The message must carry the platform StatusCode, not just an Id — the StatusCode '
                + 'is the entire diagnostic value of this channel and is what tells a reader '
                + 'whether they are looking at a deleted parent, a validation rule or the sharing '
                + 'failure ParentCounterWrites escapes. Got: ' + failure);
            Assert.isFalse(failure.contains(String.valueOf(live.Id)),
                '🔴 WRONG INDEX. A failure message named the SURVIVING sale, whose write '
                + 'succeeded. `recordFailures` must report `attempted[i]`, parallel to '
                + '`results[i]`; reporting a fixed or offset index makes every one of these '
                + 'messages point at an innocent record. Got: ' + failure);
            namedIds.add(failure.substringBefore(' -> '));
        }
        Assert.areEqual(
            new Set<String>{ String.valueOf(goneA.Id), String.valueOf(goneB.Id) },
            namedIds,
            '🔴 The two messages must name the two DIFFERENT deleted sales. One Id twice means the '
            + 'index is hard-coded rather than walked — which produces the right COUNT and the '
            + 'right StatusCode and still sends every investigation to the wrong record. Named: '
            + namedIds);

        Assert.areEqual(1, reread(live.Id).Offers_Received__c,
            '🔴 AND THE GOOD ROW IN THE SAME BATCH STILL COMMITTED, 99 -> 1. `allOrNone = false` is '
            + 'what makes that true, and it is the reason nothing is rethrown here: a refused '
            + 'parent must never roll back the child save that triggered the recompute. A 99 means '
            + 'the batch aborted as a unit and the failure channel is reporting a rollback rather '
            + 'than a partial success.');
    }
}
