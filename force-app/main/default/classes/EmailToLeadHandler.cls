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
 * ═══ 🔴 THE 2026-08-06 OUTAGE, AND WHY THIS BOUNDARY LOOKS THE WAY IT DOES ═══
 * `InboundEmailAttachmentService.persist` was called HERE from 2026-08-05 until 2026-08-06 and
 * it DESTROYED EVERY INBOUND EMAIL CARRYING AN ATTACHMENT in this org. The evidence is direct,
 * from anonymous Apex against `usman-dpeg`, four cases:
 *
 *     no attachment                     -> success: staging row, Lead and Task all created
 *     100 KB / 1 MB / 5 MB attachment   -> identical fatal failure, everything rolled back
 *
 *     System.UnexpectedException: ContentPublication Limit exceeded.
 *       at InboundEmailAttachmentService.persist -> Database.insert(versions, false)
 *
 * FIVE MEASURED FACTS, EACH OF WHICH DEFEATS AN OBVIOUS "FIX":
 *
 *   1. SIZE IS IRRELEVANT. Heap peaked at 4,262 bytes — three orders of magnitude below the
 *      6 MB limit. This is NOT the heap failure VISION_MAX_BYTES / TEXT_MAX_BYTES address, and
 *      lowering either constant would change nothing.
 *   2. IT IGNORES `allOrNone = false` entirely. Partial-success patterns give no protection.
 *   3. IT ESCAPES BOTH `catch (Exception e)` BLOCKS — persist()'s own AND this method's —
 *      reaching the top as FATAL_ERROR. 🔴 DO NOT ATTEMPT A "BETTER CATCH". It has been
 *      measured; it does not work.
 *   4. IT CANNOT BE PRE-CHECKED. The Apex `Limits` class exposes no `ContentPublicationLimit`.
 *      (And do not add a REST callout to the `/limits` API: it is prohibited by
 *      ARCHITECTURE.md §3.1, and SP-6 measured that reading MEASURABLY STALE and
 *      NON-MONOTONIC, so it would be actively misleading rather than merely imprecise.)
 *   5. THE ROLLBACK IS TOTAL. Salesforce rolls back the whole transaction including the
 *      already-committed staging insert, so the outcome is: no staging row, no Lead, no Task,
 *      no AsyncApexJob, no bounce, no error record. THE EMAIL IS SIMPLY GONE.
 *
 * ⚠ AND NO EMAIL SERVICE SETTING COVERS IT. The five configurable failure actions govern
 * sender/rate/deactivation/inactive-service REJECTIONS. When the handler dies with an uncaught
 * FATAL_ERROR, `InboundEmailResult` is never returned at all and none of them applies — so the
 * `Discard` -> `Bounce` change (applied, and worth having) did NOT address the invisibility.
 * Only the transaction structure below does.
 *
 * ═══ ✅ THE FIX (2026-08-06): THE BYTES ARE PARKED HERE, CONVERTED SOMEWHERE ELSE ═══
 * THE DESIGN RULE, stated once: **a `ContentVersion` insert must never sit inside a transaction
 * whose rollback would lose something irreplaceable.** Three transactions, and only the third
 * may touch Content:
 *
 *   1. THIS METHOD          owns THE EMAIL (the staging row is the only record it existed)
 *   2. ExtractAddressQueueable owns THE LEAD AND THE REGISTRY CLAIM
 *   3. AttachmentPersistQueueable owns only FILES — and under the carrier model not even those,
 *      because a failure leaves the bytes on the staging row for the sweeper to retry.
 *
 * So this handler now calls `InboundEmailAttachmentService.stageBytes(...)`, which parks each
 * retained attachment on the staging row as a CLASSIC `Attachment` — **zero ContentPublications
 * (SP-4.1, definitive) and ~152 bytes of heap at any file size (SP-4.3)** — and the file job
 * chained from routing converts them later. `Attachment_Status__c` is stamped 'Pending' (or
 * 'None') in the staging insert itself, which is what makes the retry sweep possible.
 *
 * 🔴 IDS ONLY ON THE ENQUEUE, NEVER BYTES. SP-1 measured an UNCATCHABLE
 * `System.LimitException: Batchable instance is too big` thrown at `System.enqueueJob` ITSELF
 * above ~4.2-4.5 MB — a `try/catch` around the enqueue did not catch it. Carrying attachments
 * on the payload would have moved the outage ONE CALL EARLIER, into this very transaction. The
 * <= 1 MB vision image stays, and only because SP-1 proved ~4x headroom for it specifically.
 *
 * ═══ ATTACHMENT CLASSIFICATION (2026-08-05; constants revised 2026-08-06) ═══
 *   • THE VISION ENCODE IS SIZE-GATED (VISION_MAX_BYTES, decisions A1-a / A2) — the one
 *     approved crossing of the "vision path unchanged" boundary, and the ONLY defence
 *     against the uncatchable heap LimitException documented on that constant. UNCHANGED.
 *   • `MAX_ATTACHMENTS` is 3 (was 10) and `ATTACHMENT_MAX_BYTES` is 4,000,000 (was 5,000,000).
 *     Both live on InboundEmailAttachmentService; neither classification RULE changed.
 *   • GOVERNOR BUDGET: **0 SOQL / 2 DML** — the staging insert plus ONE bulk carrier insert,
 *     constant regardless of file count, and **0 SOQL / 1 DML when nothing was retained**, so
 *     the feature is provably zero-cost on an ordinary email. Caps are 100 / 150.
 *
 * LAYER — Inbound email handler (boundary). No SOQL, no callouts, and no DML of its own:
 * the staging insert is delegated to InboundEmailStagingService and every file write to
 * InboundEmailAttachmentService. `global` is mandated by the Messaging.InboundEmailHandler
 * interface (both the class and the method must be global). `with sharing` is declared for
 * standards conformance and is functionally a no-op because the handler performs no data
 * access itself.
 *
 * @see InboundEmailStagingService.cls (owns the staging DML)
 * @see InboundEmailAttachmentService.cls (classify() + stageBytes(); persist() is NOT called here)
 * @see ExtractAddressQueueable.cls (the async routing tree this enqueues)
 * @see AttachmentPersistQueueable.cls (transaction 3 — the ONLY admissible home for Content DML)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §3.4, §11.8
 * @see agent-output/spike-attachment-persistence-v2.md (SP-1, SP-4, SP-5)
 */
