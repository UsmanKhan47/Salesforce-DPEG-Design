/**
 * Tests for `ReceivablesSummaryDomain` - the DTO to mirror-row mapping.
 *
 * NO DML anywhere. The domain is pure by construction, so the mapping - including every null rule -
 * is proved without touching the database. Unit records are built in memory with a fake Id so even
 * the join can be exercised without an insert.
 *
 * `.claude/rules/bulk-test-rule.md`: `toRecords` DOES take a collection, so a volume test is
 * warranted and is included at 251 rows. It performs no DML and no SOQL, so 251 costs nothing and
 * proves the mapping loop has no per-row query hiding in it.
 */
@isTest
private class ReceivablesSummaryDomainTest {

    private static final DateTime FEED_AS_OF = DateTime.newInstanceGmt(2026, 8, 22, 2, 0, 0);

    /**
     * @param yardiUnitId The external id to key on.
     * @return An in-memory Unit with a fake Id and a fake master, so no DML is needed.
     */
    private static Unit__c fakeUnit(String yardiUnitId) {
        return new Unit__c(
            Id = fakeId(Unit__c.SObjectType, 1),
            Yardi_Unit_Id__c = yardiUnitId,
            Property_Asset__c = fakeId(Property_Asset__c.SObjectType, 2),
            Tenant_Name__c = 'Unit Tenant',
            Current_Monthly_Rent__c = 4321
        );
    }

    /**
     * @param sobjectType The type to mint an Id for.
     * @param index       A per-type counter.
     * @return A syntactically valid, non-existent Id.
     */
    private static Id fakeId(Schema.SObjectType sobjectType, Integer index) {
        return Id.valueOf(sobjectType.getDescribe().getKeyPrefix()
            + '0'.repeat(12 - String.valueOf(index).length()) + index);
    }

    @isTest
    static void shouldMapEveryFinancialField_WhenFeedIsComplete() {
        ReceivablesFeedDTO row = new ReceivablesFeedDTO();
        row.yardiArId = 'AR-1';
        row.yardiUnitId = 'YU-1';
        row.tenantName = 'Feed Tenant';
        row.monthlyRent = 5000;
        row.totalOutstanding = 15000;
        row.baseRentOutstanding = 12000;
        row.nnnCamOutstanding = 2000;
        row.lateFeeOutstanding = 900;
        row.otherOutstanding = 100;
        row.currentAmount = 0;
        row.aging1To30 = 1000;
        row.aging31To60 = 2000;
        row.aging61To90 = 3000;
        row.aging90Plus = 9000;
        row.daysPastDue = 118;

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            new List<ReceivablesFeedDTO>{ row },
            new Map<String, Unit__c>{ 'YU-1' => fakeUnit('YU-1') },
            new Map<String, Id>(), null, FEED_AS_OF);

