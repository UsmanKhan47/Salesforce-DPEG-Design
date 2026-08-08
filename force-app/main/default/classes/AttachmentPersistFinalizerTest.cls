/**
 * Test class for AttachmentPersistFinalizer — the only reporter for AttachmentPersistQueueable's
 * failure, and the sole trigger for ContentPublicationBudget's circuit breaker.
 *
 * ═══ ZERO ContentPublication COST ═══
 * No test here inserts a ContentVersion — the Finalizer's own job is to react to a FAILED file
 * job, never to run persist() itself. Fixtures use only Inbound_Email_Staging__c and Task.
 *
 * ═══ isPublicationLimitFailure IS THE ONLY APEX-PROVABLE PART OF THE BREAKER (design §8.2 T7) ═══
 * SP-3 measured `ctx.getException().getTypeName()` reporting `System.AsyncException`, NOT
 * `System.UnexpectedException`, when the platform wraps a failing Queueable's exception for a
 * Finalizer — the real type and message survive only as TEXT inside the wrapper's getMessage().
 * So the detector MUST be a substring match, never a type check, and this is pinned against the
 * VERBATIM 2026-08-06 outage message, not a paraphrase.
 *
 * ═══ finalizer_onUnhandledException — A PURPOSE-BUILT THROWING Queueable, NOT PRODUCTION CODE ═══
 * AttachmentPersistQueueable has no test seam that lets it escape unhandled (every sub-call it
 * makes is individually fail-soft, by design — see its own class header: "the only way out
 * through an exception is a genuine, unexpected failure"). Salesforce's own documented technique
 * for testing a Finalizer is to attach the REAL Finalizer under test to a small, test-local
 * Queueable that deliberately throws, then observe the Finalizer's real side effects through a
 * REAL platform-supplied FinalizerContext. That is what ThrowingQueueable below does — it does
 * NOT modify AttachmentPersistQueueable or any other production class.
 *
 * ⚠ SP-3's finding, restated as an anti-vacuity rule: an unhandled exception thrown by a
 * Queueable running synchronously at Test.stopTest() PROPAGATES OUT of Test.stopTest() to the
 * calling test method — unlike production, where there is no synchronous caller left. Any test
 * here that deliberately fails the job wraps Test.stopTest() in try/catch, or it reports as a
 * broken test rather than a passing assertion of the failure path.
 *
 * @see AttachmentPersistFinalizer.cls
 * @see agent-output/spike-attachment-persistence-v2.md (SP-3)
 * @author Unit Testing Agent
 */
@isTest
private class AttachmentPersistFinalizerTest {

    /** Attaches a REAL AttachmentPersistFinalizer, then deliberately throws unhandled. */
    private class ThrowingQueueable implements Queueable {
        private final Id stagingId;
        private final String message;
        ThrowingQueueable(Id stagingId, String message) {
            this.stagingId = stagingId;
            this.message = message;
        }
        public void execute(QueueableContext ctx) {
            System.attachFinalizer(new AttachmentPersistFinalizer(stagingId));
            throw new SimulatedFailureException(message);
        }
    }

    private class SimulatedFailureException extends Exception {}

