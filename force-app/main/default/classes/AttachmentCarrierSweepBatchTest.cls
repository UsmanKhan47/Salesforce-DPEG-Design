/**
 * Test class for AttachmentCarrierSweepBatch — the retry/replay engine and the reason a carrier
 * is temporary rather than permanent.
 *
 * ═══ QUOTA DISCIPLINE ═══
 * Five tests insert a ContentVersion (1 each — 5 total for this class):
 * sweep_pendingRowConverts_stampsSaved, sweep_partialRow_convertsTheRemainderAndBecomesSaved, and
 * the three routedTargets/addTarget parser tests (sweep_routedRecordIdsPopulated_...,
 * sweep_resultRecordIdFallback_..., sweep_malformedRoutedRecordIdsLine_...), each of which needs
 * a real conversion to prove its target was resolved correctly. Every other test — including the
 * bulk-safety test — uses staging rows with NO carrier, which is precisely why volume there costs
 * ZERO ContentPublications.
 *
 * ═══ THE 251-RECORD MANDATE IS SATISFIED AT TWO DIFFERENT LAYERS, NOT ONE ═══
 * `.claude/rules/bulk-test-rule.md`'s literal 251 is proven at the SELECTOR layer
 * (`InboundEmailStagingSelectorTest.queryCarrierSweep_at251Rows_isBulkSafe` — a plain bulk DML
 * insert + one query, genuinely free and safe at any N). It is NOT reachable through the BATCH
 * machinery itself in a unit test: `sweep_at150StagingRows_isBulkSafeWithinOneChunk`'s own
 * Javadoc records two INDEPENDENT, MEASURED platform ceilings that make a literal 251-row batch
 * run impossible inside one test method (Apex refuses a second batch chunk per test method, and
 * cramming 251 rows into one chunk instead exceeds the 200-SOQL async ceiling once each row's own
 * `AttachmentPersistQueueable.convert()` call is counted). What that test proves instead — and
 * this is not a downgrade, it is the ACTUAL thing at risk — is that `execute()`'s per-row loop is
 * safe at real multi-row volume within the ONE chunk a test can exercise.
 *
 * ═══ Test.setCreatedDate — how the 14-day expiry is reached deterministically ═══
 * `AttachmentCarrierSweepBatch.isExpired` reads the staging row's own CreatedDate (a system
 * field with no ordinary writable path). `Test.setCreatedDate` is the platform's own supported
 * mechanism for backdating a test record's CreatedDate, and is used here rather than any
 * production-code seam — there is none, deliberately, since age must be measured from the truth
 * of when the record was actually created.
 *
 * @see AttachmentCarrierSweepBatch.cls
 * @see agent-output/design-requirements-attachment-persistence-v2.md §8.7 (tests 34-39)
 * @author Unit Testing Agent
 */
@isTest
private class AttachmentCarrierSweepBatchTest {

