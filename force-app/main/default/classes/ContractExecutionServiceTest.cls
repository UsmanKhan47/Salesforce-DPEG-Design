/**
 * Tests ContractExecutionService: marking the PSA Executed stamps the parent
 * Opportunity (Day 0), creates exactly ONE Transaction (arming the existing
 * Day-0 task fan-out), and never duplicates on re-execution.
 */
@isTest
private class ContractExecutionServiceTest {

    private static Contract_Review__c dealAtPsaNegotiation() {
        Opportunity o = new Opportunity(
            Name = 'Handoff Test', StageName = 'LOI Signed', CloseDate = Date.today().addDays(30)
        );
        insert o;
        // Entering PSA Negotiation auto-creates the Contract Review + Primary_Contract__c stamp.
        o.StageName = 'PSA Negotiation';
        update o;
        return [SELECT Id, Opportunity__c FROM Contract_Review__c WHERE Opportunity__c = :o.Id];
    }

    @isTest
    static void executionStampsOppAndOpensTransaction() {
        Contract_Review__c cr = dealAtPsaNegotiation();
        cr.Contract_Value__c = 12000000;
        update cr;

        Test.startTest();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        Opportunity o = [
            SELECT StageName, Contract_Signed__c, Contract_Executed_Date__c, Deal_Status__c, Deal_Bucket__c
            FROM Opportunity WHERE Id = :cr.Opportunity__c
        ];
        System.assertEquals('PSA Executed', o.StageName, 'Deal advances to PSA Executed');
        System.assert(o.Contract_Signed__c, 'Contract Signed stamped');
        System.assertNotEquals(null, o.Contract_Executed_Date__c, 'Day 0 stamped');
        System.assertEquals('Contract Signed', o.Deal_Status__c, 'Deal status stamped');
        System.assertEquals('PSA Executed/About to Close', o.Deal_Bucket__c, 'Tracker bucket follows');

        List<Transaction__c> txns = [
            SELECT Status__c, Stage__c, Contract_Value__c, Contract_Executed_Date__c
            FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c
        ];
        System.assertEquals(1, txns.size(), 'Exactly one Transaction created');
        System.assertEquals('Active', txns[0].Status__c, 'Transaction opens Active');
        System.assertEquals(12000000, txns[0].Contract_Value__c, 'Contract value carried over');
        System.assertNotEquals(null, txns[0].Contract_Executed_Date__c,
            'Executed date set on the Transaction - arms the Day-0 fan-out flow');

        // Contract Review itself synced by the before-save flow.
        cr = [SELECT Stage__c, Execution_Date__c FROM Contract_Review__c WHERE Id = :cr.Id];
        System.assertEquals('Contract Execution (Signed)', cr.Stage__c, 'CR stage synced');
        System.assertEquals(Date.today(), cr.Execution_Date__c, 'CR execution date stamped');
    }

    @isTest
    static void reExecutionNeverDuplicatesTheTransaction() {
        Contract_Review__c cr = dealAtPsaNegotiation();
        cr.Negotiation_Status__c = 'Executed';
        update cr;

        Test.startTest();
        cr.Negotiation_Status__c = 'Revised';
        update cr;
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c],
            'Re-executing must not open a second Transaction');
    }
}
