/**
 * @description Negative-test coverage for the No_Backward_Stage_Movement validation rule
 * (Opportunity), added to close code-review gap W2: validation rules are invisible to Apex
 * coverage metrics, so "delete this rule - does anything go red?" answered NO for this rule
 * before this class existed. See
 * force-app/main/default/objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml
 * for the deployed formula and its full rationale (in the file's XML comment, not its
 * 255-character <description>).
 *
 * Carve-out 1 (the LOI-rejection approval transition) is pinned separately in
 * LoiGateTest.directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval - see that
 * method's header for why the pre-existing LoiGateTest.rejectionReturnsDealToUnderwriting does
 * NOT pin it (approval-process field updates bypass validation rules entirely in this org).
 *
 * @author Unit Testing Agent
 */
@isTest
private class StageBackwardMovementGateTest {

    private static final String BLOCK_MESSAGE_FRAGMENT =
        'A deal cannot be moved back to an earlier stage';

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    @isTest
    static void plainBackwardMove_psaToUnderReview_isBlocked() {
        Opportunity o = newOpp('PSA');
        insert o; // ISCHANGED(StageName) is false on insert, so every gate is bypassed here.

        Boolean blocked = false;
        try {
            o.StageName = 'Under Review';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains(BLOCK_MESSAGE_FRAGMENT),
                'The backward-block message should be surfaced, got: ' + e.getMessage());
        }
        System.assert(blocked, 'PSA -> Under Review is a plain backward move and must be blocked');

        System.assertEquals('PSA',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage untouched');
    }

    /**
     * CARVE-OUT 2, first half: ticking Initiate_Underwriting__c on a CLOSED WON deal is REFUSED.
     * This is the user's explicit 2026-08-04 override of the rewind allowance - see the rule's
     * XML comment, "USER DECISION, CLOSED WON EXCLUSION" - closing the case where a WON deal
     * could be silently reversed by any deal driver ticking a checkbox.
     */
    @isTest
    static void carveOut2_initiateUnderwritingOnClosedWon_isRefused() {
        Opportunity o = newOpp('Closed Won');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: Underwriting entry is ALSO NDA-gated

        Boolean blocked = false;
        try {
            o.Initiate_Underwriting__c = true;
            update o; // before-save flow rewrites StageName to 'Underwriting' before this rule runs
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains(BLOCK_MESSAGE_FRAGMENT),
                'A Closed Won deal must not be reachable backward via the checkbox, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Ticking Initiate Underwriting on a Closed Won deal must be refused');

        System.assertEquals('Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage at Closed Won');
    }

    /**
     * CARVE-OUT 2, second half: the IDENTICAL tick SUCCEEDS from a PSA deal - discriminates in the
     * opposite direction from the test above, so neither could pass by accident (e.g. by the
     * checkbox update always throwing, or always succeeding, regardless of prior stage).
     */
    @isTest
    static void carveOut2_initiateUnderwritingOnPsa_succeeds() {
        Opportunity o = newOpp('PSA');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: Underwriting entry is ALSO NDA-gated

        Test.startTest();
        o.Initiate_Underwriting__c = true;
        update o;
        Test.stopTest();

        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Ticking Initiate Underwriting on a PSA deal must still be allowed - this is the '
            + 'legitimate "needs more underwriting" use the carve-out exists to preserve');
    }

    /**
     * THE ISCHANGED(Initiate_Underwriting__c) GUARD - load-bearing per the rule's own XML comment.
     * The before-save flow never clears the checkbox back to false, so without this guard a deal
     * that ticked it ONCE would carry a PERMANENT backward-move exemption into Underwriting,
     * indefinitely - exactly the sticky, unadministered bypass the user rejected when they refused
     * a bypass custom permission (D4), reintroduced through a different field.
     *
     * This constructs exactly that state - Initiate_Underwriting__c already true, UNCHANGED in the
     * save under test - by advancing the deal through two prior saves first, then attempting a
     * third, separate backward move that never touches the checkbox.
     */
    @isTest
    static void stickyCheckboxGuard_backwardMoveIsStillBlockedWhenCheckboxWasNotChangedThisSave() {
        Opportunity o = newOpp('Under Review');
        insert o;
        TestDataFactory.signPrimaryNda(o);

        // Save 1: flips the checkbox true. Fires the flow: Under Review -> Underwriting is FORWARD
        // (rank 2 -> 4), so the backward block does not apply here regardless of any carve-out.
        o.Initiate_Underwriting__c = true;
        update o;
        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Precondition: the flow advanced the deal to Underwriting');

        // Save 2: an unrelated forward move to PSA. Does not assign the checkbox field, but the
        // in-memory Opportunity still carries it (populated back in Save 1) at its already-true
        // value, so it round-trips unchanged - which is exactly the "sticky, unchanged" state this
        // test needs. The flow does not refire here: doesRequireRecordChangedToMeetCriteria is
        // true and the checkbox is not newly becoming true on this save.
        TestDataFactory.placeApprovedLoi(o);
        o.StageName = 'PSA';
        update o;
        System.assertEquals('PSA',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Precondition: the deal is now at PSA with Initiate_Underwriting__c already true, unchanged');

        // Save 3 (the save under test): a DIRECT backward move PSA -> Underwriting. The checkbox is
        // already true and is NOT changed by this save. If ISCHANGED(Initiate_Underwriting__c) were
        // ever dropped from carve-out 2, this save would be silently ALLOWED instead of blocked.
        Test.startTest();
        Boolean blocked = false;
        try {
            o.StageName = 'Underwriting';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains(BLOCK_MESSAGE_FRAGMENT),
                'The sticky-checkbox backward move must be blocked by the plain backward-block path, '
                + 'got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(blocked,
            'A sticky (already-true, unchanged-this-save) Initiate_Underwriting__c must NOT grant a '
            + 'permanent backward-move exemption - dropping ISCHANGED(Initiate_Underwriting__c) from '
            + 'carve-out 2 would make this assertion fail');
        System.assertEquals('PSA',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage at PSA');
    }
}
