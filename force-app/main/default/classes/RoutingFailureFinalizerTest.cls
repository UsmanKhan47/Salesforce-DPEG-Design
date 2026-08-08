/**
 * Test class for RoutingFailureFinalizer — the failure reporter for ExtractAddressQueueable, the
 * routing job that owns the Lead and the Property_Registry__c claim.
 *
 * ═══ ZERO ContentPublication COST ═══
 * No test here inserts a ContentVersion/ContentNote/ContentDocument — this Finalizer reacts to a
 * FAILED routing job, never to file persistence. Fixtures use only Inbound_Email_Staging__c and
 * Task.
 *
 * ═══ classify IS THE ONLY APEX-PROVABLE PART OF THE MESSAGE-SUBSTRING RULE (design §9 T3) ═══
 * SP-3 measured `ctx.getException().getTypeName()` reporting `System.AsyncException`, never the
 * real `System.LimitException`, when the platform wraps a failing Queueable's exception for a
 * Finalizer. SP-R1 (2026-08-08) GENERALISED that beyond the ContentPublication case: both a heap
 * and a CPU LimitException arrived wrapped the same way. So detection MUST be a substring match on
 * the message text, never a type check — pinned here against the VERBATIM 2026-08-08 spike
 * messages, not a paraphrase.
 *
 * ═══ finalizer_* — A PURPOSE-BUILT THROWING Queueable, NOT PRODUCTION CODE ═══
 * ExtractAddressQueueable has no test seam that lets it die unhandled on demand (every branch it
 * takes is individually fail-soft). Salesforce's own documented technique for testing a Finalizer
 * is to attach the REAL Finalizer under test to a small, test-local Queueable that deliberately
 * throws, then observe the Finalizer's real side effects through a REAL platform-supplied
 * FinalizerContext. That is what ThrowingQueueable below does — it does NOT modify
 * ExtractAddressQueueable or any other production class.
 *
 * ⚠ SP-3's finding, restated as an anti-vacuity rule: an unhandled exception thrown by a Queueable
 * running synchronously at Test.stopTest() PROPAGATES OUT of Test.stopTest() to the calling test
 * method — unlike production, where there is no synchronous caller left. Every test here that
 * deliberately fails the job wraps Test.stopTest() in try/catch, or it reports as a broken test
 * rather than a passing assertion of the failure path. Test.stopTest() is called EXACTLY ONCE per
 * test method — never add a second call "to be safe" after the catch block.
 *
 * ═══ 🔴 THE CENTRAL SAFETY RULE, PINNED END TO END (design §3.3) ═══
 * finalizer_onAlreadyTerminalErrorRow_doesNotPromoteToFailedAndNeverRequeues drives the REAL
 * Finalizer against a row that a PREVIOUS, COMPLETED run already stamped 'Error'. An unhandled
 * exception rolls back only the FAILING attempt's own DML (SP-5) — it says nothing about what an
 * earlier, successful-catch attempt already committed — so the Finalizer must never drag an
 * 'Error' row into 'Failed' (which RoutingRetrySweepBatch would then replay, corrupting the claim
 * or minting a second Lead). This is the single most important behaviour in this class; see
 * InboundEmailStagingService.STATUS_FAILED / isRetryableRoutingState for the full reasoning.
 *
 * @see RoutingFailureFinalizer.cls
 * @see agent-output/design-requirements-routing-resilience.md §3.2, §3.3, §9 (T1-T3)
 * @see agent-output/spike-routing-resilience.md (SP-R1, SP-R2)
 * @author Unit Testing Agent
 */
@isTest
private class RoutingFailureFinalizerTest {

    /** Attaches a REAL RoutingFailureFinalizer, then deliberately throws unhandled. */
    private class ThrowingQueueable implements Queueable {
        private final Id stagingId;
        private final String message;
        ThrowingQueueable(Id stagingId, String message) {
            this.stagingId = stagingId;
            this.message = message;
        }
        public void execute(QueueableContext ctx) {
            System.attachFinalizer(new RoutingFailureFinalizer(stagingId));
            throw new SimulatedFailureException(message);
        }
    }

    /** Attaches the REAL Finalizer and completes cleanly — proves the SUCCESS no-op branch. */
    private class CleanQueueable implements Queueable {
        private final Id stagingId;
        CleanQueueable(Id stagingId) { this.stagingId = stagingId; }
        public void execute(QueueableContext ctx) {
            System.attachFinalizer(new RoutingFailureFinalizer(stagingId));
        }
    }

    private class SimulatedFailureException extends Exception {}

