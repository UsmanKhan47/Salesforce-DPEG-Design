/**
 * @description Tests DispositionOfferSelector — the first and only Disposition_Offer__c SOQL in
 * this application (Tranche 5 Item B).
 *
 * ── WHAT MATTERS HERE, IN ORDER ─────────────────────────────────────────────
 *   1. THE ABSENT-KEY CONTRACT. `GROUP BY` emits no row for an empty group, so a disposition with
 *      no offers is MISSING from the map rather than present with 0. Every caller has to default
 *      the miss, and a test that only ever counted non-empty groups would never notice.
 *   1b. `MIN(Offer_Date__c)` — added 2026-08-21 with the traction clock's PAUSE. `countByDispositionIds`
 *      became `selectOfferTractionByDispositionIds` and now returns the count AND the earliest offer
 *      date from ONE aggregate. ⚠ EVERY DATE-BEARING TEST BELOW SETS THE DATES ITSELF, because
 *      `TestDataFactory.createDispositionOffers` stamps `Offer_Date__c = Date.today()` on every
 *      fixture — over which a MIN, a MAX and a hardcoded `Date.today()` are indistinguishable.
 *   2. SCOPING. A count must be scoped to its own disposition — a selector that ignored the WHERE
 *      clause would still "work" on a single-disposition fixture.
 *   3. BULK. `.claude/rules/bulk-test-rule.md` applies in full: Disposition_Offer__c is an
 *      ordinary custom object, NOT content, so the `.claude/rules/content-publication-rule.md`
 *      20-row ceiling does not apply here and 251 is the correct number.
 *
 * ── ⚠ WHAT THIS SUITE CANNOT PROVE, SAID OUT LOUD ──────────────────────────
 * THE `without sharing` DECISION IS NOT REPRODUCED. The query lives in a `private without sharing`
 * inner class because a sharing-filtered COUNT would report "no traction" for a listing that has
 * offers — a WRONG ANSWER rather than an error, which nothing would notice. Reproducing that needs
 * a second user who is denied sharing on rows they did not create, and `Disposition_Offer__c` is
 * OWD Private with `viewAllRecords = true` on both disposition permission sets, so inside a test
 * the two configurations are indistinguishable. These tests pin the COUNTING; they do not pin the
 * reason the sharing keyword is what it is. Do not read a green run as licence to make the inner
 * class `with sharing`.
 *
 * @see force-app/main/default/classes/DispositionOfferSelector.cls
 * @author Salesforce Developer
 */
