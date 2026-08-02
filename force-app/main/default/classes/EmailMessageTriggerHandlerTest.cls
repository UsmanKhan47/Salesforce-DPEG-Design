/**
 * Tests for EmailMessageTrigger → EmailMessageTriggerHandler → EmailCaptureQueueable
 * — the ASYNC PLUMBING of the EAC capture pipeline. The decisions themselves are covered
 * elsewhere (EmailThreadGuardServiceTest for keep/delete, EmailThreadAdopterServiceTest
 * for adoption); this class proves the wiring that gets a captured email to those
 * decisions, and the guard clause that keeps the wiring from taking Einstein Activity
 * Capture down with it.
 *
 * ⚠ THE QUEUEABLE WAS RENAMED 2026-08-02 (EmailThreadGuardQueueable → EmailCaptureQueueable)
 * when the adopter was added: one job now runs the adopter and THEN the guard, sharing a
 * single anchor read. The enqueue count stays at exactly ONE per trigger chunk, which is
 * what keeps the cap math asserted below unchanged.
 *
 * ⚠ WHY AN END-TO-END INSERT TEST EXISTS AT ALL. A test that only calls
 * `EmailThreadGuardService.run(...)` directly would pass with a broken trigger, a
 * misnamed handler, or no enqueue whatsoever — the feature would be silently dead in
 * production while the suite stayed green. `capturedEmailInsert_...` therefore inserts a
 * real EmailMessage and asserts the outcome AFTER `Test.stopTest()`, which is the only
 * point at which the enqueued job has run.
 *
 * ⚠ THE RELATION IS INSERTED AFTER THE MESSAGE ON PURPOSE. That is exactly how EAC
 * behaves (EmailMessageRelation rows land after the EmailMessage in the same
 * transaction) and it is the whole reason the guard must be async. If this were ever
 * made synchronous, the end-to-end test below is the one that would go red.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes.
 *
 * @see EmailThreadGuardServiceTest.cls (decision logic, scope guards, 251-record bulk)
 */
@isTest
private class EmailMessageTriggerHandlerTest {

    private static final String DEAL_ROOT = 'root@deal.example.invalid';
    private static final String NEW_CONVO = 'new-convo@mail.example.invalid';

