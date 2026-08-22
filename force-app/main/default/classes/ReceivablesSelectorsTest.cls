/**
 * Tests for the five receivables selectors, and above all for THE DUPLICATE-CASE GUARD.
 *
 * ==========================================================================================
 * `shouldSeeCaseOwnedByAnotherUser_WhenRunningAsMinimumAccessUser` IS THE TEST THAT MATTERS
 * ==========================================================================================
 * `Case` OWD in this org is PRIVATE. `WITH SYSTEM_MODE` lifts CRUD and FLS and NEVER lifts sharing.
 * A sharing-filtered guard read does not disable the feature - it INVERTS it into a duplicate-maker,
 * because "I cannot see your open Case" is indistinguishable from "there is no open Case", and the
 * caller responds by opening another one. Every night. Silently, because the DML is
 * `allOrNone = false`.
 *
 * MUTATION-CHECK THIS TEST RATHER THAN TRUSTING IT: delete `without sharing` from
 * `CaseSelector.GuardReads` and confirm this method FAILS. If it still passes, the test is proving
 * nothing and the guard is unprotected.
 *
 * WHY THE PROFILE IS `Minimum Access - Salesforce` AND NOT `Standard User`: `Case` is a STANDARD
 * object, and `Standard User` already grants Case read. A Standard-User-based test would pass with
 * the escape removed, which is the exact way this class of test goes quietly vacuous.
 *
 * `.claude/rules/bulk-test-rule.md`: these are SELECTOR READS. A query has no batch chunking, so
 * behaviour at 251 rows is identical to behaviour at 20 - the 251 mandate exists to force a SECOND
 * trigger-batch firing, which does not apply. Volume here is kept small deliberately.
 */
@isTest
private class ReceivablesSelectorsTest {

    private static final String STATUS_IDENTIFIED = 'Identified';

    /**
     * @return A running user on Minimum Access with no delinquency data of their own.
     */
    private static User minimumAccessUser() {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        String unique = String.valueOf(DateTime.now().getTime());
        return new User(
            ProfileId = minimumAccess.Id,
            LastName = 'ArGuard',
            Email = 'ar.guard' + unique + '@dpeg.invalid',
            Username = 'ar.guard' + unique + '@dpeg.invalid',
            Alias = 'arg',
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    // ── THE GUARD ────────────────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldSeeCaseOwnedByAnotherUser_WhenRunningAsMinimumAccessUser() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> cases =
            ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        Set<String> arKeys = new Set<String>{ summaries[0].Yardi_AR_Id__c };

        User otherUser = minimumAccessUser();
        insert otherUser;

        List<Case> found;
        Test.startTest();
        System.runAs(otherUser) {
            // This user owns nothing, has Minimum Access, and can see no Case through sharing.
            found = CaseSelector.selectOpenDelinquencyByArKeys(arKeys);
        }
        Test.stopTest();

        Assert.areEqual(1, found.size(),
            'THE GUARD MUST SEE A CASE IT DOES NOT OWN. If this is 0, the sync will open a SECOND '
            + 'open Case for this tenant every single night, silently.');
        Assert.areEqual(cases[0].Id, found[0].Id, 'And it must be the right Case');
    }

    @isTest
    static void shouldNotReturnClosedCases_WhenGuardRuns() {
        // Case.Yardi_AR_Id__c is deliberately NOT unique: closed Cases accumulate per tenant, and a
        // unique index would refuse the second-ever Case for a tenant who re-delinquents. The guard
        // must therefore filter on IsClosed rather than assume one row per key.
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> cases = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        update new Case(Id = cases[0].Id, Status = 'Resolved');

        List<Case> found = CaseSelector.selectOpenDelinquencyByArKeys(
            new Set<String>{ summaries[0].Yardi_AR_Id__c });

        Assert.areEqual(0, found.size(),
            'A resolved Case must not block a genuinely re-delinquenting tenant from getting a new one');
    }

    @isTest
    static void shouldReturnEmpty_WhenGuardGivenNoKeys() {
        Assert.areEqual(0, CaseSelector.selectOpenDelinquencyByArKeys(null).size(),
            'Null keys must short-circuit without a query');
        Assert.areEqual(0, CaseSelector.selectOpenDelinquencyByArKeys(new Set<String>()).size(),
            'Empty keys must short-circuit without a query');
    }

    @isTest
    static void shouldCostOneQuery_WhenGuardChecksManyKeys() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(20, null, null, 9000, 95, null, true);
        ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        Set<String> arKeys = new Set<String>();
        for (Receivables_Summary__c summary : summaries) {
            arKeys.add(summary.Yardi_AR_Id__c);
        }

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Case> found = CaseSelector.selectOpenDelinquencyByArKeys(arKeys);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(20, found.size(), 'Every open Case must be found');
        Assert.areEqual(1, spent,
            'The guard must be ONE query for the whole chunk - a per-row guard would break at 200');
    }