        Assert.areEqual(1, mapped.size(), 'One feed row maps to one mirror row');
        Receivables_Summary__c summary = mapped[0];
        Assert.areEqual('AR-1', summary.Yardi_AR_Id__c, 'The upsert key must carry through');
        Assert.areEqual('Feed Tenant', summary.Tenant_Name__c, 'The feed label wins over the unit');
        Assert.areEqual(15000, summary.Total_Outstanding_Amount__c, 'Total must map');
        Assert.areEqual(12000, summary.Base_Rent_Outstanding_Amount__c, 'Base rent must map');
        Assert.areEqual(2000, summary.NNN_CAM_Outstanding_Amount__c, 'CAM must map');
        Assert.areEqual(900, summary.Late_Fee_Outstanding_Amount__c, 'Late fee must map');
        Assert.areEqual(100, summary.Other_Outstanding_Amount__c, 'Other must map');
        Assert.areEqual(9000, summary.Aging_90_Plus_Amount__c, 'The 90+ bucket must map');
        Assert.areEqual(118, summary.Days_Past_Due__c, 'Aging must map');
    }

    @isTest
    static void shouldStampTheFeedClock_NotSalesforceClock() {
        // Stamping System.now() would make a three-day-old feed LOOK fresh on screen - the exact
        // deception the health check exists to prevent, reproduced on the UI (FSD section 4).
        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            ReceivablesTestData.feedRows(1, null, 100, 10),
            null, null, null, FEED_AS_OF);

        Assert.areEqual(FEED_AS_OF, mapped[0].Yardi_Last_Synced_DateTime__c,
            'Last-synced must carry the FEED clock so a stale feed looks stale to a human too');
    }

    @isTest
    static void shouldDeriveThePropertyAsset_FromTheMatchedUnit() {
        // Property_Asset__c has no external id in this org, so the master of the matched Unit is the
        // only route to it.
        Unit__c unit = fakeUnit('YU-9');
        List<ReceivablesFeedDTO> rows = ReceivablesTestData.feedRows(1, 'YU-9', 500, 30);

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            rows, new Map<String, Unit__c>{ 'YU-9' => unit }, null, null, FEED_AS_OF);

        Assert.areEqual(unit.Id, mapped[0].Unit__c, 'The unit join must resolve');
        Assert.areEqual(unit.Property_Asset__c, mapped[0].Property_Asset__c,
            'The property asset must be derived from the unit master, not from the feed');
    }

    @isTest
    static void shouldLeaveLookupsNull_WhenUnitDoesNotMatch() {
        // An unmatched unit is a data problem to see in a report, not a reason to drop the row.
        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            ReceivablesTestData.feedRows(1, 'YU-DOES-NOT-EXIST', 500, 30),
            new Map<String, Unit__c>(), null, null, FEED_AS_OF);

        Assert.areEqual(1, mapped.size(), 'The row must still land');
        Assert.isNull(mapped[0].Unit__c, 'An unmatched unit leaves the lookup null');
        Assert.isNull(mapped[0].Property_Asset__c, 'And therefore leaves the property null');
    }

    @isTest
    static void shouldFallBackToUnitRent_WhenFeedOmitsMonthlyRent() {
        // OQ-3. A fallback to the OTHER Yardi mirror of the same fact, never to an invented number.
        ReceivablesFeedDTO row = new ReceivablesFeedDTO();
        row.yardiArId = 'AR-2';
        row.yardiUnitId = 'YU-2';
        row.monthlyRent = null;
        row.totalOutstanding = 8000;

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            new List<ReceivablesFeedDTO>{ row },
            new Map<String, Unit__c>{ 'YU-2' => fakeUnit('YU-2') },
            null, null, FEED_AS_OF);

        Assert.areEqual(4321, mapped[0].Monthly_Rent__c,
            'A missing feed rent must fall back to the unit rent so Months_Outstanding__c still works');
    }

    @isTest
    static void shouldLeaveRentNull_WhenNeitherSourceHasIt() {
        ReceivablesFeedDTO row = new ReceivablesFeedDTO();
        row.yardiArId = 'AR-3';
        row.monthlyRent = null;
        row.totalOutstanding = 8000;

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            new List<ReceivablesFeedDTO>{ row }, null, null, null, FEED_AS_OF);

        Assert.isNull(mapped[0].Monthly_Rent__c,
            'With no denominator anywhere the field must stay NULL - a zero would corrupt the '
            + 'months-of-rent ranking rather than blank it');
    }

    @isTest
    static void shouldPreserveNulls_WhenFeedOmitsAmounts() {
        ReceivablesFeedDTO row = new ReceivablesFeedDTO();
        row.yardiArId = 'AR-4';

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            new List<ReceivablesFeedDTO>{ row }, null, null, null, FEED_AS_OF);

        Assert.isNull(mapped[0].Total_Outstanding_Amount__c,
            'A null total must stay null - a zero reads as "the tenant paid up" and auto-closes a '
            + 'live Case');
        Assert.isNull(mapped[0].Days_Past_Due__c, 'A null aging must stay null');
        Assert.isNull(mapped[0].Aging_90_Plus_Amount__c, 'A null bucket must stay null');
    }

    @isTest
    static void shouldFallBackToUnitTenantName_WhenFeedOmitsIt() {
        ReceivablesFeedDTO row = new ReceivablesFeedDTO();
        row.yardiArId = 'AR-5';
        row.yardiUnitId = 'YU-5';
        row.tenantName = null;

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            new List<ReceivablesFeedDTO>{ row },
            new Map<String, Unit__c>{ 'YU-5' => fakeUnit('YU-5') }, null, null, FEED_AS_OF);

        Assert.areEqual('Unit Tenant', mapped[0].Tenant_Name__c,
            'Tenant identity is a STRING in this org and the rankings group on it, so it is worth '
            + 'falling back rather than leaving blank');
    }

    @isTest
    static void shouldResolveManagerCaseInsensitively() {
        ReceivablesFeedDTO row = new ReceivablesFeedDTO();
        row.yardiArId = 'AR-6';
        row.responsiblePropertyManagerUsername = 'MixedCase@Dpeg.Com';
        Id managerId = fakeId(User.SObjectType, 7);

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            new List<ReceivablesFeedDTO>{ row }, null,
            new Map<String, Id>{ 'mixedcase@dpeg.com' => managerId }, null, FEED_AS_OF);

        Assert.areEqual(managerId, mapped[0].Responsible_Property_Manager__c,
            'Username matching must be case-insensitive or every Case lands unowned');
    }

    @isTest
    static void shouldLeaveManagerNull_WhenUsernameDoesNotResolve() {
        ReceivablesFeedDTO row = new ReceivablesFeedDTO();
        row.yardiArId = 'AR-7';
        row.responsiblePropertyManagerUsername = 'ghost@dpeg.com';

        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            new List<ReceivablesFeedDTO>{ row }, null, new Map<String, Id>(), null, FEED_AS_OF);

        Assert.isNull(mapped[0].Responsible_Property_Manager__c,
            'An unresolvable manager must leave the lookup null rather than guessing an owner');
    }

    @isTest
    static void shouldReturnEmpty_WhenInputIsNull() {
        Assert.areEqual(0, ReceivablesSummaryDomain.toRecords(null, null, null, null, null).size(),
            'Null input returns an empty list, never null');
        Assert.areEqual(0, ReceivablesSummaryDomain.collectUnitKeys(null).size(),
            'Null input returns an empty set');
        Assert.areEqual(0, ReceivablesSummaryDomain.collectManagerUsernames(null).size(),
            'Null input returns an empty set');
    }

    @isTest
    static void shouldCollectDistinctKeys_WhenRowsRepeatAndOmit() {
        List<ReceivablesFeedDTO> rows = new List<ReceivablesFeedDTO>();
        for (Integer i = 0; i < 3; i++) {
            ReceivablesFeedDTO row = new ReceivablesFeedDTO();
            row.yardiArId = 'AR-' + i;
            row.yardiUnitId = 'YU-SHARED';
            row.responsiblePropertyManagerUsername = 'pm@dpeg.com';
            rows.add(row);
        }
        ReceivablesFeedDTO blankRow = new ReceivablesFeedDTO();
        blankRow.yardiArId = 'AR-blank';
        rows.add(blankRow);

        Assert.areEqual(1, ReceivablesSummaryDomain.collectUnitKeys(rows).size(),
            'Repeated keys must collapse and blanks must be skipped - this is what keeps the join to '
            + 'ONE query regardless of row count');
        Assert.areEqual(1, ReceivablesSummaryDomain.collectManagerUsernames(rows).size(),
            'Repeated usernames must collapse');
    }

    @isTest
    static void shouldMapAtVolume_WhenFeedCarries251Rows() {
        List<ReceivablesFeedDTO> rows = ReceivablesTestData.feedRows(251, 'YU-VOL', 9000, 95);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Receivables_Summary__c> mapped = ReceivablesSummaryDomain.toRecords(
            rows, new Map<String, Unit__c>{ 'YU-VOL' => fakeUnit('YU-VOL') },
            new Map<String, Id>(), null, FEED_AS_OF);
        Integer queriesSpent = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(251, mapped.size(), 'Every one of 251 rows must map');
        Assert.areEqual(0, queriesSpent,
            'The mapping loop must cost ZERO queries at any volume - a per-row query here would be '
            + 'invisible at small N and fatal at production scale');
    }
}
