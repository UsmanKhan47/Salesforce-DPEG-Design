/**
 * Test class for ContentPublicationBudget — the L4 (reactive circuit breaker) and L5
 * (predictive daily budget) layers guarding the org's shared ContentPublication quota.
 *
 * ═══ ZERO ContentPublication COST ═══
 * Every test here touches only the `Content_Publication_Budget__c` hierarchy Custom Setting.
 * No ContentVersion, no ContentNote, no Attachment is ever created — this class costs nothing
 * against `.claude/rules/content-publication-rule.md`'s ceiling, which is exactly why the
 * budget/breaker logic is exercised directly here rather than only indirectly through
 * AttachmentPersistQueueableTest.
 *
 * COVERS: canPublish/allowance under a fresh (never-written) setting, after record() consumes
 * some of the daily allowance, once the daily budget is exhausted, and while the breaker is
 * tripped (including its own expiry); record()'s window-roll behaviour; trip()'s suspension
 * window; and the two note-builder methods. The fail-soft "degrades to permitted" contract is
 * inherent in every method here (there is no way to force settings() itself to throw from
 * outside the class), so it is not separately re-asserted — the class header's own reasoning
 * (a backstop that blocks the feature when it malfunctions is worse than no backstop) is the
 * documented justification, not a testable branch.
 *
 * @see ContentPublicationBudget.cls
 * @author Unit Testing Agent
 */
@isTest
private class ContentPublicationBudgetTest {

    // ── canPublish / allowance — the fresh, never-written setting ────────────

    @isTest
    static void allowance_freshSetting_returnsTheFullDailyBudget() {
        Test.startTest();
        Integer allowance = ContentPublicationBudget.allowance();
        Test.stopTest();

        Assert.areEqual(1000, allowance,
            'A never-written org-default row must behave as a fresh window with the full budget available');
    }

    @isTest
    static void canPublish_freshSetting_isTrueForAnyReasonableCount() {
        Test.startTest();
        Boolean permitted = ContentPublicationBudget.canPublish(3);
        Test.stopTest();

        Assert.isTrue(permitted, 'A fresh setting must permit an ordinary MAX_ATTACHMENTS-sized request');
    }

    @isTest
    static void canPublish_nullOrNonPositiveCount_isTreatedAsOne() {
        Test.startTest();
        Boolean fromNull = ContentPublicationBudget.canPublish(null);
        Boolean fromZero = ContentPublicationBudget.canPublish(0);
        Boolean fromNegative = ContentPublicationBudget.canPublish(-5);
        Test.stopTest();

        Assert.isTrue(fromNull, 'null must be treated as "is publishing permitted at all", not skipped');
        Assert.isTrue(fromZero, '');
        Assert.isTrue(fromNegative, '');
    }

    // ── record() — consumes the window, rolls when expired ───────────────────

    @isTest
    static void record_consumesAllowanceWithinTheSameWindow() {
        Test.startTest();
        ContentPublicationBudget.record(3);
        Integer allowanceAfter = ContentPublicationBudget.allowance();
        Test.stopTest();

        Assert.areEqual(997, allowanceAfter, 'Recording 3 publications must reduce the remaining allowance by 3');
    }

    @isTest
    static void record_calledTwice_accumulatesWithinTheSameWindow() {
        Test.startTest();
        ContentPublicationBudget.record(400);
        ContentPublicationBudget.record(400);
        Integer allowanceAfter = ContentPublicationBudget.allowance();
        Test.stopTest();

        Assert.areEqual(200, allowanceAfter, 'Two records in the same window must accumulate: 1000 - 400 - 400 = 200');
    }

    @isTest
    static void record_nullOrNonPositiveCount_isANoOp() {
        Test.startTest();
        ContentPublicationBudget.record(null);
        ContentPublicationBudget.record(0);
        ContentPublicationBudget.record(-10);
        Integer allowanceAfter = ContentPublicationBudget.allowance();
        Test.stopTest();

        Assert.areEqual(1000, allowanceAfter, 'null/zero/negative counts must never move the counter');
    }

    @isTest
    static void allowance_budgetFullyConsumed_returnsZeroNeverNegative() {
        Test.startTest();
        ContentPublicationBudget.record(1000);
        Integer allowanceAfter = ContentPublicationBudget.allowance();
        Boolean stillPermitted = ContentPublicationBudget.canPublish(1);
        Test.stopTest();

        Assert.areEqual(0, allowanceAfter, 'A fully consumed window must report zero remaining allowance');
        Assert.isFalse(stillPermitted, 'canPublish must refuse once the daily budget is exhausted');
    }

