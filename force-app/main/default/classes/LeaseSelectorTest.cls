/**
 * Tests for LeaseSelector (P4 cleanup wave F1 — Lease Activity Tracker).
 *
 * Covers the one relocated Lease__c query:
 *   - selectMostRecentByInquiryId : picks the newest-created Lease for the inquiry
 *                                   (CreatedDate set deterministically via
 *                                   Test.setCreatedDate — same-transaction rows
 *                                   otherwise share CreatedDate), field population,
 *                                   the null-input -> null guard, and the
 *                                   no-Lease -> null contract that getLeaseSummary
 *                                   relies on (an inquiry with no Lease is normal).
 *
 * @TestSetup builds the Property -> Property_Asset -> Lease_Inquiry scaffold with
 * explicit parent Ids; tests query for that inquiry rather than calling default*()
 * (TestDataFactory header). The setup inquiry stays at 'Inquiry Received', so no
 * Create Lease flow fires — the no-Lease test sees a genuinely lease-free inquiry.
 *
 * No System.runAs USER_MODE test: Lease__c is custom (FLS gap 0, P3); Legal_Owner__r.Name
 * traverses a custom User lookup enforced under USER_MODE, and User.Name is
 * standard/always-readable. No 251 test: selectMostRecentByInquiryId is a single-record
 * read (not a Set<Id> / child-by-parent bulk consumer), mirroring the WireSelector
 * precedent.
 */
@isTest
private class LeaseSelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createLeaseInquiry(asset.Id, true);
    }

    private static Id inquiryId() {
        return [SELECT Id FROM Lease_Inquiry__c LIMIT 1].Id;
    }

    @isTest
    static void selectMostRecentByInquiryId_returnsLatest_withFields() {
        Id inqId = inquiryId();
        List<Lease__c> leases = TestDataFactory.createLeases(2, inqId, false);
        leases[0].Target_Execution_Date__c = Date.today().addDays(10);  // older
        leases[1].Target_Execution_Date__c = Date.today().addDays(99);  // newer-created
        insert leases;
        // ORDER BY CreatedDate DESC needs distinct, deterministic CreatedDate values.
        Datetime base = Datetime.newInstance(2026, 1, 1, 0, 0, 0);
        Test.setCreatedDate(leases[0].Id, base);
        Test.setCreatedDate(leases[1].Id, base.addDays(1)); // leases[1] is newest

        Test.startTest();
        Lease__c result = LeaseSelector.selectMostRecentByInquiryId(inqId);
        Test.stopTest();

        Assert.areEqual(leases[1].Id, result.Id, 'The most-recently-created Lease should be returned');
        Assert.areEqual(Date.today().addDays(99), result.Target_Execution_Date__c,
            'Target_Execution_Date__c must be selected and belong to the newest Lease');
        Assert.areEqual('Draft', result.Stage__c, 'Stage__c must be selected for the summary header');
        Assert.isNotNull(result.Name, 'Name must be selected for the summary header');
        Assert.isNotNull(result.Legal_Owner__r.Name, 'Legal_Owner__r.Name must be selected for the legal-owner column');
    }

    @isTest
    static void selectMostRecentByInquiryId_nullInput_returnsNull() {
        Test.startTest();
        Lease__c result = LeaseSelector.selectMostRecentByInquiryId(null);
        Test.stopTest();

        Assert.isNull(result, 'A null inquiry Id should short-circuit to null, not query');
    }

    @isTest
    static void selectMostRecentByInquiryId_noLease_returnsNull() {
        Test.startTest();
        Lease__c result = LeaseSelector.selectMostRecentByInquiryId(inquiryId());
        Test.stopTest();

        Assert.isNull(result, 'An inquiry with no Lease should return null (a normal, non-error state)');
    }
}
