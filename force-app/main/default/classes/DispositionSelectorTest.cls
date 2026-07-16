/**
 * Tests for DispositionSelector (P4 cleanup wave E — Disposition module).
 *
 * Covers all three relocated queries:
 *   - selectMostRecentByPropertyAssetId : most-recent ordering (deterministic via
 *     Test.setCreatedDate, since the query has no Id tiebreak), the no-Disposition
 *     -> null contract, and a 251-record LIMIT-1 read.
 *   - selectClosingSummaryById : field population, the Wires__r subquery flag with
 *     and without a Wire, and the missing-Id -> System.QueryException contract.
 *   - selectOutreachById : field population (including Package_Sent__c, a DATE
 *     despite its name) and the missing-Id -> System.QueryException contract.
 *
 * @TestSetup builds Property -> Property_Asset -> Disposition with explicit parent
 * Ids; test methods QUERY that data (TestDataFactory ⚠1 cache trap). No runAs
 * USER_MODE test — Disposition__c is custom, FLS gap 0.
 */
@isTest
private class DispositionSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c setupDisposition() {
        return [SELECT Id FROM Disposition__c LIMIT 1];
    }

    @isTest
    static void selectMostRecentByPropertyAssetId_returnsMostRecent() {
        Id asset = assetId();
        // Age the @TestSetup Disposition so the new one is unambiguously the most recent
        // (ORDER BY CreatedDate DESC only — same-transaction rows would otherwise tie).
        Disposition__c older = setupDisposition();
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-5));
        Disposition__c newer = TestDataFactory.createDisposition(asset, true);

        Test.startTest();
        Disposition__c result = DispositionSelector.selectMostRecentByPropertyAssetId(asset);
        Test.stopTest();

        Assert.isNotNull(result, 'The asset has Dispositions, so a row should return');
        Assert.areEqual(newer.Id, result.Id, 'ORDER BY CreatedDate DESC should return the most recent Disposition');
    }

    @isTest
    static void selectMostRecentByPropertyAssetId_noDisposition_returnsNull() {
        // A fresh asset with no Disposition of its own.
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c freshAsset = TestDataFactory.createPropertyAsset(prop.Id, true);

        Test.startTest();
        Disposition__c result = DispositionSelector.selectMostRecentByPropertyAssetId(freshAsset.Id);
        Test.stopTest();

        Assert.isNull(result, 'An asset with no Disposition should return null, not throw (find-or-create then inserts)');
    }

    @isTest
    static void selectMostRecentByPropertyAssetId_bulk251_resolvesOne() {
        Id asset = assetId();
        // 250 more under the same asset (the @TestSetup one makes 251 total).
        TestDataFactory.createDispositions(BULK_N - 1, asset, true);

        Test.startTest();
        Disposition__c result = DispositionSelector.selectMostRecentByPropertyAssetId(asset);
        Test.stopTest();

        Integer total = [SELECT COUNT() FROM Disposition__c WHERE Property_Asset__c = :asset];
        Assert.areEqual(BULK_N, total, 'All 251 Dispositions should exist under the asset');
        Assert.isNotNull(result, 'LIMIT 1 should still resolve exactly one row at 251-record volume');
    }

    @isTest
    static void selectClosingSummaryById_populatesFieldsAndWireFlag() {
        Disposition__c disp = setupDisposition();
        TestDataFactory.createWire(disp.Id, true);

        Test.startTest();
        Disposition__c result = DispositionSelector.selectClosingSummaryById(disp.Id);
        Test.stopTest();

        Assert.areEqual('Test Asset 0', result.Property_Asset__r.Name, 'Property_Asset__r.Name should be selected');
        Assert.areEqual('Disposition Readiness', result.Disposition_Stage__c, 'Disposition_Stage__c should be selected');
        Assert.areEqual(false, result.PSA_Executed__c, 'PSA_Executed__c should be selected');
        Assert.areEqual('Test Title Co', result.Title_Company__c, 'Title_Company__c should be selected');
        Assert.areEqual(false, result.Closing_Statement_Uploaded__c, 'Closing_Statement_Uploaded__c should be selected');
        Assert.isFalse(result.Wires__r.isEmpty(), 'The Wires__r subquery should return the inserted Wire');
    }

    @isTest
    static void selectClosingSummaryById_noWire_wiresEmpty() {
        Disposition__c disp = setupDisposition();

        Test.startTest();
        Disposition__c result = DispositionSelector.selectClosingSummaryById(disp.Id);
        Test.stopTest();

        Assert.isTrue(result.Wires__r.isEmpty(), 'A Disposition with no Wire should have an empty Wires__r subquery');
    }

    @isTest
    static void selectClosingSummaryById_missingId_throwsQueryException() {
        Disposition__c ghost = TestDataFactory.createDisposition(assetId(), true);
        Id deletedId = ghost.Id;
        delete ghost;

        Test.startTest();
        try {
            DispositionSelector.selectClosingSummaryById(deletedId);
            Assert.fail('A Disposition Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching Disposition row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void selectOutreachById_populatesFields() {
        Disposition__c disp = setupDisposition();

        Test.startTest();
        Disposition__c result = DispositionSelector.selectOutreachById(disp.Id);
        Test.stopTest();

        Assert.areEqual('Test Asset 0', result.Property_Asset__r.Name, 'Property_Asset__r.Name should be selected');
        Assert.areEqual(Date.today(), result.Package_Sent__c, 'Package_Sent__c (a DATE) should be selected');
        Assert.areEqual(Date.today().addDays(30), result.Submission_Deadline__c, 'Submission_Deadline__c should be selected');
        Assert.areEqual(0, result.Responses_Received__c, 'Responses_Received__c should be selected');
        Assert.areEqual(0, result.Brokers_Contacted__c, 'Brokers_Contacted__c should be selected');
        // Accessing Selected_Broker__c (null here) proves it is in the SELECT — an
        // unselected field would throw SObjectException on this read.
        Assert.isNull(result.Selected_Broker__c, 'Selected_Broker__c should be selected (null on the factory default)');
    }

    @isTest
    static void selectOutreachById_missingId_throwsQueryException() {
        Disposition__c ghost = TestDataFactory.createDisposition(assetId(), true);
        Id deletedId = ghost.Id;
        delete ghost;

        Test.startTest();
        try {
            DispositionSelector.selectOutreachById(deletedId);
            Assert.fail('A Disposition Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching Disposition row: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
