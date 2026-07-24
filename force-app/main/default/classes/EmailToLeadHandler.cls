/**
 * Broker-Protection inbound-email intake — email-service boundary (CHUNK 3). Registered as
 * the target of a Salesforce Email Service; the platform invokes handleInboundEmail for
 * every forwarded broker email. This class is the THIN boundary: it does attachment
 * parsing only (locate the first inline image, if any) and immediately delegates all Lead
 * creation and downstream orchestration to EmailToLeadService.
 *
 * LAYER — Inbound email handler (boundary). No business DML, no SOQL, no callouts here.
 * `global` is mandated by the Messaging.InboundEmailHandler interface (both the class and
 * the method must be global). `with sharing` is declared for standards conformance and is
 * functionally a no-op because the handler performs no data access itself.
 *
 * @see EmailToLeadService.cls (owns Lead DML + enqueues the async extractor)
 */
global with sharing class EmailToLeadHandler implements Messaging.InboundEmailHandler {

    /** Attachment MIME prefix / bare subtypes treated as an inline image to send to the LLM. */
    private static final String IMAGE_MIME_PREFIX = 'image/';
    private static final String SUBTYPE_JPEG = 'jpeg';
    private static final String SUBTYPE_PNG = 'png';

    /**
     * Handle one inbound forwarded broker email: find the first image attachment (base64 +
     * MIME type), then hand the envelope off to EmailToLeadService.createLeadAndEnqueue.
     * Any failure is caught and reported back on the result so the platform records the
     * bounce/failure rather than throwing.
     *
     * @param email    The inbound email (from name/address, subject, bodies, attachments).
     * @param envelope The inbound envelope (from/to routing addresses); unused here.
     * @return An InboundEmailResult: success=true when the Lead was created and the async
     *         extractor enqueued; success=false with a message when creation failed.
     */
    global Messaging.InboundEmailResult handleInboundEmail(
            Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        try {
            String imageBase64 = null;
            String imageMimeType = null;

            if (email.binaryAttachments != null) {
                for (Messaging.InboundEmail.BinaryAttachment att : email.binaryAttachments) {
                    String subtype = (att.mimeTypeSubType == null)
                        ? '' : att.mimeTypeSubType.toLowerCase();
                    if (subtype.startsWith(IMAGE_MIME_PREFIX)
                            || subtype == SUBTYPE_JPEG
                            || subtype == SUBTYPE_PNG) {
                        imageBase64 = EncodingUtil.base64Encode(att.body);
                        // Normalize to a valid image/* MIME. mimeTypeSubType may arrive as a
                        // bare subtype ('png'/'jpeg') OR already-qualified ('image/png'); the
                        // LLM data URL requires the 'image/' prefix, so add it only when absent.
                        // `subtype` is already the lowercased mimeTypeSubType.
                        imageMimeType = subtype.startsWith(IMAGE_MIME_PREFIX)
                            ? subtype
                            : IMAGE_MIME_PREFIX + subtype;
                        System.debug(LoggingLevel.DEBUG,
                            'EmailToLeadHandler: using image attachment "' + att.fileName
                            + '" (' + att.mimeTypeSubType + ')');
                        break;
                    }
                }
            }

            EmailToLeadService.createLeadAndEnqueue(
                email.fromName, email.fromAddress, email.subject,
                email.plainTextBody, email.htmlBody, imageBase64, imageMimeType);

            result.success = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'EmailToLeadHandler.handleInboundEmail failed: ' + e.getMessage());
            result.success = false;
            result.message = 'Lead creation failed: ' + e.getMessage();
        }
        return result;
    }
}