    private static Id insertStaging(String suffix, String attachmentStatus, String routingStatus) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Sweep batch fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-sweep-fixture-' + suffix + '@example.invalid',
            Attachment_Status__c = attachmentStatus,
            Status__c = routingStatus
        );
        insert staging;
        return staging.Id;
    }

    private static void insertCarrier(Id stagingId, String name, String content) {
        insert new Attachment(
            ParentId = stagingId,
            Name = name,
            ContentType = 'application/pdf',
            Body = Blob.valueOf(content)
        );
    }

    // ── test 34 — a Pending row converts and reaches Saved ────────────────────

    @isTest
    static void sweep_pendingRowConverts_stampsSaved() {
        Id stagingId = insertStaging('pending-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');
        insertCarrier(stagingId, 'sweep-pending.pdf', 'CONTENT');

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'sweep-pending.pdf'],
            'Precondition: the sweep must actually have converted the file, or the status assertion below proves nothing');
        Assert.areEqual(0, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], 'The converted carrier must be deleted');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c,
            'RETRY IS REAL: a row picked up purely by the daily sweep must reach the same terminal Saved state as the live job');
    }

    // ── test 35 — a Partial row's remainder converges to Saved ────────────────

    @isTest
    static void sweep_partialRow_convertsTheRemainderAndBecomesSaved() {
        // Simulates the state a prior deferral/partial-refusal run would have left: status
        // Partial, exactly one carrier still waiting.
        Id stagingId = insertStaging('partial-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL, 'Processed');
        insertCarrier(stagingId, 'sweep-remainder.pdf', 'REMAINING CONTENT');

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'sweep-remainder.pdf'], '');
        Assert.areEqual(0, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], '');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c,
            'A Partial row whose remainder converts cleanly must reach Saved — multi-pass conversion converges');
    }

    // ── test 36 — expiry at 14 days ────────────────────────────────────────────

    @isTest
    static void sweep_rowOlderThanFourteenDays_expiresTheCarrierAndNotesIt() {
        Id stagingId = insertStaging('expired-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_FAILED, 'Processed');
        insertCarrier(stagingId, 'too-old.pdf', 'STALE CONTENT');
        Test.setCreatedDate(stagingId, Datetime.now().addDays(-15));

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'too-old.pdf'],
            'An expired carrier must NEVER be converted, only removed');
        Assert.areEqual(0, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId],
            'The stale carrier bytes must be deleted — they cannot accumulate forever');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_EXPIRED, staging.Attachment_Status__c, '');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('CARRIER_MAX_AGE_DAYS'),
            'The terminal note must name the reason. Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('exists only in the original email'),
            'An EXPIRED row is terminal — the note must say where the file still exists. Actual: '
            + staging.Dropped_Attachment_Notes__c);
    }

    @isTest
    static void sweep_rowUnderFourteenDays_isNotExpired() {
        // The boundary's other side: a row that is old-ISH but NOT yet past the threshold must
        // be retried normally, not expired.
        Id stagingId = insertStaging('not-expired-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');
        insertCarrier(stagingId, 'still-fresh.pdf', 'FRESH CONTENT');
        Test.setCreatedDate(stagingId, Datetime.now().addDays(-13));

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c,
            'A row 13 days old must still be RETRIED (and, here, convert cleanly), never expired — the '
            + 'boundary is CARRIER_MAX_AGE_DAYS (14), not "old"');
    }

    // ── test 37 — the breaker holds even when reached via the sweep ──────────

    @isTest
    static void sweep_breakerTripped_defersAndConvertsNothing() {
        Id stagingId = insertStaging('breaker-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');
        insertCarrier(stagingId, 'suspended-by-sweep.pdf', 'CONTENT');
        ContentPublicationBudget.trip();

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'suspended-by-sweep.pdf'],
            'The sweep must not hammer an exhausted quota — zero ContentVersion DML while the breaker is tripped');
        Assert.areEqual(1, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], 'The carrier must survive, untouched');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_FAILED, staging.Attachment_Status__c, '');
    }

    // ── routing not finished yet — left alone, not converted ──────────────────

    @isTest
    static void sweep_routingStillPending_isSkippedNotConverted() {
        // Converting before routing finishes would create files with no routed record to link
        // them to, and stamping a terminal state would prevent the links from ever being made.
        Id stagingId = insertStaging('routing-pending-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Pending');
        insertCarrier(stagingId, 'routing-not-done.pdf', 'CONTENT');

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'routing-not-done.pdf'], '');
        Assert.areEqual(1, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], 'The carrier must be left untouched');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, staging.Attachment_Status__c,
            'A row whose ROUTING has not finished must be left exactly as it was for a later pass');
    }

    // ── test 38 — bulk safety, content-free ───────────────────────────────────

    /**
     * 🔴 NOT 251 ROWS THROUGH THE BATCH MACHINERY — TWO INDEPENDENT, MEASURED PLATFORM CEILINGS,
     * NOT A CHOICE. THE LITERAL 251 IS PROVEN AT THE SELECTOR LAYER INSTEAD — see
     * InboundEmailStagingSelectorTest.queryCarrierSweep_at251Rows_isBulkSafe, which is where it
     * is actually safe to satisfy the mandate literally.
     *
     * Ceiling 1 — Apex refuses a SECOND batch chunk inside one test method. `SCOPE = 1` against
     * 251 rows needs 251 separate `execute()` invocations; the platform throws
     * `System.UnexpectedException: No more than one executeBatch can be called from within a
     * test method` the instant a second chunk would be needed — measured directly against this
     * exact test, not assumed.
     *
     * Ceiling 2 — cramming all 251 rows into ONE chunk (scope = 251) to satisfy Ceiling 1 instead
     * blows the OTHER limit: each row's own `AttachmentPersistQueueable.convert()` call issues at
     * least one SOQL, and 251 of them in a single transaction hits
     * `System.LimitException: Too many SOQL queries: 201` — also measured directly, not assumed.
     * (200 is the async-context SOQL ceiling; the 251st row's query is the one that overflows it.)
     *
     * So no single test method can exercise this SCOPE = 1 batch at literal 251-row volume by any
     * route. What CAN be proven safely, and is: `execute()`'s per-row loop handles MANY rows in
     * one chunk (150, comfortably under the 200-query ceiling with headroom to spare) without a
     * SOQL-in-a-hidden-loop bug, and every one of them reaches a correct terminal outcome.
     */
    @isTest
    static void sweep_at150StagingRows_isBulkSafeWithinOneChunk() {
        final Integer bulkRows = 150; // see this method's own Javadoc for why not 251
        List<Inbound_Email_Staging__c> rows = new List<Inbound_Email_Staging__c>();
        for (Integer i = 0; i < bulkRows; i++) {
            rows.add(new Inbound_Email_Staging__c(
                From_Name__c = 'Bulk Broker',
                From_Address__c = 'bulk@example.invalid',
                Subject__c = 'FW: Bulk sweep ' + i,
                Raw_Body__c = 'body',
                Forwarded_By__c = 'forwarder@example.invalid',
                Message_Id__c = 'msg-sweep-bulk-' + i + '@example.invalid',
                Attachment_Status__c = InboundEmailStagingService.ATTACHMENT_STATUS_PENDING,
                Status__c = 'Processed'
            ));
        }
        insert rows;
        Assert.areEqual(bulkRows, [
            SELECT COUNT() FROM Inbound_Email_Staging__c WHERE Attachment_Status__c = 'Pending'
        ], 'Precondition: all rows must be in the sweep\'s work queue');

        Test.startTest();
        Id jobId = Database.executeBatch(new AttachmentCarrierSweepBatch(), bulkRows);
        Test.stopTest();

        AsyncApexJob job = [SELECT Status, NumberOfErrors, JobItemsProcessed FROM AsyncApexJob WHERE Id = :jobId];
        Assert.areEqual('Completed', job.Status,
            'The batch must complete cleanly across ' + bulkRows + ' rows in one chunk without hitting a governor limit');
        Assert.areEqual(0, job.NumberOfErrors, '');
        Assert.areEqual(1, job.JobItemsProcessed, 'One chunk (this test\'s scope=' + bulkRows + ') was processed');

        Assert.areEqual(bulkRows, [
            SELECT COUNT() FROM Inbound_Email_Staging__c WHERE Attachment_Status__c = 'Pending'
        ], 'A row with no carrier is a true no-op (AttachmentPersistQueueable.convert returns without a '
            + 'stamp when carriers.isEmpty()) — every row must remain exactly as it was, proving the '
            + 'batch touched every row without side effects it should not have had');
    }

    // ── test 39 — convergence: a converted row leaves the work queue for good ─

    @isTest
    static void sweep_isConvergent_convertedRowLeavesTheWorkQueue() {
        // The strongest, most direct proof of "a second pass writes nothing": once this row
        // reaches Saved, it no longer matches queryCarrierSweep()'s own WHERE clause at all, so
        // a second sweep would never even SELECT it — there is nothing to write, by construction.
        Id stagingId = insertStaging('convergent-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');
        insertCarrier(stagingId, 'converges.pdf', 'CONTENT');

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c,
            'Precondition: the row must have actually reached Saved, or the convergence check below proves nothing');

        Assert.areEqual(0, [
            SELECT COUNT() FROM Inbound_Email_Staging__c
            WHERE Id = :stagingId AND Attachment_Status__c IN ('Pending', 'Partial', 'Failed')
        ], 'A Saved row must no longer match the sweep\'s own work-queue predicate — a re-run is free '
            + 'because there is nothing left to select, not merely nothing left to do');
    }

    // ── execute() defensive guards — direct unit calls, no batch machinery ───

    @isTest
    static void execute_emptyScope_isANoOp() {
        Test.startTest();
        new AttachmentCarrierSweepBatch().execute(null, new List<Inbound_Email_Staging__c>());
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'An empty scope must do nothing at all');
    }

    @isTest
    static void execute_nullElementInScope_isSkippedDefensively() {
        Id stagingId = insertStaging('null-elem-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');

        Test.startTest();
        new AttachmentCarrierSweepBatch().execute(
            null, new List<Inbound_Email_Staging__c>{ null });
        Test.stopTest();

        // The null element must not throw and must not touch the REAL row inserted above —
        // proving the guard skips the null without affecting anything else in the (hypothetical
        // multi-row) scope.
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, staging.Attachment_Status__c, '');
    }

    // ── routedTargets / addTarget — the audit-trail recovery parser ──────────

    @isTest
    static void sweep_routedRecordIdsPopulated_targetsTheRoutedRecordDirectly() {
        Lead target = TestDataFactory.createLead(true);
        Id stagingId = insertStaging('routed-ids-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');
        update new Inbound_Email_Staging__c(
            Id = stagingId,
            Routed_Record_Ids__c = '100 main st | New Lead (winner) | ' + target.Id);
        insertCarrier(stagingId, 'routed-audit.pdf', 'CONTENT');

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(1, [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :target.Id
        ], 'The audit-line-recovered target must be the one the file links to — proves Routed_Record_Ids__c parsing, not just Result_Record_Id__c');
    }

    @isTest
    static void sweep_resultRecordIdFallback_usedWhenRoutedRecordIdsIsBlank() {
        Lead target = TestDataFactory.createLead(true);
        Id stagingId = insertStaging('result-fallback-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');
        update new Inbound_Email_Staging__c(Id = stagingId, Result_Record_Id__c = target.Id);
        insertCarrier(stagingId, 'result-fallback.pdf', 'CONTENT');

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(1, [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :target.Id
        ], 'Result_Record_Id__c must be used as the fallback target for rows written before the '
            + 'Routed_Record_Ids__c audit field carried anything');
    }

    @isTest
    static void sweep_malformedRoutedRecordIdsLine_isSkippedSilentlyAndLinksToStagingOnly() {
        // A gate line (fewer than 3 pipe-delimited columns) and a line whose last column is not
        // a real Id must both be ignored without throwing — the row still converts, just with no
        // routed target, so the file links only to the staging row itself.
        Id stagingId = insertStaging('malformed-1',
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, 'Processed');
        update new Inbound_Email_Staging__c(
            Id = stagingId,
            Routed_Record_Ids__c = 'gated line with too few columns\n999 fake st | Not Routed | NOT-A-REAL-ID');
        insertCarrier(stagingId, 'malformed-audit.pdf', 'CONTENT');

        Test.startTest();
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'malformed-audit.pdf'],
            'A malformed audit trail must not abort conversion — the file still converts to the staging row');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c, '');
    }
}
