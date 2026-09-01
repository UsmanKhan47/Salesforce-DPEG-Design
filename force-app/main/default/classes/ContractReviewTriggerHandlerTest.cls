/**
 * Tests ContractReviewTriggerHandler: the Contract_Review__c after-update context routes to
 * ContractExecutionService. Behaviour is asserted through the trigger, as it fires in production.
 *
 * ═══ 🔴 RE-SCOPED 2026-08-17. BOTH TESTS ASSERTED A TRANSACTION AND HAD BEEN RED SINCE AT LEAST
 * 2026-08-12 (Expected 1 / Actual 0, and Expected 251 / Actual 0). THE ZEROS WERE CORRECT.
 *
 * This class header used to end "...so executing a PSA opens exactly one Transaction for the deal."
 * That stopped being true on 2026-08-05, when Transaction creation MOVED out of handleExecution to
 * ContractExecutionService.openTransactionsOnAboutToClose, keyed on the Opportunity entering
 * 'About to Close' (user decision: the Transactions team picks a deal up when it is genuinely
 * about to close, not at signature). That class's header carries the standing instruction "Do not
 * re-add Transaction creation to handleExecution."
 *
 * 🔴 WHY THE TESTS WERE RE-SCOPED RATHER THAN HAVING THE FIXTURE ADVANCED TO 'About to Close'.
 * That was the other option and it is wrong FOR THIS CLASS, for a reason that outlives this fix:
 * 'About to Close' is an OPPORTUNITY stage, so it fires OpportunityReviewTrigger — a DIFFERENT
 * trigger routing to a DIFFERENT handler. A test in ContractReviewTriggerHandlerTest that asserted
 * a Transaction appeared after an Opportunity stage change would go green even if
 * ContractReviewTrigger were DELETED OUTRIGHT, which is the precise opposite of what this class
 * exists to detect. Transaction creation belongs to whatever covers openTransactionsOnAboutToClose;
 * this class must assert what the Contract Review trigger itself causes.
 *
 * WHAT THE TESTS ASSERT NOW — the real, current observable of that routing: handleExecution ->
 * stampOpportunities writes Contract_Signed__c = true and the Day-0 Contract_Executed_Date__c onto
 * the parent Opportunity. Nothing was weakened: the stamp is a strictly TIGHTER pin than the old
 * count (it can only be produced by this trigger's own routing), and each test additionally asserts
 * ZERO Transactions — which is a NEW falsifier the old version could not have, going red the moment
 * anyone re-adds Transaction creation to handleExecution against the instruction above.
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 */
@isTest
private class ContractReviewTriggerHandlerTest {

