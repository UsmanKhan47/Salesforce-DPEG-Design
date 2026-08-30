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
 * ═══ ATTACHMENT CAPTURE (2026-08-05; REDESIGNED 2026-08-06) — NEAR THE BOTTOM OF THIS CLASS ═══
 * Covers: classification via a real attachment set (PDF retained, signature logo dropped, CSV
 * retained per G3, MAX_ATTACHMENTS overflow — now 3, not 10), the vision-encode size gate
 * (VISION_MAX_BYTES, decisions A1-a/A2) at its exact boundary, the zero-attachment COMPATIBILITY
 * guarantee (byte-identical to pre-feature behaviour), and the GOVERNOR BUDGET.
 *
 * 🔴 2026-08-06 REDESIGN — READ THIS BEFORE TRUSTING ANY "0 files" ASSERTION IN THIS FILE.
 * v1 (2026-08-05) called `InboundEmailAttachmentService.persist(...)` synchronously from this
 * handler and it DESTROYED EVERY INBOUND EMAIL CARRYING AN ATTACHMENT — see
 * EmailToLeadHandler's class header for the full outage writeup. The FIX is not "disable
 * persistence" (that was a temporary interim state, since removed along with the
 * PERSISTENCE_DISABLED banner and its helper, per their own Javadoc) — it is
 * `InboundEmailAttachmentService.stageBytes(...)`: the handler now writes each retained
 * attachment as a classic `Attachment` CARRIER (ZERO ContentPublications, SP-4.1) synchronously,
 * and a LATER transaction (`AttachmentPersistQueueable`, chained from routing) converts those
 * carriers into Salesforce Files. So this suite now asserts THREE THINGS, not one:
 *   (a) a carrier `Attachment` IS written here (Tier 1, structural, deterministic);
 *   (b) `Attachment_Status__c` is stamped 'Pending' (or 'None') so the file pipeline's work
 *       queue is seeded correctly;
 *   (c) NO `ContentVersion` is EVER created by this handler (T1 — see design §8.2) — this is the
 *       regression net that goes red on the exact change that caused the outage, and it is
 *       unrelated to whether persistence happens at all: the whole point is that it happens
 *       LATER, in a transaction that owns nothing else. See `AttachmentPersistQueueableTest.cls`
 *       and `EmailToLeadHandler`'s own class header for the transaction structure.
 *
 * 🔴 THE SINGLE MOST IMPORTANT TEST IN THIS SUITE:
 * handleInboundEmail_pdfAttachment_writesCarrierStampsPendingAndCreatesNoContentVersion. An
 * email carrying an attachment must route normally AND write no ContentVersion at the
 * boundary — that is the case that was FAILING IN PRODUCTION, destroying the Lead, the registry
 * claim and the audit trail with the email.
 *
 * ⚠ v1's PREDECESSOR TEST PASSED THROUGHOUT THAT OUTAGE, and the reason is worth remembering:
 * it armed `InboundEmailAttachmentService.forcePersistFailure` and asserted that the catch
 * held. The real failure was `System.UnexpectedException: ContentPublication Limit exceeded`,
 * which escapes `catch (Exception e)` entirely — a shape NO in-Apex seam can simulate. A seam
 * that can only raise catchable exceptions cannot falsify a claim about uncatchable ones, so
 * the test was structurally incapable of failing. Every test below asserts STRUCTURE (DML
 * counts, the absence of ContentVersion, the presence of a carrier) instead, which is
 * observable and which no platform behaviour can fake.
 *
 * Governor-budget assertions here read `Limits.getQueries()` / `Limits.getDmlStatements()`
 * captured IMMEDIATELY AFTER the synchronous `handleInboundEmail(...)` call, still inside
 * `Test.startTest()` and BEFORE `Test.stopTest()` — deliberately different from
 * ExtractAddressQueueableTest's `lastRunQueryCount`/`lastRunDmlCount` statics pattern.
 * EmailToLeadHandler has no such static of its own (it is a synchronous boundary, not an async
 * job), and capturing the counters into a local BEFORE `Test.stopTest()` runs the enqueued
 * queueable is what keeps the numbers isolated to the handler's own work, not the routing job's.
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
            // Deliberately NOT one of the six headers the handler parses into a dedicated
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
        // 2026-08-05: must be >= IMAGE_MIN_BYTES (20,000), or attachment classification (G2)
        // now drops it as a likely signature logo BEFORE it ever reaches the vision candidate —
        // this test is about MIME normalization, not the floor, so the fixture must clear it.
        att.body = Blob.valueOf(''.rightPad(InboundEmailAttachmentService.IMAGE_MIN_BYTES, 'i'));
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
        // 2026-08-05: see the IMAGE_MIN_BYTES note above — must clear the G2 floor.
        att.body = Blob.valueOf(''.rightPad(InboundEmailAttachmentService.IMAGE_MIN_BYTES, 'i'));
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
        // 2026-08-05: see the IMAGE_MIN_BYTES note above — must clear the G2 floor.
        att.body = Blob.valueOf(''.rightPad(InboundEmailAttachmentService.IMAGE_MIN_BYTES, 'i'));
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

    // ── attachment capture (2026-08-05): classification via a real attachment set ──

    private static Messaging.InboundEmail.BinaryAttachment binaryAttachment(
            String fileName, String mimeSubType, String content) {
        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.fileName = fileName;
        att.mimeTypeSubType = mimeSubType;
        att.body = Blob.valueOf(content);
        return att;
    }

    private static Messaging.InboundEmail.TextAttachment textAttachment(
            String fileName, String mimeSubType, String content) {
        Messaging.InboundEmail.TextAttachment att = new Messaging.InboundEmail.TextAttachment();
        att.fileName = fileName;
        att.mimeTypeSubType = mimeSubType;
        att.body = content;
        return att;
    }

    @isTest
    static void handleInboundEmail_pdfAttachment_writesCarrierStampsPendingAndCreatesNoContentVersion() {
        // Test 23 (writesCarrierAndStampsPending) + Test 26 / T1 (createsNoContentVersion),
        // combined: the two properties describe the SAME boundary call and splitting them would
        // re-derive the fixture for no benefit.
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-attach-1@example.invalid>') };
        String pdfContent = 'PDF OFFERING MEMORANDUM CONTENT';
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{
            binaryAttachment('offering-memo.pdf', 'pdf', pdfContent)
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        // Query BEFORE stopTest() — same established pattern as this file's very first test — so
        // the async router (which may RELEASE the carrier on a gate, or in production would
        // enqueue the file job) has not yet run. This method's whole point is to pin what the
        // SYNCHRONOUS handler itself did.
        Inbound_Email_Staging__c staging = [
            SELECT Id, Attachment_Count__c, Attachment_Bytes__c, Attachment_Status__c, Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-attach-1@example.invalid>'
        ];
        List<Attachment> carriers = [SELECT Name, ContentType, Body FROM Attachment WHERE ParentId = :staging.Id];
        Test.stopTest();

        Assert.isTrue(result.success, 'An email with a legitimate PDF attachment must still succeed');
        Assert.areEqual(1, staging.Attachment_Count__c, 'Exactly one attachment was CLASSIFIED as retainable');
        Assert.areEqual(pdfContent.length(), staging.Attachment_Bytes__c, 'Attachment_Bytes__c is the classified file\'s real byte count');
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, staging.Attachment_Status__c,
            'A carrier was written, so the file pipeline\'s work queue must be seeded as Pending');
        Assert.isNull(staging.Dropped_Attachment_Notes__c, 'Nothing was DROPPED here — the file was retained and carried, not refused');

        // The bytes DID travel — as a classic Attachment carrier, at zero ContentPublication cost.
        Assert.areEqual(1, carriers.size(), 'The retained file must be staged as a carrier Attachment');
        Assert.areEqual('offering-memo.pdf', carriers[0].Name, '');
        Assert.areEqual(pdfContent, carriers[0].Body.toString(), 'The carrier must hold the file\'s real bytes, unchanged');

        // 🔴 T1 — THE REGRESSION NET. Zero ContentVersion, no matter what happens afterward.
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'offering-memo.pdf'],
            'A ContentVersion insert must NEVER sit inside the SYNCHRONOUS transaction that owns the '
            + 'email — a ContentPublication quota refusal there (M1-M5) ignores allOrNone=false, escapes '
            + 'catch(Exception), and destroys the whole email. See EmailToLeadHandler\'s class header for '
            + 'the 2026-08-06 outage. (This also holds after Test.stopTest(): SP-2 makes the routing job\'s '
            + 'own file-job chain a no-op inside @isTest, so no ContentVersion can appear here either way.)');
    }

    @isTest
    static void handleInboundEmail_signatureLogoUnderImageFloor_isDroppedAndRecordedWithNoFileSaved() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-attach-2@example.invalid>') };
        // A real Blob under IMAGE_MIN_BYTES (20,000) — small enough that its actual size, not a
        // manufactured one, is what trips the floor.
        String logoContent = ''.rightPad(5000, 'l');
        Messaging.InboundEmail.BinaryAttachment logo = binaryAttachment('signature-logo.png', 'png', logoContent);
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ logo };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, '');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Dropped_Attachment_Notes__c, Has_Image__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-attach-2@example.invalid>'
        ];
        Assert.areEqual(0, staging.Attachment_Count__c, 'A sub-floor signature logo (G2) must not be retained');
        Assert.isNotNull(staging.Dropped_Attachment_Notes__c, 'The drop must be RECORDED, never silent');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('signature-logo.png'),
            'Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.isFalse(staging.Has_Image__c,
            'firstVisionImage() only ever considers the RETAINED list — a dropped logo must never be sent to the LLM');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'signature-logo.png'],
            'A dropped attachment must never reach persist() — no file may be saved for it');
    }

    @isTest
    static void handleInboundEmail_signatureLogoBeforeARealPhoto_visionCandidateSkipsTheDroppedLogo() {
        // Pins EmailToLeadHandler.firstVisionImage's documented rule: the vision candidate is
        // chosen from the RETAINED list only, never a fresh scan of email.binaryAttachments — so
        // a dropped logo listed FIRST must not block a legitimate photo listed second.
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-attach-3@example.invalid>') };
        Messaging.InboundEmail.BinaryAttachment logo =
            binaryAttachment('logo.png', 'png', ''.rightPad(5000, 'l'));
        Messaging.InboundEmail.BinaryAttachment photo =
            binaryAttachment('property-photo.jpg', 'jpeg', ''.rightPad(25000, 'p'));
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ logo, photo };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Has_Image__c, Image_Mime_Type__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-attach-3@example.invalid>'
        ];
        Assert.areEqual(1, staging.Attachment_Count__c, 'Only the real photo survives classification');
        Assert.isTrue(staging.Has_Image__c, 'The real photo must still be sent to the LLM despite being second in the list');
        Assert.areEqual('image/jpeg', staging.Image_Mime_Type__c, '');
    }

    @isTest
    static void handleInboundEmail_csvTextAttachment_isRetained() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-attach-4@example.invalid>') };
        String csvContent = 'unit,rent\n101,1200\n102,1350';
        email.textAttachments = new List<Messaging.InboundEmail.TextAttachment>{
            textAttachment('rentroll.csv', 'csv', csvContent)
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Attachment_Bytes__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-attach-4@example.invalid>'
        ];
        Assert.areEqual(1, staging.Attachment_Count__c, 'A .csv rent roll must be classified as retainable (G3)');
        Assert.areEqual(csvContent.length(), staging.Attachment_Bytes__c, '');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'rentroll.csv'],
            'The boundary must NEVER create a ContentVersion — classification and carrier-staging still '
            + 'run, but conversion to a Salesforce File happens later, in a different transaction');
    }

    @isTest
    static void handleInboundEmail_vCardTextAttachment_isDroppedAndRecorded() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-attach-5@example.invalid>') };
        email.textAttachments = new List<Messaging.InboundEmail.TextAttachment>{
            textAttachment('contact.vcf', 'x-vcard', 'BEGIN:VCARD...')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-attach-5@example.invalid>'
        ];
        Assert.areEqual(0, staging.Attachment_Count__c, 'A vCard is not a CSV and must be dropped (G3)');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('contact.vcf'), 'Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], '');
    }

    @isTest
    static void handleInboundEmail_fourAttachments_thirdRetainedFourthDroppedByCountCap() {
        // 🔴 RE-PINNED 2026-08-06: MAX_ATTACHMENTS is 3, not 10 (user decision, design §2.1).
        // This test's PREDECESSOR sent 11 files expecting a cap at 10 and asserted
        // Attachment_Count__c == 10, verbatim — compile-clean but semantically stale the moment
        // the constant changed, which is exactly why it was flagged for this pass.
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-attach-6@example.invalid>') };
        List<Messaging.InboundEmail.BinaryAttachment> atts = new List<Messaging.InboundEmail.BinaryAttachment>();
        for (Integer i = 0; i < 4; i++) {
            atts.add(binaryAttachment('file' + i + '.pdf', 'pdf', 'content ' + i));
        }
        email.binaryAttachments = atts;

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-attach-6@example.invalid>'
        ];
        Assert.areEqual(3, staging.Attachment_Count__c, 'MAX_ATTACHMENTS caps retention at 3');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('file3.pdf'),
            'The 4th (zero-indexed file3) must be the one recorded as dropped. Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'file%.pdf'],
            'The boundary must never create a ContentVersion — the count cap is enforced by classify(), '
            + 'but conversion to a Salesforce File happens later, in a different transaction');
    }

    // ── attachment capture: the vision-encode size gate (VISION_MAX_BYTES, A1-a/A2) ──

    @isTest
    static void handleInboundEmail_imageOverVisionMaxBytes_isNotEncodedButEmailStillRoutesNormally() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-vision-1@example.invalid>') };
        String overThreshold = ''.rightPad(EmailToLeadHandler.VISION_MAX_BYTES + 1, 'z');
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{
            binaryAttachment('huge-property-photo.png', 'png', overThreshold)
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'An oversized image must never crash or fail the handler — that is the whole point of the gate');
        Inbound_Email_Staging__c staging = [
            SELECT Has_Image__c, Attachment_Count__c, Dropped_Attachment_Notes__c, Status__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-vision-1@example.invalid>'
        ];
        Assert.isFalse(staging.Has_Image__c, 'A1-a: an image over VISION_MAX_BYTES must NOT be sent to the LLM');
        Assert.areEqual(1, staging.Attachment_Count__c, 'The image is still RETAINED as a file — only the vision call is skipped, per the class header');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains(EmailToLeadHandler.REASON_VISION_TOO_LARGE),
            'The skip must be RECORDED, never silent. Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.areEqual('Processed', staging.Status__c, 'The async router must still run to completion despite the vision skip');
    }

    @isTest
    static void handleInboundEmail_imageAtExactlyVisionMaxBytes_isStillEncodedNormally() {
        // The check is `bytes > VISION_MAX_BYTES`, so a file exactly AT the threshold is the
        // precise pin of the off-by-one boundary — anything at or under behaves identically.
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-vision-2@example.invalid>') };
        String atThreshold = ''.rightPad(EmailToLeadHandler.VISION_MAX_BYTES, 'z');
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{
            binaryAttachment('at-threshold.png', 'png', atThreshold)
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, '');
        Inbound_Email_Staging__c staging = [
            SELECT Has_Image__c, Image_Mime_Type__c, Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-vision-2@example.invalid>'
        ];
        Assert.isTrue(staging.Has_Image__c, 'An image exactly AT VISION_MAX_BYTES must still be encoded and sent to the LLM');
        Assert.areEqual('image/png', staging.Image_Mime_Type__c, '');
        Boolean mentionsVisionSkip = staging.Dropped_Attachment_Notes__c != null
            && staging.Dropped_Attachment_Notes__c.contains(EmailToLeadHandler.REASON_VISION_TOO_LARGE);
        Assert.isFalse(mentionsVisionSkip, 'No vision-skip note may appear when the image was actually encoded');
    }

    // ── attachment capture: the failure boundary (§4.4's most important rule) ────

    /**
     * 🔴 THE ACCEPTANCE CRITERION — REWRITTEN 2026-08-06 AND NOW STRONGER THAN IT WAS.
     *
     * It used to arm `InboundEmailAttachmentService.forcePersistFailure` and assert that a
     * persistence failure did not surface as `result.success = false`. **That test passed while
     * production was destroying every email carrying an attachment**, because the real failure
     * was `System.UnexpectedException: ContentPublication Limit exceeded`, which escapes BOTH
     * `catch (Exception e)` blocks and rolls the whole transaction back — a shape no in-Apex
     * seam can simulate. A seam that can only produce catchable failures cannot falsify a claim
     * about uncatchable ones.
     *
     * The guarantee is not "the catch holds" (it does not, and cannot) but "there is nothing IN
     * THIS TRANSACTION that a quota refusal could ever touch": the handler performs a bulk
     * classic-Attachment CARRIER insert (design §3.4) — zero ContentPublications, by measurement
     * (SP-4.1) — and NO ContentVersion DML at all, which is verified structurally below and is
     * true regardless of what happens to the quota later, in a different transaction.
     *
     * If a ContentVersion insert is ever restored to the synchronous handler, this test must go red.
     */
    @isTest
    static void handleInboundEmail_attachmentEmail_writesOnlyTheCarrierAndRoutesNormally() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-boundary-1@example.invalid>') };
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{
            binaryAttachment('always-converts-later.pdf', 'pdf', 'PDF CONTENT')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Integer dmlUsedByHandler = Limits.getDmlStatements();
        // Query BEFORE stopTest() so the async router (whose file-job chain is a no-op inside
        // @isTest per SP-2, but which MAY still release the carrier on a gate) has not yet run —
        // this test's whole point is to pin what the SYNCHRONOUS handler itself did.
        Inbound_Email_Staging__c staging = [
            SELECT Id, Status__c, Result_Record_Id__c, Attachment_Count__c, Attachment_Status__c,
                   Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-boundary-1@example.invalid>'
        ];
        Integer carrierCount = [SELECT COUNT() FROM Attachment WHERE ParentId = :staging.Id];
        Test.stopTest();

        Assert.isTrue(result.success,
            'An email carrying an attachment must succeed — this is the single most important '
            + 'assertion in this suite, and it is the one that was failing in production');

        // THE STRUCTURAL GUARANTEE: exactly TWO DML — the staging insert and ONE bulk carrier
        // insert. No ContentVersion insert means no ContentPublication is consumed, so the quota
        // that destroyed these emails is unreachable from this transaction, full stop.
        Assert.areEqual(2, dmlUsedByHandler,
            'The handler must perform EXACTLY TWO DML — the staging insert and the bulk carrier '
            + 'insert. Any more (or a ContentVersion appearing anywhere) means the outage-causing '
            + 'shape has been reintroduced — see EmailToLeadHandler\'s class header');
        Assert.areEqual(1, carrierCount, 'The retained file must have been staged as a carrier Attachment');
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PENDING, staging.Attachment_Status__c, '');
        Assert.isNull(staging.Dropped_Attachment_Notes__c, 'Nothing was dropped — the file was retained and carried');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion],
            'NOT ONE ContentVersion may ever be created by this handler');
    }

    @isTest
    static void handleInboundEmail_attachmentEmail_routesTheEmailNormallyAfterStopTest() {
        // The other half of the acceptance criterion, checked AFTER Test.stopTest() runs the
        // enqueued router: the Lead, its claim and the Task must all still exist, exactly as
        // they would for a zero-attachment email — an attachment must never cost the email its
        // own routing.
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-boundary-2@example.invalid>') };
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{
            binaryAttachment('routes-normally.pdf', 'pdf', 'PDF CONTENT')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Inbound_Email_Staging__c staging = [
            SELECT Status__c, Result_Record_Id__c, Attachment_Count__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-boundary-2@example.invalid>'
        ];
        Assert.areEqual('Processed', staging.Status__c,
            'Routing must complete normally — the Lead, the claim and the Task must all still be created');
        Assert.isNotNull(staging.Result_Record_Id__c, 'The Lead and its claim must exist');
        Assert.areEqual(1, staging.Attachment_Count__c, 'Classification still runs, so the row still records WHAT ARRIVED');
    }

    // ── attachment capture: governor budget (design §9) ───────────────────────

    @isTest
    static void handleInboundEmail_oneRetainedAttachment_pinsGovernorBudgetAtZeroSoqlTwoDml() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-budget-1@example.invalid>') };
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{
            binaryAttachment('budget-test.pdf', 'pdf', 'PDF CONTENT FOR BUDGET TEST')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        // Captured BEFORE Test.stopTest() runs the enqueued ExtractAddressQueueable job, so these
        // counts reflect ONLY the handler's own synchronous work — see the class header.
        Integer queriesUsed = Limits.getQueries();
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.isTrue(result.success, 'Precondition: the handler must succeed, or the budget below proves nothing');
        // RE-PINNED 2026-08-06: 0 SOQL / 2 DML (was 0 SOQL / 1 DML while persistence was
        // disabled, and 1 SOQL / 3 DML in the v1 shape that caused the outage). The staging
        // insert plus ONE bulk carrier insert — CONSTANT regardless of file count.
        Assert.areEqual(0, queriesUsed, 'GOVERNOR BUDGET: zero SOQL — the handler holds no read of its own');
        Assert.areEqual(2, dmlUsed,
            'GOVERNOR BUDGET: exactly 2 DML — the staging insert plus ONE bulk carrier insert. If '
            + 'this is ever anything other than +1 against the zero-attachment baseline, stageBytes '
            + 'has stopped being a single bulk call, or a ContentVersion insert has crept back into '
            + 'this transaction — see the EmailToLeadHandler class header for why that is fatal');
    }

    @isTest
    static void handleInboundEmail_zeroAttachments_pinsGovernorBudgetAtZeroSoqlOneDmlAndStampsZeroNotNull() {
        // §4.9 #7 — the COMPATIBILITY test: a zero-attachment email must behave BYTE-IDENTICALLY
        // to the pre-feature pipeline. Mirrors the buildLlmText_blankSubject_returnsTheBody
        // ByteIdentically precedent — proving an additive change is provably additive.
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Message-ID', '<msg-budget-2@example.invalid>') };
        // Deliberately no binaryAttachments, no textAttachments.

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Integer queriesUsed = Limits.getQueries();
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.isTrue(result.success, '');
        Assert.areEqual(0, queriesUsed,
            'GOVERNOR BUDGET: zero SOQL — the handler holds no read of its own');
        Assert.areEqual(1, dmlUsed,
            'GOVERNOR BUDGET: exactly 1 DML — the staging insert alone');

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Count__c, Attachment_Bytes__c, Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c WHERE Message_Id__c = '<msg-budget-2@example.invalid>'
        ];
        Assert.areEqual(0, staging.Attachment_Count__c, 'Stamped 0, never null, on a zero-attachment email');
        Assert.areEqual(0, staging.Attachment_Bytes__c, 'Stamped 0, never null');
        Assert.isNull(staging.Dropped_Attachment_Notes__c, 'Nothing to report when nothing was dropped');
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

    // ═══════════════════════════════════════════════════════════════════════════
    // WS1 (2026-08-30) — THE RFC `Date:` HEADER → Received_DateTime__c
    //
    // TWO TIERS, AND THE SECOND ONE IS THE IMPORTANT ONE.
    //
    //   Tier 1, through the boundary: the header is read, parsed and stamped on the staging row,
    //   and — critically — an UNREADABLE header still stages the email. That is the claim that
    //   matters. `parseRfc5322Date` sits inside `handleInboundEmail`'s try/catch ABOVE the
    //   staging insert, so a throw there returns success=false and the email is BOUNCED, not
    //   staged. The class header's 2026-08-06 outage writeup is what that costs.
    //
    //   Tier 2, direct on `@TestVisible parseRfc5322Date`: the grammar cases. They are direct
    //   rather than boundary-driven for a reason beyond speed — each one is a statement about
    //   the PARSER, and routing 20 malformed headers through the whole email boundary would
    //   assert the same null 20 times while making it much harder to see which input produced
    //   it. The never-throw contract is proved at BOTH tiers, because "returns null" and
    //   "does not lose the email" are different claims.
    //
    // ⚠ NO 251-RECORD BULK TEST HERE, AND THAT IS NOT AN OVERSIGHT. This is a synchronous
    // per-email boundary — `Messaging.InboundEmailHandler` is invoked once per email by the
    // platform and there is no collection and no loop over records to bulkify. The volume
    // dimension of this feature lives in ExtractAddressQueueableTest, where one email fans out
    // to MAX_PROPERTIES Leads (see .claude/rules/bulk-test-rule.md's narrowed C-18 scope).
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Tier 1: through the boundary ──────────────────────────────────────────

    @isTest
    static void handleInboundEmail_rfcDateHeader_stampsReceivedDateTimeFromTheHeaderNotTheClock() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-ws1-1@example.invalid>'),
            header('Date', 'Tue, 26 Aug 2026 14:03:22 -0500')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [
            SELECT Received_DateTime__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-ws1-1@example.invalid>'
        ];
        Test.stopTest();

        Assert.isTrue(result.success, 'A well-formed email carrying a Date header must still succeed');
        // 14:03:22 at -0500 is 19:03:22 UTC. The EXACT value is asserted, not merely non-null:
        // an off-by-the-offset bug is the whole failure mode of a timezone-bearing parser and a
        // null-check would not see it.
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 19, 3, 22), staging.Received_DateTime__c,
            'Received_DateTime__c must be the RFC Date header converted to UTC (14:03:22 -0500 = 19:03:22Z), '
            + 'not the processing clock');
    }

    @isTest
    static void handleInboundEmail_uppercaseDateHeaderName_isStillMatched() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-ws1-2@example.invalid>'),
            header('DATE', 'Wed, 27 Aug 2026 09:00:00 +0000')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [
            SELECT Received_DateTime__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-ws1-2@example.invalid>'
        ];
        Test.stopTest();

        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 27, 9, 0, 0), staging.Received_DateTime__c,
            'RFC 5322 header names are case-insensitive and relays disagree about casing, so DATE, Date '
            + 'and date must all resolve — HEADER_DATE is matched lowercased for exactly this reason');
    }

    @isTest
    static void handleInboundEmail_noDateHeader_leavesReceivedDateTimeNullAndStagesNormally() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-ws1-3@example.invalid>')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [
            SELECT Received_DateTime__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-ws1-3@example.invalid>'
        ];
        Test.stopTest();

        Assert.isTrue(result.success, 'An email with no Date header is ordinary, not an error');
        Assert.isNull(staging.Received_DateTime__c,
            'No Date header must leave Received_DateTime__c NULL — the CreatedDate fallback is resolved '
            + 'downstream in ExtractAddressQueueable, deliberately not here, so there is only ever one '
            + 'fallback rule to keep correct');
    }

    @isTest
    static void handleInboundEmail_malformedDateHeader_stillStagesTheEmailAndDoesNotBounceIt() {
        // 🔴 THE SINGLE MOST IMPORTANT TEST IN THIS WS1 SECTION. The parse runs inside
        // handleInboundEmail's try/catch and ABOVE the staging insert: if it threw, this email
        // would be reported success=false and BOUNCED, and the body, headers, Lead and registry
        // claim would all be lost for the sake of a nice-to-have timestamp.
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-ws1-4@example.invalid>'),
            header('Date', 'yesterday afternoon-ish, probably')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        List<Inbound_Email_Staging__c> staged = [
            SELECT Received_DateTime__c, Raw_Body__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-ws1-4@example.invalid>'
        ];
        Test.stopTest();

        Assert.isTrue(result.success,
            'AN UNREADABLE Date HEADER MUST NOT BOUNCE THE EMAIL. parseRfc5322Date never throws; if this '
            + 'fails, a change has made it throw and the pipeline now loses every email a relay '
            + 'mis-formats — see THE 2026-08-06 OUTAGE in EmailToLeadHandler.cls');
        Assert.areEqual(1, staged.size(), 'The staging row — the pipeline durability guarantee — must exist');
        Assert.areEqual('body', staged[0].Raw_Body__c, 'The email body must have survived intact');
        Assert.isNull(staged[0].Received_DateTime__c,
            'An unreadable header degrades to null; it must never guess a value');
    }

    @isTest
    static void handleInboundEmail_emptyDateHeader_stillStagesTheEmail() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<msg-ws1-5@example.invalid>'),
            header('Date', '')
        };

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Inbound_Email_Staging__c staging = [
            SELECT Received_DateTime__c FROM Inbound_Email_Staging__c
            WHERE Message_Id__c = '<msg-ws1-5@example.invalid>'
        ];
        Test.stopTest();

        Assert.isTrue(result.success, 'A present-but-empty Date header must not bounce the email either');
        Assert.isNull(staging.Received_DateTime__c, 'An empty header value is not a date');
    }

    // ── Tier 2: the parser's grammar, direct ──────────────────────────────────

    @isTest
    static void parseRfc5322Date_fullyFormedHeader_convertsTheOffsetToUtc() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 -0500');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 19, 3, 22), parsed,
            'localTime minus the zone offset is UTC: 14:03:22 at -0500 is 19:03:22Z');
    }

    @isTest
    static void parseRfc5322Date_eastOfUtcOffset_subtractsRatherThanAdds() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 +0530');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 8, 33, 22), parsed,
            'A POSITIVE offset must move the UTC value BACK, not forward — this is the assertion that '
            + 'catches a sign inversion, which a west-of-UTC-only test cannot');
    }

    @isTest
    static void parseRfc5322Date_noDayOfWeekPrefix_isStillParsed() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('26 Aug 2026 14:03:22 +0000');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 14, 3, 22), parsed,
            'The day-of-week is OPTIONAL in RFC 5322 §3.3 and its absence must not break the parse');
    }

    @isTest
    static void parseRfc5322Date_noSeconds_defaultsToZeroSeconds() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03 +0000');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 14, 3, 0), parsed,
            'Seconds are OPTIONAL in the grammar and default to zero');
    }

    @isTest
    static void parseRfc5322Date_trailingZoneComment_isIgnored() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 +0000 (UTC)');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 14, 3, 22), parsed,
            'A CFWS comment after the zone is legal and carries nothing the zone token does not — '
            + 'Gmail and Outlook both emit it, so failing on it would reject most real email');
    }

    @isTest
    static void parseRfc5322Date_obsoleteZoneName_usesTheMappedOffset() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 EDT');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 18, 3, 22), parsed,
            'EDT is -0400 per RFC 5322 §4.3; older clients still emit the alphabetic form');
    }

    @isTest
    static void parseRfc5322Date_gmtZoneName_isUtc() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('26 Aug 2026 14:03:22 GMT');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 14, 3, 22), parsed, 'GMT is offset zero');
    }

    @isTest
    static void parseRfc5322Date_twoDigitYear_expandsPerTheObsoleteRule() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 26 14:03:22 +0000');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 14, 3, 22), parsed,
            'RFC 5322 §4.3: a two-digit year below 50 is 20xx. Getting this wrong yields year 26, which '
            + 'Salesforce rejects outright rather than storing wrong');
    }

    @isTest
    static void parseRfc5322Date_foldedWhitespace_isCollapsed() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue,   26   Aug   2026   14:03:22   +0000');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 14, 3, 22), parsed,
            'Header folding and runs of whitespace between tokens are legal, so tokenising on a single '
            + 'literal space without collapsing first would produce empty tokens and a spurious null');
    }

    @isTest
    static void parseRfc5322Date_colonSeparatedZone_isTolerated() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 -05:00');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 26, 19, 3, 22), parsed,
            'Not RFC-conforming, but emitted by some clients; tolerating it costs one replace() and '
            + 'recovers a timestamp that would otherwise be discarded');
    }

    @isTest
    static void parseRfc5322Date_leapSecond_doesNotThrowAndRollsForward() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 31 Dec 2026 23:59:60 +0000');
        Assert.areEqual(Datetime.newInstanceGmt(2027, 1, 1, 0, 0, 0), parsed,
            'Second 60 is a legal leap second in the grammar. It is added to midnight rather than passed '
            + 'to newInstanceGmt precisely so it rolls forward instead of throwing');
    }

    @isTest
    static void parseRfc5322Date_hourTwentyFour_doesNotThrowAndRollsForward() {
        Datetime parsed = EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 24:00:00 +0000');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 27, 0, 0, 0), parsed,
            'Hour 24 means end-of-day and is legal; same reason it is added rather than constructed');
    }

    @isTest
    static void parseRfc5322Date_missingZone_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22'),
            'The zone is REQUIRED and this parser refuses to assume UTC — assuming would silently move '
            + 'the value by up to 12 hours, whereas null degrades to CreatedDate, which is within seconds '
            + 'of the truth');
    }

    @isTest
    static void parseRfc5322Date_militarySingleLetterZone_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 M'),
            'RFC 5322 §4.3 records that single-letter military zones were widely implemented with the '
            + 'SIGN INVERTED and directs readers to treat them as unknown. A 50%-wrong answer is worse '
            + 'than no answer');
    }

    @isTest
    static void parseRfc5322Date_unknownZoneName_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 XYZ'),
            'An unrecognised alphabetic zone must reject the header rather than default to UTC');
    }

    @isTest
    static void parseRfc5322Date_zoneOffsetBeyondTwentyFourHours_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 +2500'),
            'An offset past +/-24:00 is corruption, not a timezone — this is what MAX_ZONE_OFFSET_MINUTES '
            + 'is for, and without it a garbage zone would shift the timestamp by days');
    }

    @isTest
    static void parseRfc5322Date_zoneOffsetWithOutOfRangeMinutes_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 +0099'),
            'The minute half of a numeric offset is still a minute count; 99 is not one. Tested separately '
            + 'from the hour overflow above because they are different guards');
    }

    @isTest
    static void parseRfc5322Date_shortNumericZone_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:03:22 +05'),
            'A numeric zone must be exactly four digits; +05 is ambiguous between +0500 and +0005 and the '
            + 'parser does not guess');
    }

    @isTest
    static void parseRfc5322Date_timeWithoutColons_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 140322 +0000'),
            'The time token must carry at least hour:minute; a bare digit run is not a time');
    }

    @isTest
    static void parseRfc5322Date_fullMonthName_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 August 2026 14:03:22 +0000'),
            'The grammar allows ONLY the three-letter abbreviation; a full month name is not a date this '
            + 'parser will guess at');
    }

    @isTest
    static void parseRfc5322Date_nonNumericDay_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, XX Aug 2026 14:03:22 +0000'),
            'A non-numeric day must be rejected, not coerced');
    }

    @isTest
    static void parseRfc5322Date_nonNumericTime_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 aa:bb:cc +0000'),
            'A non-numeric time must be rejected, not coerced');
    }

    @isTest
    static void parseRfc5322Date_minuteOutOfRange_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug 2026 14:99:22 +0000'),
            'Minute 99 is corruption; the range guards exist so it never silently rolls into the next hour');
    }

    @isTest
    static void parseRfc5322Date_truncatedHeader_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('Tue, 26 Aug'),
            'A truncated header has fewer than the five required tokens and must return null, not throw '
            + 'an index-out-of-bounds that the boundary would turn into a bounced email');
    }

    @isTest
    static void parseRfc5322Date_garbage_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('()'),
            'A header that is nothing but a CFWS comment reduces to an empty string after stripping; it '
            + 'must reduce to null, not throw on the empty token list');
    }

    @isTest
    static void parseRfc5322Date_nullInput_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date(null),
            'A null header — the ordinary "the email carried no Date" case — must return null');
    }

    @isTest
    static void parseRfc5322Date_blankInput_returnsNull() {
        Assert.isNull(EmailToLeadHandler.parseRfc5322Date('   '),
            'Whitespace-only is not a date. Tested separately from null per one-behaviour-per-method');
    }
}
