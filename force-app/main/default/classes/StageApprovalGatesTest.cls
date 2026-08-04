/**
 * @description Negative-test coverage for three Opportunity stage validation rules, added to
 * close code-review gap W2:
 *   - Underwriting_Approved_Before_LOI (blocks LOI entry until UW_Approved__c)
 *   - Approved_LOI_Before_PSA          (blocks PSA entry until an approved LOI is in place)
 *   - Contract_Signed_Before_Closed_Won (blocks Closed Won entry until Contract_Signed__c)
 *
 * Each test leaves ONE flag false and satisfies every OTHER gate the transition crosses (via
 * TestDataFactory's stage-gate helpers and a signed primary NDA where needed), so the only
 * possible source of the DmlException is the rule under test.
 *
 * underwritingApprovedGate_blocksLoiEntryUntilApproved also gives
 * TestDataFactory.approveUnderwriting its first real caller/verification - it constructs a
 * direct-update route into LOI (no approval process involved) to prove the flag alone unlocks
 * the gate, mirroring the blocked-then-succeeds shape of UnderwritingGateTest.ndaGateBlocksUnderwritingEntry.
 *
 * @author Unit Testing Agent
 */
@isTest
private class StageApprovalGatesTest {

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    @isTest
    static void underwritingApprovedGate_blocksLoiEntryUntilApproved() {
        Opportunity o = newOpp('Underwriting');
        insert o; // ISCHANGED(StageName) is false on insert, so every gate is bypassed here.
        TestDataFactory.signPrimaryNda(o); // isolate: LOI entry is ALSO NDA-gated

        Boolean blocked = false;
        try {
            o.StageName = 'LOI';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('cannot enter LOI until the underwriting has been approved'),
                'Entering LOI unapproved should surface the approval message, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Entering LOI without principal-approved underwriting must be blocked');

        // Approving unlocks the SAME direct update - no approval process involved. This is the
        // first real caller of TestDataFactory.approveUnderwriting.
        TestDataFactory.approveUnderwriting(o);
        Test.startTest();
        o.StageName = 'LOI';
        update o;
        Test.stopTest();

        System.assertEquals('LOI',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'UW_Approved__c unlocks a direct move into LOI');
    }

    @isTest
    static void approvedLoiGate_blocksPsaEntryWithoutApprovedLoi() {
        Opportunity o = newOpp('LOI');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: PSA entry is ALSO NDA-gated

        Boolean blocked = false;
        try {
            o.StageName = 'PSA';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('cannot enter PSA until an approved LOI is in place'),
                'Entering PSA without an approved LOI should surface the LOI message, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Entering PSA without an approved LOI (Primary_LOI__c + LOI_Approved__c) '
            + 'must be blocked');

        System.assertEquals('LOI',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage untouched');
    }

    @isTest
    static void contractSignedGate_blocksClosedWonEntryWithoutSignedContract() {
        Opportunity o = newOpp('About to Close');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: Closed Won entry is ALSO NDA-gated

        Boolean blocked = false;
        try {
            o.StageName = 'Closed Won';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('cannot be marked Closed Won until the contract is signed'),
                'Entering Closed Won without a signed contract should surface the contract message, got: '
                + e.getMessage());
        }
        System.assert(blocked, 'Entering Closed Won without Contract_Signed__c must be blocked');

        System.assertEquals('About to Close',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage untouched');
    }
}