    /**
     * END TO END: inserting a capture must fire the trigger, route through the handler,
     * enqueue the queueable, and delete the unanchored email post-commit. This is the
     * only test that proves the trigger file and the handler are wired at all.
     */
    @isTest
    static void capturedEmailInsert_firesTriggerAndGuardRemovesTheUnanchoredEmail() {
        Lead broker = TestDataFactory.createLead(true);
        insert anchorTask(broker.Id, DEAL_ROOT);
        EmailThreadGuardService.treatAllAsMaterialized = true;

        Test.startTest();
        EmailMessage noise = buildCapture(NEW_CONVO, NEW_CONVO);
        insert noise; // fires EmailMessageTrigger -> handler.afterInsert -> enqueue
        // EAC writes the association AFTER the message, in the same transaction.
        insert new EmailMessageRelation(
            EmailMessageId = noise.Id, RelationId = broker.Id, RelationType = 'ToAddress');
        Id companionId = [SELECT ActivityId FROM EmailMessage WHERE Id = :noise.Id].ActivityId;
        Assert.isNotNull(companionId,
            'PRECONDITION FAILED: Enhanced Email must stamp EmailMessage.ActivityId on insert; '
            + 'without a companion Task the guard has no EAC fingerprint to match');
        Test.stopTest(); // the enqueued guard job runs here

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :noise.Id],
            'The trigger must enqueue the guard and the guard must remove an email whose thread '
            + 'no anchor on this Lead knows — if this passes only when run() is called directly, '
            + 'the trigger wiring is broken');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion timeline Task must be removed by the same async pass');
    }

    /**
     * The queueable is a wrapper, but `execute(QueueableContext)` is its whole contract:
     * this enqueues it explicitly (rather than via the trigger) so the async entry point
     * is exercised on its own terms.
     *
     * The GUARD half is asserted here because it is the destructive one — a wiring break
     * that skipped it would leave polluted timelines. The ADOPTER half of the same
     * execute() is asserted in EmailThreadAdopterServiceTest (including through this
     * trigger path at 251 rows), so both halves of the job are pinned somewhere.
     */
    @isTest
    static void enqueuedCaptureJob_executesTheGuardOnItsMessageIds() {
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage noise = buildCapture(NEW_CONVO, NEW_CONVO);
        insert noise;
        insert new EmailMessageRelation(
            EmailMessageId = noise.Id, RelationId = broker.Id, RelationType = 'ToAddress');
        EmailThreadGuardService.treatAllAsMaterialized = true;

        Test.startTest();
        System.enqueueJob(new EmailCaptureQueueable(new Set<Id>{ noise.Id }));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :noise.Id],
            'execute(QueueableContext) must hand its message Ids to the guard');
    }

    /**
     * 🔴 THE GUARD CLAUSE THAT PROTECTS EAC ITSELF. Apex caps System.enqueueJob per
     * transaction, and this handler enqueues once per 200-record trigger chunk — a
     * volume Einstein Activity Capture sets, not this org. Once the slots are gone the
     * handler must SKIP: an uncaught LimitException here would roll back EAC own
     * insert, destroying the captures instead of merely leaving them unexamined
     * (harmless, because the guard is self-healing and the one-off sweep is the
     * documented remedy).
     *
     * The cap is read from Limits rather than hardcoded so the test holds whether the
     * running context allows 50 jobs or 1.
     *
     * ⚠ DRIVEN THROUGH A REAL INSERT, NOT A HAND-BUILT TRIGGER CONTEXT. The DML is the
     * test: if the guard did not hold, `insert capture` itself would throw
     * System.LimitException and roll back — which is precisely the production failure
     * being guarded against (EAC's own insert going down with the guard). A test that
     * fabricated the trigger context would assert the branch but never demonstrate the
     * consequence.
     *
     * ⚠ The `@SuppressWarnings` is deliberate and must stay. PMD flags the
     * `System.enqueueJob` inside the fill loop as `OperationWithLimitsInLoop` — which is
     * exactly what this test is FOR: deliberately consuming the queueable limit is the
     * only way to reach the handler's skip branch. "Fixing" the warning by moving the
     * enqueue out of the loop would delete the test's entire premise.
     */
    @SuppressWarnings('PMD.OperationWithLimitsInLoop')
    @isTest
    static void afterInsertWhenQueueableSlotsAreExhausted_skipsInsteadOfThrowing() {
        Test.startTest();
        Integer cap = Limits.getLimitQueueableJobs();
        while (Limits.getQueueableJobs() < cap) {
            System.enqueueJob(new EmailCaptureQueueable(new Set<Id>()));
        }
        Assert.areEqual(cap, Limits.getQueueableJobs(),
            'Precondition: every queueable slot must be consumed, or this test proves nothing');

        // The real trigger fires here with no slot left. Reaching the next line at all is
        // half the assertion — an unguarded enqueue would throw and take this insert with it.
        EmailMessage capture = buildCapture(NEW_CONVO, NEW_CONVO);
        insert capture;

        Assert.areEqual(cap, Limits.getQueueableJobs(),
            'With no slot left the handler must skip silently — enqueueing anyway would throw '
            + 'System.LimitException and roll back the EAC capture insert that fired it');
        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'The capture must survive: skipping the guard leaves an email unexamined (harmless, '
            + 'and self-healing), whereas throwing would destroy the capture entirely');
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * An unsaved Broker-Protection pipeline thread anchor. Task.Type is deliberately
     * absent and must stay absent — it does not exist in this org, compiles anyway, and
     * throws at runtime (see InboundEmailActivityService header).
     *
     * @param leadId    The Lead the anchor sits on (Task.WhoId).
     * @param threadKey The conversation-root Message-ID.
     * @return The unsaved anchor Task.
     */
    private static Task anchorTask(Id leadId, String threadKey) {
        return new Task(
            WhoId = leadId,
            Subject = 'Email: deal',
            Status = 'Completed',
            TaskSubtype = 'Email',
            Thread_Key__c = threadKey,
            Inbound_Message_Id__c = threadKey
        );
    }

    /**
     * An unsaved EmailMessage in the shape EAC materializes.
     *
     * @param threadId  RFC Message-ID of the thread root.
     * @param messageId RFC Message-ID of this message.
     * @return The unsaved EmailMessage.
     */
    private static EmailMessage buildCapture(String threadId, String messageId) {
        return new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = false,
            ThreadIdentifier = threadId,
            MessageIdentifier = messageId,
            FromAddress = 'junior@example.invalid',
            ToAddress = 'guard.broker@example.invalid'
        );
    }
}
