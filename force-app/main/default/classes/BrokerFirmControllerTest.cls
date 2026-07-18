/**
 * Tests BrokerFirmController.getBrokerFirm — the Opportunity record-page sidebar's
 * brokerage-firm summary (firm name, broker contact, firm-level deal counts).
 */
@isTest
private class BrokerFirmControllerTest {

    @isTest
    static void nullOpportunityId_returnsEmptyDefault() {
        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(null);
        Test.stopTest();

        System.assert(!bf.hasFirm, 'No firm for a null opportunityId');
        System.assertEquals(null, bf.firmName, 'firmName stays null');
        System.assertEquals(null, bf.brokerName, 'brokerName stays null');
        System.assertEquals(0, bf.dealsSubmitted, 'dealsSubmitted stays 0');
        System.assertEquals(0, bf.dealsWon, 'dealsWon stays 0');
        System.assertEquals(0, bf.dealsLost, 'dealsLost stays 0');
    }

    @isTest
    static void opportunityWithNoAccount_returnsEmptyDefault() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(opp.Id);
        Test.stopTest();

        System.assert(!bf.hasFirm, 'No Account behind the deal means no firm was found');
        System.assertEquals(null, bf.firmName, 'firmName stays null when there is no firm');
        System.assertEquals(0, bf.dealsSubmitted, 'dealsSubmitted stays 0 for the no-Account branch');
    }

    @isTest
    static void firmWithNoBrokerContact_countsDealsAcrossStagesWithoutBrokerName() {
        Account firm = TestDataFactory.createAccount(true);
        // No Contact created under this Account: the earliest-Contact lookup returns null.
        Opportunity target = TestDataFactory.createOpportunity(firm.Id, true); // default 'New' stage
        Opportunity won1 = TestDataFactory.createOpportunity(firm.Id, false);
        won1.StageName = 'Closed Won';
        Opportunity won2 = TestDataFactory.createOpportunity(firm.Id, false);
        won2.StageName = 'Closed Won';
        Opportunity lost = TestDataFactory.createOpportunity(firm.Id, false);
        lost.StageName = 'Dead/Pass';
        insert new List<Opportunity>{ won1, won2, lost };

        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(target.Id);
        Test.stopTest();

        System.assert(bf.hasFirm, 'An Account behind the deal means a firm was found');
        System.assertEquals(firm.Name, bf.firmName, 'firmName mirrors the Account name');
        System.assertEquals(null, bf.brokerName, 'No Contact under the Account leaves brokerName null');
        System.assertEquals(4, bf.dealsSubmitted, 'All 4 opportunities under the firm are counted');
        System.assertEquals(2, bf.dealsWon, 'The two Closed Won opportunities are counted as won');
        System.assertEquals(1, bf.dealsLost, 'The one Dead/Pass opportunity is counted as lost');
    }

    @isTest
    static void firmWithBrokerContact_returnsEarliestContactName() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createContact(firm.Id, true);
        Opportunity opp = TestDataFactory.createOpportunity(firm.Id, true);

        // Contact.Name is a compound field the platform computes server-side; the
        // in-memory `broker` from the DML insert above never has it populated
        // locally, so it must be re-queried to get the real value.
        broker = [SELECT Id, Name FROM Contact WHERE Id = :broker.Id];

        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(opp.Id);
        Test.stopTest();

        System.assert(bf.hasFirm, 'Firm should be found');
        System.assertEquals(broker.Name, bf.brokerName, 'brokerName mirrors the Contact under the firm Account');
        System.assertEquals(1, bf.dealsSubmitted, 'One opportunity submitted under this firm');
        System.assertEquals(0, bf.dealsWon, 'No Closed Won opportunities yet');
        System.assertEquals(0, bf.dealsLost, 'No Dead/Pass opportunities yet');
    }

    /**
     * Bulk scenario per .claude/rules/bulk-test-rule.md's controller carve-out
     * (single Id in, so no 251-sequential-call loop): a brokerage firm can
     * legitimately accumulate hundreds of Opportunities over its lifetime, and
     * getBrokerFirm's GROUP BY aggregate must scale to that in ONE call.
     */
    @isTest
    static void firmWith251Opportunities_aggregatesAcrossAllOfThem() {
        Account firm = TestDataFactory.createAccount(true);
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, firm.Id, false);
        for (Integer i = 0; i < opps.size(); i++) {
            opps[i].StageName = Math.mod(i, 2) == 0 ? 'Closed Won' : 'Dead/Pass';
        }
        insert opps;
        Id anchorId = opps[0].Id; // any one of the 251 works as the clicked record

        Test.startTest();
        BrokerFirmController.BrokerFirm bf = BrokerFirmController.getBrokerFirm(anchorId);
        Test.stopTest();

        System.assertEquals(251, bf.dealsSubmitted, 'All 251 opportunities under the firm are counted');
        System.assertEquals(126, bf.dealsWon, 'Even indices (126 of 251) are Closed Won');
        System.assertEquals(125, bf.dealsLost, 'Odd indices (125 of 251) are Dead/Pass');
    }
}
