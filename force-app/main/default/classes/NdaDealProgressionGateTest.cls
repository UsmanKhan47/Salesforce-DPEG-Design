/**
 * @description Negative-test coverage for the NDA_Signed_Before_Deal_Progression validation
 * rule (Opportunity), added to close code-review gap W2.
 *
 * This rule REPLACED NDA_Signed_Before_Underwriting (2026-08-04), widening a single
 * Underwriting-entry gate into a 5-stage gate: Underwriting, LOI, PSA, About to Close and
 * Closed Won. The Underwriting leg was already pinned by
 * UnderwritingGateTest.ndaGateBlocksUnderwritingEntry and
 * StageAdvanceServiceTest.signedNdaGateBlocksUnderwritingAndSurfacesMessage - but nothing
 * pinned the four NEWLY-ADDED legs, which are the entire point of the widening: they close the
 * hole where a deal could reach Closed Won via About to Close with an unsigned NDA.
 *
 * Each test below leaves the primary NDA UNSIGNED and satisfies every OTHER gate the target
 * transition crosses (via the TestDataFactory stage-gate helpers), so the only possible source
 * of the DmlException is this rule. If the rule's OR-list were ever reverted to
 * Underwriting-only, every one of these four transitions would stop being blocked and go red.
 *
 * @author Unit Testing Agent
 */
@isTest
private class NdaDealProgressionGateTest {

    private static final String NDA_MESSAGE_FRAGMENT =
        'The primary NDA must be signed before this deal can move to this stage';

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    @isTest
    static void ndaGate_blocksLoiEntryWhenNdaUnsigned() {
        Opportunity o = newOpp('Underwriting');
        insert o; // ISCHANGED(StageName) is false on insert, so every gate is bypassed here.
        TestDataFactory.approveUnderwriting(o); // isolate: LOI entry is ALSO gated by Underwriting_Approved_Before_LOI

        Boolean blocked = false;
        try {
            o.StageName = 'LOI';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains(NDA_MESSAGE_FRAGMENT),
                'Entering LOI with an unsigned NDA should surface the NDA message, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Entering LOI with an unsigned primary NDA must be blocked');
    }

    @isTest
    static void ndaGate_blocksPsaEntryWhenNdaUnsigned() {
        Opportunity o = newOpp('LOI');
        insert o;
        // isolate: PSA entry is ALSO gated by Approved_LOI_Before_PSA, and (since 2026-08-12) by
        // Completed_LOI_Before_PSA, which reads the LOI's OWN Stage__c. placeApprovedLoi leaves it
        // at 'Draft', so drive it to 'Completed' via the real production route so only the NDA gate
        // under test can fire.
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Completed');

        Boolean blocked = false;
        try {
            o.StageName = 'PSA';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains(NDA_MESSAGE_FRAGMENT),
                'Entering PSA with an unsigned NDA should surface the NDA message, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Entering PSA with an unsigned primary NDA must be blocked');
    }

    @isTest
    static void ndaGate_blocksAboutToCloseEntryWhenNdaUnsigned() {
        Opportunity o = newOpp('PSA');
        insert o; // default CloseDate = today + 90, so Close_Date_Before_About_To_Close cannot fire here

        Boolean blocked = false;
        try {
            o.StageName = 'About to Close';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains(NDA_MESSAGE_FRAGMENT),
                'Entering About to Close with an unsigned NDA should surface the NDA message, got: '
                + e.getMessage());
        }
        System.assert(blocked, 'Entering About to Close with an unsigned primary NDA must be blocked');
    }

    /**
     * The minimum bar set by code review: pin entry to Closed Won with an unsigned NDA being
     * blocked. This is the shortcut hole the rule's widening exists to close - a deal reaching
     * Closed Won via About to Close with a never-signed NDA.
     */
    @isTest
    static void ndaGate_blocksClosedWonEntryWhenNdaUnsigned() {
        Opportunity o = newOpp('About to Close');
        insert o;
        TestDataFactory.signContract(o); // isolate: Closed Won entry is ALSO gated by Contract_Signed_Before_Closed_Won

        Boolean blocked = false;
        try {
            o.StageName = 'Closed Won';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains(NDA_MESSAGE_FRAGMENT),
                'Entering Closed Won with an unsigned NDA should surface the NDA message, got: '
                + e.getMessage());
        }
        System.assert(blocked, 'Entering Closed Won with an unsigned primary NDA must be blocked '
            + '- this closes the About-to-Close shortcut hole the rule was widened to fix');
    }
}