@isTest
private class DispositionOfferSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Disposition__c newDisposition() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        return TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
    }

    @isTest
    static void nullAndEmptyInputsReturnAnEmptyMap() {
        Assert.areEqual(0,
            DispositionOfferSelector.selectOfferTractionByDispositionIds(null).size(),
            'A null input must return an empty map, never a NullPointerException');
        Assert.areEqual(0,
            DispositionOfferSelector.selectOfferTractionByDispositionIds(new Set<Id>()).size(),
            'An empty input must return an empty map');
    }

    /**
     * 🔴 THE ABSENT-KEY CONTRACT. This is the one a caller gets wrong: the map does not carry a 0
     * for an offerless disposition, so a caller reading `.offerCount` off the miss would
     * NullPointer rather than read zero.
     */
    @isTest
    static void aDispositionWithNoOffersIsABSENTFromTheMapRatherThanZero() {
        Disposition__c d = newDisposition();

        Map<Id, DispositionOfferSelector.OfferTraction> byId =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(new Set<Id>{ d.Id });

        Assert.areEqual(0, byId.size(),
            'GROUP BY emits no row for an empty group, so the Id must be absent');
        Assert.isFalse(byId.containsKey(d.Id),
            'Callers must default a miss to 0 - the map does not do it for them');
        Assert.isNull(byId.get(d.Id),
            'A miss reads null, which is why the callers null-check the wrapper');
    }

    @isTest
    static void countsTheOffersOnOneDisposition() {
        Disposition__c d = newDisposition();
        TestDataFactory.createDispositionOffers(3, d.Id, true);

        Map<Id, DispositionOfferSelector.OfferTraction> byId =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(new Set<Id>{ d.Id });

        Assert.areEqual(1, byId.size(), 'One disposition with offers means one entry');
        Assert.areEqual(3, byId.get(d.Id).offerCount, 'All three offers must be counted');
    }

    /**
     * 🔴 `MIN(Offer_Date__c)` IS THE PAUSE POINT — the day `DispositionTractionService` stops the
     * marketing clock. It must be the EARLIEST date, not the latest and not whichever row the
     * platform returned first.
     *
     * ⚠ THE DATES ARE SET EXPLICITLY BECAUSE THE FACTORY DATES EVERY OFFER TODAY. Three offers
     * straight from `createDispositionOffers` all carry `Date.today()`, so a MIN over them is
     * indistinguishable from a MAX, a FIRST, or a hardcoded `Date.today()` in the selector.
     */
    @isTest
    static void theEarliestOfferDateIsReturnedAsThePausePoint() {
        Disposition__c d = newDisposition();
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(3, d.Id, false);
        offers[0].Offer_Date__c = Date.today().addDays(-5);
        offers[1].Offer_Date__c = Date.today().addDays(-40); // the earliest
        offers[2].Offer_Date__c = Date.today();
        insert offers;

        Map<Id, DispositionOfferSelector.OfferTraction> byId =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(new Set<Id>{ d.Id });

        Assert.areEqual(3, byId.get(d.Id).offerCount, 'All three still count');
        Assert.areEqual(Date.today().addDays(-40), byId.get(d.Id).firstOfferDate,
            'MIN must return the earliest offer date - it is where the clock stops');
    }

    /**
     * `MIN` IGNORES NULLS, and both halves of that matter. An undated offer must not become the
     * minimum (which would pause the clock at null), and it must not stop a DATED sibling from
     * being found.
     */
    @isTest
    static void undatedOffersAreIgnoredByTheMinButStillCounted() {
        Disposition__c bothKinds = newDisposition();
        List<Disposition_Offer__c> mixed =
            TestDataFactory.createDispositionOffers(2, bothKinds.Id, false);
        mixed[0].Offer_Date__c = null;
        mixed[1].Offer_Date__c = Date.today().addDays(-12);

        Disposition__c allUndated = newDisposition();
        List<Disposition_Offer__c> undated =
            TestDataFactory.createDispositionOffers(2, allUndated.Id, false);
        undated[0].Offer_Date__c = null;
        undated[1].Offer_Date__c = null;

        List<Disposition_Offer__c> all = new List<Disposition_Offer__c>(mixed);
        all.addAll(undated);
        insert all;

        Map<Id, DispositionOfferSelector.OfferTraction> byId =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(
                new Set<Id>{ bothKinds.Id, allUndated.Id });

        Assert.areEqual(2, byId.get(bothKinds.Id).offerCount, 'An undated offer is still an offer');
        Assert.areEqual(Date.today().addDays(-12), byId.get(bothKinds.Id).firstOfferDate,
            'The dated sibling must still be found - a null must not win the MIN');
        Assert.areEqual(2, byId.get(allUndated.Id).offerCount,
            'A disposition whose offers are ALL undated still appears in the map');
        Assert.isNull(byId.get(allUndated.Id).firstOfferDate,
            'And its pause point is null - the caller must render "not paused", never invent a date');
    }

    /**
     * SCOPING. Without this a selector that dropped its WHERE clause would pass every other test
     * in this class, because they all use a single-disposition fixture.
     */
    @isTest
    static void countsAreScopedPerDispositionAndNeverPooled() {
        Disposition__c a = newDisposition();
        Disposition__c b = newDisposition();
        Disposition__c untouched = newDisposition();
        TestDataFactory.createDispositionOffers(2, a.Id, true);
        TestDataFactory.createDispositionOffers(5, b.Id, true);
        TestDataFactory.createDispositionOffers(4, untouched.Id, true);

        Map<Id, DispositionOfferSelector.OfferTraction> byId =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(new Set<Id>{ a.Id, b.Id });

        Assert.areEqual(2, byId.size(),
            'Only the requested dispositions may appear - the third must be filtered out');
        Assert.areEqual(2, byId.get(a.Id).offerCount, 'A gets its own 2, not the pooled 11');
        Assert.areEqual(5, byId.get(b.Id).offerCount, 'B gets its own 5');
        Assert.isFalse(byId.containsKey(untouched.Id),
            'A disposition outside the requested set must not appear');
    }

    /**
     * BULK per `.claude/rules/bulk-test-rule.md`. The assertion that matters is the QUERY COUNT: a
     * per-record count would still return the right numbers and would fail here.
     *
     * ⚠ The counters are snapshotted around the call inside the test transaction; reading
     * `Limits.getQueries()` after `Test.stopTest()` is silently vacuous because stopTest restores
     * the pre-test counters.
     */
    @isTest
    static void bulkCountAt251IsOneQuery() {
        List<Disposition__c> dispositions = new List<Disposition__c>();
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        dispositions = TestDataFactory.createDispositions(
            BULK_N, asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        // One offer on each, in ONE bulk DML.
        List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();
        for (Disposition__c d : dispositions) {
            offers.add(TestDataFactory.createDispositionOffer(d.Id, false));
        }
        insert offers;
        Set<Id> ids = new Map<Id, Disposition__c>(dispositions).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Map<Id, DispositionOfferSelector.OfferTraction> byId =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(ids);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, byId.size(),
            'Every one of the ' + BULK_N + ' dispositions must be counted');
        Assert.areEqual(1, queriesUsed,
            'BOTH facts must come from ONE aggregate query for the whole set - never one per '
            + 'record, and never a second query for the first offer date');
        Assert.areEqual(1, byId.get(dispositions[0].Id).offerCount,
            'Each carries exactly one offer');
        Assert.areEqual(1, byId.get(dispositions[BULK_N - 1].Id).offerCount,
            'Including the last one, which is in the second trigger chunk');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectSelectionStateByDispositionId — backs DispositionApprovalService.selectOffer
    // (2026-08-19 redesign, D-3). `with sharing` — the TractionReads `without sharing` argument
    // does NOT transfer to this row read; see the selector's own header.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectSelectionStateByDispositionId_returnsEveryOfferNotJustSelected() {
        Disposition__c d = newDisposition();
        Disposition_Offer__c selected = TestDataFactory.createDispositionOffer(d.Id, false);
        selected.Is_Selected__c = true;
        Disposition_Offer__c other = TestDataFactory.createDispositionOffer(d.Id, false);
        other.Is_Selected__c = false;
        insert new List<Disposition_Offer__c>{ selected, other };

        Test.startTest();
        List<Disposition_Offer__c> result =
            DispositionOfferSelector.selectSelectionStateByDispositionId(d.Id);
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            '🔴 EVERY OFFER MUST RETURN — this is simultaneously the exclusivity input and the '
            + 'membership check that proves a caller-supplied offer Id belongs to THIS disposition');
    }

    @isTest
    static void selectSelectionStateByDispositionId_nullInput_returnsEmptyList() {
        Assert.areEqual(0, DispositionOfferSelector.selectSelectionStateByDispositionId(null).size());
    }

    @isTest
    static void selectSelectionStateByDispositionId_scopedToOneDisposition() {
        Disposition__c a = newDisposition();
        Disposition__c b = newDisposition();
        TestDataFactory.createDispositionOffer(a.Id, true);
        TestDataFactory.createDispositionOffer(b.Id, true);

        Test.startTest();
        List<Disposition_Offer__c> result =
            DispositionOfferSelector.selectSelectionStateByDispositionId(a.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only A\'s offer must return — B\'s must not leak in');
        Assert.areEqual(a.Id, result[0].Disposition__c);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectSelectedByDispositionIds — backs DispositionOfferSelectionGuardService
    // (2026-08-20, Tranche 2 A2). SET-keyed, WITH SYSTEM_MODE, `with sharing`.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The SET is the point: one query must answer for MANY dispositions at once, because the caller
     * runs inside a trigger chunk of up to 200 records.
     *
     * ⚠ ONE SELECTED OFFER PER DISPOSITION, NOT TWO ON ONE. Since 2026-08-20 the trigger guard this
     * method backs makes a second selected offer on one disposition UNSAVABLE, so a fixture that
     * built one would fail at `insert`, not at the assertion.
     */
    @isTest
    static void selectSelectedByDispositionIds_spansManyParentsAndReturnsOnlySelected() {
        Disposition__c a = newDisposition();
        Disposition__c b = newDisposition();
        Disposition_Offer__c aSelected = TestDataFactory.createDispositionOffer(a.Id, false);
        aSelected.Is_Selected__c = true;
        Disposition_Offer__c aOther = TestDataFactory.createDispositionOffer(a.Id, false);
        aOther.Is_Selected__c = false;
        Disposition_Offer__c bSelected = TestDataFactory.createDispositionOffer(b.Id, false);
        bSelected.Is_Selected__c = true;
        insert new List<Disposition_Offer__c>{ aSelected, aOther, bSelected };

        Test.startTest();
        List<Disposition_Offer__c> result =
            DispositionOfferSelector.selectSelectedByDispositionIds(new Set<Id>{ a.Id, b.Id });
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            'ONE query must answer for BOTH dispositions — that is what keeps the guard out of a '
            + 'per-record loop');
        Map<Id, Disposition_Offer__c> byId = new Map<Id, Disposition_Offer__c>(result);
        Assert.isTrue(byId.containsKey(aSelected.Id), 'A\'s selected offer');
        Assert.isTrue(byId.containsKey(bSelected.Id), 'B\'s selected offer');
        Assert.isFalse(byId.containsKey(aOther.Id),
            'An unselected offer must NOT be returned — the guard counts selected siblings only');
        Assert.areEqual(a.Id, byId.get(aSelected.Id).Disposition__c,
            'Disposition__c must be selected — the caller groups the count by it');
    }

    /** Null/empty-safe and, on empty, issues NO query at all. */
    @isTest
    static void selectSelectedByDispositionIds_nullAndEmptyInput_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer nullSize = DispositionOfferSelector.selectSelectedByDispositionIds(null).size();
        Integer emptySize =
            DispositionOfferSelector.selectSelectedByDispositionIds(new Set<Id>()).size();
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, nullSize, 'Null input returns an empty list');
        Assert.areEqual(0, emptySize, 'An empty set returns an empty list');
        Assert.areEqual(0, queriesUsed,
            'Neither may issue a query — the guard\'s zero-query fast path depends on this');
    }
}
