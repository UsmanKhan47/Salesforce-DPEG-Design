/**
 * Test class for InboundEmailStagingService — the ONLY place an Inbound_Email_Staging__c row is
 * inserted or updated (staging model). No dedicated test class existed before 2026-08-05;
 * EmailToLeadHandlerTest and ExtractAddressQueueableTest already exercise createStaging,
 * getStaging, markRouted and markSkipped indirectly through the real pipeline, so this class
 * focuses on what those integration paths do NOT reach: the null-input guards on every method,
 * appendDroppedNote's read-then-append merge behaviour (the new method added 2026-08-05 with
 * attachment capture), and markProcessed/markError — public methods with no current caller in
 * the pipeline (markRouted/markSkipped cover their call sites today) but still part of this
 * class's public contract and therefore still owed direct coverage.
 *
 * ⚠ TWO SMALL, DELIBERATE RESIDUAL GAPS — the `catch (DmlException de)` bodies inside
 * storeExtractedJson and stamp() are NOT independently exercised here. Both exist to swallow a
 * genuine platform DML failure on an otherwise-valid update (see the FAIL-SOFT note in this
 * class's own header), and forcing one deterministically would require either a contrived
 * cross-object-type Id assignment (which throws a DIFFERENT, uncaught exception type before DML
 * even runs, proving nothing about this catch) or a live FLS/validation-rule failure unrelated to
 * this feature. This mirrors the documented CMDT-provider and describe-guard residual gaps
 * elsewhere in this codebase — a genuine ceiling, not an oversight.
 *
 * @see InboundEmailStagingService.cls
 * @author Unit Testing Agent
 */
@isTest
private class InboundEmailStagingServiceTest {

    private static InboundEmailStagingService.StagingRequest minimalRequest(String messageId) {
        InboundEmailStagingService.StagingRequest request = new InboundEmailStagingService.StagingRequest();
        request.fromName = 'Jane Broker';
        request.fromAddress = 'jane@brokerfirm.example.invalid';
        request.subject = 'FW: Service fixture';
        request.rawBody = 'body';
        request.forwardedBy = 'forwarder@example.invalid';
        request.messageId = messageId;
        return request;
    }

    // ── createStaging ──────────────────────────────────────────────────────────

    @isTest
    static void createStaging_zeroAttachmentFields_stampsCountAndBytesAsZeroNotNull() {
        // Pins the same "0, never null" compatibility contract EmailToLeadHandlerTest asserts at
        // the boundary level, but DIRECTLY against this service — the class that actually owns
        // the stamp.
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-create-1@example.invalid');
        request.attachmentCount = 0;
        request.attachmentBytes = 0;
        request.droppedNotes = null;

        Test.startTest();
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Attachment_Bytes__c, Dropped_Attachment_Notes__c, Status__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(0, staging.Attachment_Count__c, '');
        Assert.areEqual(0, staging.Attachment_Bytes__c, '');
        Assert.isNull(staging.Dropped_Attachment_Notes__c, '');
        Assert.areEqual('Pending', staging.Status__c, 'createStaging always starts a row Pending');
    }

    @isTest
    static void createStaging_withAttachmentFields_stampsThemAllInTheSameInsert() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-create-2@example.invalid');
        request.attachmentCount = 2;
        request.attachmentBytes = 54321;
        request.droppedNotes = 'logo.png | png | 5000 | image below IMAGE_MIN_BYTES';

