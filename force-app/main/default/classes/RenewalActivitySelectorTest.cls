/**
 * Tests for RenewalActivitySelector (P4 Module B1 — Property Management).
 *
 * Covers both timeline forms:
 *   - selectByLeaseRenewalId  : field population (incl. CreatedBy.Name), newest-first
 *                               order, null-input guard, and an empty-timeline result.
 *   - selectByLeaseRenewalIds : the 251-parent bulk read mandated by
 *                               .claude/rules/bulk-test-rule.md, plus null / empty guards.
 *
 * @TestSetup builds the Property -> Property_Asset -> Lease_Renewal scaffold with
 * explicit parent Ids; single-parent tests query for that renewal rather than
 * calling default*() (TestDataFactory header: the static scaffold cache does not
 * survive the @TestSetup boundary).
 *
 * No System.runAs USER_MODE test: Renewal_Activity__c is custom (FLS gap 0, P3);
 * CreatedBy.Name is a non-permissionable relationship field (design §5).
 */
@isTest
private class RenewalActivitySelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createLeaseRenewal(asset.Id, true);
    }

    private static Id leaseRenewalId() {
        return [SELECT Id FROM Lease_Renewal__c LIMIT 1].Id;
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectByLeaseRenewalId_populatesFields_newestFirst() {
        Id lrId = leaseRenewalId();
        List<Renewal_Activity__c> acts = TestDataFactory.createRenewalActivities(3, lrId, false);
        Datetime base = Datetime.newInstance(2026, 1, 1, 9, 0, 0);
        for (Integer i = 0; i < acts.size(); i++) {
            acts[i].Entry_DateTime__c = base.addMinutes(i); // i = 2 is newest
            acts[i].Details__c = 'ENTRY-' + i;
        }
        insert acts;

        Test.startTest();
        List<Renewal_Activity__c> result = RenewalActivitySelector.selectByLeaseRenewalId(lrId);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three activities for the renewal should return');
        Assert.areEqual('ENTRY-2', result[0].Details__c, 'Newest Entry_DateTime__c should sort first');
        Assert.areEqual('ENTRY-0', result[2].Details__c, 'Oldest Entry_DateTime__c should sort last');
        Assert.areEqual(lrId, result[0].Lease_Renewal__c, 'Parent Lease_Renewal__c should be selected for grouping');
        Assert.isNotNull(result[0].Method__c, 'Method__c should be selected');
        Assert.isNotNull(result[0].CreatedBy.Name, 'CreatedBy.Name should be selected for the "entered by" column');
    }

    @isTest
    static void selectByLeaseRenewalId_nullInput_returnsEmpty() {
        Test.startTest();
        List<Renewal_Activity__c> result = RenewalActivitySelector.selectByLeaseRenewalId(null);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A null parent Id should short-circuit to an empty list, not query');
    }

    @isTest
    static void selectByLeaseRenewalId_noActivities_returnsEmpty() {
        Test.startTest();
        List<Renewal_Activity__c> result = RenewalActivitySelector.selectByLeaseRenewalId(leaseRenewalId());
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A renewal with no activities should return an empty list');
    }

    @isTest
    static void selectByLeaseRenewalIds_251Parents_returnsAllGroupedByParent() {
        List<Lease_Renewal__c> lrs = TestDataFactory.createLeaseRenewals(251, assetId(), true);
        Set<Id> lrIds = new Map<Id, Lease_Renewal__c>(lrs).keySet();
        List<Renewal_Activity__c> acts = new List<Renewal_Activity__c>();
        for (Lease_Renewal__c lr : lrs) {
            acts.addAll(TestDataFactory.createRenewalActivities(1, lr.Id, false));
        }
        insert acts;

        Test.startTest();
        List<Renewal_Activity__c> result = RenewalActivitySelector.selectByLeaseRenewalIds(lrIds);
        Test.stopTest();

        Assert.areEqual(251, result.size(), 'One activity per parent across 251 parents should all return');
        Set<Id> parentsSeen = new Set<Id>();
        for (Renewal_Activity__c a : result) {
            parentsSeen.add(a.Lease_Renewal__c);
        }
        Assert.areEqual(251, parentsSeen.size(), 'Every one of the 251 parents should be represented');
    }

    @isTest
    static void selectByLeaseRenewalIds_nullInput_returnsEmpty() {
        Test.startTest();
        List<Renewal_Activity__c> result = RenewalActivitySelector.selectByLeaseRenewalIds(null);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A null Id set should short-circuit to an empty list');
    }

    @isTest
    static void selectByLeaseRenewalIds_emptyInput_returnsEmpty() {
        Test.startTest();
        List<Renewal_Activity__c> result = RenewalActivitySelector.selectByLeaseRenewalIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'An empty Id set should short-circuit to an empty list');
    }
}
