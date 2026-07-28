/**
 * Test class for EmailToLeadHandler — the Messaging.InboundEmailHandler boundary
 * (staging model, Phase 3 rewrite). Builds Messaging.InboundEmail instances in
 * memory (the standard pattern for testing inbound email handlers — no real Email
 * Service invocation needed).
 *
 * SCOPE CHANGE THIS REWRITE TRACKS: the handler NO LONGER creates a Lead. It parses
 * the envelope/headers/first image, writes an Inbound_Email_Staging__c row
 * SYNCHRONOUSLY via InboundEmailStagingService, and enqueues ExtractAddressQueueable
 * to do the rest asynchronously. This class therefore tests ONLY the handler's own
 * synchronous contract — staging creation, header capture/parsing, monitored-inbox
 * resolution, image-attachment normalization, and the catch-all error boundary.
 * Lead field derivation (name splitting, email precedence, ...) is Phase 2's
 * responsibility split into EmailToLeadService (EmailToLeadServiceTest) and the
 * routing tree (ExtractAddressQueueableTest); it is not retested here.
 *
 * TIMING PATTERN: several tests query the staging row BETWEEN
 * handler.handleInboundEmail(...) and Test.stopTest() specifically to capture the
 * row's state as the handler itself left it (e.g. Status__c = 'Pending'), before the
 * enqueued ExtractAddressQueueable job (which runs AT Test.stopTest()) advances it
 * to 'Processed'. This is a valid, deterministic pattern — Apex query results are an
 * in-memory snapshot, unaffected by DML that happens later in the same test.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes in
 * this exact module (PropertyClaimServiceTest, PropertyMatchingServiceTest).
 *
 * @author Unit Testing Agent
 */
@isTest
private class EmailToLeadHandlerTest {

