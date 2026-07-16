/**
 * Tests for LeadSelector.
 *
 * Covers the internal Lead-Funnel USER_MODE reads (countByStatus, countByLeadSource,
 * countConvertedInLastNDays, countDisqualifiedInLastNDays, selectRecent) added by the
 * P4 cleanup wave, plus the pre-existing SYSTEM_MODE guest read (selectByIdsSystem)
 * backing BrokerPortalNotifier.
 *
 * Factory-based per ARCHITECTURE.md §2; 251-record bulk on the collection-reading
 * methods per .claude/rules/bulk-test-rule.md. Lead inserts bypass the org duplicate
 * rule (Database.DMLOptions.DuplicateRuleHeader.AllowSave = true) — a 251-record
 * standard-object insert can otherwise trip a duplicate rule (guardrail from prior
 * modules; the factory already makes Company/Email unique, so this is defence in
 * depth). This org's Lead Status set is New / Under Review / Qualified / Converted /
 * Disqualified; there are no Lead validation rules, so Status 'Disqualified' is
 * insertable directly ('Converted' is a converted-flag status and is NOT set directly
 * — it requires lead conversion, which these tests deliberately avoid). LeadSource
 * tests use 'Web' rather than 'Broker Portal' to avoid triggering the
 * Broker_Portal_New_Lead_Notify after-save flow (an unrelated dependency).
 */
@isTest
private class LeadSelectorTest {

    private static final Integer BULK_N = 251;

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNNEL READS — WITH USER_MODE
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void countByStatus_bulk_groupsAllByStatus() {
        insertLeads(BULK_N); // factory default Status 'New'

        Test.startTest();
        Map<String, Integer> byStatus = aggCountMap(LeadSelector.countByStatus(), 'st');
        Test.stopTest();

        Assert.areEqual(BULK_N, byStatus.get('New'), 'All 251 leads count under the New status');
    }

    @isTest
    static void countByLeadSource_groupsBySourceExcludingNull() {
        // Use 'Web' (a valid LeadSource) rather than 'Broker Portal' on purpose:
        // the Broker_Portal_New_Lead_Notify after-save flow fires the
        // BrokerPortalNotifier Apex action for LeadSource='Broker Portal', which is
        // irrelevant to this selector and an avoidable dependency. 'Web' exercises
        // the same GROUP BY LeadSource / WHERE LeadSource != null behaviour.
        List<Lead> sourced = TestDataFactory.createLeads(10, false);
        for (Lead l : sourced) {
            l.LeadSource = 'Web';
        }
        List<Lead> unsourced = TestDataFactory.createLeads(4, false); // LeadSource left null
        List<Lead> all = new List<Lead>();
        all.addAll(sourced);
        all.addAll(unsourced);
        insertWithDupBypass(all);

        Test.startTest();
        Map<String, Integer> bySource = aggCountMap(LeadSelector.countByLeadSource(), 'ls');
        Test.stopTest();

        Assert.areEqual(10, bySource.get('Web'), 'All 10 sourced leads group under Web');
        Assert.isFalse(bySource.containsKey(null), 'Null-source leads are excluded by the WHERE clause');
    }

    @isTest
    static void countConvertedInLastNDays_noConversions_returnsZero() {
        insertLeads(10); // Status 'New', never converted -> ConvertedDate null

        Test.startTest();
        Integer count = LeadSelector.countConvertedInLastNDays(90);
        Test.stopTest();

        Assert.areEqual(0, count, 'No leads have been converted, so the 90-day converted count is 0');
    }

    @isTest
    static void countConvertedInLastNDays_nullOrNonPositive_returnsZero() {
        Test.startTest();
        Integer nullDays = LeadSelector.countConvertedInLastNDays(null);
        Integer zeroDays = LeadSelector.countConvertedInLastNDays(0);
        Test.stopTest();

        Assert.areEqual(0, nullDays, 'Null day-window short-circuits to 0 without querying');
        Assert.areEqual(0, zeroDays, 'Non-positive day-window short-circuits to 0 without querying');
    }

    @isTest
    static void countDisqualifiedInLastNDays_recentlyDisqualified_countsThem() {
        List<Lead> disqualified = TestDataFactory.createLeads(6, false);
        for (Lead l : disqualified) {
            l.Status = 'Disqualified';
        }
        insertWithDupBypass(disqualified); // LastModifiedDate == now -> inside the 90-day window
        insertLeads(3); // New leads must NOT be counted (proves the Status filter)

        Test.startTest();
        Integer count = LeadSelector.countDisqualifiedInLastNDays(90);
        Test.stopTest();

        Assert.areEqual(6, count, 'Only the 6 leads disqualified within 90 days are counted');
    }

