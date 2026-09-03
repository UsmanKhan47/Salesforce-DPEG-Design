/**
 * @description Negative-test coverage for Opportunity stage validation rules, added to close
 * code-review gap W2 and extended 2026-08-12 (live UI testing fix item 1):
 *   - Underwriting_Approved_Before_LOI (blocks LOI entry until UW_Approved__c)
 *   - Approved_LOI_Before_PSA          (blocks PSA entry until an approved LOI is in place)
 *   - Contract_Signed_Before_Closed_Won (blocks Closed Won entry until Contract_Signed__c)
 *   - Transaction_Closed_Before_Closed_Won (blocks Closed Won entry unless the deal owns at least
 *                                       one Transaction and none of them is still open — added
 *                                       2026-09-02, FAIL-CLOSED by explicit user decision)
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
        // isolate: and, since 2026-09-02, transaction-gated. Without this the assertion below
        // could read a message stack containing BOTH refusals.
        TestDataFactory.markTransactionClosed(o);

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

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Transaction_Closed_Before_Closed_Won (added 2026-09-02) — THE FAIL-CLOSED GATE
    //
    // 🔴 THESE THREE TESTS ARE THE ONLY PIN ON A DECISION THAT CHANGES ROUGHLY HALF OF TODAY'S
    // CLOSES, AND THE MIDDLE ONE IS THE ONE THAT WOULD BE OMITTED.
    // The rule fails CLOSED: a deal with NO Transaction at all cannot reach Closed Won. That was
    // an explicit user decision taken with the consequence stated — `StageAdvanceService.cls`
    // records that "half the closes carry no Transaction__c at all", and measured on `usman-dpeg`
    // 2026-09-02, 3 of the 5 live Closed Won deals had none. The three states the two flags span
    // (see DealTransactionGateService's header) need one test each, because a rule written with
    // only the "open transaction" clause would pass the first and third and silently fail open on
    // the second — which is exactly the population the user is worried about.
    //
    // ⚠ THE FIXTURES SET THE FLAGS DIRECTLY rather than creating a Transaction__c. The flags ARE
    // the rule's inputs; how they got their values is `DealTransactionGateServiceTest`'s subject,
    // not this class's. Creating a real Transaction here would drag in the 82-task Day-0 fan-out
    // for no gain.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * The state fail-closed exists for: no Transaction at all, both flags false.
     *
     * 🔴 THE FIXTURE STAGE IS `'Under Contract (PSA)'` AND IT CANNOT BE `'About to Close'`. That
     * looks like the natural choice and it silently destroys the test: inserting an Opportunity AT
     * `'About to Close'` runs `ContractExecutionService.openTransactionsOnAboutToClose`, whose
     * entry test is `prior == null || prior.StageName != ABOUT_TO_CLOSE` — so an INSERT at that
     * stage counts as entering it and AUTO-CREATES a Transaction. The deal then has one, the
     * precondition below reads true, and the "no transaction at all" case is never exercised.
     * MEASURED: validate `0Afiw000000VCMgCAO`, 2026-09-02, where this method failed on its own
     * precondition for exactly that reason.
     *
     * `'Under Contract (PSA)'` creates a Contract Review on insert but no Transaction, and rank 6
     * to rank 8 is forward, so `No_Backward_Stage_Movement` allows the hop. It is also a real
     * route: after the 2026-09-02 `NEXT_STAGE` repoint no BUTTON goes PSA -> Closed Won, but the
     * API, Data Loader, a list view and the Path all still can, which is precisely the population
     * this gate has to refuse.
     */
    @isTest
    static void transactionGate_blocksClosedWonWhenTheDealHasNoTransactionAtAll() {
        Opportunity o = newOpp('Under Contract (PSA)');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: Closed Won entry is ALSO NDA-gated
        TestDataFactory.signContract(o);   // isolate: and contract-gated

        // WITH SYSTEM_MODE, not decoration: a field with zero FieldPermissions rows is ABSENT
        // from the running user's schema, and a plain SELECT throws "No such column" even as an
        // administrator. Measured on validate 0Afiw000000VDSPCA4, 2026-09-02.
        Opportunity readBack = [
            SELECT Has_Open_Transaction__c, Has_Closed_Transaction__c
            FROM Opportunity WHERE Id = :o.Id
            WITH SYSTEM_MODE
        ];
        Assert.isFalse(readBack.Has_Open_Transaction__c,
            'Precondition: a deal that never opened a Transaction reads false');
        Assert.isFalse(readBack.Has_Closed_Transaction__c, 'and false');

        Boolean blocked = false;
        try {
            o.StageName = 'Closed Won';
            update o;
        } catch (DmlException e) {
            blocked = true;
            Assert.isTrue(e.getMessage().contains('until its transaction is closed'),
                'A deal with no Transaction must surface the TRANSACTION message specifically — a '
                + 'generic "something threw" would also pass if one of the other four Closed Won '
                + 'rules fired, and the other four are satisfied above precisely so they cannot. '
                + 'Got: ' + e.getMessage());
        }
        Assert.isTrue(blocked,
            '🔴 FAIL-CLOSED: a deal with NO Transaction must not reach Closed Won. If this goes '
            + 'green-and-not-blocked the rule was written fail-OPEN, which leaves exactly the '
            + 'population this feature exists to stop still able to close.');

        Assert.areEqual('Under Contract (PSA)',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A rejected save must leave the stage untouched');
    }

    /** The state everyone thinks of first: a Transaction exists and is still open. */
    @isTest
    static void transactionGate_blocksClosedWonWhileATransactionIsStillOpen() {
        Opportunity o = newOpp('About to Close');
        insert o;
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.signContract(o);
        // System mode for the same reason the SELECT above needs it — a bare update throws
        // "fields being inaccessible on Sobject Opportunity" while the flags carry no FLS.
        Database.update(new Opportunity(
            Id = o.Id, Has_Open_Transaction__c = true, Has_Closed_Transaction__c = false),
            true, AccessLevel.SYSTEM_MODE);

        Boolean blocked = false;
        try {
            o.StageName = 'Closed Won';
            update o;
        } catch (DmlException e) {
            blocked = true;
            Assert.isTrue(e.getMessage().contains('until its transaction is closed'),
                'An open transaction must surface the transaction message, got: ' + e.getMessage());
        }
        Assert.isTrue(blocked, 'A deal whose transaction is still open must not close');
    }

    /**
     * The positive control, and it is not optional: without it every assertion above would still
     * pass if the rule refused Closed Won UNCONDITIONALLY.
     */
    @isTest
    static void transactionGate_allowsClosedWonOnceEveryTransactionIsClosed() {
        Opportunity o = newOpp('About to Close');
        insert o;
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.signContract(o);
        TestDataFactory.markTransactionClosed(o);

        o.StageName = 'Closed Won';
        update o; // must NOT throw

        Assert.areEqual('Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A deal whose every Transaction is closed closes normally — the gate is a gate, not '
            + 'a wall');
    }

    /**
     * 🔴 THE MULTI-TRANSACTION INVARIANT: A DEAL CLOSES WHEN ITS **LAST** TRANSACTION CLOSES, AND
     * NOT BEFORE — AND CLOSING AN EARLIER ONE IS A CLEAN, SUCCESSFUL SAVE.
     *
     * ═══ THIS METHOD REPLACES A REFUSAL-ERA ASSERTION. DO NOT "RESTORE" THE OLD ONE. ═══
     * Until 2026-09-02 this method was `transactionGate_closingOneOfTwoTransactions_isRefusedAnd
     * RollsBack`, and it asserted the OPPOSITE of what is asserted below: that closing the first
     * of two Transactions was REFUSED and rolled the user's Transaction save back. That was an
     * accurate description of the code at the time and it was pinned deliberately, because
     * `flows/Transaction_Complete_Close` closed the parent whenever ANY Transaction reached
     * `Status__c = 'Closed'` without looking at the deal's other Transactions: on a two-Transaction
     * deal the flow attempted `Closed Won` while `Has_Open_Transaction__c` was still true, the new
     * rule refused it, and — because the flow runs inside the Transaction's own save — the refusal
     * came back as `CANNOT_EXECUTE_FLOW_TRIGGER` and undid the user's edit. The old method's own
     * failure message named the successor condition: *"if this ever passes, either the flow gained
     * an open-transaction filter (good …)"*.
     *
     * 🔴 IT GAINED EXACTLY THAT FILTER, ON PURPOSE, AS AN EXPLICIT USER ACCEPTANCE CRITERION.
     * `flows/Transaction_Complete_Close` now runs `Get_Open_Sibling_Transactions` (any OTHER
     * Transaction on the same Opportunity not yet `Closed`) into the `No_Open_Sibling_Transactions`
     * decision, and only the "no open siblings" outcome reaches `Close_Opportunity`. On the open-
     * sibling branch the flow ENDS without touching the Opportunity at all, so
     * `Transaction_Closed_Before_Closed_Won` never evaluates on that save and there is nothing to
     * roll back. ⚠ THE GUARD LIVES IN THE FLOW, NOT IN THE VALIDATION RULE AND NOT IN
     * `DealTransactionGateService` — the rule is unchanged and still refuses `Closed Won` while a
     * Transaction is open (`transactionGate_blocksClosedWonWhileATransactionIsStillOpen` above
     * still pins that, and must keep passing). Deleting this method instead of inverting it would
     * have dropped the only coverage of a user-visible behaviour that was just deliberately
     * changed, leaving nothing to catch a silent revert of the flow.
     *
     * The two halves below are BOTH load-bearing and neither alone is sufficient:
     *   - Act 1 asserts the deal is still open AND the Transaction save COMMITTED. Asserting only
     *     the stage would pass even if the save had rolled back (the deal would be untouched
     *     either way) — the committed `Status__c = 'Closed'` is the half that proves the
     *     `CANNOT_EXECUTE_FLOW_TRIGGER` era is over.
     *   - Act 2 asserts the deal DOES close on the last one. Without it, a flow that had simply
     *     been switched off would satisfy Act 1 perfectly.
     *
     * 🔴 THE FIXTURE STAGE IS `'Under Contract (PSA)'` AND IT CANNOT BE `'About to Close'` — the
     * same trap `transactionGate_blocksClosedWonWhenTheDealHasNoTransactionAtAll` documents above.
     * Inserting AT `'About to Close'` runs `ContractExecutionService.openTransactionsOnAboutToClose`
     * (its entry test is `prior == null || …`, so an insert counts as entering) and AUTO-CREATES a
     * THIRD Transaction. Act 2 would then still leave one open, the deal would not close, and the
     * failure would look like a broken sibling guard rather than a broken fixture. The
     * `Assert.areEqual(2, …)` precondition below exists to catch that if the auto-create stage ever
     * moves.
     */
    @isTest
    static void transactionGate_twoTransactions_dealClosesOnlyWhenTheLastOneCloses() {
        Opportunity o = newOpp('Under Contract (PSA)');
        insert o;
        TestDataFactory.signPrimaryNda(o); // isolate: Closed Won entry is ALSO NDA-gated
        TestDataFactory.signContract(o);   // isolate: and contract-gated

        List<Transaction__c> pair = TestDataFactory.createTransactions(2, o.Id, null, false);
        for (Transaction__c row : pair) {
            row.Status__c = 'Active';
            // Suppress the Day-0 fan-out. THE NULL DATE IS WHAT SUPPRESSES IT since 2026-09-03:
            // flows/Transaction_Task_Fanout was repointed onto ChecklistFanoutService and its
            // second entry filter moved from Tasks_Fanned_Out__c to Checklist_Fanned_Out__c (and
            // M5 then DELETED Tasks_Fanned_Out__c), so a flag no longer keeps the flow out.
            // Contract_Executed_Date__c is the filter BOTH versions shared. Nothing here reads it.
            row.Contract_Executed_Date__c = null;
        }
        insert pair;

        Assert.areEqual(2,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c = :o.Id],
            'Precondition: EXACTLY two Transactions. A third (see the auto-create note above) '
            + 'would make Act 2 fail for a reason that has nothing to do with the sibling guard');

        // ── ACT 1 — close the FIRST of two. No try/catch: a throw here IS the failure. ──
        update new Transaction__c(Id = pair[0].Id, Status__c = 'Closed');

        Assert.areEqual('Closed',
            [SELECT Status__c FROM Transaction__c WHERE Id = :pair[0].Id].Status__c,
            '🔴 THE USER\'S OWN SAVE COMMITTED. This is the assertion that inverted: before the '
            + 'sibling guard this read \'Active\', because the flow\'s refused Opportunity write '
            + 'rolled the whole Transaction save back with it');
        Assert.areEqual('Under Contract (PSA)',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'and the DEAL did NOT close while a sibling Transaction is still open — if this reads '
            + 'Closed Won the flow stopped consulting Get_Open_Sibling_Transactions and deals are '
            + 'closing with work still running on them');

        // ── ACT 2 — close the SECOND. Nothing is open now, so the flow may close the deal. ──
        update new Transaction__c(Id = pair[1].Id, Status__c = 'Closed');

        Assert.areEqual('Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            '🔴 AND THE LAST TRANSACTION TO CLOSE IS THE ONE THAT CLOSES THE DEAL. Without this '
            + 'half, a Transaction_Complete_Close that had simply been deactivated would pass Act '
            + '1 and this test would prove only that nothing happens');
    }

    /**
     * 🔴 THE HOLE, PINNED SO IT IS A DECISION RATHER THAN A SURPRISE. All five Closed Won rules
     * are `ISCHANGED(StageName)`-scoped and ISCHANGED is false on insert, so a record CREATED at
     * Closed Won crosses none of them — including this one.
     *
     * That was chosen, not overlooked. A Transaction cannot reference an Opportunity that does not
     * exist yet, so the two flags cannot be true in the same DML that inserts the deal: an
     * insert-scoped rule would make "closed deal" unreachable by ANY route and would block every
     * data load and migration with no workaround. This test exists so that if someone later widens
     * the rule to insert, they fail HERE, on a documented decision, instead of in a data load.
     */
    @isTest
    static void transactionGate_doesNotFireOnInsert_andThatIsDeliberate() {
        Opportunity o = newOpp('Closed Won');
        insert o; // must NOT throw

        Opportunity readBack = [
            SELECT StageName, Has_Open_Transaction__c, Has_Closed_Transaction__c
            FROM Opportunity WHERE Id = :o.Id
            WITH SYSTEM_MODE
        ];
        Assert.areEqual('Closed Won', readBack.StageName,
            'A deal INSERTED at Closed Won is accepted — ISCHANGED is false on insert');
        Assert.isFalse(readBack.Has_Closed_Transaction__c,
            'and it is accepted with NO closed transaction, which is precisely the residual this '
            + 'method documents. Read the docstring before "fixing" it.');
    }
}