    private static void setBenignMock() {
        Map<String, String> blank = new Map<String, String>{
            'broker_name' => '', 'broker_email' => '', 'property_address' => '', 'sent_datetime' => ''
        };
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(blank, false)));
    }

    private static Messaging.InboundEmail.Header header(String name, String value) {
        Messaging.InboundEmail.Header h = new Messaging.InboundEmail.Header();
        h.name = name;
        h.value = value;
        return h;
    }

    private static Messaging.InboundEmail baseEmail() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'FW: Test property';
        email.fromAddress = 'broker@example.invalid';
        email.plainTextBody = 'body';
        return email;
    }

    // ── staging creation (synchronous) ───────────────────────────────────────

    @isTest
    static void handleInboundEmail_wellFormedEmail_createsStagingRowSynchronouslyAsPending() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-1@example.invalid>') };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        // Query BEFORE stopTest() so the async queueable's later Processed stamp has not
        // yet overwritten the synchronous Pending state this test verifies.
        Inbound_Email_Staging__c staging = [
            SELECT Status__c, From_Name__c, From_Address__c, Subject__c, Raw_Body__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-1@example.invalid>'
        ];
        Test.stopTest();

        Assert.isTrue(result.success, 'A well-formed email should succeed');
        Assert.areEqual('Pending', staging.Status__c, 'The staging row should be Pending immediately after synchronous creation');
        Assert.areEqual('Jane Broker', staging.From_Name__c, 'From_Name__c should be the envelope display name');
        Assert.areEqual('broker@example.invalid', staging.From_Address__c, 'From_Address__c should be the envelope From address');
        Assert.areEqual('FW: Test property', staging.Subject__c, 'Subject__c should be the inbound subject');
        Assert.areEqual('body', staging.Raw_Body__c, 'Raw_Body__c should be the email body');
    }

    // ── header extraction ─────────────────────────────────────────────────────

    @isTest
    static void handleInboundEmail_multipleHeaders_capturesRawHeadersAndParsesThreadingFields() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-2@example.invalid>'),
            header('In-Reply-To', '<parent-2@example.invalid>'),
            header('References', '<root-2@example.invalid> <parent-2@example.invalid>'),
            // Deliberately NOT one of the five headers the handler parses into a dedicated
            // field, to prove Raw_Headers__c captures EVERYTHING, not just the parsed set.
            header('X-Forwarded-To', 'someone@example.invalid')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [
            SELECT Raw_Headers__c, Message_Id__c, In_Reply_To__c, References__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-2@example.invalid>'
        ];
        Test.stopTest();

        Assert.isTrue(staging.Raw_Headers__c.contains('Message-ID: <msg-2@example.invalid>'), 'Raw_Headers__c should capture every header verbatim, one per line');
        Assert.isTrue(staging.Raw_Headers__c.contains('X-Forwarded-To: someone@example.invalid'),
            'Raw_Headers__c should also capture headers this pipeline never parses into a dedicated field');
        Assert.areEqual('<msg-2@example.invalid>', staging.Message_Id__c, 'Message_Id__c should be parsed from the Message-ID header');
        Assert.areEqual('<parent-2@example.invalid>', staging.In_Reply_To__c, 'In_Reply_To__c should be parsed from the In-Reply-To header');
        Assert.areEqual('<root-2@example.invalid> <parent-2@example.invalid>', staging.References__c, 'References__c should be parsed from the References header');
    }

    // ── monitored-inbox detection ────────────────────────────────────────────

    @isTest
    static void handleInboundEmail_xForwardedForHeader_resolvesMonitoredInboxAsForwardedBy() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-3@example.invalid>'),
            header('X-Forwarded-For', 'monitoring3@example.invalid')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [SELECT Forwarded_By__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-3@example.invalid>'];
        Test.stopTest();

        Assert.areEqual('monitoring3@example.invalid', staging.Forwarded_By__c,
            'An auto-forward (X-Forwarded-For present) should resolve Forwarded_By__c to the monitored inbox, not the envelope From');
    }

    @isTest
    static void handleInboundEmail_noForwardingHeaders_fallsBackToEnvelopeFromAsForwardedBy() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromAddress = 'internal.forwarder@example.invalid';
        email.fromName = 'Internal Forwarder';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-4@example.invalid>') };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [SELECT Forwarded_By__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-4@example.invalid>'];
        Test.stopTest();

        Assert.areEqual('internal.forwarder@example.invalid', staging.Forwarded_By__c,
            'A manual forward (no forwarding headers) should fall back to the envelope From address');
    }

    @isTest
    static void handleInboundEmail_xForwardedForIncludesServiceAddress_excludesItAndKeepsTheOtherOne() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-5@example.invalid>'),
            // The service's own address appears among the candidates and must be skipped,
            // leaving the real monitored inbox as the resolved address.
            header('X-Forwarded-For', 'service@dpeg.example.invalid monitoring5@example.invalid')
        };
        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'service@dpeg.example.invalid';

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, envelope);
        Inbound_Email_Staging__c staging = [SELECT Forwarded_By__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-5@example.invalid>'];
        Test.stopTest();

        Assert.areEqual('monitoring5@example.invalid', staging.Forwarded_By__c,
            'The Email Service\'s own address must be excluded from the candidate addresses, leaving the real monitored inbox');
    }

    @isTest
    static void handleInboundEmail_noXForwardedForButDeliveredToPresent_resolvesFromDeliveredTo() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-6@example.invalid>'),
            header('Delivered-To', 'monitoring6@example.invalid')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [SELECT Forwarded_By__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-6@example.invalid>'];
        Test.stopTest();

        Assert.areEqual('monitoring6@example.invalid', staging.Forwarded_By__c,
            'With no X-Forwarded-For, a Delivered-To header should still resolve the monitored inbox');
    }

    // ── image attachment handling ─────────────────────────────────────────────

    @isTest
    static void handleInboundEmail_bareImagePngAttachment_setsHasImageAndNormalizesMimeType() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-img-1@example.invalid>') };

        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.body = Blob.valueOf('fake image bytes');
        att.fileName = 'screenshot.png';
        att.mimeTypeSubType = 'png';
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'An email with an image attachment should still succeed');

        Inbound_Email_Staging__c staging = [
            SELECT Has_Image__c, Image_Mime_Type__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-img-1@example.invalid>'
        ];
        Assert.isTrue(staging.Has_Image__c, 'Has_Image__c should be true when an image attachment was found');
        Assert.areEqual('image/png', staging.Image_Mime_Type__c, 'A bare "png" mimeTypeSubType should be normalized to image/png on the staging row');
        // LLM callout verification moved to ExtractAddressQueueableTest, which tests the queueable's responsibility.
    }

    @isTest
    static void handleInboundEmail_alreadyQualifiedImageMime_isNotDoublePrefixed() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-img-2@example.invalid>') };

        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.body = Blob.valueOf('fake image bytes');
        att.fileName = 'screenshot.png';
        // Some inbound sources already qualify mimeTypeSubType (e.g. 'image/png') rather than
        // the bare subtype ('png') that is typical.
        att.mimeTypeSubType = 'image/png';
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'An email with an already-qualified image MIME type should still succeed');
        Inbound_Email_Staging__c staging = [SELECT Image_Mime_Type__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-img-2@example.invalid>'];
        Assert.areEqual('image/png', staging.Image_Mime_Type__c, 'An already-qualified MIME type should be stored unchanged, not double-prefixed');
        // LLM callout verification moved to ExtractAddressQueueableTest, which tests the queueable's responsibility.
    }

    @isTest
    static void handleInboundEmail_bareJpegAttachment_isNormalizedToImageJpeg() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-img-3@example.invalid>') };

        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.body = Blob.valueOf('fake jpeg bytes');
        att.fileName = 'photo.jpg';
        att.mimeTypeSubType = 'jpeg';
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Inbound_Email_Staging__c staging = [SELECT Image_Mime_Type__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-img-3@example.invalid>'];
        Assert.areEqual('image/jpeg', staging.Image_Mime_Type__c, 'A bare "jpeg" mimeTypeSubType should be normalized to image/jpeg');
        // LLM callout verification moved to ExtractAddressQueueableTest, which tests the queueable's responsibility.
    }

    @isTest
    static void handleInboundEmail_noAttachments_hasImageFalseAndNoImageUrlSent() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-img-4@example.invalid>') };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Has_Image__c, Image_Mime_Type__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-img-4@example.invalid>'
        ];
        Assert.isFalse(staging.Has_Image__c, 'Has_Image__c should be false with no attachments');
        Assert.isNull(staging.Image_Mime_Type__c, 'Image_Mime_Type__c should be blank with no attachments');
        // LLM callout verification moved to ExtractAddressQueueableTest, which tests the queueable's responsibility.
    }

    // ── error handling: the catch-all boundary ───────────────────────────────

    @isTest
    static void handleInboundEmail_unexpectedException_isCaughtAndReturnsFailureResult() {
        // EmailToLeadHandler's field-safety helpers (InboundEmailFieldUtil.clip /
        // sanitizeEmail) deliberately make a genuine DmlException on the staging insert
        // extremely hard to construct through ordinary malformed input — every value is
        // clipped/sanitized before DML specifically to prevent that failure mode (see the
        // class header). Passing a null `email` instead exercises the SAME catch-all
        // contract deterministically: the very first statement inside the try block
        // dereferences `email`, so this proves the boundary never lets an exception escape
        // uncaught, regardless of what actually threw it.
        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(null, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isFalse(result.success, 'An unexpected exception should surface as success=false, not an uncaught exception');
        Assert.isNotNull(result.message, 'A failure message should be populated');
        Assert.isTrue(result.message.startsWith('Inbound email staging failed:'), 'The failure message should carry the documented prefix');
        Assert.areEqual(0, [SELECT COUNT() FROM Inbound_Email_Staging__c], 'No staging row should be committed when the handler fails before ever building one');
    }

    @isTest
    static void handleInboundEmail_adversarialOverLongAndMalformedInput_stillSucceedsThanksToFieldSafety() {
        // The positive-side proof of the same field-safety contract: an over-long subject
        // and a malformed "email" address must be clipped/sanitized, not thrown — matching
        // the documented regression this refactor fixed (the OLD pre-staging pipeline threw
        // on exactly this kind of input and lost the email).
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.subject = ''.rightPad(300, 'x');
        email.fromAddress = 'not a valid email address';
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-adversarial-1@example.invalid>') };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [
            SELECT Subject__c, From_Address__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-adversarial-1@example.invalid>'
        ];
        Test.stopTest();

        Assert.isTrue(result.success, 'An over-long subject and a malformed From address must not fail staging creation');
        Assert.areEqual(255, staging.Subject__c.length(), 'An over-long subject should be clipped to 255 characters, not throw STRING_TOO_LONG');
        Assert.isNull(staging.From_Address__c, 'A malformed From address should be sanitized to blank, not throw INVALID_EMAIL_ADDRESS');
    }

    // ── end-to-end wiring sanity ──────────────────────────────────────────────

    @isTest
    static void handleInboundEmail_wellFormedEmail_enqueuesExtractAddressQueueableJob() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-enqueue-1@example.invalid>') };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ExtractAddressQueueable'],
            'handleInboundEmail should enqueue exactly one ExtractAddressQueueable job per inbound email');

        Inbound_Email_Staging__c staging = [SELECT Status__c FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-enqueue-1@example.invalid>'];
        Assert.areEqual('Processed', staging.Status__c, 'By the time Test.stopTest() completes, the enqueued job should have run and stamped the staging row Processed');
    }
}
