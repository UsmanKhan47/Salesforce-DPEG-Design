/**
 * Tests for BrokerAssignmentSelector (P4, Module B2 — Property Management).
 *
 * Covers all three relocated queries:
 *   - selectAllOrderedByCreatedDateDesc : field population, ORDER BY CreatedDate
 *     DESC (proven with Test.setCreatedDate because same-transaction inserts share
 *     CreatedDate), empty-org guard, and a 251-record bulk read (bulk-test-rule).
 *   - selectActiveOverdueByCheckInDays  : the Status='Active' + Days_Since_Check_In__c
 *     filter, the null-threshold guard, and a 251-record bulk read.
 *   - selectRequiredById : happy path (snapshot fields selected) and the
 *     missing-Id -> System.QueryException contract replaceBroker relies on.
 *
 * No System.runAs USER_MODE test: Broker_Assignment__c is a custom object and P3
 * proved the custom-field FLS gap is 0, so the running user reads every selected
 * field (WireSelectorTest rationale; the runAs proof is reserved for the
 * standard-object ContactSelector per design §7).
 *
 * @TestSetup builds the Property -> Property_Asset -> broker Contact scaffold with
 * explicit Ids; tests query for it rather than re-calling default*() (the
 * TestDataFactory header warns the static scaffold cache does NOT survive the
 * @TestSetup boundary).
 *
 * @see force-app/main/default/classes/WireSelectorTest.cls (P4 pilot test template)
 * @see agent-output/p4-selector-design.md (§3 #5, §5, §7)
 */
