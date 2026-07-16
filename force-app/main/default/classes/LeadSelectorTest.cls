/**
 * Tests for LeadSelector.selectByIdsSystem (SYSTEM_MODE guest/automation read
 * backing BrokerPortalNotifier). Covers the 251-record bulk path plus the
 * null/empty-input contract. Factory-based per ARCHITECTURE.md §2; 251-record
 * bulk per .claude/rules/bulk-test-rule.md.
 */
@isTest
private class LeadSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectByIdsSystem_bulk_returnsAll() {
        // Build 251 Leads unsaved, then insert with duplicate rules bypassed — a
        // 251-record standard-object insert can otherwise trip an org duplicate rule
        // (guardrail from prior modules). The factory already makes Company/Email
        // unique, so this is defence-in-depth.
        List<Lead> leads = TestDataFactory.createLeads(BULK_N, false);
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(leads, dml);
        Set<Id> leadIds = new Map<Id, Lead>(leads).keySet();

        Test.startTest();
        List<Lead> result = LeadSelector.selectByIdsSystem(leadIds);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 Leads for the Id set');
        Assert.isNotNull(result[0].Company, 'Company must be populated for the notification body');
        Assert.isNotNull(result[0].Name, 'Name must be populated for the notification body');
    }

    @isTest
    static void selectByIdsSystem_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Lead> nullResult = LeadSelector.selectByIdsSystem(null);
        List<Lead> emptyResult = LeadSelector.selectByIdsSystem(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }
}
