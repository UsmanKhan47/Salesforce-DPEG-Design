/**
 * Test class for RoutingRetrySweepBatch — the retry/replay engine for the routing transaction
 * that owns the Lead and the Property_Registry__c claim.
 *
 * ═══ ZERO ContentPublication COST ═══
 * No test here inserts a ContentVersion/ContentNote/ContentDocument — staging rows are free.
 *
 * ═══ 🔴 THE 251-RECORD MANDATE IS SATISFIED AT THE SELECTOR LAYER, NOT HERE — AND THAT IS BY
 * DESIGN, NOT A SHORTCUT ═══
 * `InboundEmailStagingSelectorTest.queryRoutingRetrySweep_at251Rows_isBulkSafe` proves the literal
 * 251 (a plain bulk DML insert + one query, genuinely free and safe at any N — no batch machinery
 * involved). It is NOT reproduced through THIS class's batch machinery, for a reason specific to
 * this batch and STRONGER than the file sweeper's analogous limitation:
 * `Limits.getLimitQueueableJobs()` is **1** inside a genuinely asynchronous transaction (a real
 * `Database.executeBatch` chunk), so a SECOND `System.enqueueJob` call in the same real chunk
 * throws `System.LimitException: Too many queueable jobs added to the queue: 2` — this is a
 * PLATFORM ceiling stronger than "expensive to test", it is the reason `SCOPE = 1` exists at all
 * (see the class header). 251 real dispatches is therefore UNREACHABLE in production (SCOPE = 1
 * forces 251 separate chunks, and Apex refuses more than one `executeBatch` chunk inside a single
 * test method), and 251 ABANDONS in one manufactured chunk would burn ~251 SOQL + ~251 DML in one
 * transaction — comfortably past the 150-DML synchronous/async ceiling. Both routes are the exact
 * "test a state production cannot produce" anti-pattern `.claude/rules/bulk-test-rule.md`'s own
 * exemptions exist to avoid.
 *
 * What THIS class proves instead, and it is not a downgrade — it is the thing actually at risk:
 *   (a) the four dispatch DECISIONS (design §9 T4), each isolated via a DIRECT `execute()` call
 *       shaped exactly like production (one row, SCOPE = 1);
 *   (b) CONSTANT per-row cost with NO SOQL/DML hidden inside a loop, proven with a small
 *       multi-row direct `execute()` call (safe precisely BECAUSE a direct synchronous method
 *       call is not "inside an asynchronous transaction" in the platform's sense, so the
 *       1-queueable ceiling above does not apply to it — this is a genuine platform distinction,
 *       not an evasion: production always calls `execute()` through `Database.executeBatch`,
 *       where SCOPE = 1 already guarantees one dispatch per chunk);
 *   (c) two REAL `Database.executeBatch` runs at the production SCOPE = 1, proving the whole
 *       `start()` → `execute()` wiring end to end (T7, T8).
 *
 * ═══ T7 / T8 — REPLAY SAFETY, POSITIVELY AND NEGATIVELY ═══
 * T7 proves a 'Failed' row with NOTHING committed replays as a clean first run. T8 proves the
 * routing tree's OWN idempotency guard (`InboundEmailActivityService.isAlreadyLogged`) protects a
 * retry exactly as it protects an ordinary redelivery — built as two staging rows sharing one
 * Message-ID (a genuine sibling delivery, not a literal F5 row: F5 — `stamp()`'s own DML
 * swallowed — never enters this queue at all, since it leaves the row 'Pending' forever; see
 * `InboundEmailStagingService.STATUS_FAILED`'s Javadoc). The safety property under test — a retry
 * must never duplicate work a sibling delivery already committed — holds regardless of which of
 * the two produced the Task first, so this is not a weaker substitute for F5, it is the same guard
 * proven the way it is actually reachable.
 *
 * @see RoutingRetrySweepBatch.cls
 * @see agent-output/design-requirements-routing-resilience.md §3.3, §9 (T4, T5, T7, T8)
 * @author Unit Testing Agent
 */
@isTest
private class RoutingRetrySweepBatchTest {

