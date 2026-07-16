/**
 * Tests for LeaseInquirySelector (P4 cleanup wave F1 — Lease Activity Tracker).
 *
 * Covers the six relocated Lease_Inquiry__c queries:
 *   - selectRequiredById              : header field set (incl. Ball_In_Court__c) +
 *                                       missing-Id -> System.QueryException contract
 *                                       that getLog depends on.
 *   - selectStageStatusById           : the narrower advance-decision field set +
 *                                       missing-Id -> System.QueryException.
 *   - selectForKpis                   : reads all inquiries incl. a 251-record volume read.
 *   - selectRecent                    : field population + LIMIT 6 cap. LastModifiedDate
 *                                       is NOT test-settable, so no ordering assertion is
 *                                       made on it (only the cap and field population).
 *   - selectActiveStagesCreatedSince  : Active-only + CreatedDate cutoff filter, proven
 *                                       deterministically via Test.setCreatedDate.
 *   - selectActive                    : Active-only filter (excludes Closed).
 *
 * @TestSetup builds only the Property -> Property_Asset scaffold with explicit parent
 * Ids; each test builds its own inquiries and queries for the asset (never default*(),
 * per the TestDataFactory header — the static scaffold cache does not cross the
 * @TestSetup boundary). Inserting a Lease_Inquiry__c fires the Stage Timer and Open Log
 * flows; neither affects the inquiry-count assertions here.
 *
 * No System.runAs USER_MODE test: Lease_Inquiry__c is custom (FLS gap 0, P3). No
 * ORDER BY targets the Stage__c picklist, so definition-order sorting is not exercised.
 */
@isTest
private class LeaseInquirySelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectRequiredById_existingId_returnsHeaderFields() {
        Lease_Inquiry__c inq = TestDataFactory.createLeaseInquiry(assetId(), true);

        Test.startTest();
        Lease_Inquiry__c result = LeaseInquirySelector.selectRequiredById(inq.Id);
        Test.stopTest();

        Assert.areEqual(inq.Id, result.Id, 'selectRequiredById should return the record for the given Id');
        Assert.areEqual('Inquiry Received', result.Stage__c, 'Stage__c must be selected for the log header');
        Assert.areEqual('Landlord', result.Ball_In_Court__c, 'Ball_In_Court__c must be selected for the log header');
        Assert.isNotNull(result.Status__c, 'Status__c must be selected for the log header');
    }

    @isTest
    static void selectRequiredById_missingId_throwsQueryException() {
        Lease_Inquiry__c inq = TestDataFactory.createLeaseInquiry(assetId(), true);
        Id deletedId = inq.Id;
        delete inq;

        Test.startTest();
        try {
            LeaseInquirySelector.selectRequiredById(deletedId);
            Assert.fail('An inquiry Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching inquiry row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void selectStageStatusById_existingId_returnsStageStatus() {
        Lease_Inquiry__c inq = TestDataFactory.createLeaseInquiry(assetId(), true);

        Test.startTest();
        Lease_Inquiry__c result = LeaseInquirySelector.selectStageStatusById(inq.Id);
        Test.stopTest();

        Assert.areEqual(inq.Id, result.Id, 'selectStageStatusById should return the record for the given Id');
        Assert.areEqual('Inquiry Received', result.Stage__c, 'Stage__c must be selected for the advance decision');
        Assert.isNotNull(result.Status__c, 'Status__c must be selected for the advance decision');
    }

    @isTest
    static void selectStageStatusById_missingId_throwsQueryException() {
        Lease_Inquiry__c inq = TestDataFactory.createLeaseInquiry(assetId(), true);
        Id deletedId = inq.Id;
        delete inq;

        Test.startTest();
        try {
            LeaseInquirySelector.selectStageStatusById(deletedId);
            Assert.fail('A missing update-target Id should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching inquiry row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void selectForKpis_returnsAllInquiries_withAggregateFields() {
        TestDataFactory.createLeaseInquiries(3, assetId(), true); // default Status 'Active'

        Test.startTest();
        List<Lease_Inquiry__c> result = LeaseInquirySelector.selectForKpis();
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'selectForKpis should return every inquiry');
        for (Lease_Inquiry__c q : result) {
            Assert.areEqual('Active', q.Status__c, 'Status__c should be selected and default to Active');
            Assert.areEqual('Landlord', q.Ball_In_Court__c, 'Ball_In_Court__c should be selected');
        }
    }

    @isTest
    static void selectForKpis_251Inquiries_returnsAll() {
        TestDataFactory.createLeaseInquiries(251, assetId(), true);

        Test.startTest();
        List<Lease_Inquiry__c> result = LeaseInquirySelector.selectForKpis();
        Test.stopTest();

        Assert.areEqual(251, result.size(), 'selectForKpis should read all 251 inquiries');
    }

    @isTest
    static void selectRecent_populatesFields() {
        List<Lease_Inquiry__c> inqs = TestDataFactory.createLeaseInquiries(1, assetId(), false);
        inqs[0].Tenant_Name__c = 'Sunrise Cafe';
        insert inqs;

        Test.startTest();
        List<Lease_Inquiry__c> result = LeaseInquirySelector.selectRecent();
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'selectRecent should return the single inquiry');
        Assert.areEqual('Sunrise Cafe', result[0].Tenant_Name__c, 'Tenant_Name__c must be selected for the row');
        Assert.areEqual('Inquiry Received', result[0].Stage__c, 'Stage__c must be selected for the row');
        Assert.isNotNull(result[0].Ball_In_Court__c, 'Ball_In_Court__c must be selected for the row');
    }

    @isTest
    static void selectRecent_capsAtSix() {
        TestDataFactory.createLeaseInquiries(8, assetId(), true);

        Test.startTest();
        List<Lease_Inquiry__c> result = LeaseInquirySelector.selectRecent();
        Test.stopTest();

        Assert.areEqual(6, result.size(), 'selectRecent should cap at LIMIT 6 even with 8 inquiries');
    }

    @isTest
    static void selectActive_returnsOnlyActive_excludesClosed() {
        List<Lease_Inquiry__c> inqs = TestDataFactory.createLeaseInquiries(3, assetId(), true);
        inqs[2].Status__c = 'Closed Lost';
        update inqs[2];

        Test.startTest();
        List<Lease_Inquiry__c> result = LeaseInquirySelector.selectActive();
        Test.stopTest();

        Assert.areEqual(2, result.size(), 'Only the two Active inquiries should surface');
        for (Lease_Inquiry__c q : result) {
            Assert.areEqual('Active', q.Status__c, 'selectActive must return only Active inquiries');
        }
    }

    @isTest
    static void selectActiveStagesCreatedSince_filtersOldAndClosed() {
        List<Lease_Inquiry__c> inqs = TestDataFactory.createLeaseInquiries(3, assetId(), true);
        // inqs[0]: Active, created now  -> INCLUDED
        // inqs[1]: Active, created 6yrs -> excluded by the cutoff
        Test.setCreatedDate(inqs[1].Id, Datetime.now().addYears(-6));
        // inqs[2]: Closed, created now  -> excluded by the Status filter
        inqs[2].Status__c = 'Closed Lost';
        update inqs[2];

        Datetime cutoff = Datetime.now().addYears(-5);

        Test.startTest();
        List<Lease_Inquiry__c> result = LeaseInquirySelector.selectActiveStagesCreatedSince(cutoff);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the recent, Active inquiry should pass both filters');
        Assert.areEqual('Inquiry Received', result[0].Stage__c, 'Stage__c must be selected for pipeline bucketing');
    }
}
