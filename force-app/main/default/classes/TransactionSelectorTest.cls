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
}
