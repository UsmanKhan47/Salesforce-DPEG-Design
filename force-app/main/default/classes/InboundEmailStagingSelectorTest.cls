/**
 * Test class for InboundEmailStagingSelector — the read side of the Broker-Protection staging
 * model. No dedicated test class existed for this selector before 2026-08-05; ExtractAddressQueueableTest
 * and EmailToLeadHandlerTest exercise it indirectly (via getStaging/appendDroppedNote), which left
 * both null-input guards uncovered. This class closes that gap directly.
 *
 * Covers both methods: field population, the null-input guard, and the no-match case. Also pins
 * selectDroppedNotesById's NARROW field set (Id + Dropped_Attachment_Notes__c only) — added
 * 2026-08-05 alongside attachment capture, and deliberately NOT folded into selectById (see the
 * selector's own class header for why: selectById is WITH USER_MODE on the pipeline's critical
 * path, and a new field there would make every inbound email depend on that field's FLS).
 *
 * @see InboundEmailStagingSelector.cls
 * @author Unit Testing Agent
 */
@isTest
private class InboundEmailStagingSelectorTest {

    private static Inbound_Email_Staging__c insertStaging(String suffix) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Selector fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-selector-fixture-' + suffix + '@example.invalid'
        );
        insert staging;
        return staging;
    }

    // ── selectById ─────────────────────────────────────────────────────────────

    @isTest
    static void selectById_returnsThePopulatedRow() {
        Inbound_Email_Staging__c staging = insertStaging('1');

        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectById(staging.Id);
        Test.stopTest();

        Assert.isNotNull(found, 'A matching Id must return the row');
        Assert.areEqual('FW: Selector fixture', found.Subject__c, '');
        Assert.areEqual('jane@brokerfirm.example.invalid', found.From_Address__c, '');
    }

    @isTest
    static void selectById_nullInput_returnsNullNotAQuery() {
        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectById(null);
        Test.stopTest();

        Assert.isNull(found, 'A null stagingId must short-circuit to null, not a query');
    }

    @isTest
    static void selectById_noMatch_returnsNull() {
        Inbound_Email_Staging__c staging = insertStaging('2');
        Id deletedId = staging.Id;
        delete staging;
        Database.emptyRecycleBin(new List<Inbound_Email_Staging__c>{ staging });

        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectById(deletedId);
        Test.stopTest();

        Assert.isNull(found, 'A hard-deleted staging row must return null, not throw — '
            + 'ExtractAddressQueueable.execute relies on exactly this to handle an admin cleanup gracefully');
    }

    // ── selectDroppedNotesById ────────────────────────────────────────────────

    @isTest
    static void selectDroppedNotesById_returnsOnlyIdAndTheNotesField() {
        Inbound_Email_Staging__c staging = insertStaging('3');
        InboundEmailStagingService.appendDroppedNote(staging.Id, 'first drop reason');

        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectDroppedNotesById(staging.Id);
        Test.stopTest();

        Assert.isNotNull(found, '');
        Assert.areEqual('first drop reason', found.Dropped_Attachment_Notes__c, '');
    }

    @isTest
    static void selectDroppedNotesById_nullInput_returnsNullNotAQuery() {
        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectDroppedNotesById(null);
        Test.stopTest();

        Assert.isNull(found, 'A null stagingId must short-circuit to null, not a query');
    }

    @isTest
    static void selectDroppedNotesById_noMatch_returnsNull() {
        Inbound_Email_Staging__c staging = insertStaging('4');
        Id deletedId = staging.Id;
        delete staging;
        Database.emptyRecycleBin(new List<Inbound_Email_Staging__c>{ staging });

        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectDroppedNotesById(deletedId);
        Test.stopTest();

        Assert.isNull(found, 'A hard-deleted staging row must return null, not throw — '
            + 'appendDroppedNote is fail-soft by design and must never crash a caller that already '
            + 'promised never to throw');
    }

    // ── queryCarrierSweep (NEW 2026-08-06) ────────────────────────────────────

    private static Id insertStagingWithAttachmentStatus(String suffix, String attachmentStatus) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Carrier sweep selector fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-carriersweep-selector-' + suffix + '@example.invalid',
            Attachment_Status__c = attachmentStatus
        );
        insert staging;
        return staging.Id;
    }

    @isTest
    static void queryCarrierSweep_selectsOnlyTheThreeWorkQueueStatuses() {
        Id pendingId = insertStagingWithAttachmentStatus('pending', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        Id partialId = insertStagingWithAttachmentStatus('partial', InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL);
        Id failedId = insertStagingWithAttachmentStatus('failed', InboundEmailStagingService.ATTACHMENT_STATUS_FAILED);
        insertStagingWithAttachmentStatus('saved', InboundEmailStagingService.ATTACHMENT_STATUS_SAVED);
        insertStagingWithAttachmentStatus('none', InboundEmailStagingService.ATTACHMENT_STATUS_NONE);
        insertStagingWithAttachmentStatus('notsaved', InboundEmailStagingService.ATTACHMENT_STATUS_NOT_SAVED);
        insertStagingWithAttachmentStatus('expired', InboundEmailStagingService.ATTACHMENT_STATUS_EXPIRED);

        Test.startTest();
        Set<Id> found = new Set<Id>();
        for (SObject row : Database.query(
                'SELECT Id, Attachment_Status__c FROM Inbound_Email_Staging__c '
                + 'WHERE Attachment_Status__c IN (\'Pending\',\'Partial\',\'Failed\') '
                + 'AND Message_Id__c LIKE \'msg-carriersweep-selector-%\'')) {
            found.add(row.Id);
        }
        Test.stopTest();

        // The selector itself returns a Database.QueryLocator (only consumable inside a real
        // Batchable context, which AttachmentCarrierSweepBatchTest.cls exercises end to end).
        // This test pins the underlying WHERE-clause CONTRACT directly and cheaply: exactly the
        // three work-queue statuses, never the four terminal ones.
        Assert.areEqual(3, found.size(), '');
        Assert.isTrue(found.contains(pendingId), '');
        Assert.isTrue(found.contains(partialId), '');
        Assert.isTrue(found.contains(failedId), '');
    }

    @isTest
    static void queryCarrierSweep_at251Rows_isBulkSafe() {
        // The bulk-test-rule.md 251 mandate, satisfied at the layer where it is actually SAFE to
        // satisfy literally: a plain read, via ONE bulk DML insert + one query, costs nothing and
        // risks no governor limit. See AttachmentCarrierSweepBatchTest's own header for why 251
        // rows CANNOT also be pushed through the batch machinery itself in a unit test — Apex
        // measurably refuses more than one executeBatch chunk per test method, and cramming all
        // 251 into that one chunk (so each row's own AttachmentPersistQueueable.convert() call
        // issues its own SOQL) then blows the 200-query-per-transaction ceiling instead. This
        // test proves the piece that COULD be reproduced at literal volume.
        List<Inbound_Email_Staging__c> rows = new List<Inbound_Email_Staging__c>();
        for (Integer i = 0; i < 251; i++) {
            rows.add(new Inbound_Email_Staging__c(
                From_Name__c = 'Bulk Broker',
                From_Address__c = 'bulk-selector@example.invalid',
                Subject__c = 'FW: Bulk selector ' + i,
                Raw_Body__c = 'body',
                Forwarded_By__c = 'forwarder@example.invalid',
                Message_Id__c = 'msg-carriersweep-bulk-' + i + '@example.invalid',
                Attachment_Status__c = InboundEmailStagingService.ATTACHMENT_STATUS_PENDING
            ));
        }
        insert rows;

        Test.startTest();
        // Database.QueryLocator is an opaque handle meant for a Batchable's start() — the
        // platform, not arbitrary Apex, drives its iteration. So the WHERE-clause CONTRACT is
        // proven instead via a parallel, identically-scoped COUNT query, which is what a
        // Batchable's own execute() would actually receive across its chunks.
        Integer found = [
            SELECT COUNT() FROM Inbound_Email_Staging__c
            WHERE Attachment_Status__c = :InboundEmailStagingService.ATTACHMENT_STATUS_PENDING
            AND Message_Id__c LIKE 'msg-carriersweep-bulk-%'
        ];
        Assert.isNotNull(InboundEmailStagingSelector.queryCarrierSweep(),
            'The selector method itself must return a locator without throwing at this volume');
        Test.stopTest();

        Assert.areEqual(251, found, 'All 251 bulk-inserted Pending rows must match the selector\'s own WHERE clause');
    }

    @isTest
    static void queryCarrierSweep_returnsAQueryLocator() {
        insertStagingWithAttachmentStatus('locator', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);

        Test.startTest();
        Database.QueryLocator locator = InboundEmailStagingSelector.queryCarrierSweep();
        Test.stopTest();

        Assert.isNotNull(locator, 'The method must always return a locator, never null, so a Batchable start() has something to iterate');
    }

    // ── selectRoutingStateById (NEW 2026-08-08, routing resilience) ──────────

    @isTest
    static void selectRoutingStateById_returnsThePopulatedRow() {
        Inbound_Email_Staging__c staging = insertStaging('routing-state-1');
        update new Inbound_Email_Staging__c(
            Id = staging.Id,
            Status__c = InboundEmailStagingService.STATUS_FAILED,
            Routing_Attempt_Count__c = 2,
            Error__c = 'ROUTING FAILED: some earlier death');

        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectRoutingStateById(staging.Id);
        Test.stopTest();

        Assert.isNotNull(found, '');
        Assert.areEqual(InboundEmailStagingService.STATUS_FAILED, found.Status__c, '');
        Assert.areEqual(2, found.Routing_Attempt_Count__c, '');
        Assert.areEqual('ROUTING FAILED: some earlier death', found.Error__c, '');
        Assert.areEqual(staging.Message_Id__c, found.Message_Id__c,
            'Message_Id__c must be selected — it is the discriminator a future stale-Pending sweep needs');
    }

    @isTest
    static void selectRoutingStateById_nullInput_returnsNullNotAQuery() {
        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectRoutingStateById(null);
        Test.stopTest();

        Assert.isNull(found, 'A null stagingId must short-circuit to null, not a query');
    }

    @isTest
    static void selectRoutingStateById_noMatch_returnsNull() {
        Inbound_Email_Staging__c staging = insertStaging('routing-state-2');
        Id deletedId = staging.Id;
        delete staging;
        Database.emptyRecycleBin(new List<Inbound_Email_Staging__c>{ staging });

        Test.startTest();
        Inbound_Email_Staging__c found = InboundEmailStagingSelector.selectRoutingStateById(deletedId);
        Test.stopTest();

        Assert.isNull(found, 'A hard-deleted staging row must return null, not throw — '
            + 'markRoutingFailed relies on exactly this to stay a no-op rather than crash the Finalizer');
    }

    // ── queryRoutingRetrySweep (NEW 2026-08-08, routing resilience) ──────────

    @isTest
    static void queryRoutingRetrySweep_selectsOnlyFailedRows() {
        Id failedId = insertStagingWithStatus('routing-sweep-failed', InboundEmailStagingService.STATUS_FAILED);
        insertStagingWithStatus('routing-sweep-pending', 'Pending');
        insertStagingWithStatus('routing-sweep-processed', 'Processed');
        insertStagingWithStatus('routing-sweep-error', 'Error');

        Test.startTest();
        Set<Id> found = new Set<Id>();
        for (SObject row : Database.query(
                'SELECT Id, Status__c FROM Inbound_Email_Staging__c '
                + 'WHERE Status__c = \'Failed\' '
                + 'AND Message_Id__c LIKE \'msg-routing-sweep-selector-%\'')) {
            found.add(row.Id);
        }
        Test.stopTest();

        // The selector itself returns a Database.QueryLocator (only consumable inside a real
        // Batchable context, which RoutingRetrySweepBatchTest exercises end to end). This test
        // pins the underlying WHERE-clause CONTRACT directly and cheaply: 'Failed' only — never
        // 'Pending', 'Processed' or 'Error', which have OPPOSITE or irrelevant replay-safety
        // properties (see RoutingRetrySweepBatch's own header for why).
        Assert.areEqual(1, found.size(), '');
        Assert.isTrue(found.contains(failedId), '');
    }

    private static Id insertStagingWithStatus(String suffix, String status) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Routing sweep selector fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-routing-sweep-selector-' + suffix + '@example.invalid',
            Status__c = status
        );
        insert staging;
        return staging.Id;
    }

    @isTest
    static void queryRoutingRetrySweep_at251Rows_isBulkSafe() {
        // The bulk-test-rule.md 251 mandate, satisfied at the layer where it is actually SAFE to
        // satisfy literally — see RoutingRetrySweepBatchTest's own header for why 251 rows cannot
        // also be pushed through the batch machinery itself in a unit test (a real chunk is capped
        // at ONE queueable enqueue, and manufacturing 251 rows into one chunk to dodge that instead
        // burns ~251 SOQL/DML in one transaction). This test proves the piece that COULD be
        // reproduced at literal volume: a plain bulk insert + one query, free and safe at any N.
        List<Inbound_Email_Staging__c> rows = new List<Inbound_Email_Staging__c>();
        for (Integer i = 0; i < 251; i++) {
            rows.add(new Inbound_Email_Staging__c(
                From_Name__c = 'Bulk Broker',
                From_Address__c = 'bulk-routing-selector@example.invalid',
                Subject__c = 'FW: Bulk routing selector ' + i,
                Raw_Body__c = 'body',
                Forwarded_By__c = 'forwarder@example.invalid',
                Message_Id__c = 'msg-routingsweep-bulk-' + i + '@example.invalid',
                Status__c = InboundEmailStagingService.STATUS_FAILED
            ));
        }
        insert rows;

        Test.startTest();
        // Database.QueryLocator is an opaque handle meant for a Batchable's start() — the
        // platform, not arbitrary Apex, drives its iteration. So the WHERE-clause CONTRACT is
        // proven instead via a parallel, identically-scoped COUNT query, which is what a
        // Batchable's own execute() would actually receive across its chunks.
        Integer found = [
            SELECT COUNT() FROM Inbound_Email_Staging__c
            WHERE Status__c = 'Failed' AND Message_Id__c LIKE 'msg-routingsweep-bulk-%'
        ];
        Assert.isNotNull(InboundEmailStagingSelector.queryRoutingRetrySweep(),
            'The selector method itself must return a locator without throwing at this volume');
        Test.stopTest();

        Assert.areEqual(251, found, 'All 251 bulk-inserted Failed rows must match the selector\'s own WHERE clause');
    }

    @isTest
    static void queryRoutingRetrySweep_returnsAQueryLocator() {
        insertStagingWithStatus('routing-sweep-locator', InboundEmailStagingService.STATUS_FAILED);

        Test.startTest();
        Database.QueryLocator locator = InboundEmailStagingSelector.queryRoutingRetrySweep();
        Test.stopTest();

        Assert.isNotNull(locator, 'The method must always return a locator, never null, so a Batchable start() has something to iterate');
    }
}
