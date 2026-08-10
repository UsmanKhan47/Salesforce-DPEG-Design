/**
 * @description Tests DispositionOfferSelector — the first and only Disposition_Offer__c SOQL in
 * this application (Tranche 5 Item B).
 *
 * ── WHAT MATTERS HERE, IN ORDER ─────────────────────────────────────────────
 *   1. THE ABSENT-KEY CONTRACT. `GROUP BY` emits no row for an empty group, so a disposition with
 *      no offers is MISSING from the map rather than present with 0. Every caller has to default
 *      the miss, and a test that only ever counted non-empty groups would never notice.
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
        Assert.areEqual(0, DispositionOfferSelector.countByDispositionIds(null).size(),
            'A null input must return an empty map, never a NullPointerException');
        Assert.areEqual(0, DispositionOfferSelector.countByDispositionIds(new Set<Id>()).size(),
            'An empty input must return an empty map');
    }

    /**
     * 🔴 THE ABSENT-KEY CONTRACT. This is the one a caller gets wrong: `containsKey` is required,
     * because the map does not carry a 0 for an offerless disposition.
     */
    @isTest
    static void aDispositionWithNoOffersIsABSENTFromTheMapRatherThanZero() {
        Disposition__c d = newDisposition();

        Map<Id, Integer> counts =
            DispositionOfferSelector.countByDispositionIds(new Set<Id>{ d.Id });

        Assert.areEqual(0, counts.size(),
            'GROUP BY emits no row for an empty group, so the Id must be absent');
        Assert.isFalse(counts.containsKey(d.Id),
            'Callers must default a miss to 0 - the map does not do it for them');
        Assert.isNull(counts.get(d.Id), 'A miss reads null, which is why containsKey is required');
    }

    @isTest
    static void countsTheOffersOnOneDisposition() {
        Disposition__c d = newDisposition();
        TestDataFactory.createDispositionOffers(3, d.Id, true);

        Map<Id, Integer> counts =
            DispositionOfferSelector.countByDispositionIds(new Set<Id>{ d.Id });

        Assert.areEqual(1, counts.size(), 'One disposition with offers means one entry');
        Assert.areEqual(3, counts.get(d.Id), 'All three offers must be counted');
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

        Map<Id, Integer> counts =
            DispositionOfferSelector.countByDispositionIds(new Set<Id>{ a.Id, b.Id });

        Assert.areEqual(2, counts.size(),
            'Only the requested dispositions may appear - the third must be filtered out');
        Assert.areEqual(2, counts.get(a.Id), 'A gets its own 2, not the pooled 11');
        Assert.areEqual(5, counts.get(b.Id), 'B gets its own 5');
        Assert.isFalse(counts.containsKey(untouched.Id),
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
        Map<Id, Integer> counts = DispositionOfferSelector.countByDispositionIds(ids);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, counts.size(),
            'Every one of the ' + BULK_N + ' dispositions must be counted');
        Assert.areEqual(1, queriesUsed,
            'The count must be ONE aggregate query for the whole set, never one per record');
        Assert.areEqual(1, counts.get(dispositions[0].Id), 'Each carries exactly one offer');
        Assert.areEqual(1, counts.get(dispositions[BULK_N - 1].Id),
            'Including the last one, which is in the second trigger chunk');
    }
}