@isTest
private class BrokerAssignmentSelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createBrokerContact(null, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Id brokerId() {
        return [SELECT Id FROM Contact WHERE Is_Broker__c = true LIMIT 1].Id;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectAllOrderedByCreatedDateDesc
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectAllOrderedByCreatedDateDesc_populatesFieldsAndOrdersByCreatedDesc() {
        List<Broker_Assignment__c> pair =
            TestDataFactory.createBrokerAssignments(2, assetId(), brokerId(), false);
        pair[0].Status__c = 'Active';
        pair[0].Reason_Ended__c = null;
        pair[1].Status__c = 'Disposed';
        pair[1].Reason_Ended__c = 'Performance Issue';
        insert pair;

        // Same-transaction inserts share CreatedDate, so force a deterministic order:
        // pair[1] is the newest and must sort first under ORDER BY CreatedDate DESC.
        Test.setCreatedDate(pair[0].Id, Datetime.now().addDays(-3));
        Test.setCreatedDate(pair[1].Id, Datetime.now());

        Test.startTest();
        List<Broker_Assignment__c> rows = BrokerAssignmentSelector.selectAllOrderedByCreatedDateDesc();
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both assignments are returned');
        Assert.areEqual(pair[1].Id, rows[0].Id, 'ORDER BY CreatedDate DESC returns the newest assignment first');
        Assert.areEqual('Disposed', rows[0].Status__c, 'Status__c is selected');
        Assert.areEqual('Performance Issue', rows[0].Reason_Ended__c, 'Reason_Ended__c is selected');
        Assert.areEqual(brokerId(), rows[0].Broker__c, 'Broker__c is selected');
        Assert.areEqual(assetId(), rows[0].Property_Asset__c, 'Property_Asset__c is selected');
        // Deterministic factory values prove the remaining dashboard-critical fields
        // are in the SELECT (a narrower query would throw SObjectException downstream).
        Assert.areEqual(Date.today().addDays(-30), rows[0].Listing_Start_Date__c, 'Listing_Start_Date__c is selected');
        Assert.areEqual(Date.today(), rows[0].Last_Check_In_Date__c, 'Last_Check_In_Date__c is selected');
        Assert.areEqual(0, rows[0].Days_Since_Check_In__c, 'Days_Since_Check_In__c formula (TODAY - today) is selected and resolves to 0');
        Assert.areEqual(assetId(), rows[1].Property_Asset__c, 'The older assignment still resolves its fields');
    }

    @isTest
    static void selectAllOrderedByCreatedDateDesc_noRecords_returnsEmpty() {
        Test.startTest();
        List<Broker_Assignment__c> rows = BrokerAssignmentSelector.selectAllOrderedByCreatedDateDesc();
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'With no Broker_Assignment__c records the selector returns an empty list, not null');
    }

    @isTest
    static void selectAllOrderedByCreatedDateDesc_bulk251_readsAll() {
        TestDataFactory.createBrokerAssignments(251, assetId(), brokerId(), true);

        Test.startTest();
        List<Broker_Assignment__c> rows = BrokerAssignmentSelector.selectAllOrderedByCreatedDateDesc();
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'The full-table read returns all 251 assignments at bulk volume');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectActiveOverdueByCheckInDays
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectActiveOverdueByCheckInDays_returnsOnlyOverdueActive() {
        Date today = Date.today();
        List<Broker_Assignment__c> mix =
            TestDataFactory.createBrokerAssignments(3, assetId(), brokerId(), false);
        // Days_Since_Check_In__c = TODAY() - Last_Check_In_Date__c.
        mix[0].Status__c = 'Active';   mix[0].Last_Check_In_Date__c = today.addDays(-40); // overdue -> included
        mix[1].Status__c = 'Active';   mix[1].Last_Check_In_Date__c = today.addDays(-5);  // fresh   -> excluded
        mix[2].Status__c = 'Disposed'; mix[2].Last_Check_In_Date__c = today.addDays(-40); // not Active -> excluded
        insert mix;

        Test.startTest();
        List<Broker_Assignment__c> rows =
            BrokerAssignmentSelector.selectActiveOverdueByCheckInDays(BrokerAssignmentController.OVERDUE_DAYS);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the Active assignment stale beyond OVERDUE_DAYS is returned');
        Assert.areEqual(mix[0].Id, rows[0].Id, 'The overdue Active assignment is the one returned');
        Assert.areEqual(brokerId(), rows[0].Broker__c, 'Broker__c is selected for the reminder WhoId');
    }

    @isTest
    static void selectActiveOverdueByCheckInDays_nullThreshold_returnsEmpty() {
        TestDataFactory.createBrokerAssignments(1, assetId(), brokerId(), true);

        Test.startTest();
        List<Broker_Assignment__c> rows = BrokerAssignmentSelector.selectActiveOverdueByCheckInDays(null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A null threshold short-circuits to an empty list, never a bad query');
    }

    @isTest
    static void selectActiveOverdueByCheckInDays_bulk251_readsAll() {
        List<Broker_Assignment__c> overdue =
            TestDataFactory.createBrokerAssignments(251, assetId(), brokerId(), false);
        TestDataFactory.applyOverrides(overdue, new Map<String, Object>{
            'Status__c' => 'Active',
            'Last_Check_In_Date__c' => Date.today().addDays(-40)
        });
        insert overdue;

        Test.startTest();
        List<Broker_Assignment__c> rows = BrokerAssignmentSelector.selectActiveOverdueByCheckInDays(21);
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'All 251 overdue Active assignments are returned at bulk volume');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectRequiredById
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectRequiredById_existingId_returnsRecordWithSnapshotFields() {
        Broker_Assignment__c a = TestDataFactory.createBrokerAssignment(assetId(), brokerId(), true);

        Test.startTest();
        Broker_Assignment__c result = BrokerAssignmentSelector.selectRequiredById(a.Id);
        Test.stopTest();

        Assert.areEqual(a.Id, result.Id, 'selectRequiredById returns the record for the given Id');
        Assert.areEqual(assetId(), result.Property_Asset__c, 'Property_Asset__c must be selected for the replaceBroker snapshot');
        Assert.areEqual(brokerId(), result.Broker__c, 'Broker__c must be selected for the replaceBroker snapshot');
        // replaceBroker copies these onto the history record; deterministic factory
        // values prove they are in the SELECT (a SELECT Id-only query would throw).
        Assert.areEqual(Date.today().addDays(-30), result.Listing_Start_Date__c, 'Listing_Start_Date__c must be selected for the snapshot');
        Assert.areEqual(Date.today(), result.Last_Check_In_Date__c, 'Last_Check_In_Date__c must be selected for the snapshot');
    }

    @isTest
    static void selectRequiredById_missingId_throwsQueryException() {
        Broker_Assignment__c a = TestDataFactory.createBrokerAssignment(assetId(), brokerId(), true);
        Id deletedId = a.Id;
        delete a;

        Test.startTest();
        try {
            BrokerAssignmentSelector.selectRequiredById(deletedId);
            Assert.fail('A Broker_Assignment__c Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching assignment row: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
