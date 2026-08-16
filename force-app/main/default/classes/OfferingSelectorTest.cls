/**
 * Tests for `OfferingSelector` — the first and only `Offering__c` SOQL in the application.
 *
 * ── WHAT IS AND IS NOT PROVABLE HERE ────────────────────────────────────────
 * 🔴 **THE `without sharing` HALF CANNOT BE FALSIFIED BY ANY TEST IN THIS ORG, AND SAYING SO IS
 * PART OF THE COVERAGE.** `System.runAs` does not change record OWNERSHIP of rows created outside
 * its block, and a test that created an Offering as the running user can always see it; reproducing
 * "a Private-OWD row owned by somebody else" needs a second real user with a real profile and no
 * `viewAllRecords` grant, which this suite has no way to guarantee. The consequence of getting it
 * wrong is a DUPLICATE Offering, not a silence, so it is argued at the selector and carried by the
 * class header rather than pretended to be tested. What IS pinned below is the observable contract:
 * the field set, the empty-input guard's zero-query promise, and one query at 251.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies (this backs a trigger path) and is
 * met. `.claude/rules/content-publication-rule.md` does NOT apply — `Offering__c` is not a content
 * object and no `ContentVersion` is created anywhere in this feature.
 */
@isTest
private class OfferingSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectByOpportunityIds_returnsTheGuardFieldSet() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Offering__c offering = TestDataFactory.createOffering(opp.Id, true);

        Test.startTest();
        List<Offering__c> rows = OfferingSelector.selectByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The deal has exactly one Offering');
        Assert.areEqual(offering.Id, rows[0].Id, 'and it is the one that was created');
        // Opportunity__c is what the caller groups on — get() throws for a never-selected field,
        // which is what makes the declared field set falsifiable rather than merely documented.
        Assert.areEqual(opp.Id, rows[0].Opportunity__c,
            'Opportunity__c IS the idempotency key and must be in the field list');
    }

    @isTest
    static void selectByOpportunityIds_nullOrEmptyInput_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Offering__c> nullResult = OfferingSelector.selectByOpportunityIds(null);
        List<Offering__c> emptyResult = OfferingSelector.selectByOpportunityIds(new Set<Id>());
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, nullResult.size(), 'Null input returns an empty list, never null');
        Assert.areEqual(0, emptyResult.size(), 'Empty input returns an empty list');
        Assert.areEqual(0, used,
            'Neither guard may issue a query. This selector is reached from a Contract_Review__c '
            + 'after-update trigger, so a wasted query here is a wasted query on every PSA save');
    }

    @isTest
    static void selectByOpportunityIds_dealWithNoOfferingIsSimplyAbsent() {
        // The guard's whole job. A deal with no Offering must produce NO row rather than a null
        // one, because the caller turns the result into a Set<Id> membership test.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        List<Offering__c> rows = OfferingSelector.selectByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A deal with no Offering contributes no row');
    }

    @isTest
    static void selectByOpportunityIds_isOneQueryAt251Deals() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_N, true);
        List<Offering__c> offerings = new List<Offering__c>();
        Set<Id> oppIds = new Set<Id>();
        for (Opportunity opp : opps) {
            oppIds.add(opp.Id);
            offerings.add(new Offering__c(Opportunity__c = opp.Id, Status__c = 'Draft'));
        }
        insert offerings;

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Offering__c> rows = OfferingSelector.selectByOpportunityIds(oppIds);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'Every existing Offering comes back');
        // 🔴 THE CONSTANCY IS THE CLAIM, NOT THE ROW COUNT. A per-record selector call would blow
        // the 100-query limit at 251 long before this assertion was reached; pinning ONE makes a
        // future "just query it in the loop" change fail here instead of in production.
        Assert.areEqual(1, used, 'ONE query for the whole set, regardless of deal count');
    }
}