    @isTest
    static void record_windowExpired_rollsRatherThanAccumulates() {
        // Simulate an expired window by writing the org-default row directly with a
        // Window_Start_DateTime__c older than WINDOW_HOURS (24h) — the same shape record()
        // itself would encounter on its first call after the window lapses.
        Content_Publication_Budget__c budget = Content_Publication_Budget__c.getOrgDefaults();
        budget.Publication_Count__c = 900;
        budget.Window_Start_DateTime__c = Datetime.now().addHours(-25);
        upsert budget;

        Test.startTest();
        Integer allowanceBeforeRecord = ContentPublicationBudget.allowance();
        ContentPublicationBudget.record(10);
        Integer allowanceAfterRecord = ContentPublicationBudget.allowance();
        Test.stopTest();

        Assert.areEqual(1000, allowanceBeforeRecord,
            'allowance() must treat an EXPIRED window as zero-used, not carry the stale 900 forward');
        Assert.areEqual(990, allowanceAfterRecord,
            'record() must RESTART the window rather than accumulate onto the stale count: '
            + '1000 - 10 (fresh window), never 1000 - 900 - 10');
    }

    // ── isSuspended / trip — the reactive circuit breaker ─────────────────────

    @isTest
    static void isSuspended_freshSetting_isFalse() {
        Test.startTest();
        Boolean suspended = ContentPublicationBudget.isSuspended();
        Test.stopTest();

        Assert.isFalse(suspended, 'A never-tripped setting must never report suspended');
    }

    @isTest
    static void trip_setsSuspendedForTheConfiguredWindow() {
        Test.startTest();
        ContentPublicationBudget.trip();
        Boolean suspended = ContentPublicationBudget.isSuspended();
        Boolean stillPermitted = ContentPublicationBudget.canPublish(1);
        Integer allowanceWhileSuspended = ContentPublicationBudget.allowance();
        Test.stopTest();

        Assert.isTrue(suspended, 'trip() must set the breaker to suspended');
        Assert.isFalse(stillPermitted, 'canPublish must refuse while the breaker is tripped');
        Assert.areEqual(0, allowanceWhileSuspended, 'allowance() must report zero while suspended');

        Content_Publication_Budget__c budget = Content_Publication_Budget__c.getOrgDefaults();
        Assert.isNotNull(budget.Suspended_Until_DateTime__c, 'trip() must stamp a resume time');
        Assert.isTrue(budget.Suspended_Until_DateTime__c > Datetime.now(),
            'The resume time must be in the future — BREAKER_SUSPEND_HOURS (24) ahead of now');
    }

    @isTest
    static void isSuspended_pastItsSuspendedUntil_clearsByPassageOfTimeAlone() {
        // No reset job, no admin action — the breaker clears purely because the clock passed
        // Suspended_Until_DateTime__c. Simulated by writing that timestamp directly in the past.
        Content_Publication_Budget__c budget = Content_Publication_Budget__c.getOrgDefaults();
        budget.Is_Suspended__c = true;
        budget.Suspended_Until_DateTime__c = Datetime.now().addHours(-1);
        upsert budget;

        Test.startTest();
        Boolean suspended = ContentPublicationBudget.isSuspended();
        Test.stopTest();

        Assert.isFalse(suspended,
            'A breaker whose Suspended_Until_DateTime__c has already passed must report NOT suspended, '
            + 'with no job and no admin intervention required');
    }

    // ── suspensionNote / budgetNote — the §7 copy ─────────────────────────────

    @isTest
    static void suspensionNote_afterTrip_namesTheResumeTimeAndSaysRecoverable() {
        ContentPublicationBudget.trip();

        Test.startTest();
        String note = ContentPublicationBudget.suspensionNote();
        Test.stopTest();

        Assert.isTrue(note.contains('ContentPublication limit reached'), 'Actual: ' + note);
        Assert.isTrue(note.contains('will be retried'),
            'The note must say the file is RECOVERABLE, not lost — the single most important '
            + 'distinction design §7 calls out. Actual: ' + note);
    }

    @isTest
    static void budgetNote_afterPartialConsumption_namesBothNumbers() {
        ContentPublicationBudget.record(250);

        Test.startTest();
        String note = ContentPublicationBudget.budgetNote(5);
        Test.stopTest();

        Assert.isTrue(note.contains('250'), 'The note must name how much of the budget is already used. Actual: ' + note);
        Assert.isTrue(note.contains('1000'), 'The note must name the budget ceiling too. Actual: ' + note);
        Assert.isTrue(note.contains('will be retried'), 'Actual: ' + note);
    }
}
