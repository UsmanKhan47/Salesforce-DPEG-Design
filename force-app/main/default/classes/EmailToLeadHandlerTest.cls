/**
 * Test class for EmailToLeadHandler: the Messaging.InboundEmailHandler boundary.
 * Builds Messaging.InboundEmail instances in memory (the standard pattern for testing
 * inbound email handlers — no real email service invocation needed).
 *
 * @author Unit Testing Agent
 */
@isTest
private class EmailToLeadHandlerTest {

    private static Map<String, String> blankFields() {
        return new Map<String, String>{
            'broker_name' => '', 'broker_email' => '', 'property_address' => '', 'sent_datetime' => ''
        };
    }

    private static void setBenignMock() {
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(blankFields(), false)));
    }

    private static Messaging.InboundEmail baseEmail() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'FW: Test property';
        email.fromAddress = 'broker@example.invalid';
        return email;
    }

    // ── body handling ─────────────────────────────────────────────────────────

    @isTest
    static void handleInboundEmail_plainTextBody_setsDescriptionFromPlainText() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.plainTextBody = 'Plain text body content.';
        email.htmlBody = '<p>Html body content.</p>';

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'A well-formed email should succeed');
        Lead created = [SELECT Description FROM Lead WHERE Email = 'broker@example.invalid'];
        Assert.areEqual('Plain text body content.', created.Description, 'Description should prefer the plain-text body');
    }

    @isTest
    static void handleInboundEmail_htmlOnlyBody_setsDescriptionFromHtml() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.htmlBody = '<p>Html only body content.</p>';

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'A well-formed email with only an HTML body should succeed');
        Lead created = [SELECT Description FROM Lead WHERE Email = 'broker@example.invalid'];
        Assert.areEqual('<p>Html only body content.</p>', created.Description, 'Description should fall back to the HTML body');
    }

    // ── image attachment detection ───────────────────────────────────────────

    @isTest
    static void handleInboundEmail_imageAttachment_isPickedUpAndForwardedToLlm() {
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.plainTextBody = 'See attached screenshot.';

        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.body = Blob.valueOf('fake image bytes');
        att.fileName = 'screenshot.png';
        att.mimeTypeSubType = 'png';
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(blankFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'An email with an image attachment should still succeed');
        Assert.isNotNull(mock.lastRequest, 'The LLM callout should have been made');
        String sentBody = mock.lastRequest.getBody();
        Assert.isTrue(sentBody.contains('"image_url"'), 'The image attachment should be forwarded to the LLM as an image_url content part');

        // W1 FIX: Messaging.InboundEmail.BinaryAttachment.mimeTypeSubType returns the bare
        // subtype ('png'), and EmailToLeadHandler now normalizes it to 'image/png' before
        // forwarding as imageMimeType. LLMExtractionCalloutService.buildRequestBody then builds
        // a well-formed 'data:image/png;base64,...' URL that OpenAI vision accepts (the bare
        // 'data:png;base64,...' shape was rejected with HTTP 400).
        Assert.isTrue(sentBody.contains('data:image/png;base64,'),
            'The bare mimeTypeSubType should be normalized to a valid image/* data URL (W1 fix)');
    }

    @isTest
    static void handleInboundEmail_alreadyQualifiedImageMime_isNotDoublePrefixed() {
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.plainTextBody = 'See attached screenshot.';

        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.body = Blob.valueOf('fake image bytes');
        att.fileName = 'screenshot.png';
        // Some inbound sources already qualify mimeTypeSubType (e.g. 'image/png') rather than
        // the bare subtype ('png') EmailToLeadHandler's own doc comment describes as typical.
        att.mimeTypeSubType = 'image/png';
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(blankFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'An email with an already-qualified image MIME type should still succeed');
        String sentBody = mock.lastRequest.getBody();
        // W1: subtype.startsWith('image/') is already true here, so the ternary's TRUE branch
        // must pass the subtype through UNCHANGED — asserting the exact single-prefixed shape
        // proves this branch does not double-prefix to 'data:image/image/png;base64,...'.
        Assert.isTrue(sentBody.contains('data:image/png;base64,'),
            'An already-qualified image/png MIME type should be forwarded unchanged, not double-prefixed (W1 fix)');
        Assert.isFalse(sentBody.contains('data:image/image/png;base64,'),
            'An already-qualified MIME type must never be prefixed a second time');
    }

    @isTest
    static void handleInboundEmail_bareJpegAttachment_isNormalizedToImageJpeg() {
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.plainTextBody = 'See attached photo.';

        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.body = Blob.valueOf('fake jpeg bytes');
        att.fileName = 'photo.jpg';
        att.mimeTypeSubType = 'jpeg';
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(blankFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isTrue(result.success, 'An email with a bare jpeg attachment should still succeed');
        String sentBody = mock.lastRequest.getBody();
        Assert.isTrue(sentBody.contains('data:image/jpeg;base64,'),
            'A bare "jpeg" mimeTypeSubType should be normalized to a valid image/jpeg data URL (W1 fix)');
    }

    @isTest
    static void handleInboundEmail_noAttachments_sendsNoImageUrlPart() {
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.plainTextBody = 'No attachment here.';

        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(blankFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isFalse(mock.lastRequest.getBody().contains('"image_url"'),
            'No image_url part should be sent when there is no image attachment');
    }

    // ── fromName derivation (via the full handler -> service chain) ─────────

    @isTest
    static void handleInboundEmail_fromNameWithSpace_splitsFirstAndLastName() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Jane Broker';
        email.plainTextBody = 'body';

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Email = 'broker@example.invalid'];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should be the first token of fromName');
        Assert.areEqual('Broker', created.LastName, 'LastName should be the second token of fromName');
    }

    @isTest
    static void handleInboundEmail_singleWordFromName_setsLastNameOnly() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = 'Broker';
        email.plainTextBody = 'body';

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Email = 'broker@example.invalid'];
        Assert.isNull(created.FirstName, 'A spaceless fromName should not populate FirstName');
        Assert.areEqual('Broker', created.LastName, 'A spaceless fromName should become the whole LastName');
    }

    @isTest
    static void handleInboundEmail_nullFromName_defaultsLastNameToUnknown() {
        setBenignMock();
        Messaging.InboundEmail email = baseEmail();
        email.fromName = null;
        email.plainTextBody = 'body';

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Email = 'broker@example.invalid'];
        Assert.isNull(created.FirstName, 'A null fromName should leave FirstName unset');
        Assert.areEqual('Unknown', created.LastName, 'A null fromName should fall back to the required LastName default');
    }

    // ── exception path ────────────────────────────────────────────────────────

    @isTest
    static void handleInboundEmail_leadInsertFails_returnsFailureResult() {
        Messaging.InboundEmail email = baseEmail();
        String overLongSubject = '';
        for (Integer i = 0; i < 256; i++) {
            overLongSubject += 'x';
        }
        email.subject = overLongSubject; // exceeds Lead.Email_Subject__c's 255-char length -> DmlException on insert
        email.fromName = 'Jane Broker';
        email.plainTextBody = 'body';

        EmailToLeadHandler handler = new EmailToLeadHandler();
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        Assert.isFalse(result.success, 'An insert failure should surface as success=false, not an uncaught exception');
        Assert.isNotNull(result.message, 'A failure message should be populated');
        Assert.isTrue(result.message.contains('Lead creation failed'), 'The failure message should carry the documented prefix');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Email = 'broker@example.invalid'],
            'No Lead should be committed when the insert fails');
    }
}
