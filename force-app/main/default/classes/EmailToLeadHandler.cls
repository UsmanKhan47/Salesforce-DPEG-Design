/**
 * Broker-Protection inbound-email intake — email-service boundary (staging model).
 * Registered as the target of a Salesforce Email Service; the platform invokes
 * handleInboundEmail for every forwarded broker email. This class does PARSING ONLY —
 * envelope, RFC headers, and the first inline image — then hands a fully-shaped payload to
 * InboundEmailStagingService and enqueues the async router.
 *
 * IT NO LONGER CREATES A LEAD. Previously this boundary inserted a Lead immediately so the
 * email "could not be lost". That guarantee is now carried by Inbound_Email_Staging__c, and
 * carrying it there is strictly better: the raw body AND every RFC header survive, whereas a
 * Lead could only hold what the envelope said. Deferring Lead creation to the routing tree
 * is what makes reply-threading, repeat detection and redelivery suppression possible at
 * all — each of those must be able to decide that NO new Lead should exist.
 *
 * WHY THE HEADERS ARE CAPTURED HERE AND NOWHERE ELSE. Messaging.InboundEmail is a
 * transient, platform-supplied object that exists only for the duration of this method.
 * Message-ID, In-Reply-To and References are unrecoverable once it goes out of scope, and
 * they are precisely what the async job needs for idempotency and threading. Everything the
 * pipeline will ever know about the transport must be read and persisted in this one call.
 *
 * AUTO-FORWARD vs MANUAL FORWARD. Both arrive as ordinary inbound email but mean opposite
 * things about the From address:
 *   • AUTO-forward (a Gmail rule on a monitored inbox) preserves the BROKER as From and
 *     records the forwarding inbox in X-Forwarded-For / Delivered-To.
 *   • MANUAL forward (a person hitting Fwd) puts the INTERNAL FORWARDER in From, and the
 *     broker survives only inside the quoted body — where the LLM finds it later.
 * resolveMonitoredInbox reads the headers first and falls back to From, so
 * Forwarded_By__c means "the monitored inbox this reached us through" in both shapes.
 *
 * LAYER — Inbound email handler (boundary). No SOQL, no callouts, and no DML of its own:
 * the staging insert is delegated to InboundEmailStagingService. `global` is mandated by the
 * Messaging.InboundEmailHandler interface (both the class and the method must be global).
 * `with sharing` is declared for standards conformance and is functionally a no-op because
 * the handler performs no data access itself.
 *
 * @see InboundEmailStagingService.cls (owns the staging DML)
 * @see ExtractAddressQueueable.cls (the async routing tree this enqueues)
 */
