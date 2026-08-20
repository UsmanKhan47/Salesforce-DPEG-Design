/**
 * @description Tests `DispositionOfferSelectionGuardService.enforceSingleSelected` — the
 * before-context trigger guard that REFUSES any save leaving a Disposition with more than one
 * `Is_Selected__c = true` offer. Added 2026-08-20 with the disposition redesign, Tranche 2
 * Workstream A2 (`agent-output/disposition-tranche-2-requirements.md` §1.2).
 *
 * ── 🔴 THE CLASS NAME DROPS "Service" BECAUSE IT PHYSICALLY CANNOT KEEP IT ──
 * `DispositionOfferSelectionGuardServiceTest` is 41 characters and Apex caps an identifier at 40:
 * the compiler rejects the file outright with `Identifier name is too long`. Measured 2026-08-20.
 * The BOV twin drops `Service` too — symmetric by choice — even though its conventional name would
 * have fitted. The class under test is `DispositionOfferSelectionGuardService`.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * ⚠ WHAT THIS SUITE IS ACTUALLY PROVING, STATED HONESTLY. `Is_Selected__c` is READ-ONLY FLS in BOTH
 * disposition permission sets and is written ONLY by `DispositionApprovalService.selectOffer`, which
 * is already exclusive. The invariant is therefore already unbreakable through the UI, through LDS,
 * and through any `USER_MODE` Apex — so this guard closes an API / data-loader / anonymous-Apex
 * residual, NOT a live user-facing hole. The BOV twin is the high-value half (its status field IS
 * user-editable). Every "must be rejected" test below is therefore written with `Database.insert` /
 * `Database.update` in system context, which is the shape the residual actually takes.
 * ─────────────────────────────────────────────────────────────────────────────────────
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE 251-RECORD MANDATE APPLIES IN FULL — NO EXEMPTION. This is a trigger path
 * (`DispositionOfferTriggerHandler.beforeInsert` / `beforeUpdate`) that loops over a collection.
 * ─────────────────────────────────────────────────────────────────────────────────────
 *
 * ── 🔴 THE TESTS THAT MUST NEVER BE DELETED ──
 *   `existingSelectOfferService_stillSucceeds`
 *        `DispositionApprovalService.selectOffer` de-selects the incumbent and selects the winner in
 *        ONE bulk DML, so a correctly written guard sees both rows and permits it. A guard reading
 *        only committed data would refuse the Select Offer action outright.
 *   `theApprovalsOwnFieldUpdateOnASelectedOffer_isNotBlocked`
 *        `Offer_Selection_Approval` writes `Approval_Status__c` on a row whose `Is_Selected__c` is
 *        ALREADY true, firing these very contexts. If the guard judged "is selected NOW" instead of
 *        "is BECOMING selected", the approval would be unable to complete.
 *   `deselectingTheSelectedOffer_isAlwaysPermitted`
 *        The remedy path out of a bad state.
 *
 * ── ⚠ WHY THE ERROR-BEHAVIOUR TESTS USE REAL DML AND ONLY THE COST TESTS INVOKE DIRECTLY ──
 * `addError` is a trigger-context API, and a real 251-row DML spans TWO trigger chunks — so
 * asserting "1 query" around one would be asserting a falsehood, and asserting "2" would pin the
 * chunk size rather than the service. The per-chunk constant is measured by invoking the service
 * once with 251 records in hand; the real trigger is proven separately by completing a genuine
 * 251-row DML at all (a per-record query would blow the 100-query limit at the 101st row). Same
 * split, same reason, as `BovSubmissionBrokerStampServiceTest`.
 *
 * ⚠ Counters are snapshotted INSIDE `Test.startTest()` / `Test.stopTest()` — never across
 * `stopTest()`, which restores the pre-test counters and makes the assertion silently vacuous.
 *
 * ── ALL_NDAs_SIGNED_BEFORE_PROGRESSION ──
 * `Offer Selection` is one of the VR's gated target stages, so every fixture that reaches
 * `selectOffer` signs a buyer NDA first — same helper, same reason, as
 * `DispositionApprovalServiceTest`.
 *
 * ⚠ FIXTURES NEVER ASSUME AN EMPTY ORG. Every test creates its own Disposition and asserts scoped to
 * it, so the org's existing disposition rows are invisible to every assertion here.
 *
 * @see force-app/main/default/classes/DispositionOfferSelectionGuardService.cls
 * @see force-app/main/default/classes/BovSubmissionSelectionGuardTest.cls (the twin suite — the
 *      fuller argument lives there)
 */