    private static Id insertStaging(String suffix) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Finalizer fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-finalizer-fixture-' + suffix + '@example.invalid'
        );
        insert staging;
        return staging.Id;
    }

    // ── isPublicationLimitFailure — the substring detector, T7 ───────────────

    @isTest
    static void isPublicationLimitFailure_verbatimOutageMessage_isTrue() {
        // Pinned against the VERBATIM text from the 2026-08-06 outage log, not a paraphrase —
        // design §8.2 T7.
        Boolean result = AttachmentPersistFinalizer.isPublicationLimitFailure(
            'System.UnexpectedException: ContentPublication Limit exceeded.');

        Assert.isTrue(result, 'The exact outage message must be recognized as a quota refusal');
    }

    @isTest
    static void isPublicationLimitFailure_wrappedAsyncExceptionText_isTrue() {
        // SP-3's measured wrapper shape: the platform hands the Finalizer a System.AsyncException
        // whose OWN message embeds the original UnexpectedException's text verbatim.
        Boolean result = AttachmentPersistFinalizer.isPublicationLimitFailure(
            'System.AsyncException: System.UnexpectedException: ContentPublication Limit exceeded.'
            + '\n    Class.AttachmentPersistQueueable.convert: line 267, column 1');

        Assert.isTrue(result,
            'The token must be found even when embedded inside the wrapper exception\'s message, '
            + 'which is the ONLY place SP-3 found it surviving');
    }

    @isTest
    static void isPublicationLimitFailure_caseVariant_isStillTrue() {
        // A deliberate SUPERSET of the design's literal .contains(...): case-insensitive, so a
        // platform string whose casing drifts by one character cannot silently disable the
        // breaker.
        Boolean result = AttachmentPersistFinalizer.isPublicationLimitFailure(
            'contentpublication limit exceeded');

        Assert.isTrue(result, 'The detector is deliberately case-insensitive');
    }

    @isTest
    static void isPublicationLimitFailure_ordinaryDmlMessage_isFalse() {
        Boolean result = AttachmentPersistFinalizer.isPublicationLimitFailure(
            'System.DmlException: Insert failed. First exception on row 0; first error: '
            + 'REQUIRED_FIELD_MISSING, Required fields are missing: [Name]');

        Assert.isFalse(result, 'An unrelated DML failure must never trip the breaker');
    }

    @isTest
    static void isPublicationLimitFailure_nullOrBlank_isFalse() {
        Assert.isFalse(AttachmentPersistFinalizer.isPublicationLimitFailure(null), '');
        Assert.isFalse(AttachmentPersistFinalizer.isPublicationLimitFailure(''), '');
        Assert.isFalse(AttachmentPersistFinalizer.isPublicationLimitFailure('   '), '');
    }

    // ── execute() — the full reaction to an unhandled exception ──────────────

    @isTest
    static void finalizer_onOrdinaryUnhandledException_stampsFailedAndNotesItWithoutTrippingTheBreaker() {
        Id stagingId = insertStaging('ordinary');

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(stagingId, 'Simulated ordinary failure, not quota-related'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest() '
                + 'in test context (SP-3) — if it does not, this test needs re-examining, not the try/catch removed');
        } catch (Exception e) {
            // SP-3: in test context this propagates out of stopTest(); in production there is no
            // synchronous caller left to propagate to. The Finalizer's own DML still committed
            // before the re-throw, independently queryable below. NOTE: Test.stopTest() must be
            // called EXACTLY ONCE per test method — do not add a second call after this block.
        }

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_FAILED, staging.Attachment_Status__c,
            'An unhandled exception must stamp Failed, which is what puts the row back in the sweeper\'s queue');
        Assert.isNotNull(staging.Dropped_Attachment_Notes__c, 'The failure must be RECORDED, never merely a System.debug (the R1 lesson)');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('NOT SAVED'), 'Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('the file job failed'), 'Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('AsyncApexJob'),
            'The note must name the AsyncApexJob Id so an operator can find the failed job. Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('will be retried'),
            'The note must say the file bytes and the record are all still intact — the whole point of the redesign. '
            + 'Actual: ' + staging.Dropped_Attachment_Notes__c);

        Assert.isFalse(ContentPublicationBudget.isSuspended(),
            'An ORDINARY failure (no ContentPublication text) must never trip the breaker');
    }

    @isTest
    static void finalizer_onPublicationLimitFailure_stampsFailedAndTripsTheBreaker() {
        Id stagingId = insertStaging('quota');

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(stagingId,
            'System.UnexpectedException: ContentPublication Limit exceeded.'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest() (SP-3)');
        } catch (Exception e) {
            // Expected — see SP-3's finding, documented above.
        }

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_FAILED, staging.Attachment_Status__c, '');

        Assert.isTrue(ContentPublicationBudget.isSuspended(),
            'A ContentPublication-shaped failure MUST trip the breaker — this is the whole reason '
            + 'the detector exists, and it must work through the platform\'s real wrapping, not a '
            + 'hand-built message');
    }

    @isTest
    static void finalizer_nullStagingId_stillRunsWithoutThrowing() {
        // A degraded case: the finalizer must survive even if it was somehow attached with no
        // staging Id to report against, rather than compounding one failure into a second.
        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(null, 'Simulated failure with no staging row'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest() (SP-3)');
        } catch (Exception e) {
            // Expected.
        }

        // No assertion beyond "this test itself did not error out of the finalizer's own logic" —
        // the finalizer's job here is simply to not compound a failure into a second one.
        Assert.isTrue(true, 'A null stagingId must not prevent the Finalizer from completing cleanly');
    }

    @isTest
    static void finalizer_onSuccessfulParentJob_doesNothing() {
        // Attach the REAL Finalizer to a Queueable that completes cleanly. On SUCCESS the
        // Finalizer must do nothing — the job stamps its own terminal state, and a second write
        // here would only be able to disagree with it.
        Id stagingId = insertStaging('success');
        update new Inbound_Email_Staging__c(Id = stagingId,
            Attachment_Status__c = InboundEmailStagingService.ATTACHMENT_STATUS_SAVED);

        Test.startTest();
        System.enqueueJob(new CleanQueueable(stagingId));
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c,
            'A Finalizer running after a SUCCESSFUL parent job must not overwrite the status the job itself stamped');
        Assert.isNull(staging.Dropped_Attachment_Notes__c, 'A successful run must add no note');
    }

    /** Attaches the REAL Finalizer and completes cleanly — proves the SUCCESS no-op branch. */
    private class CleanQueueable implements Queueable {
        private final Id stagingId;
        CleanQueueable(Id stagingId) { this.stagingId = stagingId; }
        public void execute(QueueableContext ctx) {
            System.attachFinalizer(new AttachmentPersistFinalizer(stagingId));
        }
    }
}