    @isTest
    static void countDisqualifiedInLastNDays_nullOrNonPositive_returnsZero() {
        Test.startTest();
        Integer nullDays = LeadSelector.countDisqualifiedInLastNDays(null);
        Integer negDays = LeadSelector.countDisqualifiedInLastNDays(-1);
        Test.stopTest();

        Assert.areEqual(0, nullDays, 'Null day-window short-circuits to 0 without querying');
        Assert.areEqual(0, negDays, 'Negative day-window short-circuits to 0 without querying');
    }

    @isTest
    static void selectRecent_bulk_capsAtRowLimit() {
        insertLeads(BULK_N);

        Test.startTest();
        List<Lead> capped = LeadSelector.selectRecent(50);
        List<Lead> all = LeadSelector.selectRecent(BULK_N + 50);
        Test.stopTest();

        Assert.areEqual(50, capped.size(), 'Row cap of 50 is honoured across 251 leads');
        Assert.areEqual(BULK_N, all.size(), 'A cap above the row count returns every lead');
        Assert.isNotNull(capped[0].Status, 'Status must be populated for the funnel row');
        Assert.isNotNull(capped[0].Name, 'Name must be populated for the funnel row');
    }

    @isTest
    static void selectRecent_ordersByFirstSeenDateDesc() {
        // Explicit, distinct, non-null First_Seen_Date__c values so the ordering is
        // deterministic on the primary sort key. A null First_Seen_Date__c (the
        // NULLS LAST branch) is unreachable via DML here: the Lead_Intake_Stamp
        // before-save flow stamps First_Seen_Date__c = now whenever it is blank on
        // insert, so the ORDER BY's NULLS LAST is defensive-only in this org.
        List<Lead> leads = TestDataFactory.createLeads(3, false);
        DateTime base = DateTime.now();
        leads[0].First_Seen_Date__c = base.addDays(-2); // oldest
        leads[1].First_Seen_Date__c = base;             // newest
        leads[2].First_Seen_Date__c = base.addDays(-1); // middle
        insertWithDupBypass(leads);

        Test.startTest();
        List<Lead> recent = LeadSelector.selectRecent(10);
        Test.stopTest();

        Assert.areEqual(3, recent.size(), 'All three leads returned within the row cap');
        Assert.areEqual(leads[1].Id, recent[0].Id, 'Newest First Seen Date comes first');
        Assert.areEqual(leads[2].Id, recent[1].Id, 'Middle First Seen Date comes second');
        Assert.areEqual(leads[0].Id, recent[2].Id, 'Oldest First Seen Date comes last');
    }

    @isTest
    static void selectRecent_nullOrNonPositiveLimit_returnsEmpty() {
        insertLeads(3);

        Test.startTest();
        List<Lead> nullLimit = LeadSelector.selectRecent(null);
        List<Lead> zeroLimit = LeadSelector.selectRecent(0);
        List<Lead> negLimit = LeadSelector.selectRecent(-5);
        Test.stopTest();

        Assert.isTrue(nullLimit.isEmpty(), 'Null limit returns an empty list, not null');
        Assert.isTrue(zeroLimit.isEmpty(), 'Zero limit returns an empty list, not null');
        Assert.isTrue(negLimit.isEmpty(), 'Negative limit returns an empty list, not null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GUEST / AUTOMATION READ — WITH SYSTEM_MODE (unchanged)
    // ═══════════════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /** Inserts `count` factory Leads (Status 'New') with duplicate rules bypassed. */
    private static void insertLeads(Integer count) {
        insertWithDupBypass(TestDataFactory.createLeads(count, false));
    }

    /** Inserts pre-built Leads with the org duplicate rule bypassed. */
    private static void insertWithDupBypass(List<Lead> leads) {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(leads, dml);
    }

    /**
     * Collapses COUNT(Id) aggregate rows into a {keyValue -> count} map.
     *
     * @param rows     AggregateResult rows aliased `<keyAlias>` and `c`.
     * @param keyAlias The grouping-field alias ('st' for Status, 'ls' for LeadSource).
     * @return Map of grouping value to its count.
     */
    private static Map<String, Integer> aggCountMap(List<AggregateResult> rows, String keyAlias) {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (AggregateResult ar : rows) {
            counts.put((String) ar.get(keyAlias), (Integer) ar.get('c'));
        }
        return counts;
    }
}