@isTest
private class DispositionOfferSelectionGuardTest {

    private static final Integer BULK_N = 251;
    private static final String STAGE_ACTIVE_LISTING = 'Active Listing';
    private static final String STAGE_OFFER_SELECTION = 'Offer Selection';

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c onMarketAt(String stage) {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    /** Satisfies All_NDAs_Signed_Before_Progression, which gates the stage `selectOffer` advances to. */
    private static void signBuyerNdaOn(Id dispositionId) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Status__c = 'Signed';
        insert nda;
    }

    /** An INSERTED offer carrying the given selection flag. */
    private static Disposition_Offer__c offerOn(Id dispositionId, Boolean isSelected) {
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(dispositionId, false);
        offer.Is_Selected__c = isSelected;
        insert offer;
        return offer;
    }

    private static Map<Id, Disposition_Offer__c> flagsOn(Id dispositionId) {
        return new Map<Id, Disposition_Offer__c>([
            SELECT Id, Is_Selected__c
            FROM Disposition_Offer__c
            WHERE Disposition__c = :dispositionId
        ]);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 CONSEQUENCE 1 — THE EXISTING SERVICE MUST STILL SUCCEED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE REQUIRED FALSIFIER. An offer is already selected; `selectOffer` picks a DIFFERENT one,
     * building a change-only list (incumbent -> false, winner -> true) and applying it in ONE bulk
     * DML. The before-update context therefore holds both rows and the incumbent's in-memory
     * `false` supersedes its committed `true`.
     *
     * ⚠ The disposition is deliberately left at `Active Listing` with an offer already flagged —
     * the same fixture shape `DispositionApprovalServiceTest.selectOffer_submitFailure_...` uses —
     * because `selectOffer` requires that stage and the re-pick is the case under test.
     */
    @isTest
    static void existingSelectOfferService_stillSucceeds() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c incumbent = offerOn(d.Id, true);
        Disposition_Offer__c winner = offerOn(d.Id, false);

        Test.startTest();
        String message = DispositionApprovalService.selectOffer(d.Id, winner.Id);
        Test.stopTest();

        Map<Id, Disposition_Offer__c> after = flagsOn(d.Id);
        Assert.isTrue(after.get(winner.Id).Is_Selected__c,
            '🔴 THE GUARD MUST NOT REFUSE selectOffer\'S OWN EXCLUSIVITY SWEEP. The winner must be '
            + 'flagged — a guard reading only committed data would have blocked this save');
        Assert.isFalse(after.get(incumbent.Id).Is_Selected__c,
            'And the incumbent must be de-selected in the same save, which is what makes the new '
            + 'selection legal');
        Assert.areEqual(STAGE_OFFER_SELECTION,
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'The whole operation must have completed, not merely the flag write: ' + message);
    }

    /** The same shape with RAW DML, pinning the guard's contract independently of the service. */
    @isTest
    static void deselectAndSelectInOneSave_isPermitted() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c incumbent = offerOn(d.Id, true);
        Disposition_Offer__c challenger = offerOn(d.Id, false);

        Test.startTest();
        update new List<Disposition_Offer__c>{
            new Disposition_Offer__c(Id = incumbent.Id, Is_Selected__c = false),
            new Disposition_Offer__c(Id = challenger.Id, Is_Selected__c = true)
        };
        Test.stopTest();

