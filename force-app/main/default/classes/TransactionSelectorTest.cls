/**
 * Tests for TransactionSelector (P4, Module C — Transactions).
 *
 * Covers selectByIdsWithConditionFields:
 *   - base fields + a valid, describe-resolved condition field are selected and
 *     readable via SObject.get (the exact access TaskFanoutService performs);
 *   - a bogus condition field is skipped, not injected — the query still succeeds
 *     (the §6 defense-in-depth guarantee against a bad CMDT Condition_Field__c row);
 *   - null conditionFields still returns the base fields;
 *   - null/empty transactionIds short-circuit to an empty map;
 *   - a 251-record bulk read on the Set<Id> method (bulk-test-rule).
 *
 * Transactions are created with the fan-out Flow suppressed
 * (Contract_Executed_Date__c = null) so inserting them does not enqueue async
 * checklist work that the selector test does not care about. No default*()
 * accessor is used, so the @TestSetup scaffold-cache trap does not apply.
 *
 * @see force-app/main/default/classes/WireSelectorTest.cls (P4 pilot test template)
 * @see agent-output/p4-selector-design.md (§3 #15, §5, §6)
 */
@isTest
private class TransactionSelectorTest {

    private static final Integer BULK_N = 251;

    private static Transaction__c insertSuppressedTransaction(Boolean loanRequired) {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{
            'Contract_Executed_Date__c' => null,
            'Loan_Required__c' => loanRequired,
            'Tasks_Fanned_Out__c' => false
        });
        insert t;
        return t;
    }

    /**
     * Inserts `count` Transactions at the given Status__c with the Day-0 fan-out
     * suppressed (Contract_Executed_Date__c = null). Status__c is a restricted
     * picklist — only 'Draft' / 'Active' / 'Closed' are valid.
     */
    private static List<Transaction__c> insertSuppressed(Integer count, String status) {
        List<Transaction__c> txns = TestDataFactory.createTransactions(count, false);
        TestDataFactory.applyOverrides(txns, new Map<String, Object>{
            'Contract_Executed_Date__c' => null,
            'Status__c' => status
        });
        insert txns;
        return txns;
    }

    @isTest
    static void selectByIdsWithConditionFields_selectsBaseAndValidConditionField() {
        Transaction__c t = insertSuppressedTransaction(true);

        Test.startTest();
        Map<Id, Transaction__c> result = TransactionSelector.selectByIdsWithConditionFields(
            new Set<Id>{ t.Id }, new Set<String>{ 'Loan_Required__c' });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The single Transaction is returned keyed by Id');
        Transaction__c fetched = result.get(t.Id);
        Assert.isNotNull(fetched, 'The map is keyed by Transaction Id');
        Assert.areEqual(UserInfo.getUserId(), fetched.OwnerId, 'OwnerId base field is selected');
        Assert.areEqual(false, fetched.Tasks_Fanned_Out__c, 'Tasks_Fanned_Out__c base field is selected');
        Assert.areEqual(true, fetched.get('Loan_Required__c'),
            'The valid condition field is selected and readable via SObject.get — the access TaskFanoutService performs');
    }

    @isTest
    static void selectByIdsWithConditionFields_skipsInvalidConditionField() {
        Transaction__c t = insertSuppressedTransaction(false);

        Test.startTest();
        // A condition field that does not exist on Transaction__c must be dropped by
        // the describe allowlist, NOT concatenated into the SELECT (which would throw
        // a malformed-query exception). The query should still succeed and return the row.
        Map<Id, Transaction__c> result = TransactionSelector.selectByIdsWithConditionFields(
            new Set<Id>{ t.Id }, new Set<String>{ 'Definitely_Not_A_Real_Field__c' });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'A bogus condition field is skipped, so the query still succeeds and returns the Transaction');
        Assert.areEqual(t.Id, result.get(t.Id).Id, 'Base fields are still selected when the condition field is invalid');
    }

    @isTest
    static void selectByIdsWithConditionFields_nullConditionFields_returnsBaseFields() {
        Transaction__c t = insertSuppressedTransaction(false);

        Test.startTest();
        Map<Id, Transaction__c> result = TransactionSelector.selectByIdsWithConditionFields(
            new Set<Id>{ t.Id }, null);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'A null condition-field set still returns the Transaction with base fields');
        Assert.areEqual(UserInfo.getUserId(), result.get(t.Id).OwnerId, 'Base OwnerId is selected with no condition fields');
    }

    @isTest
    static void selectByIdsWithConditionFields_nullOrEmptyIds_returnsEmptyMap() {
        Test.startTest();
        Map<Id, Transaction__c> forNull = TransactionSelector.selectByIdsWithConditionFields(
            null, new Set<String>{ 'Loan_Required__c' });
        Map<Id, Transaction__c> forEmpty = TransactionSelector.selectByIdsWithConditionFields(
            new Set<Id>(), null);
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'Null ids short-circuit to an empty map, not null');
        Assert.areEqual(0, forEmpty.size(), 'Empty ids short-circuit to an empty map, not null');
    }

    @isTest
    static void selectByIdsWithConditionFields_bulk251_readsAllViaSetId() {
        List<Transaction__c> txns = TestDataFactory.createTransactions(251, false);
        TestDataFactory.applyOverrides(txns, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert txns;

        Set<Id> ids = new Set<Id>();
        for (Transaction__c t : txns) {
            ids.add(t.Id);
        }

        Test.startTest();
        Map<Id, Transaction__c> result = TransactionSelector.selectByIdsWithConditionFields(
            ids, new Set<String>{ 'Loan_Required__c' });
        Test.stopTest();

        Assert.areEqual(251, result.size(), 'All 251 Transactions are read in a single bulk Set<Id> query');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dashboard reads relocated from TransactionController (P4 cleanup wave)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectForKpis_returnsAllRowsRegardlessOfStatus() {
        insertSuppressed(2, 'Active');
        insertSuppressed(1, 'Closed');

        Test.startTest();
        List<Transaction__c> rows = TransactionSelector.selectForKpis();
        Test.stopTest();

        Assert.areEqual(3, rows.size(),
            'selectForKpis is unfiltered: the YTD missed-feasibility tile counts every Transaction, not just Active');
        for (Transaction__c t : rows) {
            Assert.isNotNull(t.Status__c, 'Status__c must be selected for the active-vs-all KPI branch');
            Assert.isNotNull(t.Contract_Value__c, 'Contract_Value__c must be selected for the in-contract-value tile');
        }
    }

    @isTest
    static void selectActiveForTaskSummary_returnsOnlyActive() {
        insertSuppressed(3, 'Active');
        insertSuppressed(2, 'Closed');

        Test.startTest();
        List<Transaction__c> rows = TransactionSelector.selectActiveForTaskSummary();
        Test.stopTest();

        Assert.areEqual(3, rows.size(),
            'Only the 3 Active Transactions are returned; the 2 Closed ones are filtered out');
    }

    @isTest
    static void selectActiveStages_returnsOnlyActiveWithStage() {
        insertSuppressed(3, 'Active');
        insertSuppressed(1, 'Closed');

        Test.startTest();
        List<Transaction__c> rows = TransactionSelector.selectActiveStages();
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'Only Active Transactions contribute to the stage donut');
        Assert.areEqual('Open Contract', rows[0].Stage__c, 'Stage__c must be selected for the donut count');
    }

    @isTest
    static void selectActiveRows_onlyActiveOrderedByName() {
        insertSuppressed(4, 'Active');
        insertSuppressed(2, 'Closed');

        Test.startTest();
        List<Transaction__c> rows = TransactionSelector.selectActiveRows();
        Test.stopTest();

        Assert.areEqual(4, rows.size(), 'Only Active Transactions appear in the row table');
        for (Integer i = 1; i < rows.size(); i++) {
            Assert.isTrue(rows[i - 1].Name <= rows[i].Name,
                'Rows must be ordered by Name ascending (ORDER BY Name)');
        }
        Assert.isNotNull(rows[0].Contract_Value__c, 'Contract_Value__c must be selected for the price column');
    }

    @isTest
    static void selectByOpportunityIds_returnsOnlyMatchingTransactions() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Transaction__c linked = TestDataFactory.createTransaction(opp.Id, null, false);
        Transaction__c unlinked = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(new List<Transaction__c>{ linked, unlinked },
            new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert new List<Transaction__c>{ linked, unlinked };

        Test.startTest();
        List<Transaction__c> rows =
            TransactionSelector.selectByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the Transaction on the supplied Opportunity is returned');
        Assert.areEqual(opp.Id, rows[0].Opportunity__c, 'Opportunity__c must be selected for the idempotency de-dup');
    }

    @isTest
    static void selectByOpportunityIds_nullOrEmpty_returnsEmptyList() {
        Test.startTest();
        List<Transaction__c> forNull = TransactionSelector.selectByOpportunityIds(null);
        List<Transaction__c> forEmpty = TransactionSelector.selectByOpportunityIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'Null opportunityIds short-circuit to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'Empty opportunityIds short-circuit to an empty list, not null');
    }

    @isTest
    static void selectByOpportunityIds_bulk251_readsAllViaSetId() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_N, true);
        List<Transaction__c> txns = new List<Transaction__c>();
        for (Opportunity o : opps) {
            txns.add(TestDataFactory.createTransaction(o.Id, null, false));
        }
        TestDataFactory.applyOverrides(txns, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert txns;

        Set<Id> oppIds = (new Map<Id, Opportunity>(opps)).keySet();

        Test.startTest();
        List<Transaction__c> rows = TransactionSelector.selectByOpportunityIds(oppIds);
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(),
            'All 251 Transactions are read by their parent Opportunity in a single bulk Set<Id> query');
    }
}