    // ── The alert reads ──────────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldFindStaleCase_WhenNextFollowUpDateHasPassed() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> cases = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        update new Case(Id = cases[0].Id, Next_Follow_Up_Date__c = Date.today().addDays(-3));

        List<Case> stale = CaseSelector.selectStaleFollowUp(Date.today(), 7, 100);

        Assert.areEqual(1, stale.size(),
            'A missed promised follow-up date must be caught by the first arm');
    }

    @isTest
    static void shouldFindStaleCase_WhenNoFollowUpRecordedInWindow() {
        // The more common failure: a PM who never set a date at all. Keying only on
        // Next_Follow_Up_Date__c would miss most of them.
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> cases = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        update new Case(Id = cases[0].Id,
            Last_Follow_Up_DateTime__c = System.now().addDays(-30));

        List<Case> stale = CaseSelector.selectStaleFollowUp(Date.today(), 7, 100);

        Assert.areEqual(1, stale.size(), 'A long-silent Case must be caught by the second arm');
    }

    @isTest
    static void shouldReturnEmpty_WhenStaleDaysIsUnconfigured() {
        Assert.areEqual(0, CaseSelector.selectStaleFollowUp(Date.today(), null, 100).size(),
            'An unconfigured stale-follow-up window disables the alert rather than defaulting');
        Assert.areEqual(0, CaseSelector.selectStaleFollowUp(null, 7, 100).size(),
            'A null as-of date short-circuits');
    }

    @isTest
    static void shouldFindWriteOff_WhenRequestedAndUndecided() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> cases = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        update new Case(Id = cases[0].Id,
            Write_Off_Requested__c = true,
            Write_Off_Requested_Amount__c = 9000,
            Write_Off_Decision__c = 'Pending');

        List<Case> awaiting = CaseSelector.selectWriteOffAwaitingDecision(100);

        Assert.areEqual(1, awaiting.size(), 'A pending write-off must be routable to the principals');
    }

    @isTest
    static void shouldNotFindWriteOff_WhenAlreadyDecided() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> cases = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        update new Case(Id = cases[0].Id,
            Write_Off_Requested__c = true, Write_Off_Decision__c = 'Approved');

        Assert.areEqual(0, CaseSelector.selectWriteOffAwaitingDecision(100).size(),
            'A decided write-off must stop appearing in the queue');
    }

    @isTest
    static void shouldReturnCasesByIds_WhenReopeningIsNeeded() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(2, null, null, 9000, 95, null, true);
        List<Case> cases = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);

        List<Case> found = CaseSelector.selectByIds(new Map<Id, Case>(cases).keySet());

        Assert.areEqual(2, found.size(), 'Both Cases must come back');
        Assert.areEqual(0, CaseSelector.selectByIds(null).size(), 'Null input short-circuits');
    }

    // ── The mirror selector ──────────────────────────────────────────────────────────────────────

    @isTest
    static void shouldFindMirrorRows_ByYardiArId() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(3, null, null, 5000, 40, null, true);
        Set<String> keys = new Set<String>();
        for (Receivables_Summary__c summary : summaries) {
            keys.add(summary.Yardi_AR_Id__c);
        }

        Assert.areEqual(3, ReceivablesSummarySelector.selectByYardiArIds(keys).size(),
            'All three mirror rows must be found by external id');
        Assert.areEqual(0, ReceivablesSummarySelector.selectByYardiArIds(null).size(),
            'Null input short-circuits');
        Assert.areEqual(3,
            ReceivablesSummarySelector.selectByIds(new Map<Id, Receivables_Summary__c>(summaries).keySet()).size(),
            'And by Id');
        Assert.areEqual(0, ReceivablesSummarySelector.selectByIds(null).size(),
            'Null input short-circuits');
    }

    @isTest
    static void shouldScopeLifecycleLocator_ToThisRunOnly() {
        // The stated residual: a tenant absent from tonight's feed is NOT selected, so their Case is
        // never auto-closed on missing data. That is the safe direction and it is deliberate.
        Sync_Run__c thisRun = ReceivablesTestData.syncRun('Running', 2, true);
        Sync_Run__c priorRun = ReceivablesTestData.syncRun('Completed', 2, true);
        ReceivablesTestData.summaries(2, null, null, 5000, 40, thisRun.Id, true);
        ReceivablesTestData.summaries(3, null, null, 5000, 40, priorRun.Id, true);

        List<Receivables_Summary__c> selected = new List<Receivables_Summary__c>();
        Database.QueryLocator locator = ReceivablesSummarySelector.queryLifecycleLocator(thisRun.Id);
        Database.QueryLocatorIterator iterator = locator.iterator();
        while (iterator.hasNext()) {
            selected.add((Receivables_Summary__c) iterator.next());
        }

        Assert.areEqual(2, selected.size(),
            'The locator must select only the rows THIS run wrote, not last night s');
    }

    // ── Sync run, commitments, users, static resource ────────────────────────────────────────────

    @isTest
    static void shouldReturnLatestCompletedRun_IgnoringHaltedOnes() {
        // A halted run's row count is by definition a number nobody trusted. Letting it become the
        // baseline would wedge the job shut: one truncated feed halts, then the next healthy feed
        // looks like a huge change against the truncated baseline and halts too.
        Sync_Run__c completed = ReceivablesTestData.syncRun('Completed', 480, true);
        Sync_Run__c halted = ReceivablesTestData.syncRun('Halted', 3, true);

        Sync_Run__c baseline = SyncRunSelector.selectLastCompleted();

        Assert.isNotNull(baseline, 'A completed run must be found');
        Assert.areEqual(480, baseline.Row_Count__c,
            'The baseline must be the COMPLETED run, never the halted one');
        Assert.areEqual(completed.Id, baseline.Id, 'And it must be that exact row');
        Assert.isNotNull(SyncRunSelector.selectById(halted.Id), 'selectById must find any run');
        Assert.isNull(SyncRunSelector.selectById(null), 'Null Id short-circuits');
    }

    @isTest
    static void shouldReturnNullBaseline_WhenNoRunHasEverCompleted() {
        ReceivablesTestData.syncRun('Halted', 3, true);

        Assert.isNull(SyncRunSelector.selectLastCompleted(),
            'No baseline is a valid answer for a first run and must disable the change arm, not halt');
    }

    @isTest
    static void shouldFindOverdueCommitments_AndIgnoreFutureOnes() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        List<Case> cases = ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true);
        ReceivablesTestData.commitments(2, cases[0].Id, 'Promise to Pay', Date.today().addDays(-1), true);
        ReceivablesTestData.commitments(1, cases[0].Id, 'Promise to Pay', Date.today().addDays(30), true);

        List<Payment_Commitment__c> overdue =
            PaymentCommitmentSelector.selectOpenDueOnOrBefore(Date.today(), 100);

        Assert.areEqual(2, overdue.size(), 'Only the overdue commitments must be swept');
        Assert.isNotNull(overdue[0].Case__r, 'The parent Case fields must be available to the sweep');
        Assert.areEqual(0, PaymentCommitmentSelector.selectOpenDueOnOrBefore(null, 100).size(),
            'Null as-of short-circuits');
        Assert.areEqual(3,
            PaymentCommitmentSelector.selectByCaseIds(new Map<Id, Case>(cases).keySet()).size(),
            'selectByCaseIds must return every commitment regardless of status');
        Assert.areEqual(0, PaymentCommitmentSelector.selectByCaseIds(null).size(),
            'Null input short-circuits');
    }

    @isTest
    static void shouldResolveUsernames_CaseInsensitively() {
        User running = [SELECT Id, Username FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];

        Map<String, Id> resolved = UserSelector.selectActiveByUsernames(
            new Set<String>{ running.Username.toUpperCase() });

        Assert.areEqual(running.Id, resolved.get(running.Username.toLowerCase()),
            'Usernames must match case-insensitively or every Case lands unowned');
        Assert.areEqual(0, UserSelector.selectActiveByUsernames(null).size(), 'Null short-circuits');
        Assert.areEqual(0, UserSelector.selectActiveByUsernames(new Set<String>{ '  ' }).size(),
            'Blank usernames are skipped without a query');
    }

    @isTest
    static void shouldReadStaticResourceBody_WhenResourceExists() {
        String body = StaticResourceSelector.selectBodyByName('Receivables_Feed_Sample');

        Assert.isNotNull(body, 'The deployed fixture must be readable');
        Assert.isTrue(body.contains('yardiArId'), 'And must be the receivables feed payload');
        Assert.isNull(StaticResourceSelector.selectBodyByName('NoSuchResource'),
            'A missing resource returns null, which the stub turns into a recorded halt');
        Assert.isNull(StaticResourceSelector.selectBodyByName(null), 'Blank name short-circuits');
    }

    @isTest
    static void shouldResolveUnitsByYardiId_WhenTheyExist() {
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;
        List<Unit__c> units = TestDataFactory.createUnits(2, assetId, true);
        Set<String> keys = new Set<String>();
        for (Unit__c unit : units) {
            keys.add(unit.Yardi_Unit_Id__c);
        }

        Map<String, Unit__c> resolved = ReceivablesUnitSelector.selectByYardiUnitIds(keys);

        Assert.areEqual(2, resolved.size(), 'Both units must resolve by external id');
        Assert.areEqual(assetId, resolved.get(units[0].Yardi_Unit_Id__c).Property_Asset__c,
            'The master property asset must come back - it is the only route to the property');
        Assert.areEqual(0, ReceivablesUnitSelector.selectByYardiUnitIds(null).size(),
            'Null input short-circuits');
    }
}
