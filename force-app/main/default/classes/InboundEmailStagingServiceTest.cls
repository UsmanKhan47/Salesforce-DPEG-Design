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
}