        Map<Id, Disposition_Offer__c> after = flagsOn(d.Id);
        Assert.isTrue(after.get(challenger.Id).Is_Selected__c,
            'A de-select-and-select in ONE DML must be permitted');
        Assert.isFalse(after.get(incumbent.Id).Is_Selected__c,
            'And the de-select must have applied');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 CONSEQUENCE 2 — AN ALREADY-SELECTED ROW IS NEVER BLOCKED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 NOT ACADEMIC ON THIS OBJECT. `Offer_Selection_Approval`'s `finalApprovalActions` field
     * update writes `Approval_Status__c` on a row whose `Is_Selected__c` is ALREADY true, re-firing
     * these contexts. A guard judging "is selected NOW" rather than "is BECOMING selected" would
     * make the approval unable to complete — and would also freeze any pre-existing duplicate pair.
     */
    @isTest
    static void theApprovalsOwnFieldUpdateOnASelectedOffer_isNotBlocked() {
        Disposition__c d = onMarketAt(STAGE_OFFER_SELECTION);
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c winner = offerOn(d.Id, true);

        Test.startTest();
        update new Disposition_Offer__c(Id = winner.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Disposition_Offer__c after = [
            SELECT Is_Selected__c, Approval_Status__c, Offer_Status__c
            FROM Disposition_Offer__c WHERE Id = :winner.Id
        ];
        Assert.areEqual('Approved', after.Approval_Status__c,
            '🔴 THE APPROVAL\'S OWN FIELD UPDATE MUST COMMIT. It fires the guard on a row that is '
            + 'already selected, and the guard must not judge it');
        Assert.isTrue(after.Is_Selected__c, 'The flag must be untouched');
        Assert.areEqual('Accepted', after.Offer_Status__c,
            'And the sibling before-context stamp must still have run — the guard must not have '
            + 'aborted the save it shares a context with');
    }

    /** Re-writing the same `true` is not a transition and must not be judged. */
    @isTest
    static void rewritingTheSameSelectedFlag_isNotBlocked() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c winner = offerOn(d.Id, true);

        Test.startTest();
        update new Disposition_Offer__c(Id = winner.Id, Is_Selected__c = true);
        Test.stopTest();

        Assert.isTrue(
            [SELECT Is_Selected__c FROM Disposition_Offer__c WHERE Id = :winner.Id].Is_Selected__c,
            'Re-writing the same value is not a transition and must not be refused');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 CONSEQUENCE 3 — A SAVE THAT REDUCES THE SELECTED COUNT ALWAYS PASSES
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void deselectingTheSelectedOffer_isAlwaysPermitted() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c winner = offerOn(d.Id, true);

        Test.startTest();
        update new Disposition_Offer__c(Id = winner.Id, Is_Selected__c = false);
        Test.stopTest();

        Assert.isFalse(
            [SELECT Is_Selected__c FROM Disposition_Offer__c WHERE Id = :winner.Id].Is_Selected__c,
            'De-selecting is a REDUCTION in the selected count and must always be permitted — a '
            + 'guard that blocks the remedy is worse than no guard');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE GUARD'S ACTUAL JOB — THE API-ONLY RESIDUAL IS REFUSED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE INSERT CASE IS WHY `DispositionOfferTrigger` GAINED `before insert` ON 2026-08-20. The
     * trigger previously declared `(before update, after update)`, so a loaded row arriving already
     * selected — the most likely shape of the residual this guard exists for — would have walked
     * straight past a before-update-only guard.
     */
    @isTest
    static void insertingASecondSelectedOffer_isRejectedWithAnActionableMessage() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        offerOn(d.Id, true);
        Disposition_Offer__c intruder = TestDataFactory.createDispositionOffer(d.Id, false);
        intruder.Is_Selected__c = true;

        Test.startTest();
        Database.SaveResult result = Database.insert(intruder, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            '🔴 A SECOND SELECTED OFFER MUST BE REFUSED ON INSERT — this is the exact case a '
            + 'before-update-only trigger could not see');
        String message = result.getErrors()[0].getMessage();
        Assert.isTrue(message.contains('only one is allowed'),
            'The refusal must state the rule: ' + message);
        Assert.isTrue(message.contains('Select Offer'),
            'And it must name the remedy — the action that clears the previous selection in the '
            + 'same save: ' + message);
        Assert.areEqual(1, flagsOn(d.Id).size(), 'The intruder must not have been saved at all');
    }

