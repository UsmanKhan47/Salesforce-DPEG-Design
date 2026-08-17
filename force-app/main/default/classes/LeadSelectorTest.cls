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
 * insertable directly ('Converted' is a converted-flag status and cannot be set via
 * direct DML — it requires an actual lead conversion). selectRecent excludes converted
 * Leads (IsConverted = false), so selectRecent_excludesConvertedLeads produces a
 * converted Lead through Database.convertLead with a valid converted status (the same
 * standard-conversion recipe as LeadConvertServiceTest); every other test deliberately
 * avoids conversion. LeadSource tests use 'Web' rather than 'Broker
 * Portal' to avoid triggering the Broker_Portal_New_Lead_Notify after-save flow (an
 * unrelated dependency).
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
    static void selectRecent_excludesConvertedLeads() {
        // Bug fix: a converted Lead must NOT appear in the recent / review-queue list.
        // Salesforce always auto-redirects /lightning/r/Lead/{convertedId}/view to the
        // converted Contact, so a converted row is not clickable to a Lead. selectRecent
        // now filters WHERE IsConverted = false.
        //
        // IsConverted cannot be set via direct DML, so one Lead is converted through
        // Database.convertLead with a valid converted status — the same recipe as
        // LeadConvertServiceTest (a standard conversion that creates the Opportunity;
        // conversion adds no new Lead rows, so selectRecent still returns only the two
        // open leads).
        List<Lead> openLeads = TestDataFactory.createLeads(2, false);
        Lead toConvert = TestDataFactory.createLead(false);
        toConvert.LastName = 'Convertible';
        List<Lead> all = new List<Lead>(openLeads);
        all.add(toConvert);
        insertWithDupBypass(all);
        Set<Id> openIds = new Set<Id>{ openLeads[0].Id, openLeads[1].Id };

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(toConvert.Id);
        lc.setConvertedStatus(convertedStatus());

        Test.startTest();
        Database.LeadConvertResult res = Database.convertLead(lc);
        List<Lead> recent = LeadSelector.selectRecent(100);
        Test.stopTest();

        Assert.isTrue(res.isSuccess(), 'Lead conversion should succeed');
        Set<Id> recentIds = new Map<Id, Lead>(recent).keySet();
        Assert.areEqual(2, recent.size(), 'Only the two open leads surface; the converted lead is excluded');
        Assert.isTrue(recentIds.containsAll(openIds), 'Both open (non-converted) leads are present in the recent list');
        Assert.isFalse(recentIds.contains(toConvert.Id), 'The converted lead is excluded from the recent list');
    }

    /**
     * The 2026-08-17 widening: `Extraction_Score_Pct__c` is SELECTED, so `LeadFunnelController` can
     * carry it to the renamed 'Score' column.
     *
     * 🔴 THIS IS A "THE FIELD IS IN THE SELECT" TEST AND IT NEEDS A NON-NULL VALUE TO BE HONEST. A
     * queried-but-unset field and a NOT-queried field are indistinguishable through
     * `getPopulatedFieldsAsMap()` (it drops a null-valued queried field), and reading an unqueried
     * field throws `SObjectException` rather than returning null — so the only assertion that
     * discriminates is a stored value coming back intact. Dropping the field from the SELECT makes
     * this method throw, not merely return null.
     *
     * ⚠ It also pins that NULL SURVIVES AS NULL. Scoring is fail-soft by mandate, so "not scored" is a
     * real state the whole feature depends on; a selector that coalesced it would make the client's
     * neutral band unreachable.
     */
    @isTest
    static void selectRecent_selectsTheExtractionScoreAndKeepsNullAsNull() {
        List<Lead> leads = TestDataFactory.createLeads(2, false);
        leads[0].Extraction_Score_Pct__c = 78;
        leads[1].Extraction_Score_Pct__c = null; // not scored — NOT zero
        insertWithDupBypass(leads);

        Test.startTest();
        List<Lead> recent = LeadSelector.selectRecent(10);
        Test.stopTest();

        Map<Id, Lead> byId = new Map<Id, Lead>(recent);
        Assert.areEqual(2, byId.size(), 'Both open leads are returned');
        // `.intValue()` per the `Property_Count__c.intValue()` precedent in
        // PropertyPackageSelectorTest — an Integer literal against a Decimal-typed Number field is a
        // contested `Assert.areEqual` comparison in this codebase, and the field is Number(3,0).
        Assert.areEqual(78, byId.get(leads[0].Id).Extraction_Score_Pct__c.intValue(),
            'Extraction_Score_Pct__c is in the SELECT and its stored value round-trips — reading it '
            + 'would throw SObjectException if the field were dropped from the query');
        Assert.isNull(byId.get(leads[1].Id).Extraction_Score_Pct__c,
            'An unscored lead comes back NULL, never 0 — "not scored" is a meaningful state and the '
            + 'selector must not coalesce it');
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
    // GUEST DEDUP READ — GuestReads.selectOpenDuplicatesByAddressSystem
    //   (SYSTEM_MODE + without sharing)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Lives in the `without sharing` GuestReads inner class (all-records dedup,
    // preserving the original controller behavior); SYSTEM_MODE additionally bypasses
    // FLS. These tests run as the default (privileged) test user and prove the query
    // shape (address trim, Status NOT IN filter, blank guard). The guest
    // sharing/ownership model itself needs the P3 guest-sharing spike verified before
    // portal promotion (see the report).

    private static final Set<String> CLOSED_STATUSES = new Set<String>{ 'Converted', 'Disqualified' };
    private static final String DUP_ADDRESS = '123 Main St, Dallas TX';

    @isTest
    static void selectOpenDuplicatesByAddressSystem_openLeadAtAddress_returnsMatch() {
        Lead existing = TestDataFactory.createLead(false);
        existing.Property_Address__c = DUP_ADDRESS;
        existing.Status = 'New';
        existing.LeadSource = 'Web'; // not 'Broker Portal' -> avoids the notify flow
        insertWithDupBypass(new List<Lead>{ existing });

        Test.startTest();
        // Leading/trailing spaces prove the address is trimmed before binding.
        List<Lead> result =
            new LeadSelector.GuestReads().selectOpenDuplicatesByAddressSystem('  ' + DUP_ADDRESS + '  ', CLOSED_STATUSES);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'An open lead at the same address is returned (caller reads this as a duplicate)');
    }

    @isTest
    static void selectOpenDuplicatesByAddressSystem_closedLeadAtAddress_excluded() {
        Lead closed = TestDataFactory.createLead(false);
        closed.Property_Address__c = DUP_ADDRESS;
        closed.Status = 'Disqualified'; // in CLOSED_STATUSES -> excluded
        closed.LeadSource = 'Web';
        insertWithDupBypass(new List<Lead>{ closed });

        Test.startTest();
        List<Lead> result =
            new LeadSelector.GuestReads().selectOpenDuplicatesByAddressSystem(DUP_ADDRESS, CLOSED_STATUSES);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'A closed lead (Status NOT IN excluded) is not counted as a duplicate');
    }

    @isTest
    static void selectOpenDuplicatesByAddressSystem_differentAddress_returnsEmpty() {
        Lead existing = TestDataFactory.createLead(false);
        existing.Property_Address__c = '999 Elsewhere Ave';
        existing.Status = 'New';
        existing.LeadSource = 'Web';
        insertWithDupBypass(new List<Lead>{ existing });

        Test.startTest();
        List<Lead> result =
            new LeadSelector.GuestReads().selectOpenDuplicatesByAddressSystem(DUP_ADDRESS, CLOSED_STATUSES);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'No lead at the queried address returns an empty list');
    }

    @isTest
    static void selectOpenDuplicatesByAddressSystem_nullExcludedStatuses_treatedAsNoExclusions() {
        Lead existing = TestDataFactory.createLead(false);
        existing.Property_Address__c = DUP_ADDRESS;
        existing.Status = 'New';
        existing.LeadSource = 'Web';
        insertWithDupBypass(new List<Lead>{ existing });

        Test.startTest();
        List<Lead> result = new LeadSelector.GuestReads().selectOpenDuplicatesByAddressSystem(DUP_ADDRESS, null);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Null excludedStatuses is treated as no exclusions (no NPE), so the open lead matches');
    }

    @isTest
    static void selectOpenDuplicatesByAddressSystem_blankAddress_returnsEmpty() {
        Test.startTest();
        List<Lead> nullResult = new LeadSelector.GuestReads().selectOpenDuplicatesByAddressSystem(null, CLOSED_STATUSES);
        List<Lead> blankResult = new LeadSelector.GuestReads().selectOpenDuplicatesByAddressSystem('   ', CLOSED_STATUSES);
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null address returns an empty list, not null');
        Assert.isTrue(blankResult.isEmpty(), 'Blank address returns an empty list, not null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectMatchKeysByIds  (LeadConvertMatchService — Smart Lead Conversion, 2026-08-02)
    //
    // LeadConvertMatchServiceTest exercises this query end to end through
    // matchForConversion. These are the direct selector-level proofs of the field
    // contract and the null/empty short-circuit.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectMatchKeysByIds_returnsEmailAndCompany() {
        Lead l = TestDataFactory.createLead(false);
        l.Email = 'selector.matchkey@example.invalid';
        l.Company = 'Selector Match Key Co';
        insertWithDupBypass(new List<Lead>{ l });

        Test.startTest();
        List<Lead> rows = LeadSelector.selectMatchKeysByIds(new Set<Id>{ l.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The requested Lead should be returned');
        Assert.areEqual('selector.matchkey@example.invalid', rows[0].Email,
            'Email is selected — the Contact match key');
        Assert.areEqual('Selector Match Key Co', rows[0].Company,
            'Company is selected — the Account match key');
    }

    @isTest
    static void selectMatchKeysByIds_scopedToRequestedIds() {
        List<Lead> leads = TestDataFactory.createLeads(2, false);
        insertWithDupBypass(leads);

        Test.startTest();
        List<Lead> rows = LeadSelector.selectMatchKeysByIds(new Set<Id>{ leads[0].Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the requested Lead should be returned, not every Lead in the org');
        Assert.areEqual(leads[0].Id, rows[0].Id, 'The returned row should be the requested Lead');
    }

    @isTest
    static void selectMatchKeysByIds_nullOrEmptyInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Lead> forNull = LeadSelector.selectMatchKeysByIds(null);
        List<Lead> forEmpty = LeadSelector.selectMatchKeysByIds(new Set<Id>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null Id set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty Id set short-circuits to an empty list, not null');
        Assert.areEqual(0, after - before, 'Neither call should spend a query — the empty-set guard runs before the SOQL');
    }

    /**
     * Bulk-safety at data volume, per this repo's standing selector-layer convention —
     * independent of, and in addition to, the SERVICE-level 251 proof in
     * LeadConvertMatchServiceTest.matchForConversion_at251Leads_isBulkSafe.
     */
    @isTest
    static void selectMatchKeysByIds_251Leads_returnsAll() {
        List<Lead> leads = TestDataFactory.createLeads(BULK_N, false);
        insertWithDupBypass(leads);
        Set<Id> leadIds = new Map<Id, Lead>(leads).keySet();

        Test.startTest();
        List<Lead> rows = LeadSelector.selectMatchKeysByIds(leadIds);
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'All 251 requested Leads must be returned in one query');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /** Inserts `count` factory Leads (Status 'New') with duplicate rules bypassed. */
    private static void insertLeads(Integer count) {
        insertWithDupBypass(TestDataFactory.createLeads(count, false));
    }

    /** A valid converted Lead status label for this org (drives Database.convertLead). */
    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
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
