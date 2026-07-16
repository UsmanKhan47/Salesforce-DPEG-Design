/**
 * Tests for DealMessageSelector. Covers selectByParent (found ordered / 251-bulk /
 * null-recordId / unsupported-field guard). Factory-based per ARCHITECTURE.md §2;
 * 251-record bulk per .claude/rules/bulk-test-rule.md.
 */
@isTest
private class DealMessageSelectorTest {

    private static final Integer BULK_N = 251;

    private static LOI__c freshLoi() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        return TestDataFactory.createLoi(opp.Id, true);
    }

    @isTest
    static void selectByParent_loi_returnsMessagesWithFields() {
        LOI__c loi = freshLoi();
        TestDataFactory.createDealMessagesForLoi(3, loi.Id, true);

        Test.startTest();
        List<Deal_Message__c> result = DealMessageSelector.selectByParent('LOI__c', loi.Id);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'Should return every message logged against the LOI');
        Assert.isNotNull(result[0].Details__c, 'Details__c must be populated for the dealMessageLog LWC');
        Assert.isNotNull(result[0].CreatedBy.Name, 'CreatedBy.Name must be populated for the entered-by column');
    }

    @isTest
    static void selectByParent_bulk_returnsAll() {
        LOI__c loi = freshLoi();
        TestDataFactory.createDealMessagesForLoi(BULK_N, loi.Id, true);

        Test.startTest();
        List<Deal_Message__c> result = DealMessageSelector.selectByParent('LOI__c', loi.Id);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 messages for the LOI');
    }

    @isTest
    static void selectByParent_nullRecordId_returnsEmpty() {
        Test.startTest();
        List<Deal_Message__c> result = DealMessageSelector.selectByParent('LOI__c', null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null recordId returns an empty list, not null');
    }

    @isTest
    static void selectByParent_unsupportedField_throws() {
        LOI__c loi = freshLoi();

        Test.startTest();
        try {
            DealMessageSelector.selectByParent('Bogus_Field__c', loi.Id);
            Assert.fail('A non-allow-listed parent field must be rejected before the query');
        } catch (System.QueryException e) {
            Assert.isTrue(
                e.getMessage().contains('Bogus_Field__c'),
                'The rejection message should name the offending field'
            );
        }
        Test.stopTest();
    }
}