    private static Id insertStaging(String suffix) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Routing finalizer fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-routing-finalizer-' + suffix + '@example.invalid'
        );
        insert staging;
        return staging.Id;
    }

    // ── classify — the substring detector, T3 ─────────────────────────────────

    @isTest
    static void classify_verbatimHeapMessage_returnsHeapClassification() {
        // Pinned against the VERBATIM text SP-R1 measured, not a paraphrase.
        String result = RoutingFailureFinalizer.classify(
            'System.LimitException: Apex heap size too large: 52481351');

        Assert.areEqual(RoutingFailureFinalizer.CLASS_HEAP, result, '');
    }

    @isTest
    static void classify_wrappedAsyncExceptionHeapText_returnsHeapClassification() {
        // SP-R1's measured wrapper shape: the platform hands the Finalizer a System.AsyncException
        // whose OWN message embeds the original LimitException's text verbatim, with a stack trace
        // reading "External entry point" rather than a line inside the failing class.
        String result = RoutingFailureFinalizer.classify(
            'System.AsyncException: System.LimitException: Apex heap size too large: 52481351 '
            + 'External entry point');

        Assert.areEqual(RoutingFailureFinalizer.CLASS_HEAP, result,
            'The token must be found even embedded inside the wrapper exception\'s message, which '
            + 'is the ONLY place SP-R1 found it surviving');
    }

    @isTest
    static void classify_verbatimCpuMessage_returnsCpuClassification() {
        String result = RoutingFailureFinalizer.classify(
            'System.LimitException: Apex CPU time limit exceeded');

        Assert.areEqual(RoutingFailureFinalizer.CLASS_CPU, result, '');
    }

    @isTest
    static void classify_wrappedAsyncExceptionCpuText_returnsCpuClassification() {
        String result = RoutingFailureFinalizer.classify(
            'System.AsyncException: System.LimitException: Apex CPU time limit exceeded '
            + 'Class.RoutingWhatever.execute: line 21, column 1');

        Assert.areEqual(RoutingFailureFinalizer.CLASS_CPU, result, '');
    }

    @isTest
    static void classify_caseVariant_isStillRecognized() {
        // A deliberate SUPERSET of a literal .contains(...): case-insensitive, so a platform
        // string whose casing drifts by one character cannot silently disable the classification.
        Assert.areEqual(RoutingFailureFinalizer.CLASS_HEAP,
            RoutingFailureFinalizer.classify('apex heap size too large'), '');
        Assert.areEqual(RoutingFailureFinalizer.CLASS_CPU,
            RoutingFailureFinalizer.classify('APEX CPU TIME LIMIT EXCEEDED'), '');
    }

    @isTest
    static void classify_unrelatedMessage_returnsOther() {
        String result = RoutingFailureFinalizer.classify(
            'System.DmlException: Insert failed. First exception on row 0; first error: '
            + 'REQUIRED_FIELD_MISSING, Required fields are missing: [Name]');

        Assert.areEqual(RoutingFailureFinalizer.CLASS_OTHER, result,
            'An unrelated DML failure must never be misclassified as a governor limit');
    }

    @isTest
    static void classify_nullOrBlank_returnsOther() {
        Assert.areEqual(RoutingFailureFinalizer.CLASS_OTHER, RoutingFailureFinalizer.classify(null), '');
        Assert.areEqual(RoutingFailureFinalizer.CLASS_OTHER, RoutingFailureFinalizer.classify(''), '');
        Assert.areEqual(RoutingFailureFinalizer.CLASS_OTHER, RoutingFailureFinalizer.classify('   '), '');
    }

    // ── execute() — T1: the core mechanism ────────────────────────────────────

    @isTest
    static void finalizer_onUnhandledException_stampsFailedIncrementsCounterAndNotesTheMessageAndJobId() {
        Id stagingId = insertStaging('t1-heap');

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(stagingId,
            'System.LimitException: Apex heap size too large: 52481351'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest() '
                + '(SP-3/SP-R1) — if it does not, this test needs re-examining, not the try/catch removed');
        } catch (Exception e) {
            // Expected — see the class header. The Finalizer's own DML still committed before the
            // re-throw, independently queryable below. Test.stopTest() is called EXACTLY ONCE.
        }

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Routing_Attempt_Count__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.STATUS_FAILED, staging.Status__c,
            'An unhandled exception must stamp Failed, which is what puts the row in the retry queue');
        Assert.areEqual(1, staging.Routing_Attempt_Count__c, 'The FIRST death must set the counter to 1, not leave it null');
        Assert.isNotNull(staging.Error__c, 'The failure must be RECORDED, never merely a System.debug (the R1 lesson)');
        Assert.isTrue(staging.Error__c.contains('Apex heap size too large: 52481351'),
            'The wrapped exception message must be named verbatim. Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains(RoutingFailureFinalizer.CLASS_HEAP),
            'The classification label must be present. Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains('AsyncApexJob'),
            'The note must name the AsyncApexJob Id so an operator can find the failed job. Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains('NOTHING was committed'),
            'The note must say the retry is safe because nothing committed. Actual: ' + staging.Error__c);
    }

    @isTest
    static void finalizer_secondDeathOnAnAlreadyFailedRow_incrementsCounterAgainAndAppendsBothNotes() {
        // A row that has already failed once (Status__c = Failed, counter = 1) dies a SECOND time.
        // The sequence of failures is the only evidence of whether this is transient or
        // deterministic, so the note must ACCUMULATE, not overwrite.
        Id stagingId = insertStaging('t1-second-death');
        update new Inbound_Email_Staging__c(
            Id = stagingId,
            Status__c = InboundEmailStagingService.STATUS_FAILED,
            Routing_Attempt_Count__c = 1,
            Error__c = 'ROUTING FAILED: first death, classified as unclassified. AsyncApexJob 707FIRST.');

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(stagingId,
            'System.LimitException: Apex CPU time limit exceeded'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected.
        }

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Routing_Attempt_Count__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.STATUS_FAILED, staging.Status__c, '');
        Assert.areEqual(2, staging.Routing_Attempt_Count__c, 'The SECOND death must advance the counter from 1 to 2');
        Assert.isTrue(staging.Error__c.contains('first death'), 'The FIRST failure\'s note must survive. Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains('Apex CPU time limit exceeded'), 'The SECOND failure\'s note must be appended. Actual: ' + staging.Error__c);
    }

    @isTest
    static void finalizer_nullStagingId_doesNotThrow() {
        // A degraded case: the finalizer must survive even if it was somehow attached with no
        // staging Id to report against, rather than compounding one failure into a second.
        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(null, 'Simulated failure with no staging row'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected.
        }

        Assert.isTrue(true, 'A null stagingId must not prevent the Finalizer from completing cleanly');
    }

    // ── execute() — T2: does nothing on SUCCESS ───────────────────────────────

    @isTest
    static void finalizer_onSuccessfulParentJob_doesNothing() {
        // Attach the REAL Finalizer to a Queueable that completes cleanly. On SUCCESS the
        // Finalizer must do nothing — the job stamps its own terminal state, and a second write
        // here could only ever DISAGREE with it.
        Id stagingId = insertStaging('t2-success');

        Test.startTest();
        System.enqueueJob(new CleanQueueable(stagingId));
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Routing_Attempt_Count__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Pending', staging.Status__c,
            'A Finalizer running after a SUCCESSFUL parent job must not touch the row at all');
        Assert.isNull(staging.Routing_Attempt_Count__c, '');
        Assert.isNull(staging.Error__c, 'A successful run must add no note');
    }

    // ── 🔴 THE CENTRAL SAFETY RULE, END TO END (design §3.3) ──────────────────

    @isTest
    static void finalizer_onAlreadyTerminalErrorRow_doesNotPromoteToFailedAndNeverRequeues() {
        // An 'Error' row means a PREVIOUS, COMPLETED run's catch RAN — its work MAY have
        // committed. An unhandled exception rolls back only the FAILING attempt's own DML (SP-5);
        // it says nothing about what an earlier attempt already committed. So the Finalizer must
        // NEVER drag an already-'Error' row into 'Failed', or RoutingRetrySweepBatch would replay
        // it and corrupt the claim (or mint a second Lead) — the exact thing design §3.3 forbids.
        Id stagingId = insertStaging('t-safety-error');
        update new Inbound_Email_Staging__c(
            Id = stagingId, Status__c = 'Error', Error__c = 'earlier committed work, unspecified');

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(stagingId,
            'System.LimitException: Apex CPU time limit exceeded'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected.
        }

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Routing_Attempt_Count__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Error', staging.Status__c,
            'An already-terminal Error row must NEVER be promoted to Failed — that would put '
            + 'possibly-committed work back in the automatic retry queue');
        Assert.isTrue(staging.Error__c.contains('NOT RE-QUEUED'), 'Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains('earlier committed work'),
            'The PRIOR error text must survive, not be overwritten. Actual: ' + staging.Error__c);

        Assert.areEqual(0, [
            SELECT COUNT() FROM Inbound_Email_Staging__c WHERE Id = :stagingId AND Status__c = 'Failed'
        ], 'The row must never read Failed at any point after this — there is no intermediate state to catch');
    }

    @isTest
    static void finalizer_onAlreadyProcessedRow_doesNotPromoteToFailedAndNeverRequeues() {
        // The less dangerous but still-wrong twin of the Error case: re-routing a completed row
        // is at best pointless and, on the narrow path where Message_Id__c is blank, is another
        // route to a duplicate Lead. See isRetryableRoutingState's Javadoc.
        Id stagingId = insertStaging('t-safety-processed');
        update new Inbound_Email_Staging__c(Id = stagingId, Status__c = 'Processed');

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(stagingId, 'Simulated late failure on a done row'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected.
        }

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Processed', staging.Status__c, 'A Processed row must never be promoted to Failed');
        Assert.isTrue(staging.Error__c.contains('NOT RE-QUEUED'), 'Actual: ' + staging.Error__c);
    }
}
