/**
 * Tests for LeaseRenewalSelector (P4 Module B1 — Property Management).
 *
 * Covers the four relocated Lease_Renewal__c queries:
 *   - selectForKpis      : field population + a 251-record data-volume read.
 *   - selectRecent       : LIMIT 6, newest-created-first order (CreatedDate is set
 *                          deterministically via Test.setCreatedDate — same-transaction
 *                          rows otherwise share CreatedDate and the order is nondeterministic).
 *   - selectAttention    : Active-only + (non-responsive OR expiring<=30d) filter,
 *                          proving a Closed renewal is excluded even when expiring soon.
 *   - selectRequiredById : happy path + missing-Id -> System.QueryException contract
 *                          that LeaseRenewalController.getTimeline depends on.
 *
 * @TestSetup builds only the Property -> Property_Asset scaffold with explicit
 * parent Ids; each test builds its own renewals and queries for the asset (never
 * default*(), per the TestDataFactory header).
 *
 * Stage__c is a RESTRICTED picklist — tests use only factory-default 'Not Yet Started'
 * and never assign an out-of-set value. No System.runAs USER_MODE test: Lease_Renewal__c
 * is custom (FLS gap 0, P3).
 */
@isTest
private class LeaseRenewalSelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectForKpis_returnsAllRenewals_withAggregateFields() {
        TestDataFactory.createLeaseRenewals(3, assetId(), true); // default Status 'Active'

        Test.startTest();
        List<Lease_Renewal__c> result = LeaseRenewalSelector.selectForKpis();
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'selectForKpis should return every renewal');
        for (Lease_Renewal__c r : result) {
            Assert.areEqual('Active', r.Status__c, 'Status__c should be selected and default Active');
        }
    }

    @isTest
    static void selectRecent_returnsSixNewest_byCreatedDate() {
        List<Lease_Renewal__c> lrs = TestDataFactory.createLeaseRenewals(8, assetId(), false);
        for (Integer i = 0; i < lrs.size(); i++) {
            lrs[i].Tenant_Name__c = 'LR-' + i;
        }
        insert lrs;
        // ORDER BY CreatedDate DESC needs distinct, deterministic CreatedDate values.
        Datetime base = Datetime.newInstance(2026, 1, 1, 0, 0, 0);
        for (Integer i = 0; i < lrs.size(); i++) {
            Test.setCreatedDate(lrs[i].Id, base.addDays(i)); // i = 7 is newest
        }

        Test.startTest();
        List<Lease_Renewal__c> result = LeaseRenewalSelector.selectRecent();
        Test.stopTest();

        Assert.areEqual(6, result.size(), 'selectRecent should cap at LIMIT 6');
        Assert.areEqual('LR-7', result[0].Tenant_Name__c, 'Newest-created renewal should sort first');
        Assert.areEqual('LR-2', result[5].Tenant_Name__c, 'The 6th newest should be last of the six');
    }

    @isTest
    static void selectAttention_returnsOnlyActiveNeedingAttention_excludesClosed() {
        List<Lease_Renewal__c> lrs = TestDataFactory.createLeaseRenewals(3, assetId(), false);
        // Active + expiring within 30 days -> attention.
        lrs[0].Tenant_Name__c = 'ATT';    lrs[0].Lease_End__c = Date.today().addDays(10);
        // Active but expiring far out -> not attention.
        lrs[1].Tenant_Name__c = 'FAR';    lrs[1].Lease_End__c = Date.today().addDays(120);
        // Expiring soon but Closed -> excluded by the Status = 'Active' filter.
        lrs[2].Tenant_Name__c = 'CLOSED'; lrs[2].Lease_End__c = Date.today().addDays(5);
        lrs[2].Status__c = 'Closed Won';
        insert lrs;

        Test.startTest();
        List<Lease_Renewal__c> result = LeaseRenewalSelector.selectAttention();
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the Active, soon-expiring renewal should surface');
        Assert.areEqual('ATT', result[0].Tenant_Name__c, 'The attention row should be the Active soon-expiring one');
        for (Lease_Renewal__c r : result) {
            Assert.areEqual('Active', r.Status__c, 'selectAttention must return only Active renewals');
            Assert.isTrue(r.Non_Responsive__c == true || r.Days_To_Expiry__c <= 30,
                'Every attention row must be non-responsive or expiring within 30 days');
        }
    }

    @isTest
    static void selectRequiredById_existingId_returnsHeaderFields() {
        Lease_Renewal__c lr = TestDataFactory.createLeaseRenewal(assetId(), true);

        Test.startTest();
        Lease_Renewal__c result = LeaseRenewalSelector.selectRequiredById(lr.Id);
        Test.stopTest();

        Assert.areEqual(lr.Id, result.Id, 'selectRequiredById should return the record for the given Id');
        Assert.areEqual('Active', result.Status__c, 'Status__c must be selected for the timeline header');
        Assert.isNotNull(result.Stage__c, 'Stage__c must be selected for the timeline header');
    }

    @isTest
    static void selectRequiredById_missingId_throwsQueryException() {
        Lease_Renewal__c lr = TestDataFactory.createLeaseRenewal(assetId(), true);
        Id deletedId = lr.Id;
        delete lr;

        Test.startTest();
        try {
            LeaseRenewalSelector.selectRequiredById(deletedId);
            Assert.fail('A renewal Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching renewal row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void selectForKpis_251Renewals_returnsAll() {
        TestDataFactory.createLeaseRenewals(251, assetId(), true);

        Test.startTest();
        List<Lease_Renewal__c> result = LeaseRenewalSelector.selectForKpis();
        Test.stopTest();

        Assert.areEqual(251, result.size(), 'selectForKpis should read all 251 renewals');
    }
}