        Test.startTest();
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Attachment_Bytes__c, Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(2, staging.Attachment_Count__c, '');
        Assert.areEqual(54321, staging.Attachment_Bytes__c, '');
        Assert.areEqual('logo.png | png | 5000 | image below IMAGE_MIN_BYTES', staging.Dropped_Attachment_Notes__c, '');
    }

    // ── WS1 (2026-08-30) — Received_DateTime__c rides the EXISTING insert ─────

    @isTest
    static void createStaging_receivedDateTime_isStampedInTheSameInsert() {
        // The claim is "the same insert", not merely "the value arrives": the whole reason WS1 is
        // free at this boundary is that it adds no statement to EmailToLeadHandler's pinned
        // 0 SOQL / 2 DML budget. The DML assertion below is what makes that structural rather
        // than aspirational — an implementation that updated the row afterwards would read 2.
        Datetime received = Datetime.newInstanceGmt(2026, 8, 26, 19, 3, 22);
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-ws1-1@example.invalid');
        request.receivedDateTime = received;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Received_DateTime__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(received, staging.Received_DateTime__c,
            'Received_DateTime__c must carry the parsed RFC Date header verbatim');
        Assert.areEqual(1, dmlUsed,
            'EXACTLY ONE DML: the value must ride the EXISTING staging insert. If this reads 2, WS1 has '
            + 'started costing the inbound-email boundary a statement it does not have to spare');
    }

    @isTest
    static void createStaging_nullReceivedDateTime_stampsNullAndDoesNotSubstituteNow() {
        // The absent/unparseable-header case, which is ordinary rather than exceptional. The
        // fallback to CreatedDate belongs to ExtractAddressQueueable and to nothing else — a
        // second fallback here would be a second rule to keep in step with the first.
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-ws1-2@example.invalid');
        request.receivedDateTime = null;

        Test.startTest();
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Received_DateTime__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.isNull(staging.Received_DateTime__c,
            'A null must be written as null. Substituting Datetime.now() here would silently make every '
            + 'header-less email look as though it carried a readable Date header, and would put a '
            + 'SECOND fallback rule in a second layer');
    }

    // ── appendDroppedNote (NEW, 2026-08-05) ───────────────────────────────────

    @isTest
    static void appendDroppedNote_blankExistingNotes_setsTheFirstNote() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-append-1@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);

        Test.startTest();
        InboundEmailStagingService.appendDroppedNote(stagingId, 'file.pdf | pdf | 1000 | link refused');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('file.pdf | pdf | 1000 | link refused', staging.Dropped_Attachment_Notes__c, '');
    }

    @isTest
    static void appendDroppedNote_existingNotes_appendsRatherThanOverwriting() {
        // Pins the READ-THEN-APPEND contract: classification drops are written by createStaging
        // at the synchronous boundary, and ContentDocumentLink refusals arrive LATER from the
        // async router — both must survive in the same field.
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-append-2@example.invalid');
        request.droppedNotes = 'first-drop.exe | x-msdownload | 500 | type not in the allow-list';
        Id stagingId = InboundEmailStagingService.createStaging(request);

        Test.startTest();
        InboundEmailStagingService.appendDroppedNote(stagingId, 'second-link-refusal | INVALID_CROSS_REFERENCE_KEY');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(
            'first-drop.exe | x-msdownload | 500 | type not in the allow-list\nsecond-link-refusal | INVALID_CROSS_REFERENCE_KEY',
            staging.Dropped_Attachment_Notes__c,
            'The classification-time note must be PRESERVED, and the new refusal appended on its own line');
    }

    @isTest
    static void appendDroppedNote_nullStagingId_isANoOp() {
        Test.startTest();
        InboundEmailStagingService.appendDroppedNote(null, 'some note');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c], 'A null stagingId must be a pure no-op — nothing to update');
    }

    @isTest
    static void appendDroppedNote_blankNote_isANoOp() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-append-3@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);

        Test.startTest();
        InboundEmailStagingService.appendDroppedNote(stagingId, null);
        InboundEmailStagingService.appendDroppedNote(stagingId, '');
        InboundEmailStagingService.appendDroppedNote(stagingId, '   ');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.isNull(staging.Dropped_Attachment_Notes__c, 'A blank note (null, empty, or whitespace-only) must never overwrite the field with junk');
    }

    // ── getStaging ─────────────────────────────────────────────────────────────

    @isTest
    static void getStaging_delegatesToTheSelector() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-get-1@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);

        Test.startTest();
        Inbound_Email_Staging__c staging = InboundEmailStagingService.getStaging(stagingId);
        Test.stopTest();

        Assert.isNotNull(staging, '');
        Assert.areEqual('FW: Service fixture', staging.Subject__c, '');
    }

    @isTest
    static void getStaging_missingRow_returnsNull() {
        Test.startTest();
        Inbound_Email_Staging__c staging = InboundEmailStagingService.getStaging(null);
        Test.stopTest();

        Assert.isNull(staging, '');
    }

    // ── storeExtractedJson ────────────────────────────────────────────────────

    @isTest
    static void storeExtractedJson_validStagingId_updatesTheField() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-json-1@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);

        Test.startTest();
        InboundEmailStagingService.storeExtractedJson(stagingId, '{"broker_name":"Jane Broker"}');
        Test.stopTest();

        Assert.areEqual('{"broker_name":"Jane Broker"}',
            [SELECT Extracted_JSON__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId].Extracted_JSON__c, '');
    }

    @isTest
    static void storeExtractedJson_nullStagingId_isANoOp() {
        Test.startTest();
        InboundEmailStagingService.storeExtractedJson(null, '{"anything":"here"}');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c], '');
    }

    // ── markRouted / markProcessed / markSkipped / markError ─────────────────

    @isTest
    static void markRouted_blankErrorText_stampsProcessedWithTheFullNResultPicture() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-routed-1@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Lead lead = TestDataFactory.createLead(true);

        InboundEmailStagingService.RoutingResult result = new InboundEmailStagingService.RoutingResult();
        result.resultRecordId = lead.Id;
        result.outcome = 'New Lead (winner)';
        result.routedRecordIds = '100 Main St | New Lead (winner) | ' + lead.Id;
        result.propertyCount = 1;
        result.errorText = null;

        Test.startTest();
        InboundEmailStagingService.markRouted(stagingId, result);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c, Routed_Record_Ids__c, Property_Count__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Processed', staging.Status__c, 'A blank errorText must stamp Processed');
        Assert.areEqual('New Lead (winner)', staging.Outcome__c, '');
        Assert.areEqual(String.valueOf(lead.Id), staging.Result_Record_Id__c, '');
        Assert.isNull(staging.Error__c, '');
    }

    @isTest
    static void markRouted_nonBlankErrorText_stampsErrorButKeepsWhatDidSucceed() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-routed-2@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Lead lead = TestDataFactory.createLead(true);

        InboundEmailStagingService.RoutingResult result = new InboundEmailStagingService.RoutingResult();
        result.resultRecordId = lead.Id;
        result.outcome = 'New Lead (winner)';
        result.errorText = 'System.DmlException | some failure | line 42 | stack';

        Test.startTest();
        InboundEmailStagingService.markRouted(stagingId, result);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Outcome__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Error', staging.Status__c, 'A non-blank errorText must stamp Error');
        Assert.areEqual('New Lead (winner)', staging.Outcome__c, 'The outcome reached BEFORE the failure must still be recorded');
        Assert.isTrue(staging.Error__c.contains('some failure'), '');
    }

    @isTest
    static void markProcessed_stampsTheSuccessState() {
        // markProcessed / markError have no caller in the current pipeline (markRouted /
        // markSkipped cover their call sites) but remain public API and are owed direct coverage.
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-processed-1@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Lead lead = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailStagingService.markProcessed(stagingId, lead.Id, 'New Lead (winner)');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c, Error__c, Processed_DateTime__c
            FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Processed', staging.Status__c, '');
        Assert.areEqual('New Lead (winner)', staging.Outcome__c, '');
        Assert.areEqual(String.valueOf(lead.Id), staging.Result_Record_Id__c, '');
        Assert.isNull(staging.Error__c, '');
        Assert.isNotNull(staging.Processed_DateTime__c, '');
    }

    @isTest
    static void markSkipped_stampsProcessedWithTheSkipLabelAndNoResultRecord() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-skipped-1@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);

        Test.startTest();
        InboundEmailStagingService.markSkipped(stagingId, 'Duplicate Delivery (skipped)');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Processed', staging.Status__c,
            'A redelivery skip is a correct terminal state, not an error — Status__c has no separate "skipped" value');
        Assert.areEqual('Duplicate Delivery (skipped)', staging.Outcome__c, '');
        Assert.isNull(staging.Result_Record_Id__c, '');
    }

    @isTest
    static void markError_stampsTheErrorStateWithWhateverHadAlreadySucceeded() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-error-1@example.invalid');
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Lead lead = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailStagingService.markError(stagingId, lead.Id, 'New Lead (winner)',
            'System.DmlException | Task insert failed | line 10 | stack');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Error', staging.Status__c, '');
        Assert.areEqual('New Lead (winner)', staging.Outcome__c,
            'The claim that succeeded BEFORE the failure must still be recorded, never discarded');
        Assert.areEqual(String.valueOf(lead.Id), staging.Result_Record_Id__c, '');
        Assert.isTrue(staging.Error__c.contains('Task insert failed'), '');
    }

    @isTest
    static void markProcessed_nullStagingId_isANoOp() {
        Test.startTest();
        InboundEmailStagingService.markProcessed(null, null, 'anything');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c], '');
    }

    // ── createStaging — Attachment_Status__c (NEW 2026-08-06) ────────────────

    @isTest
    static void createStaging_blankAttachmentStatus_defaultsToNone() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-attstatus-1@example.invalid');
        // Deliberately leaving request.attachmentStatus unset (null).

        Test.startTest();
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Test.stopTest();

        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_NONE,
            [SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId].Attachment_Status__c,
            'A blank attachmentStatus must default to None, never leave the field blank — it is the sweeper\'s work queue');
    }

    @isTest
    static void createStaging_pendingAttachmentStatus_stampsItInTheSameInsert() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-attstatus-2@example.invalid');
        request.attachmentStatus = InboundEmailStagingService.ATTACHMENT_STATUS_PENDING;

        Test.startTest();
        Id stagingId = InboundEmailStagingService.createStaging(request);
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PENDING,
            [SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId].Attachment_Status__c, '');
        Assert.areEqual(1, dmlUsed, 'Attachment_Status__c must be stamped in the SAME insert — zero extra DML');
    }

    // ── markAttachmentStatus (NEW 2026-08-06) ─────────────────────────────────

    @isTest
    static void markAttachmentStatus_withNote_stampsBothTheStatusAndTheNote() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-markatt-1@example.invalid'));

        Test.startTest();
        InboundEmailStagingService.markAttachmentStatus(
            stagingId, InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL, 'not yet saved: deferred, will be retried');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL, staging.Attachment_Status__c, '');
        Assert.areEqual('not yet saved: deferred, will be retried', staging.Dropped_Attachment_Notes__c, '');
    }

    @isTest
    static void markAttachmentStatus_blankNote_stampsOnlyTheStatus() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-markatt-2@example.invalid'));

        Test.startTest();
        InboundEmailStagingService.markAttachmentStatus(
            stagingId, InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, null);
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c,
            'A successful conversion writes NO note at all — silence on this field means "it worked"');
        Assert.isNull(staging.Dropped_Attachment_Notes__c, '');
    }

    @isTest
    static void markAttachmentStatus_appendsToExistingNotesRatherThanOverwriting() {
        InboundEmailStagingService.StagingRequest request = minimalRequest('msg-service-markatt-3@example.invalid');
        request.droppedNotes = 'logo.png | png | 5000 | image below IMAGE_MIN_BYTES';
        Id stagingId = InboundEmailStagingService.createStaging(request);

        Test.startTest();
        InboundEmailStagingService.markAttachmentStatus(
            stagingId, InboundEmailStagingService.ATTACHMENT_STATUS_FAILED, 'NOT SAVED: the file job failed');
        Test.stopTest();

        String notes = [
            SELECT Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Dropped_Attachment_Notes__c;
        Assert.isTrue(notes.contains('image below IMAGE_MIN_BYTES'), 'The classification-time note must survive. Actual: ' + notes);
        Assert.isTrue(notes.contains('the file job failed'), 'Actual: ' + notes);
    }

    @isTest
    static void markAttachmentStatus_nullStagingId_isANoOp() {
        Test.startTest();
        InboundEmailStagingService.markAttachmentStatus(null, InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, 'note');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c], 'A null stagingId must be a pure no-op');
    }

    @isTest
    static void markAttachmentStatus_blankStatus_writesOnlyTheNote() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-markatt-4@example.invalid'));

        Test.startTest();
        InboundEmailStagingService.markAttachmentStatus(stagingId, null, 'a note with no status change');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_NONE, staging.Attachment_Status__c,
            'A blank status must not overwrite the existing value with a DML at all — it stays whatever createStaging left it as');
        Assert.areEqual('a note with no status change', staging.Dropped_Attachment_Notes__c, '');
    }

    // ── markRoutingFailed (NEW 2026-08-08, routing resilience) ────────────────

    @isTest
    static void markRoutingFailed_pendingRow_stampsFailedAndSetsCounterToOne() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingfailed-1@example.invalid'));

        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: first death. AsyncApexJob 707FIRST.');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Routing_Attempt_Count__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.STATUS_FAILED, staging.Status__c,
            'A row that has never routed successfully (Pending) must become the FIRST time it dies unhandled');
        Assert.areEqual(1, staging.Routing_Attempt_Count__c, '');
        Assert.areEqual('ROUTING FAILED: first death. AsyncApexJob 707FIRST.', staging.Error__c, '');
    }

    @isTest
    static void markRoutingFailed_alreadyFailedRow_incrementsCounterAgainAndAppendsBothNotes() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingfailed-2@example.invalid'));
        InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: first death.');

        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: second death.');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Routing_Attempt_Count__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.STATUS_FAILED, staging.Status__c, '');
        Assert.areEqual(2, staging.Routing_Attempt_Count__c, 'A SECOND death on an already-Failed row must advance the counter from 1 to 2');
        Assert.isTrue(staging.Error__c.contains('first death'), 'The FIRST note must survive. Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains('second death'), 'The SECOND note must be appended. Actual: ' + staging.Error__c);
    }

    @isTest
    static void markRoutingFailed_blankStatusRow_treatedAsPendingAndBecomesFailed() {
        // A row written before Status__c had a default (or corrupted to blank some other way)
        // must be treated as Pending — i.e. still retryable — not silently ignored.
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingfailed-blank@example.invalid'));
        update new Inbound_Email_Staging__c(Id = stagingId, Status__c = null);

        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: from a blank status.');
        Test.stopTest();

        Assert.areEqual(InboundEmailStagingService.STATUS_FAILED, [
            SELECT Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Status__c, '');
    }

    @isTest
    static void markRoutingFailed_errorRow_isNotPromotedToFailed_recordsAuditNoteOnly() {
        // 🔴 THE CENTRAL SAFETY RULE (design §3.3). An 'Error' row's catch RAN — its work MAY have
        // already committed — so it must NEVER be promoted into the automatic retry queue. Only
        // the note is recorded, and it must say plainly that no retry will happen.
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingfailed-error@example.invalid'));
        update new Inbound_Email_Staging__c(Id = stagingId, Status__c = 'Error', Error__c = 'earlier committed work');

        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: a later unrelated death.');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Error', staging.Status__c,
            'An Error row must NEVER be promoted to Failed — that would put possibly-committed work back in the retry queue');
        Assert.isTrue(staging.Error__c.contains('NOT RE-QUEUED'), 'Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains('earlier committed work'), 'The PRIOR note must survive. Actual: ' + staging.Error__c);
    }

    @isTest
    static void markRoutingFailed_processedRow_isNotPromotedToFailed_recordsAuditNoteOnly() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingfailed-processed@example.invalid'));
        update new Inbound_Email_Staging__c(Id = stagingId, Status__c = 'Processed');

        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: a late death on a done row.');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Processed', staging.Status__c, 'A Processed row must never be promoted to Failed');
        Assert.isTrue(staging.Error__c.contains('NOT RE-QUEUED'), 'Actual: ' + staging.Error__c);
    }

    @isTest
    static void markRoutingFailed_atMaxRoutingAttemptCount_doesNotOverflowThePrecisionTwoField() {
        // Routing_Attempt_Count__c is Number(2,0) — 0..99 is the largest representable value.
        // MAX_ROUTING_ATTEMPT_COUNT is a FIELD-CAPACITY clip, not the retry policy (that lives
        // solely in RoutingRetrySweepBatch.MAX_ATTEMPTS = 3) — this proves the clip prevents a
        // NUMBER_OUTSIDE_VALID_RANGE DML failure long before any real row could reach it.
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingfailed-maxcount@example.invalid'));
        update new Inbound_Email_Staging__c(
            Id = stagingId, Status__c = InboundEmailStagingService.STATUS_FAILED, Routing_Attempt_Count__c = 99);

        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: at the field ceiling.');
        Test.stopTest();

        Assert.areEqual(99, [
            SELECT Routing_Attempt_Count__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Routing_Attempt_Count__c, 'The counter must clip at 99 rather than attempt to write 100, which the field cannot hold');
    }

    @isTest
    static void markRoutingFailed_nullStagingId_isANoOp() {
        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(null, 'anything');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c], '');
    }

    @isTest
    static void markRoutingFailed_hardDeletedRow_isANoOp() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingfailed-deleted@example.invalid'));
        Inbound_Email_Staging__c toDelete = new Inbound_Email_Staging__c(Id = stagingId);
        delete toDelete;
        Database.emptyRecycleBin(new List<Inbound_Email_Staging__c>{ toDelete });

        Test.startTest();
        InboundEmailStagingService.markRoutingFailed(stagingId, 'a row that no longer exists');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c WHERE Id = :stagingId],
            'A hard-deleted row must not resurrect or throw — the Finalizer\'s job is to report a failure, never to compound one');
    }

    // ── markRoutingAbandoned (NEW 2026-08-08, routing resilience) ─────────────

    @isTest
    static void markRoutingAbandoned_stampsErrorAndAppendsTheNoteToTheCallerSuppliedExistingError() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingabandoned-1@example.invalid'));
        update new Inbound_Email_Staging__c(
            Id = stagingId, Status__c = InboundEmailStagingService.STATUS_FAILED,
            Error__c = 'ROUTING FAILED: earlier death.');

        Test.startTest();
        InboundEmailStagingService.markRoutingAbandoned(
            stagingId, 'ROUTING FAILED: earlier death.', 'ABANDONED: MAX_ATTEMPTS reached.');
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual('Error', staging.Status__c, 'Abandoning must move the row to the human queue');
        Assert.isTrue(staging.Error__c.contains('earlier death'), 'The prior history must survive. Actual: ' + staging.Error__c);
        Assert.isTrue(staging.Error__c.contains('MAX_ATTEMPTS reached'), 'Actual: ' + staging.Error__c);
    }

    @isTest
    static void markRoutingAbandoned_nullExistingError_stillWritesTheNote() {
        Id stagingId = InboundEmailStagingService.createStaging(minimalRequest('msg-service-routingabandoned-2@example.invalid'));

        Test.startTest();
        InboundEmailStagingService.markRoutingAbandoned(stagingId, null, 'ABANDONED: first-ever note.');
        Test.stopTest();

        Assert.areEqual('ABANDONED: first-ever note.', [
            SELECT Error__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ].Error__c, '');
    }

    @isTest
    static void markRoutingAbandoned_nullStagingId_isANoOp() {
        Test.startTest();
        InboundEmailStagingService.markRoutingAbandoned(null, 'existing', 'note');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c], '');
    }
}