    /** The update half: selecting a second offer WITHOUT de-selecting the incumbent. */
    @isTest
    static void selectingASecondOfferByUpdate_isRejected() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c incumbent = offerOn(d.Id, true);
        Disposition_Offer__c challenger = offerOn(d.Id, false);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Disposition_Offer__c(Id = challenger.Id, Is_Selected__c = true), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Selecting a second offer without de-selecting the incumbent in the same save must be '
            + 'refused — that is the difference between this and selectOffer');
        Map<Id, Disposition_Offer__c> after = flagsOn(d.Id);
        Assert.isFalse(after.get(challenger.Id).Is_Selected__c,
            'The challenger must be left exactly as it was');
        Assert.isTrue(after.get(incumbent.Id).Is_Selected__c,
            'And the incumbent must be untouched — the guard REFUSES, it never self-heals');
    }

    /**
     * ⚠ THE DELIBERATE EXTENSION OF THE WRITTEN RULE, PINNED. An already-selected offer REPARENTED
     * onto a disposition that already has one arrives selected there without its flag ever changing.
     * Delete this test together with the `prior.Disposition__c != ...` clause if the narrower
     * literal rule is ever preferred — nothing else depends on it.
     */
    @isTest
    static void reparentingASelectedOfferOntoAnOccupiedDisposition_isRejected() {
        Disposition__c origin = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition__c destination = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c mover = offerOn(origin.Id, true);
        offerOn(destination.Id, true);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Disposition_Offer__c(Id = mover.Id, Disposition__c = destination.Id), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Moving an already-selected offer onto a disposition that already has one creates '
            + 'exactly the state this guard exists to prevent, so it must be refused even though '
            + 'the flag never changed');
        Assert.areEqual(origin.Id,
            [SELECT Disposition__c FROM Disposition_Offer__c WHERE Id = :mover.Id].Disposition__c,
            'The move must not have committed');
    }

    /**
     * ✅ S1 (code review, 2026-08-20): symmetry gap closed. The BOV twin
     * (BovSubmissionSelectionGuardTest.reparentingASelectedRowOntoAnEmptyDisposition_isPermitted)
     * has this test; this suite did not, even though the two suites are otherwise byte-symmetric.
     * It is the complement of reparentingASelectedOfferOntoAnOccupiedDisposition_isRejected above —
     * proving the reparenting extension blocks only a move onto an OCCUPIED destination, never
     * every move of an already-selected row.
     */
    @isTest
    static void reparentingASelectedOfferOntoAnEmptyDisposition_isPermitted() {
        Disposition__c origin = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition__c destination = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c mover = offerOn(origin.Id, true);

        Test.startTest();
        update new Disposition_Offer__c(Id = mover.Id, Disposition__c = destination.Id);
        Test.stopTest();

        Assert.areEqual(destination.Id,
            [SELECT Disposition__c FROM Disposition_Offer__c WHERE Id = :mover.Id].Disposition__c,
            'The extension must block only a move onto an OCCUPIED disposition, never every move');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SCOPE
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void firstSelectedOfferOnADispositionThatHasNone_isPermitted() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        offerOn(d.Id, false);
        Disposition_Offer__c winner = TestDataFactory.createDispositionOffer(d.Id, false);
        winner.Is_Selected__c = true;

        Test.startTest();
        insert winner;
        Test.stopTest();

        Assert.isTrue(
            [SELECT Is_Selected__c FROM Disposition_Offer__c WHERE Id = :winner.Id].Is_Selected__c,
            'The FIRST selected offer on a disposition is the normal case and must pass');
    }

    /**
     * 🔴 THE SCOPE FALSIFIER. A guard keyed on the object rather than on the parent would refuse
     * every disposition in the org after the first.
     */
    @isTest
    static void selectedOffersOnDifferentDispositions_doNotInterfere() {
        Disposition__c first = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition__c second = onMarketAt(STAGE_ACTIVE_LISTING);
        offerOn(first.Id, true);
        Disposition_Offer__c other = TestDataFactory.createDispositionOffer(second.Id, false);
        other.Is_Selected__c = true;

        Test.startTest();
        insert other;
        Test.stopTest();

        Assert.isTrue(
            [SELECT Is_Selected__c FROM Disposition_Offer__c WHERE Id = :other.Id].Is_Selected__c,
            'A selected offer on ANOTHER disposition must be irrelevant — the invariant is per '
            + 'parent, not per object');
    }

    /** An offer with no parent has no siblings, so there is no invariant to enforce. */
    @isTest
    static void selectedOfferWithNoDisposition_isNeverBlocked() {
        List<Disposition_Offer__c> orphans =
            TestDataFactory.createDispositionOffers(2, null, false);
        for (Disposition_Offer__c orphan : orphans) {
            orphan.Is_Selected__c = true;
        }

        Test.startTest();
        insert orphans;
        Test.stopTest();

        Assert.areEqual(2,
            [SELECT COUNT() FROM Disposition_Offer__c WHERE Id IN :orphans],
            'Parentless offers have no siblings and must never be judged');
    }

    /** Null/empty-safe per the method's own ApexDoc — a no-op, not an error. */
    @isTest
    static void nullOrEmptyList_returnsWithoutError() {
        Boolean completedWithoutThrowing = false;

        Test.startTest();
        DispositionOfferSelectionGuardService.enforceSingleSelected(null, null);
        DispositionOfferSelectionGuardService.enforceSingleSelected(
            new List<Disposition_Offer__c>(), null);
        completedWithoutThrowing = true; // reached only if neither call above threw
        Test.stopTest();

        Assert.isTrue(completedWithoutThrowing,
            'Both calls must return without throwing — the guard is a no-op, not an error');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BULK — 251 RECORDS, .claude/rules/bulk-test-rule.md
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE PER-CHUNK BUDGET, MEASURED BY DIRECT INVOCATION. 251 records becoming selected across
     * 251 DISTINCT dispositions must cost EXACTLY ONE query — the point of keying the selector on a
     * `Set<Id>`. A per-record implementation would issue 251 and die at the 101st.
     */
    @isTest
    static void bulk251BecomingSelected_costsExactlyOneQueryForTheWholeChunk() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        List<Disposition_Offer__c> newList = new List<Disposition_Offer__c>();
        for (Disposition__c d : dispositions) {
            Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
            offer.Is_Selected__c = true;
            newList.add(offer); // Id null — the true before-insert shape
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionOfferSelectionGuardService.enforceSingleSelected(newList, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 records across 251 dispositions — the sibling read is keyed '
            + 'on the whole Set<Id>. Anything above 1 means it moved into the per-record loop.');
        Integer refused = 0;
        for (Disposition_Offer__c offer : newList) {
            if (offer.hasErrors()) {
                refused++;
            }
        }
        Assert.areEqual(0, refused,
            '251 FIRST selections on 251 empty dispositions must all be permitted');
    }

    /**
     * 🔴 THE ASSERTION THAT MAKES THE NEW `before insert` CONTEXT SAFE. That expansion means this
     * trigger now fires on EVERY `Disposition_Offer__c` insert in the org, where previously nothing
     * did. A chunk in which no row is becoming selected must cost NOTHING even at 251 records.
     *
     * ⚠ THE ROWS DELIBERATELY LEAVE `Is_Selected__c` UNSET. On an in-memory insert row an unset
     * checkbox is NULL, not false, and the service's `!= true` test is what handles that. This
     * assertion is what pins it.
     */
    @isTest
    static void bulk251NoRowBecomesSelected_costsNothing() {
        Id dispositionId = onMarketAt(STAGE_ACTIVE_LISTING).Id;
        List<Disposition_Offer__c> newList =
            TestDataFactory.createDispositionOffers(BULK_N, dispositionId, false);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionOfferSelectionGuardService.enforceSingleSelected(newList, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            '🔴 THE ZERO-QUERY FAST PATH. It is what makes it safe for this trigger to start firing '
            + 'on every Disposition_Offer__c insert in the org');
    }

    /**
     * The real-DML bulk proof: 251 rows through the genuine trigger, spanning TWO chunks.
     * COMPLETING AT ALL is part of the falsifier — a per-record query would need 251 SOQL.
     */
    @isTest
    static void bulk251FirstSelectionsOnDistinctDispositions_allSave() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();
        for (Disposition__c d : dispositions) {
            Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
            offer.Is_Selected__c = true;
            offers.add(offer);
        }

        Test.startTest();
        insert offers; // 251 rows -> TWO trigger chunks
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition_Offer__c WHERE Id IN :offers AND Is_Selected__c = true],
            'All 251 must have saved — a total below 251 means the second trigger chunk refused '
            + 'rows it should not have, or the query budget blew');
    }

    /**
     * The bulk REFUSAL: 251 rows all claiming the same disposition. Every one must be rejected and
     * named individually — "tell the loader which rows are wrong" is the third reason this guard
     * refuses rather than self-heals.
     *
     * ⚠ ALL 251, NOT 250. No row here has a prior claim; each is judged against the other 250 in its
     * own chunk, so none is "the first".
     */
    @isTest
    static void bulk251SelectedOnOneDisposition_everyRowIsRejected() {
        Id dispositionId = onMarketAt(STAGE_ACTIVE_LISTING).Id;
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(BULK_N, dispositionId, false);
        for (Disposition_Offer__c offer : offers) {
            offer.Is_Selected__c = true;
        }

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(offers, false);
        Test.stopTest();

        Integer refused = 0;
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()
                    && result.getErrors()[0].getMessage().contains('only one is allowed')) {
                refused++;
            }
        }
        Assert.areEqual(BULK_N, refused,
            'Every one of the 251 rows must be refused BY NAME with the authored message');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Disposition_Offer__c WHERE Disposition__c = :dispositionId],
            'And nothing may have been saved');
    }
}
