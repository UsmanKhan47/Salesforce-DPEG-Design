/**
 * Tests for WorkOrderActivitySelector (P4 Module B1 — Property Management).
 *
 * Covers both timeline forms:
 *   - selectByWorkOrderId  : field population, newest-first order, null-input guard,
 *                            and an empty-timeline result.
 *   - selectByWorkOrderIds : the 251-parent bulk read mandated by
 *                            .claude/rules/bulk-test-rule.md, plus null / empty guards.
 *
 * @TestSetup builds the Property -> Property_Asset -> Work_Order scaffold with
 * explicit parent Ids; single-parent tests query for that Work Order rather than
 * calling default*() (the TestDataFactory header warns the static scaffold cache
 * does not survive the @TestSetup boundary).
 *
 * No System.runAs USER_MODE test: Work_Order_Activity__c is custom (FLS gap 0, P3).
 */
@isTest
private class WorkOrderActivitySelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createWorkOrder(asset.Id, true);
    }

    private static Id workOrderId() {
        return [SELECT Id FROM Work_Order__c LIMIT 1].Id;
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectByWorkOrderId_populatesFields_newestFirst() {
        Id woId = workOrderId();
        List<Work_Order_Activity__c> acts = TestDataFactory.createWorkOrderActivities(3, woId, false);
        Datetime base = Datetime.newInstance(2026, 1, 1, 9, 0, 0);
        for (Integer i = 0; i < acts.size(); i++) {
            acts[i].Entry_DateTime__c = base.addMinutes(i); // i = 2 is newest
            acts[i].Detail__c = 'ENTRY-' + i;
        }
        insert acts;

        Test.startTest();
        List<Work_Order_Activity__c> result = WorkOrderActivitySelector.selectByWorkOrderId(woId);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three activities for the Work Order should return');
        Assert.areEqual('ENTRY-2', result[0].Detail__c, 'Newest Entry_DateTime__c should sort first');
        Assert.areEqual('ENTRY-0', result[2].Detail__c, 'Oldest Entry_DateTime__c should sort last');
        Assert.areEqual(woId, result[0].Work_Order__c, 'Parent Work_Order__c should be selected for grouping');
        Assert.isNotNull(result[0].Kind__c, 'Kind__c should be selected');
        Assert.isNotNull(result[0].Actor__c, 'Actor__c should be selected');
    }

    @isTest
    static void selectByWorkOrderId_nullInput_returnsEmpty() {
        Test.startTest();
        List<Work_Order_Activity__c> result = WorkOrderActivitySelector.selectByWorkOrderId(null);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A null parent Id should short-circuit to an empty list, not query');
    }

    @isTest
    static void selectByWorkOrderId_noActivities_returnsEmpty() {
        Test.startTest();
        List<Work_Order_Activity__c> result = WorkOrderActivitySelector.selectByWorkOrderId(workOrderId());
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A Work Order with no activities should return an empty list');
    }

    @isTest
    static void selectByWorkOrderIds_251Parents_returnsAllGroupedByParent() {
        List<Work_Order__c> wos = TestDataFactory.createWorkOrders(251, assetId(), true);
        Set<Id> woIds = new Map<Id, Work_Order__c>(wos).keySet();
        List<Work_Order_Activity__c> acts = new List<Work_Order_Activity__c>();
        for (Work_Order__c wo : wos) {
            acts.addAll(TestDataFactory.createWorkOrderActivities(1, wo.Id, false));
        }
        insert acts;

        Test.startTest();
        List<Work_Order_Activity__c> result = WorkOrderActivitySelector.selectByWorkOrderIds(woIds);
        Test.stopTest();

        Assert.areEqual(251, result.size(), 'One activity per parent across 251 parents should all return');
        Set<Id> parentsSeen = new Set<Id>();
        for (Work_Order_Activity__c a : result) {
            parentsSeen.add(a.Work_Order__c);
        }
        Assert.areEqual(251, parentsSeen.size(), 'Every one of the 251 parents should be represented');
    }

    @isTest
    static void selectByWorkOrderIds_nullInput_returnsEmpty() {
        Test.startTest();
        List<Work_Order_Activity__c> result = WorkOrderActivitySelector.selectByWorkOrderIds(null);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A null Id set should short-circuit to an empty list');
    }

    @isTest
    static void selectByWorkOrderIds_emptyInput_returnsEmpty() {
        Test.startTest();
        List<Work_Order_Activity__c> result = WorkOrderActivitySelector.selectByWorkOrderIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'An empty Id set should short-circuit to an empty list');
    }
}