global with sharing class EmailToLeadHandler implements Messaging.InboundEmailHandler {

    /** Attachment MIME prefix / bare subtypes treated as an inline image to send to the LLM. */
    private static final String IMAGE_MIME_PREFIX = 'image/';
    private static final String SUBTYPE_JPEG = 'jpeg';
    private static final String SUBTYPE_PNG = 'png';

    /** RFC header names, lowercased — header names are case-insensitive per RFC 5322. */
    private static final String HEADER_MESSAGE_ID = 'message-id';
    private static final String HEADER_IN_REPLY_TO = 'in-reply-to';
    private static final String HEADER_REFERENCES = 'references';
    private static final String HEADER_X_FORWARDED_FOR = 'x-forwarded-for';
    private static final String HEADER_DELIVERED_TO = 'delivered-to';

    /** Raw_Headers__c / Raw_Body__c are 131072-char LongTextAreas. */
    private static final Integer LEN_RAW = 131072;

    /** Address matcher used to mine forwarding headers, which carry free-form text. */
    private static final Pattern EMAIL_PATTERN =
        Pattern.compile('[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}');

    /**
     * Handle one inbound forwarded broker email: parse the first image attachment, capture
     * every RFC header, resolve the monitored inbox that forwarded it, persist all of it as
     * an Inbound_Email_Staging__c row, and enqueue ExtractAddressQueueable to do the rest
     * asynchronously.
     *
     * The image is passed to the queueable as a CONSTRUCTOR ARGUMENT rather than stored on
     * the staging row: base64 image data routinely exceeds any text field, and the staging
     * object deliberately records only Has_Image__c / Image_Mime_Type__c. The bytes are
     * needed exactly once, by the LLM vision call in the job this method enqueues.
     *
     * Any failure is caught and reported on the result so the platform records the
     * bounce/failure rather than throwing.
     *
     * @param email    The inbound email (from name/address, subject, bodies, headers, attachments).
     * @param envelope The inbound envelope; `toAddress` identifies the Email Service address
     *                 itself, which must be excluded when mining forwarding headers.
     * @return An InboundEmailResult: success=true when the staging row was written and the
     *         async router enqueued; success=false with a message when it failed.
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

            String serviceAddress = (envelope == null) ? null : envelope.toAddress;
            String monitoredInbox = resolveMonitoredInbox(
                firstHeader(email, HEADER_X_FORWARDED_FOR),
                allHeaders(email, HEADER_DELIVERED_TO),
                serviceAddress);

            InboundEmailStagingService.StagingRequest request =
                new InboundEmailStagingService.StagingRequest();
            request.fromName = email.fromName;
            request.fromAddress = email.fromAddress;
            request.subject = email.subject;
            request.rawBody = (email.plainTextBody != null) ? email.plainTextBody : email.htmlBody;
            request.rawHeaders = extractRawHeaders(email);
            request.messageId = firstHeader(email, HEADER_MESSAGE_ID);
            request.inReplyTo = firstHeader(email, HEADER_IN_REPLY_TO);
            request.references = firstHeader(email, HEADER_REFERENCES);
            // Manual forwards carry no forwarding header, and there the envelope From IS the
            // internal person who forwarded — so From is the correct fallback, not a guess.
            request.forwardedBy = (monitoredInbox != null) ? monitoredInbox : email.fromAddress;
            request.imageMimeType = imageMimeType;
            request.hasImage = (imageBase64 != null);

            Id stagingId = InboundEmailStagingService.createStaging(request);
            System.enqueueJob(new ExtractAddressQueueable(stagingId, imageBase64, imageMimeType));

            result.success = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'EmailToLeadHandler.handleInboundEmail failed: ' + e.getMessage());
            result.success = false;
            result.message = 'Inbound email staging failed: ' + e.getMessage();
        }
        return result;
    }

    /**
     * Identify the monitored inbox an auto-forwarded email travelled through, or null when
     * there is no evidence of auto-forwarding.
     *
     * Gmail's forwarding rules stamp `X-Forwarded-For: <original> <destination>` and
     * `Delivered-To: <destination>`; both may also appear several times when an email has
     * been relayed more than once. Every address found is a candidate EXCEPT the Email
     * Service's own address, which is present in these headers on essentially every message
     * and identifies our own endpoint rather than any user's inbox.
     *
     * Returning null is a meaningful answer, not a failure: it says "this looks like a manual
     * forward", and the caller then uses the envelope From — which on a manual forward is
     * exactly the internal person who forwarded it.
     *
     * @param xForwardedFor Raw X-Forwarded-For header value; may be null.
     * @param deliveredTo   Every Delivered-To header value, in order; may be null or empty.
     * @param serviceAddress The Email Service's own inbound address, excluded from matching.
     * @return The forwarding inbox address, or null when no non-service address was found.
     */
    private static String resolveMonitoredInbox(String xForwardedFor, List<String> deliveredTo,
                                                String serviceAddress) {
        String candidate = firstNonServiceAddress(xForwardedFor, serviceAddress);
        if (candidate != null) {
            return candidate;
        }
        if (deliveredTo != null) {
            for (String header : deliveredTo) {
                candidate = firstNonServiceAddress(header, serviceAddress);
                if (candidate != null) {
                    return candidate;
                }
            }
        }
        return null;
    }

    /**
     * The first email address in `raw` that is not the Email Service's own address.
     * Forwarding headers are free-form and may hold a bare address, a display name plus an
     * angle-bracketed address, or several addresses in sequence, so the value is mined with
     * a regex rather than parsed positionally.
     *
     * @param raw            A raw forwarding header value; blank returns null.
     * @param serviceAddress The address to skip; blank means skip nothing.
     * @return The first non-service address found, or null.
     */
    private static String firstNonServiceAddress(String raw, String serviceAddress) {
        if (String.isBlank(raw)) {
            return null;
        }
        String excluded = String.isBlank(serviceAddress) ? null : serviceAddress.trim();
        Matcher addresses = EMAIL_PATTERN.matcher(raw);
        while (addresses.find()) {
            String found = addresses.group();
            if (excluded == null || !found.equalsIgnoreCase(excluded)) {
                return found;
            }
        }
        return null;
    }

    /**
     * Every RFC header the platform exposed, rendered one 'Name: Value' per line, clipped to
     * Raw_Headers__c's 131072 characters.
     *
     * This is captured WHOLE and unparsed on purpose. The pipeline extracts five headers by
     * name today, but header-driven diagnosis (spam filtering, forwarding-chain reconstruction,
     * DKIM/SPF questions, working out which relay mangled a Message-ID) always needs the ones
     * nobody thought to extract — and by the time the question is asked the
     * Messaging.InboundEmail is long gone. Storing the lot costs one field and makes those
     * questions answerable from the record.
     *
     * @param email The inbound email whose headers to render.
     * @return The rendered header block, or null when the platform supplied no headers.
     */
    private static String extractRawHeaders(Messaging.InboundEmail email) {
        if (email.headers == null || email.headers.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (Messaging.InboundEmail.Header header : email.headers) {
            if (header == null || String.isBlank(header.name)) {
                continue;
            }
            lines.add(header.name + ': ' + (header.value == null ? '' : header.value));
        }
        return lines.isEmpty() ? null : InboundEmailFieldUtil.clip(String.join(lines, '\n'), LEN_RAW);
    }

    /**
     * The first value of the named header, matched case-insensitively (RFC 5322 header names
     * are case-insensitive, and relays disagree about casing — 'Message-ID' vs 'Message-Id'
     * vs 'MESSAGE-ID' are all the same header).
     *
     * @param email      The inbound email.
     * @param lowerName  The header name to find, already lowercased.
     * @return The header's value, or null when absent.
     */
    private static String firstHeader(Messaging.InboundEmail email, String lowerName) {
        if (email.headers == null) {
            return null;
        }
        for (Messaging.InboundEmail.Header header : email.headers) {
            if (header != null && header.name != null && header.name.toLowerCase() == lowerName) {
                return header.value;
            }
        }
        return null;
    }

    /**
     * Every value of the named header, in the order the platform supplied them. Needed for
     * Delivered-To specifically: an email relayed through more than one inbox carries one
     * Delivered-To per hop, and reading only the first would miss the monitored inbox on any
     * multi-hop forward.
     *
     * @param email     The inbound email.
     * @param lowerName The header name to find, already lowercased.
     * @return All values for that header; an empty list when absent (never null).
     */
    private static List<String> allHeaders(Messaging.InboundEmail email, String lowerName) {
        List<String> values = new List<String>();
        if (email.headers == null) {
            return values;
        }
        for (Messaging.InboundEmail.Header header : email.headers) {
            if (header != null && header.name != null && header.name.toLowerCase() == lowerName
                    && String.isNotBlank(header.value)) {
                values.add(header.value);
            }
        }
        return values;
    }
}