    /**
     * Drives an Opportunity to PSA, which auto-creates its Contract Review.
     *
     * LOI -> PSA crosses the signed-NDA gate (which covers PSA) and the approved-LOI gate, so the
     * fixture is prepared to satisfy both rather than the assertions being relaxed.
     */
    private static Contract_Review__c dealAtPsa() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        TestDataFactory.signPrimaryNda(o);
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        // Completed_LOI_Before_PSA (added 2026-08-12) reads the LOI's OWN Stage__c, which
        // placeApprovedLoi deliberately leaves at its factory-default 'Draft'. Drive it to
        // 'Signed' via the real production route before entering PSA — same fix as
        // ContractExecutionServiceTest.dealAtPsa (the identical fixture, duplicated in this class).
        // ⚠ 'Signed' since observation 5 (2026-08-14); this was 'Completed' until the acquisition
        // LOI sequence was renamed. It must stay in step with Completed_LOI_Before_PSA, the
        // validation rule this line exists to satisfy — that rule reads the LOI child's OWN
        // Stage__c by string (design collision C2) and is repointed in the same P3-D2 wave. If this
        // line and that rule ever disagree, EVERY deal in the org is blocked from entering
        // 'Under Contract (PSA)' and this fixture is where it shows up first.
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Signed');
        o.StageName = 'Under Contract (PSA)';
        update o;
        return [SELECT Id, Opportunity__c FROM Contract_Review__c WHERE Opportunity__c = :o.Id];
    }

    @isTest
    static void afterUpdate_HandsOffExecutedContract() {
        // Given: a deal with a Contract Review at PSA, not yet signed.
        Contract_Review__c cr = dealAtPsa();
        Opportunity before = [SELECT Contract_Signed__c, Contract_Executed_Date__c
                              FROM Opportunity WHERE Id = :cr.Opportunity__c];
        Assert.isFalse(before.Contract_Signed__c,
            'PRECONDITION: reaching PSA does not itself sign the contract — execution does. '
            + 'Without this, the assertions below could pass on a fixture that arrived pre-stamped');
        Assert.isNull(before.Contract_Executed_Date__c, 'PRECONDITION: no Day-0 stamp yet');

        // When: the negotiation status becomes Executed.
        Test.startTest();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        // Then: the after-update handler routed to ContractExecutionService, which stamped the deal.
        Opportunity after = [SELECT Contract_Signed__c, Contract_Executed_Date__c
                             FROM Opportunity WHERE Id = :cr.Opportunity__c];
        Assert.isTrue(after.Contract_Signed__c,
            'The after-update handler routed to ContractExecutionService.handleExecution, which '
            + 'stamped Contract_Signed__c on the parent deal');
        Assert.isNotNull(after.Contract_Executed_Date__c,
            'and stamped Day 0 — the value openTransactionsOnAboutToClose later reads back to date '
            + 'the 82-task checklist, which is why the two remain coupled after the 2026-08-05 split');

        // And: NOT a Transaction. See the class header — creation moved to
        // openTransactionsOnAboutToClose and ContractExecutionService's header forbids re-adding it
        // here. This assertion is what goes red if anyone does.
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c],
            'Executing the PSA must NOT open a Transaction — that moved to '
            + 'ContractExecutionService.openTransactionsOnAboutToClose on 2026-08-05, keyed on the '
            + 'Opportunity entering About to Close. Two creators would race'
        );
    }

    /**
     * Bulk (.claude/rules/bulk-test-rule.md): 251 Contract Reviews executed in
     * one transaction forces a second Contract_Review__c trigger batch chunk and
     * proves the handler routes the whole collection, not a single record.
     *
     * ⚠ Re-scoped 2026-08-17 with its single-record sibling — the observable is the 251 Opportunity
     * STAMPS, not 251 Transactions. The volume is unchanged at 251, and the "routes the whole
     * collection" property is if anything better served: a handler that dropped everything past the
     * first chunk stamps 200, and `areEqual(251, ...)` shows exactly that.
     */
    @isTest
    static void bulk251ExecutedContractsHandOff() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        for (Opportunity o : opps) {
            o.StageName = 'LOI';
        }
        insert opps;
        // The same gates dealAtPsa() prepares, in bulk: one DML statement per helper.
        TestDataFactory.signPrimaryNda(opps);
        List<LOI__c> primaryLois = TestDataFactory.placeApprovedLoi(opps);

        // Completed_LOI_Before_PSA (added 2026-08-12) reads each LOI's OWN Stage__c, which
        // placeApprovedLoi deliberately leaves at 'Draft'. dealAtPsa() drives this through the real
        // production route (RecordStageAdvanceService.advanceTo) because it is a single-record
        // fixture, but that route is one DML statement PER CALL — looping it 251 times here would
        // blow the 150-DML-statement transaction limit before Test.startTest() is even reached.
        // 🔴 RETRACTED 2026-08-20 (Tranche 2 code review W1): "LOI__c has no validation rules
        // (confirmed: no objects/LOI__c/validationRules folder)" is NO LONGER TRUE. LOI__c gained
        // four (Workstream A4): Final_Price_Required_Before_Executed, Counter_Price_Is_Positive,
        // Closing_Period_Days_Not_Negative, Due_Diligence_Days_Not_Negative. The bulk write below
        // still passes ALL four — it only writes Stage__c = 'Signed' (not 'Executed', and it never
        // touches Counter_Price__c / Closing_Period_Days__c / Due_Diligence_Days__c, which the other
        // three rules key on) — so the fixture itself needs no change. But the SAFETY ARGUMENT that
        // justified skipping the real service route is gone: the next LOI validation rule added to
        // this object could silently break this 251-row bulk write with no warning here. Re-check
        // this block against objects/LOI__c/validationRules/ before trusting it again — same
        // retraction as ContractExecutionServiceTest.bulkExecution251ContractsHandsOffToTransactions.
        List<LOI__c> completedLois = new List<LOI__c>();
        for (LOI__c primaryLoi : primaryLois) {
            completedLois.add(new LOI__c(Id = primaryLoi.Id, Stage__c = 'Signed'));
        }
        update completedLois;

        for (Opportunity o : opps) {
            o.StageName = 'Under Contract (PSA)';
        }
        update opps; // auto-creates 251 Contract Reviews

        List<Contract_Review__c> reviews = [SELECT Id FROM Contract_Review__c WHERE Opportunity__c IN :opps];
        Assert.areEqual(251, reviews.size(), 'A Contract Review opens for every deal entering PSA');
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity WHERE Id IN :opps AND Contract_Signed__c = true],
            'PRECONDITION: none of the 251 deals is signed before its PSA is executed');

        Test.startTest();
        for (Contract_Review__c cr : reviews) {
            cr.Negotiation_Status__c = 'Executed';
        }
        update reviews;
        Test.stopTest();

        Assert.areEqual(
            251,
            [SELECT COUNT() FROM Opportunity
             WHERE Id IN :opps AND Contract_Signed__c = true AND Contract_Executed_Date__c != null],
            'Every one of the 251 executed deals is stamped by the handler. A handler that dropped '
            + 'everything past the first trigger batch chunk stamps 200, so this number is the '
            + 'bulk-routing proof'
        );
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c IN :opps],
            'and NO Transaction is opened at execution — see the class header. Creation moved to '
            + 'openTransactionsOnAboutToClose on 2026-08-05'
        );
    }
}
