/**
 * @description Negative-test coverage for Opportunity stage validation rules, added to close
 * code-review gap W2 and extended 2026-08-12 (live UI testing fix item 1):
 *   - Underwriting_Approved_Before_LOI (blocks LOI entry until UW_Approved__c)
 *   - Approved_LOI_Before_PSA          (blocks PSA entry until an approved LOI is in place)
 *   - Contract_Signed_Before_Closed_Won (blocks Closed Won entry until Contract_Signed__c)
 *   - Completed_LOI_Before_PSA         (blocks PSA entry until the primary LOI's OWN Stage__c is
 *                                       'Signed' — added 2026-08-12; the value was 'Completed'
 *                                       until observation 5 renamed the acquisition LOI sequence
 *                                       on 2026-08-14. The RULE keeps its name, which is why the
 *                                       test methods below still read completedLoiGate_*; see the
 *                                       migration-window note on the rule itself)
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
 * ── Completed_LOI_Before_PSA (added 2026-08-12) ───────────────────────────────
 * `Approved_LOI_Before_PSA` tests the OPPORTUNITY's own flag (LOI_Approved__c) and the presence of
 * the Primary_LOI__c lookup — it never reads the LOI child record's OWN Stage__c, so a deal could
 * (and did, live, on 2026-08-12) reach PSA with its primary LOI still sitting on Stage__c = 'Draft'.
 * `Completed_LOI_Before_PSA` closes that gap by reading Primary_LOI__r.Stage__c directly.
 *
 * completedLoiGate_blocksPsaEntryUntilLoiStageIsCompleted uses
 * TestDataFactory.placeApprovedLoi — which satisfies Approved_LOI_Before_PSA (Primary_LOI__c set,
 * LOI_Approved__c = true) but leaves the newly-created LOI at its factory-default Stage__c =
 * 'Draft' — to ISOLATE the new rule exactly: with the OLD rule already satisfied, the ONLY possible
 * source of a DmlException on entering PSA is Completed_LOI_Before_PSA.
 *
 * completedLoiGate_blankPrimaryLoiYieldsExactlyOneError is the rule's own falsifier for its
 * `NOT(ISBLANK(Primary_LOI__c))` guard: without it, TEXT(Primary_LOI__r.Stage__c) on a blank lookup
 * evaluates to '' (empty string), and '' <> 'Completed' is TRUE — so a blank lookup would ALSO fire
 * this rule, stacking a SECOND error message on top of Approved_LOI_Before_PSA's, which already
 * owns the blank-lookup case alone. This test proves the guard keeps that case to exactly one
 * message by asserting the SECOND rule's distinctive wording is ABSENT from the thrown message,
 * not merely that the first rule's wording is present (which the pre-existing
 * approvedLoiGate_blocksPsaEntryWithoutApprovedLoi test above already establishes and would keep
 * passing even if a second message were stacked on top).
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
            // ⚠ NARROWED 2026-08-28 from '...until the underwriting has been approved' to the
            // shorter invariant fragment. Underwriting_Approved_Before_LOI is owned by the
            // parallel declarative stream and is being rewritten from NOT(UW_Approved__c) to a
            // read of Primary_Underwriting__r.Stage__c, which changes the wording from "the
            // underwriting has been approved" to "its Underwriting record has been approved".
            // 'cannot enter LOI until' is common to both and still distinguishes THIS rule's
            // message from the NDA gate's and from a generic failure — which is all this
            // assertion ever needed to do. Tighten to the full new string once that rule ships.
            System.assert(
                e.getMessage().contains('cannot enter LOI until'),
                'Entering LOI unapproved should surface the approval message, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Entering LOI without principal-approved underwriting must be blocked');

        // Approving unlocks the SAME direct update - no approval process involved. This is the
        // first real caller of TestDataFactory.approveUnderwriting.
        // ⚠ Since 2026-08-28 that helper sets BOTH the deal's UW_Approved__c AND the primary
        // Underwriting record's Stage__c = 'Approved', so this fixture satisfies the gate under
        // either version of the rule and does not red while the two streams land.
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
            o.StageName = 'Under Contract (PSA)';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('cannot enter Under Contract (PSA) until an approved LOI is in place'),
                'Entering PSA without an approved LOI should surface the LOI message, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Entering PSA without an approved LOI (Primary_LOI__c + LOI_Approved__c) '
            + 'must be blocked');

        System.assertEquals('LOI',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage untouched');
    }

    /**
     * ISOLATES Completed_LOI_Before_PSA from its sibling Approved_LOI_Before_PSA. placeApprovedLoi
     * satisfies the OLD rule in full (Primary_LOI__c set, LOI_Approved__c = true); the newly-created
     * LOI is left at its factory-default Stage__c = 'Draft', which is what the NEW rule refuses.
     */
    @isTest
    static void completedLoiGate_blocksPsaEntryUntilLoiStageIsCompleted() {
        Opportunity o = newOpp('LOI');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: PSA entry is ALSO NDA-gated
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o); // Approved_LOI_Before_PSA satisfied;
                                                                   // Stage__c stays at factory-default 'Draft'

        System.assertEquals('Draft', [SELECT Stage__c FROM LOI__c WHERE Id = :primaryLoi.Id].Stage__c,
            'PRECONDITION: placeApprovedLoi must not have touched Stage__c, or this test would not '
            + 'isolate the new rule from its sibling');

        Boolean blocked = false;
        try {
            o.StageName = 'Under Contract (PSA)';
            update o;
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('until the primary LOI is Signed'),
                'Entering PSA with the primary LOI still on Draft should surface the Completed_LOI_'
                + 'Before_PSA message, got: ' + e.getMessage());
        }
        System.assert(blocked, 'Entering PSA with an approved-but-not-Signed primary LOI '
            + '(Approved_LOI_Before_PSA satisfied, LOI Stage__c = Draft) must be blocked');

        System.assertEquals('LOI',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage untouched');
    }

    /**
     * The positive complement: once the primary LOI's OWN Stage__c reaches 'Signed', the SAME
     * transition that was just blocked above must succeed.
     *
     * ⚠ 'Signed' since observation 5 (2026-08-14); it was 'Completed'. The rule accepts BOTH during
     * the migration window (its formula excludes each in turn), so this test passing does NOT prove
     * the rule was repointed — the negative test above, which asserts the MESSAGE, is what does.
     */
    @isTest
    static void completedLoiGate_allowsPsaEntryOnceLoiStageIsSigned() {
        Opportunity o = newOpp('LOI');
        insert o;
        TestDataFactory.signPrimaryNda(o);
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        // ⚠ 'Signed' since observation 5 (2026-08-14); this was 'Completed' until the acquisition
        // LOI sequence was renamed. It must stay in step with Completed_LOI_Before_PSA, the
        // validation rule this line exists to satisfy — that rule reads the LOI child's OWN
        // Stage__c by string (design collision C2) and is repointed in the same P3-D2 wave. If this
        // line and that rule ever disagree, EVERY deal in the org is blocked from entering
        // 'Under Contract (PSA)' and this fixture is where it shows up first.
        update new LOI__c(Id = primaryLoi.Id, Stage__c = 'Signed');

        Test.startTest();
        o.StageName = 'Under Contract (PSA)';
        update o; // must NOT throw
        Test.stopTest();

        System.assertEquals('Under Contract (PSA)',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Once the primary LOI itself reaches Signed, PSA entry must succeed');
    }

    /**
     * 🔴 THE GUARD'S OWN FALSIFIER. Without NOT(ISBLANK(Primary_LOI__c)), a blank lookup would ALSO
     * fire Completed_LOI_Before_PSA (TEXT of a blank relationship is '', and '' <> 'Completed' is
     * TRUE) — stacking a SECOND message on top of Approved_LOI_Before_PSA's, which already owns the
     * blank-lookup case alone. Asserting the SECOND rule's message is ABSENT is what distinguishes
     * "one error" from "two errors, but the test only looked for the first one".
     */
    @isTest
    static void completedLoiGate_blankPrimaryLoiYieldsExactlyOneError() {
        Opportunity o = newOpp('LOI');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: PSA entry is ALSO NDA-gated
        // Deliberately NO placeApprovedLoi call — Primary_LOI__c stays blank.

        Boolean blocked = false;
        try {
            o.StageName = 'Under Contract (PSA)';
            update o;
        } catch (DmlException e) {
            blocked = true;
            String message = e.getMessage();
            System.assert(message.contains('cannot enter Under Contract (PSA) until an approved LOI is in place'),
                'Approved_LOI_Before_PSA must still fire on a blank lookup — got: ' + message);
            System.assert(!message.contains('until the primary LOI is Signed'),
                'Completed_LOI_Before_PSA must NOT also fire on a blank lookup — its '
                + 'NOT(ISBLANK(Primary_LOI__c)) guard exists exactly to exempt this case and keep '
                + 'it to ONE error message. Two messages here means the guard is missing or '
                + 'malformed. Got: ' + message);
        }
        System.assert(blocked, 'Entering PSA with a blank Primary_LOI__c must still be blocked '
            + '(by Approved_LOI_Before_PSA alone)');

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