global with sharing class EmailToLeadHandler implements Messaging.InboundEmailHandler {

    /** Attachment MIME prefix / bare subtypes treated as an inline image to send to the LLM. */
    private static final String IMAGE_MIME_PREFIX = 'image/';
    private static final String SUBTYPE_JPEG = 'jpeg';
    private static final String SUBTYPE_PNG = 'png';

    /**
     * ✅ DECISIONS A1-a / A2 — THE ONLY HEAP LEVER THIS BOUNDARY HAS. Above this many bytes
     * an image is NOT base64-encoded and NOT sent to the LLM; the skip is recorded on the
     * staging row instead.
     *
     * WHY IT IS NECESSARY. Email services run SYNCHRONOUS Apex — heap limit 6 MB — and an
     * Apex governor LimitException is NOT CATCHABLE, so the `catch (Exception e)` below does
     * not cover it. `EncodingUtil.base64Encode(blob)` holds the source Blob (S bytes) AND the
     * encoded String (ceil(S/3) x 4 chars) simultaneously: peak 2.33S at one byte/char, 3.67S
     * at UTF-16's two. The true crossing point is therefore between ~1.6 MB and ~2.5 MB — AN
     * ORDINARY PHONE PHOTO OF A PROPERTY. Crossing it kills the transaction, rolls back the
     * staging insert, and the email is simply gone: no Lead, no registry claim, no audit row.
     * At 1,000,000 the worst case is 1.0 MB + 2.67 MB = 3.67 MB, leaving ~2.3 MB for the
     * other blobs and the body. OpenAI downsamples to ~2000 px regardless, so 1 MB is ample.
     *
     * ⚠ THIS IS THE ONE APPROVED CROSSING OF THE "vision path unchanged" BOUNDARY, taken
     * consciously at Gate 1 as a BUG FIX: the vision call's inputs are BYTE-IDENTICAL for
     * every image under the threshold, and above it the image is skipped and recorded rather
     * than crashing the handler and losing the email. No prompt change, no extraction-contract
     * change, no fixture re-pinning.
     *
     * ⚠ It lives HERE, next to the encode it gates — not on InboundEmailAttachmentService,
     * whose retention caps bound CDL rows and the pathological case but do NOT protect heap
     * (the platform already holds every attachment Blob in heap before this method starts).
     */
    @TestVisible private static final Integer VISION_MAX_BYTES = 1000000;

    /** Recorded on the staging row when VISION_MAX_BYTES turns an image away. */
    @TestVisible private static final String REASON_VISION_TOO_LARGE =
        'not sent to the LLM: exceeds VISION_MAX_BYTES (1000000)';

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
     * an Inbound_Email_Staging__c row, park the attachment BYTES on that row as classic
     * `Attachment` carriers, and enqueue ExtractAddressQueueable to do the rest asynchronously.
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
            // ═══ ATTACHMENT CLASSIFICATION — THE ORDER IS LOAD-BEARING ═══
            //   1. marshal   — references only, NEVER Blob copies
            //   2. classify  — pure; allow-list, image floor, and all four caps
            //   3. vision    — SIZE-GATED base64 of the first RETAINED image (A1-a / A2)
            //   4. staging   — counts, dropped notes and Attachment_Status__c, ONE insert
            //   5. stageBytes— ONE bulk classic-Attachment insert: the BYTE CARRIER
            //   6. enqueue   — LAST, and Ids only
            //
            // 🔴 STEP 5 USED TO BE "persist the files as ContentVersions". It destroyed every
            // email carrying an attachment; see THE 2026-08-06 OUTAGE in the class header.
            //
            // ⚠ Do NOT read the ordering as protecting the staging row from a governor death.
            // It does not — an uncatchable LimitException or UnexpectedException rolls back the
            // entire transaction INCLUDING the staging insert. Ordering is correct for ORDINARY
            // failures only; against the platform ones the only defence is not doing the work
            // here at all, which is exactly what steps 5 and 6 now respect.
            List<InboundEmailAttachmentService.AttachmentRequest> candidates =
                marshalAttachments(email);
            InboundEmailAttachmentService.ClassificationResult classified =
                InboundEmailAttachmentService.classify(candidates);

            String imageBase64 = null;
            String imageMimeType = null;
            String visionSkipNote = null;

            InboundEmailAttachmentService.AttachmentRequest visionCandidate =
                firstVisionImage(classified.retained);
            if (visionCandidate != null) {
                Integer bytes = (visionCandidate.byteSize == null) ? 0 : visionCandidate.byteSize;
                if (bytes > VISION_MAX_BYTES) {
                    // A1-a. Skipped and RECORDED, never silent — and never a crash.
                    visionSkipNote = InboundEmailAttachmentService.describeDrop(
                        visionCandidate, REASON_VISION_TOO_LARGE);
                    System.debug(LoggingLevel.WARN,
                        'EmailToLeadHandler: image attachment "' + visionCandidate.fileName
                        + '" is ' + bytes + ' bytes, above VISION_MAX_BYTES ('
                        + VISION_MAX_BYTES + '); not sent to the LLM.');
                } else {
                    imageBase64 = EncodingUtil.base64Encode(visionCandidate.body);
                    // Normalize to a valid image/* MIME. mimeTypeSubType may arrive as a
                    // bare subtype ('png'/'jpeg') OR already-qualified ('image/png'); the
                    // LLM data URL requires the 'image/' prefix, so add it only when absent.
                    String subtype = visionCandidate.mimeSubType.toLowerCase();
                    imageMimeType = subtype.startsWith(IMAGE_MIME_PREFIX)
                        ? subtype
                        : IMAGE_MIME_PREFIX + subtype;
                    System.debug(LoggingLevel.DEBUG,
                        'EmailToLeadHandler: using image attachment "' + visionCandidate.fileName
                        + '" (' + visionCandidate.mimeSubType + ')');
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
            // Has_Image__c has always meant "an inline image was found AND handed to the async
            // extractor", so a vision-gated image correctly leaves it false. The reason it was
            // not sent is on Dropped_Attachment_Notes__c.
            request.hasImage = (imageBase64 != null);
            // The row records WHAT ARRIVED (retained count and bytes) and, from 2026-08-06,
            // WHAT STATE THE FILE PIPELINE IS IN. 'Pending' means "a carrier was written and
            // conversion has not been attempted yet"; 'None' means nothing was retained. A count
            // with no files and no explanation is precisely the silent divergence this module
            // exists to prevent, which is why the status is stamped in the SAME insert.
            request.attachmentCount = classified.retainedCount;
            request.attachmentBytes = classified.retainedBytes;
            request.droppedNotes = joinNotes(classified.droppedNotes, visionSkipNote);
            request.attachmentStatus = classified.retained.isEmpty()
                ? InboundEmailStagingService.ATTACHMENT_STATUS_NONE
                : InboundEmailStagingService.ATTACHMENT_STATUS_PENDING;

            Id stagingId = InboundEmailStagingService.createStaging(request);

            // 🔴 EXACTLY TWO THINGS MAY SIT BETWEEN createStaging AND THIS RETURN, AND THIS IS
            // THE COMPLETE LIST. The staging row is the pipeline's durability guarantee; a
            // failure after it is written takes it, the Lead, the claim and the audit with it.
            //
            //   (a) stageBytes — ONE bulk classic-Attachment insert. Admissible because it
            //       consumes ZERO ContentPublications (SP-4.1, `/limits` 2500 -> 2500,
            //       definitive) and ~152 bytes of heap AT ANY FILE SIZE (SP-4.3, measured
            //       identically at 3 MB and 5 MB — `Body = <blob>` is a reference assignment,
            //       not a copy).
            //
            //       ⚠ ITS CONTRACT IS "IT MUST NOT THROW" — AN OBLIGATION, NOT A PROOF, AND
            //       THIS COMMENT MUST NOT ASSERT THE STRONGER FORM. It said "fully wrapped and
            //       cannot throw" until 2026-08-06; that is the SAME SENTENCE, one release
            //       earlier, as ARCHITECTURE.md's deleted "persist(...) AND linkTo(...) MUST
            //       NOT THROW, under any input" — which production falsified and which is why
            //       the v1 feature shipped. A try/catch cannot cover an Apex governor
            //       LimitException (uncatchable) and did not cover
            //       `UnexpectedException: ContentPublication Limit exceeded` either. What
            //       stageBytes actually has is: no Content DML at all, and a heap guard that
            //       PROJECTS its one allocation instead of merely reading heap (finding C1).
            //       Those are the reasons to believe it; "it is wrapped" is not one.
            //   (b) System.enqueueJob with IDS AND A <= 1 MB IMAGE ONLY.
            //
            // 🔴 NOTHING ELSE MAY JOIN THEM. In particular NEVER a ContentVersion insert (it
            // ignores allOrNone = false, escapes catch (Exception) and rolls back the staging
            // row — see the class header) and NEVER a byte-carrying enqueue (SP-1 measured an
            // UNCATCHABLE `Batchable instance is too big` thrown at System.enqueueJob itself
            // above ~4.2-4.5 MB, which would reproduce the outage one call earlier).
            InboundEmailAttachmentService.stageBytes(stagingId, classified.retained);

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
     * Marshal every binary and text attachment the platform supplied into the DTO
     * InboundEmailAttachmentService classifies.
     *
     * 🔴 REFERENCES ONLY — NO BLOB COPIES. `Messaging.InboundEmail` already holds every
     * attachment Blob in heap before this method runs, so `req.body = att.body` costs ~0
     * additional heap. Anything that COPIED a Blob here (a re-encode, a Blob.valueOf round
     * trip, a defensive clone) would reintroduce the very heap failure VISION_MAX_BYTES
     * exists to remove.
     *
     * ⚠ `byteSize` is exact for binary attachments (`Blob.size()`) and is the CHARACTER
     * COUNT for text attachments. A CSV is overwhelmingly ASCII, where the two coincide;
     * where they do not, characters UNDER-count UTF-8 bytes slightly, which only matters
     * against ATTACHMENT_MAX_BYTES (4 MB) — a ceiling the Email Service already enforces
     * upstream. Measuring the true byte length would require materializing a Blob for every
     * text attachment before deciding whether to keep it, which is the one thing this method
     * must not do.
     *
     * @param email The inbound email; null attachment collections are tolerated.
     * @return Every candidate, binary first then text, in platform order. Never null.
     */
    private static List<InboundEmailAttachmentService.AttachmentRequest> marshalAttachments(
            Messaging.InboundEmail email) {
        List<InboundEmailAttachmentService.AttachmentRequest> candidates =
            new List<InboundEmailAttachmentService.AttachmentRequest>();

        if (email.binaryAttachments != null) {
            for (Messaging.InboundEmail.BinaryAttachment att : email.binaryAttachments) {
                if (att == null) {
                    continue;
                }
                InboundEmailAttachmentService.AttachmentRequest candidate =
                    new InboundEmailAttachmentService.AttachmentRequest();
                candidate.fileName = att.fileName;
                candidate.mimeSubType = att.mimeTypeSubType;
                candidate.body = att.body;
                candidate.byteSize = (att.body == null) ? 0 : att.body.size();
                candidate.isImage = InboundEmailAttachmentService.isImageAttachment(
                    att.mimeTypeSubType, att.fileName);
                candidates.add(candidate);
            }
        }

        if (email.textAttachments != null) {
            for (Messaging.InboundEmail.TextAttachment att : email.textAttachments) {
                if (att == null) {
                    continue;
                }
                InboundEmailAttachmentService.AttachmentRequest candidate =
                    new InboundEmailAttachmentService.AttachmentRequest();
                candidate.fileName = att.fileName;
                candidate.mimeSubType = att.mimeTypeSubType;
                candidate.textBody = att.body;
                candidate.byteSize = (att.body == null) ? 0 : att.body.length();
                candidate.isImage = false;
                candidates.add(candidate);
            }
        }

        return candidates;
    }

    /**
     * The image to send to the LLM: the FIRST RETAINED attachment whose MIME subtype
     * satisfies the pipeline's long-standing image predicate.
     *
     * TWO THINGS ABOUT THIS ARE DELIBERATE AND EASY TO "TIDY" WRONGLY.
     *
     * 1. THE CANDIDATE COMES FROM THE RETAINED LIST, never from a fresh scan of
     *    `email.binaryAttachments`. That is what makes the type allow-list and the
     *    IMAGE_MIN_BYTES floor apply to it — and it closes, as a side effect of an approved
     *    decision, the long-standing risk that the LLM was reading a company signature logo
     *    instead of the offering flyer. (Residual, still open and NOT fixed here: a logo
     *    ABOVE 20 KB arriving before the flyer would still win first place.)
     *
     * 2. THE PREDICATE IS THE ORIGINAL MIME-SUBTYPE TEST, NOT
     *    InboundEmailAttachmentService.isImageAttachment. The service's rule is a UNION of
     *    MIME and filename extension (G1), which is right for RETENTION — a '.jpg' arriving
     *    as `application/octet-stream` should still be kept as a file. It is wrong here,
     *    because the value derived from `mimeTypeSubType` becomes the LLM data-URL type: a
     *    filename-identified image would yield 'image/octet-stream'. Restricting the vision
     *    candidate to the original predicate keeps the encode's inputs byte-identical to
     *    today for every image under the size gate, which is exactly what decision A1-a
     *    promised. Widening it is an extraction-path change and is out of scope.
     *
     * @param retained The classified, retained attachments; null or empty returns null.
     * @return The first eligible image, or null when there is none.
     */
    private static InboundEmailAttachmentService.AttachmentRequest firstVisionImage(
            List<InboundEmailAttachmentService.AttachmentRequest> retained) {
        if (retained == null) {
            return null;
        }
        for (InboundEmailAttachmentService.AttachmentRequest att : retained) {
            if (att == null || att.body == null || att.mimeSubType == null) {
                continue;
            }
            String subtype = att.mimeSubType.toLowerCase();
            if (subtype.startsWith(IMAGE_MIME_PREFIX)
                    || subtype == SUBTYPE_JPEG
                    || subtype == SUBTYPE_PNG) {
                return att;
            }
        }
        return null;
    }

    /**
     * Join the classification notes and the vision-gate note into the single value
     * createStaging writes, so recording the skip costs no extra DML.
     *
     * @param notes The classification drop lines, or null.
     * @param extra The vision-gate skip line, or null.
     * @return The joined block, or null when both are blank.
     */
    private static String joinNotes(String notes, String extra) {
        if (String.isBlank(extra)) {
            return notes;
        }
        return String.isBlank(notes) ? extra : notes + '\n' + extra;
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
