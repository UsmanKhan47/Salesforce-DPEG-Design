/**
 * Tests for WorkOrderSelector (P4 Module B1 — Property Management).
 *
 * Covers the five relocated Work_Order__c queries:
 *   - selectForKpis        : field population + a 251-record data-volume read.
 *   - selectRecentOpen     : LIMIT 6, open-only filter, Reported_DateTime__c DESC order.
 *   - selectEscalations    : escalation-only filter (breached Critical/High).
 *   - selectUntouched      : untouched-only filter, oldest-reported-first order.
 *   - selectRequiredById   : happy path + missing-Id -> System.QueryException contract
 *                            that WorkOrderController.getActivity depends on.
 *
 * @TestSetup builds only the Property -> Property_Asset scaffold with explicit
 * parent Ids (never default*()); each test queries for that asset and builds its
 * own Work Orders. Per the TestDataFactory header, calling a default*() accessor
 * in a test method after @TestSetup would silently create a SECOND asset, so tests
 * query for the @TestSetup-created asset instead.
 *
 * No System.runAs USER_MODE test: Work_Order__c is a custom object and P3 proved
 * the custom-field FLS gap is 0, so the running user reads every selected field.
 * The runAs assertion is reserved for standard-object selectors (design §7).
 */
@isTest
private class WorkOrderSelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectForKpis_populatesFlagsForEveryOpenWorkOrder() {
        TestDataFactory.createWorkOrders(3, assetId(), true); // Status 'New' -> open + untouched

        Test.startTest();
        List<Work_Order__c> result = WorkOrderSelector.selectForKpis();
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'selectForKpis should return every Work Order');
        for (Work_Order__c w : result) {
            Assert.areEqual(true, w.Is_Open__c, 'A New Work Order should be open');
            Assert.areEqual(true, w.Is_Untouched__c, 'A never-touched open Work Order should be untouched');
            Assert.areEqual(false, w.SLA_Breached__c, 'A just-reported Work Order should not be breached');
        }
    }

    @isTest
    static void selectRecentOpen_returnsSixNewestOpen_orderedByReportedDesc() {
        List<Work_Order__c> wos = TestDataFactory.createWorkOrders(8, assetId(), false);
        Datetime base = Datetime.newInstance(2026, 1, 1, 8, 0, 0);
        for (Integer i = 0; i < wos.size(); i++) {
            wos[i].Reported_DateTime__c = base.addMinutes(i); // i = 7 is newest
            wos[i].Subject__c = 'WO-' + i;
        }
        insert wos;

        Test.startTest();
        List<Work_Order__c> result = WorkOrderSelector.selectRecentOpen();
        Test.stopTest();

        Assert.areEqual(6, result.size(), 'selectRecentOpen should cap at LIMIT 6');
        Assert.areEqual('WO-7', result[0].Subject__c, 'Newest reported open Work Order should sort first');
        Assert.areEqual('WO-2', result[5].Subject__c, 'The 6th newest should be last of the six');
        for (Work_Order__c w : result) {
            Assert.areEqual(true, w.Is_Open__c, 'selectRecentOpen must return only open Work Orders');
        }
    }

    @isTest
    static void selectUntouched_returnsOnlyUntouched_excludesClosed() {
        Id aId = assetId();
        List<Work_Order__c> untouched = TestDataFactory.createWorkOrders(3, aId, false);
        Datetime base = Datetime.newInstance(2026, 2, 1, 8, 0, 0);
        for (Integer i = 0; i < untouched.size(); i++) {
            untouched[i].Reported_DateTime__c = base.addMinutes(i);
            untouched[i].Subject__c = 'UT-' + i;
        }
        insert untouched;
        // A Completed Work Order is not open, so Is_Untouched__c is false -> excluded.
        Work_Order__c closed = TestDataFactory.createWorkOrder(aId, false);
        closed.Status__c = 'Completed';
        closed.Subject__c = 'CLOSED';
        insert closed;

        Test.startTest();
        List<Work_Order__c> result = WorkOrderSelector.selectUntouched();
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'Only the three untouched open Work Orders should return');
        // Oldest reported first: UT-0 leads.
        Assert.areEqual('UT-0', result[0].Subject__c, 'selectUntouched should order oldest-reported first');
        for (Work_Order__c w : result) {
            Assert.areEqual(true, w.Is_Untouched__c, 'selectUntouched must return only untouched Work Orders');
            Assert.areNotEqual('CLOSED', w.Subject__c, 'A Completed Work Order must not appear');
        }
    }

    @isTest
    static void selectEscalations_returnsOnlyBreachedCriticalOrHigh() {
        Id aId = assetId();
        // Breached (reported 60 days ago) + Critical -> Is_Escalation__c true.
        Work_Order__c escalation =
            TestDataFactory.createWorkOrdersReportedAt(1, aId, Datetime.now().addDays(-60), false)[0];
        escalation.Priority__c = 'Critical';
        escalation.Subject__c = 'ESCALATION';
        // A just-reported Medium Work Order is neither breached nor Critical/High.
        Work_Order__c calm = TestDataFactory.createWorkOrder(aId, false);
        calm.Subject__c = 'CALM';
        insert new List<Work_Order__c>{ escalation, calm };

        Test.startTest();
        List<Work_Order__c> result = WorkOrderSelector.selectEscalations();
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the breached Critical Work Order should escalate');
        Assert.areEqual('ESCALATION', result[0].Subject__c, 'The escalation row should be the breached Critical one');
        for (Work_Order__c w : result) {
            Assert.areEqual(true, w.SLA_Breached__c, 'Every escalation must be breached');
            Assert.isTrue(new Set<String>{ 'Critical', 'High' }.contains(w.Priority__c),
                'Every escalation must be Critical or High priority');
        }
    }

    @isTest
    static void selectRequiredById_existingId_returnsUntouchedFlag() {
        Work_Order__c wo = TestDataFactory.createWorkOrder(assetId(), true);

        Test.startTest();
        Work_Order__c result = WorkOrderSelector.selectRequiredById(wo.Id);
        Test.stopTest();

        Assert.areEqual(wo.Id, result.Id, 'selectRequiredById should return the record for the given Id');
        Assert.areEqual(true, result.Is_Untouched__c, 'Is_Untouched__c must be selected so getActivity can read it');
    }

    @isTest
    static void selectRequiredById_missingId_throwsQueryException() {
        Work_Order__c wo = TestDataFactory.createWorkOrder(assetId(), true);
        Id deletedId = wo.Id;
        delete wo;

        Test.startTest();
        try {
            WorkOrderSelector.selectRequiredById(deletedId);
            Assert.fail('A Work Order Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching Work Order row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void selectForKpis_251WorkOrders_returnsAll_recentStillCapsAtSix() {
        TestDataFactory.createWorkOrders(251, assetId(), true);

        Test.startTest();
        List<Work_Order__c> kpis = WorkOrderSelector.selectForKpis();
        List<Work_Order__c> recent = WorkOrderSelector.selectRecentOpen();
        Test.stopTest();

        Assert.areEqual(251, kpis.size(), 'selectForKpis should read all 251 Work Orders');
        Assert.areEqual(6, recent.size(), 'selectRecentOpen should still cap at 6 at 251-record volume');
    }
}