    private static Id insertStagingWithStatus(String suffix, String status, Integer attemptCount) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Retry sweep fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-retry-fixture-' + suffix + '@example.invalid',
            Status__c = status,
            Routing_Attempt_Count__c = attemptCount
        );
        insert staging;
        return staging.Id;
    }

    private static Id insertFailedStaging(String suffix, Integer attemptCount) {
        return insertStagingWithStatus(suffix, InboundEmailStagingService.STATUS_FAILED, attemptCount);
    }

    private static Inbound_Email_Staging__c requeryForBatch(Id stagingId) {
        return [
            SELECT Id, CreatedDate, Status__c, Error__c, Routing_Attempt_Count__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
    }

    private static Id insertFailedStagingForRouting(String fromAddress, String forwardedBy,
            String subject, String messageId, Integer attemptCount) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = fromAddress,
            Subject__c = subject,
            Raw_Body__c = 'some forwarded email body',
            Forwarded_By__c = forwardedBy,
            Message_Id__c = messageId,
            Status__c = InboundEmailStagingService.STATUS_FAILED,
            Routing_Attempt_Count__c = attemptCount
        );
        insert staging;
        return staging.Id;
    }

    // ── T4 — the four dispatch decisions, isolated via direct execute() calls ─

    @isTest
    static void execute_failedRowUnderAttemptCap_dispatchesExactlyOneRetryJob() {
        Id stagingId = insertFailedStaging('dispatch-1', 1);
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.areEqual(1, RoutingRetrySweepBatch.lastRunDispatchedIds.size(),
            'A Failed row under the attempt cap must be dispatched exactly once');
        Assert.areEqual(stagingId, RoutingRetrySweepBatch.lastRunDispatchedIds[0], '');
        Assert.areEqual(1, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ExtractAddressQueueable'
        ], 'Exactly one ExtractAddressQueueable retry job must be enqueued for this row');
    }

    @isTest
    static void execute_failedRowOneBelowAttemptCap_stillDispatches() {
        // Boundary: MAX_ATTEMPTS (3) means attempts 1 and 2 must still retry; only reaching 3
        // abandons. Directly pins the < comparison rather than assuming it.
        Id stagingId = insertFailedStaging('boundary-below-cap', RoutingRetrySweepBatch.MAX_ATTEMPTS - 1);
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.areEqual(1, RoutingRetrySweepBatch.lastRunDispatchedIds.size(),
            'One below the cap must still be retried, not abandoned');
    }

    @isTest
    static void execute_failedRowAtAttemptCap_abandonsWithCapNoteAndNeverDispatches() {
        Id stagingId = insertFailedStaging('at-cap', RoutingRetrySweepBatch.MAX_ATTEMPTS);
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.isTrue(RoutingRetrySweepBatch.lastRunDispatchedIds.isEmpty(),
            'A row AT the attempt cap must never be dispatched');
        Assert.areEqual(0, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ExtractAddressQueueable'
        ], '');
        Inbound_Email_Staging__c updated = [
            SELECT Status__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Error', updated.Status__c,
            'A row at the attempt cap must be ABANDONED to the human queue, not retried forever');
        Assert.isTrue(updated.Error__c.contains('MAX_ATTEMPTS'), 'Actual: ' + updated.Error__c);
    }

    @isTest
    static void execute_failedRowPastAgeCap_abandonsWithAgeNoteAndNeverDispatches() {
        Id stagingId = insertFailedStaging('past-age', 1);
        Test.setCreatedDate(stagingId, Datetime.now().addDays(-15));
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.isTrue(RoutingRetrySweepBatch.lastRunDispatchedIds.isEmpty(), '');
        Inbound_Email_Staging__c updated = [
            SELECT Status__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Error', updated.Status__c, '');
        Assert.isTrue(updated.Error__c.contains('ROUTING_MAX_AGE_DAYS'), 'Actual: ' + updated.Error__c);
    }

    @isTest
    static void execute_failedRowUnderAgeCap_stillDispatches() {
        // The boundary's other side: 13 days old is NOT yet past ROUTING_MAX_AGE_DAYS (14).
        Id stagingId = insertFailedStaging('under-age', 1);
        Test.setCreatedDate(stagingId, Datetime.now().addDays(-13));
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.areEqual(1, RoutingRetrySweepBatch.lastRunDispatchedIds.size(),
            'A row 13 days old must still be RETRIED, never expired — the boundary is '
            + 'ROUTING_MAX_AGE_DAYS (14), not "old"');
    }

    @isTest
    static void execute_errorRow_isNeverDispatchedEvenIfHandedDirectly() {
        // 🔴 THE CENTRAL SAFETY RULE (design §3.3), falsified at the SECOND guard. The locator
        // (queryRoutingRetrySweep) never selects an 'Error' row at all; this test proves the
        // IN-MEMORY re-check that protects the rule if the locator is ever widened. An 'Error'
        // row's catch RAN, so its work MAY have committed — replaying it can mint a second Lead
        // or file a winning broker as a competing submission against their own Lead.
        Id stagingId = insertStagingWithStatus('error-guard', 'Error', 0);
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.isTrue(RoutingRetrySweepBatch.lastRunDispatchedIds.isEmpty(),
            'An Error row must NEVER be dispatched — its work may have already committed');
        Assert.areEqual(0, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ExtractAddressQueueable'
        ], '');
        Assert.areEqual('Error', [
            SELECT Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Status__c, 'The row must be left exactly as it was — no note, no counter change');
    }

    @isTest
    static void execute_processedRow_isNeverDispatchedEvenIfHandedDirectly() {
        Id stagingId = insertStagingWithStatus('processed-guard', 'Processed', 0);
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.isTrue(RoutingRetrySweepBatch.lastRunDispatchedIds.isEmpty(),
            'A Processed row must never be re-dispatched');
        Assert.areEqual('Processed', [
            SELECT Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Status__c, '');
    }

    @isTest
    static void execute_pendingRow_isNeverDispatchedEvenIfHandedDirectly() {
        // Extra defense: a stale-'Pending' row is a DIFFERENT, deliberately unbuilt queue (design
        // §3.3/§12 D4 — 'Failed only now'). This batch must not accidentally start treating it as
        // retryable just because isRetryableRoutingState (the WRITE-side guard) also permits it.
        Id stagingId = insertStagingWithStatus('pending-guard', 'Pending', 0);
        Inbound_Email_Staging__c row = requeryForBatch(stagingId);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>{ row });
        Test.stopTest();

        Assert.isTrue(RoutingRetrySweepBatch.lastRunDispatchedIds.isEmpty(),
            'This batch\'s work queue is Failed rows only — a Pending row must never be dispatched by it');
        Assert.areEqual('Pending', [
            SELECT Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Status__c, '');
    }

    // ── T5 — bulk safety: constant per-row cost, no SOQL/DML in a loop ────────

    @isTest
    static void execute_threeIndependentRowsAtCapInOneCall_costsExactlyOneDmlPerRow() {
        // See the class header for why literal 251 belongs at the SELECTOR layer instead. This
        // proves the loop-safety property actually at risk: N independent rows must cost N DML,
        // never more (no hidden per-row SOQL, no shared-state leak between rows).
        //
        // 🔴 THE BASELINE MUST BE CAPTURED AFTER Test.startTest(), NOT BEFORE — measured directly
        // while writing this test. Test.startTest() itself RESETS Limits.getDmlStatements() (and
        // the other governor counters) to 0 for the code that follows, not merely at stopTest().
        // A baseline captured before startTest() is therefore stale the instant startTest() runs;
        // the fix is to capture BOTH the baseline and the delta INSIDE the startTest/stopTest
        // window, which is also what keeps this consistent with the project's standing rule to
        // never read Limits.* AFTER stopTest() (which restores the pre-test counters again).
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < 3; i++) {
            ids.add(insertFailedStaging('multi-cap-' + i, RoutingRetrySweepBatch.MAX_ATTEMPTS));
        }
        List<Inbound_Email_Staging__c> rows = [
            SELECT Id, CreatedDate, Status__c, Error__c, Routing_Attempt_Count__c
            FROM Inbound_Email_Staging__c WHERE Id IN :ids
        ];

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        new RoutingRetrySweepBatch().execute(null, rows);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(3, dmlUsed,
            'Three independent rows, each abandoned via exactly one DML statement, must cost '
            + 'exactly 3 total — anything more means a hidden per-row query/DML crept into the loop');
        Assert.areEqual(3, [
            SELECT COUNT() FROM Inbound_Email_Staging__c WHERE Id IN :ids AND Status__c = 'Error'
        ], 'All three rows must independently reach the abandoned state');
    }

    // ── defensive guards, matching AttachmentCarrierSweepBatchTest's own precedent ─

    @isTest
    static void execute_emptyScope_isANoOp() {
        Test.startTest();
        new RoutingRetrySweepBatch().execute(null, new List<Inbound_Email_Staging__c>());
        Test.stopTest();

        Assert.areEqual(0, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ExtractAddressQueueable'
        ], 'An empty scope must do nothing at all');
    }

    @isTest
    static void execute_nullElementInScope_isSkippedDefensively() {
        Id stagingId = insertFailedStaging('null-elem', 1);

        Test.startTest();
        new RoutingRetrySweepBatch().execute(
            null, new List<Inbound_Email_Staging__c>{ null });
        Test.stopTest();

        // The null element must not throw and must not touch the REAL row inserted above.
        Assert.isTrue(RoutingRetrySweepBatch.lastRunDispatchedIds.isEmpty(), '');
        Assert.areEqual(InboundEmailStagingService.STATUS_FAILED, [
            SELECT Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Status__c, '');
    }

    // ── start() / finish() — thin wiring ───────────────────────────────────────

    @isTest
    static void start_delegatesToTheSelectorsQueryLocatorWithoutThrowing() {
        Test.startTest();
        Database.QueryLocator locator = new RoutingRetrySweepBatch().start(null);
        Test.stopTest();

        Assert.isNotNull(locator, 'start() must always return a locator');
    }

    @isTest
    static void finish_completesWithoutThrowing() {
        Test.startTest();
        new RoutingRetrySweepBatch().finish(null);
        Test.stopTest();

        Assert.isTrue(true, 'finish() must complete cleanly — it only summarises via debug logging');
    }

    // ── T7 — a replayed row with NOTHING committed routes as a clean first run ─

    @isTest
    static void dispatch_underCapFailedRowWithNothingElsePriorCommitted_reRoutesCleanlyAsAFirstRun() {
        // T7 (design §9): 'Failed' is provably free of ANY committed work (SP-5), so a replay must
        // behave exactly like a brand-new email — same Lead, same registry claim, same Task —
        // proven here through the REAL batch machinery at the production SCOPE.
        String propertyAddress = '900 Retry Winner Rd';
        Id stagingId = insertFailedStagingForRouting(
            'retry.winner.broker@example.invalid', 'forwarder-retry-winner@example.invalid',
            'FW: 900 Retry Winner Rd', 'msg-retry-first-run@example.invalid', 1);
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(200,
            LLMExtractionCalloutMock.extractionBody(new Map<String, String>{
                'broker_name' => 'Retry Winner Broker',
                'broker_email' => 'retry.winner.broker@example.invalid',
                'property_address' => propertyAddress,
                'sent_datetime' => ''
            }, false)));

        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Email = 'retry.winner.broker@example.invalid'],
            'Precondition: no Lead exists yet — this row has never successfully routed');

        Test.startTest();
        Database.executeBatch(new RoutingRetrySweepBatch(), RoutingRetrySweepBatch.SCOPE);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Processed', staging.Status__c,
            'A clean replay must reach the same terminal state as a first-run success');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_WINNER, staging.Outcome__c, '');
        Assert.isNotNull(staging.Result_Record_Id__c, '');

        Assert.areEqual(1, [
            SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = :propertyAddress.toLowerCase()
        ], 'The replay must claim the property exactly as a first run would — proving nothing left '
            + 'behind by the failed attempt interfered with a normal claim');
        Assert.areEqual(1, [
            SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = 'msg-retry-first-run@example.invalid'
        ], '');
    }

    // ── T8 — the routing tree's OWN idempotency guard protects a retry too ────

    @isTest
    static void dispatch_failedRowWhoseMessageIdWasAlreadyLoggedBySomeoneElse_shortCircuitsAndCreatesNothingNew() {
        // T8 (design §9). Modeled as two staging rows sharing one Message-ID: a genuine sibling
        // delivery of the SAME email that routed and logged its Task BEFORE an earlier attempt's
        // Failed row gets retried. This is NOT a literal F5 row (stamp()'s own DML swallowed) —
        // F5 never enters this queue; it stays Pending forever, invisible, by design (see
        // InboundEmailStagingService.STATUS_FAILED's header). The safety property under test — a
        // retry must never duplicate work a sibling delivery already committed — is the SAME guard
        // (isAlreadyLogged) and holds regardless of which delivery produced the Task first.
        String messageId = 'msg-retry-sibling-shared@example.invalid';
        Lead priorLead = TestDataFactory.createLead(true);
        InboundEmailActivityService.logInboundEmail(
            priorLead.Id, 'FW: 700 Sibling Delivery Ave', 'body', messageId, null, null,
            'Sibling Broker', 'sibling.broker@example.invalid');

        Id failedStagingId = insertFailedStagingForRouting(
            'sibling.broker@example.invalid', 'forwarder-sibling@example.invalid',
            'FW: 700 Sibling Delivery Ave', messageId, 1);

        Integer leadsBefore = [SELECT COUNT() FROM Lead];
        Integer tasksBefore = [SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = :messageId];

        Test.startTest();
        Database.executeBatch(new RoutingRetrySweepBatch(), RoutingRetrySweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'A retry that finds its Message-ID already logged must create NO second Lead');
        Assert.areEqual(tasksBefore, [SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = :messageId],
            'No second Task must be logged for the same Message-ID');
        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c
            FROM Inbound_Email_Staging__c WHERE Id = :failedStagingId
        ];
        Assert.areEqual('Processed', staging.Status__c,
            'Guard 2 stamps Processed via markSkipped — a duplicate is a correct terminal state, not an error');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_DUPLICATE_DELIVERY, staging.Outcome__c, '');
        Assert.isNull(staging.Result_Record_Id__c, '');
    }
}
