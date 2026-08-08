/**
 * Broker-Protection inbound-email intake — ATTACHMENT CAPTURE (2026-08-05; REDESIGNED 2026-08-06).
 * The ONLY class in the application that writes ContentVersion, ContentDocumentLink or the
 * classic `Attachment` BYTE CARRIER for this module. It classifies what arrived, stages the
 * bytes synchronously as a carrier, and — later, from a transaction that owns nothing else —
 * turns those carriers into Salesforce Files and links them to every routed record.
 *
 * ═══ 🔴 THE FAILURE BOUNDARY — REWRITTEN 2026-08-06 BECAUSE THE OLD RULE WAS FALSIFIED ═══
 * This section used to read: *"persist(...) and linkTo(...) MUST NOT THROW, under any input"*,
 * and it named that the acceptance criterion for the whole feature. **PRODUCTION FALSIFIED IT.**
 *
 * With the org's ContentPublication quota exhausted, `Database.insert(versions, false)` threw
 * `System.UnexpectedException: ContentPublication Limit exceeded`, and four things were measured:
 *
 *   M1  a ContentVersion insert is not an ordinary DML — it consumes an org-wide, rolling,
 *       non-refundable 2,500/24h quota;
 *   M2  the failure **IGNORES `allOrNone = false`** entirely;
 *   M3  it **ESCAPES `catch (Exception e)` THROUGH TWO NESTED LAYERS**, arriving as FATAL_ERROR.
 *       🔴 "Catch it better" is MEASURED-DEAD. Do not propose it;
 *   M4  Apex `Limits` exposes no `ContentPublicationLimit`, so no pre-check exists;
 *   M5  `InboundEmailResult.success = false` rolls back ALL handler DML, the staging row with it.
 *
 * So `persist` could not keep its promise, and the whole inbound email — Lead, registry claim,
 * Task, audit trail — was destroyed for every message carrying an attachment.
 *
 * **THE RULE THAT REPLACES IT, AND IT IS A RULE ABOUT CALLERS, NOT ABOUT CODE IN THIS FILE:**
 *
 *   🔴 `persist(...)` AND `linkTo(...)` MAY ONLY EVER BE CALLED FROM A TRANSACTION THAT OWNS
 *      NOTHING IRREPLACEABLE. Today that is exactly two places: `AttachmentPersistQueueable`
 *      and `AttachmentCarrierSweepBatch`. NEVER from `EmailToLeadHandler` (which owns the
 *      email) and NEVER from `ExtractAddressQueueable` (which owns the Lead and the claim).
 *
 * The `try/catch` and `allOrNone = false` in these methods are KEPT — they still handle every
 * ORDINARY failure correctly — but they are **not** protection against M1 and must never be
 * described as if they were.
 *
 * `stageBytes(...)` is the one method here that still runs at the synchronous boundary, and it
 * is admissible for a measured reason: a classic `Attachment` insert consumes **ZERO
 * ContentPublications** (SP-4.1, definitive) and costs **~152 bytes of heap at any file size**
 * (SP-4.3 — `Body = <blob>` on a fresh row is a reference assignment, not a copy). It must not
 * throw, and nothing else may join it there.
 *
 * ═══ REFUSALS ARE RECORDED, NOT MERELY LOGGED (the R1 lesson) ═══
 * ARCHITECTURE.md records what a fail-soft write costs when its ENTIRE failure surface is
 * `allOrNone = false` plus a System.debug: the EAC adopter can produce zero writes with no
 * durable signal — no exception, no failed job, nothing queryable — which is
 * indistinguishable from "nothing needed writing". Every refusal here is therefore appended
 * to `Dropped_Attachment_Notes__c` on the staging row (record Id + StatusCode), so
 * "0 links across a period in which real broker emails arrived" is answerable from a query.
 * The `lastRun*Failures` statics are IN-TRANSACTION ONLY, for tests and debugging; they are
 * NOT a monitoring surface and must never be treated as one.
 *
 * ═══ WHY THE HEAP GUARDS SIT WHERE THEY DO — TWO BUDGETS, NOT ONE ═══
 * SYNCHRONOUS SIDE (6 MB), classify + stageBytes. The Messaging.InboundEmail object the
 * platform hands the boundary ALREADY HOLDS every attachment Blob in heap before the first line
 * of our code runs, so `Attachment.Body = att.body` assigns a reference to a Blob already
 * resident and costs ~0 (SP-4.3 measured 152 bytes at both 3 MB and 5 MB). STAGING FILES IS NOT
 * THE HEAP RISK, and a per-file retention cap does NOT protect heap — claiming otherwise would
 * be a false sense of safety. The only real heap levers at that boundary are
 * `EncodingUtil.base64Encode` (gated by `EmailToLeadHandler.VISION_MAX_BYTES`, next to the
 * encode it gates) and the CSV `Blob.valueOf` path below.
 *
 * ASYNC SIDE (12 MB), persist. This is the NEW risk the 2026-08-06 spikes surfaced, and it is
 * real: SP-4.5 measured ONE 5 MB carrier converting to 10,487,036 bytes of heap — 87% of the
 * async ceiling — because the SOQL read allocates the full body and `VersionData = att.body`
 * allocates it AGAIN. **Peak ~ 2 x converted bytes.** `CONVERT_MAX_TOTAL_BYTES` bounds the
 * subset before any byte is read (in `AttachmentPersistQueueable`), and `CONVERT_HEAP_CEILING`
 * is re-checked here immediately before EACH `VersionData` assignment. Apex governor
 * LimitExceptions are UNCATCHABLE, so a blow-out cannot be rescued — only prevented.
 *
 * 🔴 THE CSV RETENTION PATH (decision G3) NOW ALLOCATES IN `stageBytes`, NOT IN `persist`.
 * A textAttachment arrives as a String, so `Blob.valueOf(...)` genuinely allocates and heap then
 * holds BOTH copies. That allocation MOVED to the synchronous side with the carrier redesign,
 * so **TEXT_MAX_BYTES (1,000,000) now guards the 6 MB SYNCHRONOUS budget** — see its own
 * comment. It remains deliberately separate from, and 4x smaller than, ATTACHMENT_MAX_BYTES,
 * which is NOT a heap bound and must never be cited as one.
 *
 * 🔴 AND TEXT_MAX_BYTES ALONE IS NOT SUFFICIENT — IT BOUNDS THE CANDIDATE, NOT THE ALLOCATION.
 * It is compared against a CHARACTER count while `Blob.valueOf` produces UTF-8 BYTES, up to 3x
 * that; and heap is already ~3.67 MB after a worst-case vision encode by the time `stageBytes`
 * runs. Both allocating guards therefore compare `currentHeapSize() + THE PROJECTED ALLOCATION`
 * against a ceiling (`HEAP_SYNC_CEILING` here, `CONVERT_HEAP_CEILING` in `persist`) rather than
 * reading heap alone — code-review finding C1, 2026-08-06, with the full arithmetic on
 * HEAP_SYNC_CEILING. A bare floor comparison was reachable in one ordinary email and would have
 * destroyed it exactly as the ContentPublication outage did.
 *
 * ═══ IDEMPOTENCY — THERE IS NONE HERE, AND THAT IS DELIBERATE (decision E1) ═══
 * A platform redelivery DOES create a duplicate staging row. It does NOT create duplicate files
 * on any business record, and the reason is STRUCTURAL AND LIVES IN ANOTHER CLASS:
 * `ExtractAddressQueueable.execute` short-circuits on
 * `InboundEmailActivityService.isAlreadyLogged(...)` and RETURNS WITHOUT CALLING finish() — and
 * `AttachmentPersistQueueable` is enqueued only from inside finish(). 🔴 ANYONE WHO MOVES THAT
 * ENQUEUE OUT OF finish(), OR MAKES THE SKIP PATH CALL finish(), SILENTLY RE-OPENS DUPLICATE
 * FILES ON LIVE LEADS. Better still, the duplicate's own carrier is RELEASED on the skip path
 * (releaseCarrier), so a redelivery costs zero publications AND leaves no bytes behind. No
 * content hash and no ContentVersion External Id was added: a dedupe check would cost the
 * per-file query the governor budget exists to prevent.
 *
 * ═══ THE CARRIER IS TEMPORARY — FOUR DEFINED EXITS ═══
 * A classic `Attachment` on a staging row is a CARRIER, not storage, and every row takes one of
 * exactly four exits: CONVERTED (deleted by AttachmentPersistQueueable, only on confirmed
 * success), RELEASED (releaseCarrier, on a gated email or a duplicate delivery), RETRIED
 * (AttachmentCarrierSweepBatch, daily) or EXPIRED (the same batch, at CARRIER_MAX_AGE_DAYS).
 * A carrier with no exit would make this module the org's file-storage strategy by accident.
 *
 * ═══ LAYER — Service. `without sharing`, AND IT MITIGATES NO PRESENT RISK ═══
 * `without sharing` is DEFENSIVE, NOT LOAD-BEARING. As of 2026-08-05 every target type
 * (`Lead`, `Opportunity`, and `Contact` — which `PropertyMatchingService.resolveLiveRecord`
 * can return on the reply and repeat branches) is already fully visible to the Email Service user via
 * `DPEG_Junior_Analyst_PSG`'s `ViewAllRecords`, so `with sharing` would work identically
 * today. This declaration exists so that a future tightening of the RBAC model, or a new
 * record type entering `ExtractAddressQueueable.orderedTaskTargets()`, does not silently
 * start dropping links. It has NOT been proven to bypass a genuine access gap in this org —
 * that experiment was confounded (every path probed was masked by `ViewAllRecords`, so the
 * `with sharing` and `without sharing` probes both succeeded for the same reason) and is
 * unrun. Do not cite this class as evidence that `without sharing` bypasses sharing here.
 *
 * ⚠ Do NOT reason "the Tasks work, so the links will". `InboundEmailActivityService` is
 * `with sharing` and does a plain insert because Task DML performs NO sharing check on the
 * referenced WhoId/WhatId. A ContentDocumentLink insert is a DIFFERENT MECHANISM with a real
 * access check on the linked entity. That reasoning is invalid; it merely happens not to
 * matter here.
 *
 * All SOQL is delegated to ContentVersionSelector and AttachmentSelector; this class holds
 * none of its own.
 *
 * @see EmailToLeadHandler.cls (marshals, classifies, gates the vision encode, calls stageBytes)
 * @see AttachmentPersistQueueable.cls (the ONLY caller of persist/linkTo on the live path)
 * @see AttachmentCarrierSweepBatch.cls (the retry/expiry path, same persist/linkTo)
 * @see ExtractAddressQueueable.cls (calls releaseCarrier on the gate/duplicate paths)
 * @see ContentVersionSelector.cls / AttachmentSelector.cls (the reads)
 * @see InboundEmailStagingService.appendDroppedNote (where refusals are recorded)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §2.1, §6.2, §11.7
 * @see agent-output/spike-attachment-persistence-v2.md (SP-1, SP-4, SP-5, SP-6)
 */
public without sharing class InboundEmailAttachmentService {

    /**
     * Per-file retention ceiling, for BINARY attachments. **4,000,000 since 2026-08-06 (was
     * 5,000,000).**
     *
     * WHY IT MOVED: it is now aligned to CONVERT_MAX_TOTAL_BYTES, i.e. to what the async
     * conversion can PROVABLY do in one transaction (SP-4.5). Because the two are equal, any
     * file this pipeline retains always fits one conversion transaction BY ITSELF, so the
     * carrier can never hold a file that is structurally unconvertible and nothing can become
     * permanently stuck at the heap gate.
     *
     * ⚠ IT IS NOT A HEAP BOUND, AND MUST NEVER BE DESCRIBED AS ONE. A binary attachment's
     * Blob is already resident in heap before our first line runs, so retaining it costs ~0.
     * The heap-allocating paths are text (see TEXT_MAX_BYTES) and the async conversion (see
     * CONVERT_HEAP_CEILING).
     */
    @TestVisible private static final Integer ATTACHMENT_MAX_BYTES = 4000000;

    /**
     * 🔴 HEAP BOUND FOR THE ONE ALLOCATING RETENTION PATH — text attachments (decision G3,
     * `.csv`). SEPARATE FROM, AND FOUR TIMES SMALLER THAN, ATTACHMENT_MAX_BYTES, deliberately.
     *
     * ⚠ **ITS VALUE IS UNCHANGED (1,000,000) BUT ITS VENUE MOVED ON 2026-08-06, so this
     * justification is rewritten rather than copied.** The `Blob.valueOf(att.textBody)`
     * allocation used to happen in `persist`; with the carrier redesign it happens in
     * `stageBytes`, at the SYNCHRONOUS boundary. So this constant now guards the **6 MB
     * synchronous budget**, not the 12 MB async one, and the margin it protects is far tighter.
     *
     * WHY IT MUST EXIST. A textAttachment arrives as a String; at the instant of
     * `Blob.valueOf(...)` heap holds the source String AND an equal-sized Blob, so this path
     * costs 2x the file whereas a binary attachment costs ~0 (its Blob is already resident).
     * Under the previous single 5,000,000 ceiling a 3.5 MB CSV rent roll was RETAINED —
     * `HEAP_HEADROOM_FLOOR` saw ~3.6 MB, below its 4,000,000 floor — and then added ~3.5 MB for
     * ~7.1 MB against the 6 MB synchronous limit. `System.LimitException` is UNCATCHABLE, so
     * `EmailToLeadHandler`'s catch never runs, `result.success` is never set, the staging insert
     * rolls back, and the email is destroyed with NO row anywhere recording that it existed.
     *
     * Same shape and same value as `EmailToLeadHandler.VISION_MAX_BYTES`, for the same reason:
     * both gate an operation that holds a source and a same-order copy simultaneously. Stacking
     * every synchronous worst case (1 MB image + its ~2.67 MB UTF-16 encoding + a 1 MB CSV + its
     * 1 MB copy) reaches ~5.67 MB — under 6 MB, but not by much, which is why `stageBytes`
     * RE-CHECKS `HEAP_HEADROOM_FLOOR` at the instant of allocation rather than trusting the
     * measurement classify() took earlier in the same transaction.
     */
    @TestVisible private static final Integer TEXT_MAX_BYTES = 1000000;

    /**
     * Per-email count cap. **3 since 2026-08-06 (was 10) — a user decision.**
     *
     * It caps ContentPublications at 3 per email and ContentDocumentLink rows at
     * 3 files x 10 routed records = 30. At 3/email, 100 attachment-bearing broker emails a day
     * costs 300 of the org's 2,500 daily publications.
     *
     * Overflow is RECORDED, never silent: the fourth and later retainable files are dropped and
     * NAMED via REASON_COUNT_CAP — the same philosophy as the ' [truncated: 10 of M]' suffix.
     */
    @TestVisible private static final Integer MAX_ATTACHMENTS = 3;

    /**
     * 🔴 THE ASYNC CONVERSION HEAP BUDGET (design §6.2), and the single source of truth for it —
     * `AttachmentPersistQueueable` aliases both constants rather than copying them, and `persist`
     * below applies CONVERT_HEAP_CEILING per row. They are `public` (not `@TestVisible private`)
     * for exactly that reason: a `@TestVisible private` member is unreachable from another class
     * in production context, and both of these have two consumers.
     *
     * THE MEASUREMENT (SP-4.5), converting ONE 5 MB carrier:
     *     heapBeforeRead   =      1,054
     *     heapAfterRead    =  5,244,053   +5,243,000  the SOQL read allocates the full body
     *     heapAfterBuild   = 10,487,036   +5,242,983  VersionData = att.body allocates it AGAIN
     * **Peak ~ 2 x total converted bytes**, against a 12,000,000-byte async ceiling.
     *
     * CONVERT_MAX_TOTAL_BYTES = 4,000,000 -> 8.0 MB peak = 67% of 12 MB, leaving 4 MB for the
     * selector reads, the link list, the notes and platform overhead. It equals
     * ATTACHMENT_MAX_BYTES so any single retained file always fits a transaction alone.
     * CONVERT_HEAP_CEILING = 9,000,000 = 75% of 12 MB, the DYNAMIC guard applied immediately
     * before each VersionData assignment. ⚠ It compares `currentHeapSize() + THE PROJECTED
     * ALLOCATION` against this value, not heap alone — a bare `heap > 9,000,000` would have
     * permitted 9,000,000 + a 3 MB text conversion = 12,000,000, exactly AT the async ceiling
     * with zero margin (code-review finding C1, 2026-08-06). See HEAP_SYNC_CEILING for the same
     * correction on the synchronous side, where it was the difference between a deferred file
     * and a destroyed email.
     *
     * ⚠ A green Apex suite proves the ACCOUNTING, not the arithmetic. Only UAT U6 — a real
     * ~3.9 MB PDF with `AttachmentPersistQueueable.lastRunHeapPeak` read back from the debug
     * log — establishes these numbers against real bytes.
     */
    public static final Integer CONVERT_MAX_TOTAL_BYTES = 4000000;
    public static final Integer CONVERT_HEAP_CEILING = 9000000;

    /**
     * The only DYNAMIC guard: once `Limits.getHeapSize()` exceeds this, retention STOPS and
     * every remaining candidate is recorded as dropped for heap headroom. It reflects the
     * transaction's actual state rather than a guess about file sizes.
     */
    @TestVisible private static final Integer HEAP_HEADROOM_FLOOR = 4000000;

    /**
     * 🔴 THE PROJECTED-ALLOCATION HEAP GUARD (added 2026-08-06 after code-review finding C1).
     *
     * ═══ WHY A BARE FLOOR COMPARISON WAS NOT ENOUGH — THE ARITHMETIC ═══
     * `stageBytes` used to guard its `Blob.valueOf(att.textBody)` with
     * `if (currentHeapSize() > HEAP_HEADROOM_FLOOR) skip;`. **That never subtracts the
     * allocation it is about to permit**, so the worst case was:
     *
     *     heap permitted at the check (strict `>`, so 4,000,000 itself PASSES)  4,000,000
     *   + Blob.valueOf on a TEXT_MAX_BYTES input, at UTF-8's 3 bytes/char       3,000,000
     *   = peak                                                             ~7,000,000  ❌ > 6 MB
     *
     * Two things compound it and neither is hypothetical:
     *   1. **TEXT_MAX_BYTES is compared against a CHARACTER COUNT, not bytes.**
     *      `EmailToLeadHandler.marshalAttachments` sets `byteSize = att.body.length()`, and its
     *      own comment concedes characters "UNDER-count UTF-8 bytes slightly" — true for ASCII,
     *      FALSE otherwise. UTF-8 reaches 3 bytes per UTF-16 code unit, so a 1,000,000-char
     *      accented or non-Latin `.csv` is a ~3 MB Blob, not a ~1 MB one.
     *   2. **Heap is already loaded when this runs.** `stageBytes` is step 5, AFTER the vision
     *      encode, whose own comment computes its worst case at 3.67 MB. The realistic trigger
     *      is ONE email carrying a ~1 MB image AND a large non-ASCII CSV rent roll: heap sits
     *      just under the floor, the guard passes, the Blob lands, `System.LimitException`
     *      fires — and it is UNCATCHABLE, so `handleInboundEmail`'s catch never runs,
     *      `InboundEmailResult` is never returned, and the staging insert rolls back. No
     *      staging row, no Lead, no claim, no Task, no bounce, no error record. **The same
     *      failure shape as the 2026-08-06 outage, through a different door.**
     *
     * ═══ THE FIX: PROJECT, THEN COMPARE — modelled on VISION_MAX_BYTES ═══
     * Both allocating guards now compute `currentHeapSize() + projectedAllocation` and compare
     * that against a ceiling, exactly as `EmailToLeadHandler.VISION_MAX_BYTES`'s comment already
     * does for the base64 encode (2.33S at one byte/char, 3.67S at UTF-16's two).
     *
     *   HEAP_SYNC_CEILING       5,000,000 = 83% of the 6,000,000 SYNCHRONOUS limit. The 1 MB
     *                           margin covers the Attachment rows, the DML and platform
     *                           overhead that follow the allocation.
     *   UTF8_MAX_BYTES_PER_CHAR 3         = the true UTF-8 worst case per UTF-16 code unit.
     *                           Used because the ONLY size figure available here is a character
     *                           count; measuring real bytes would require materialising the Blob
     *                           first, which is the one thing this guard exists to avoid.
     *
     * WORST CASE UNDER THE FIX: the allocation is permitted only if the PROJECTED total stays
     * at or below 5,000,000, so peak <= 5,000,000 against a 6,000,000 limit — with a 1 MB
     * margin — regardless of how loaded heap already is when the CSV arrives.
     *
     * ⚠ TEXT_MAX_BYTES is deliberately NOT lowered. It bounds the CANDIDATE in classify(); this
     * guard bounds the ALLOCATION at the instant it happens, which is the term that was missing.
     * Lowering the constant would have dropped legitimate rent rolls even when heap was free.
     */
    @TestVisible private static final Integer HEAP_SYNC_CEILING = 5000000;
    @TestVisible private static final Integer UTF8_MAX_BYTES_PER_CHAR = 3;

    /**
     * Signature-logo floor (decision G2), applied to IMAGES ONLY. The user's two rules
     * ("keep images" / "drop signature logos") need a discriminator; a property photo or an
     * OM render is far above 20 KB and a logo far below. The `Content-Disposition: inline` /
     * `Content-ID` alternative was NOT adopted because it depends on
     * `Messaging.InboundEmail.BinaryAttachment.headers` being populated at API 67, which was
     * never verified — designing around an unverified platform property is how the
     * `Task.Type` outage happened. Every drop is recorded.
     */
    @TestVisible private static final Integer IMAGE_MIN_BYTES = 20000;

    /** Dropped_Attachment_Notes__c is a LongTextArea(32768). */
    private static final Integer LEN_DROPPED_NOTES = 32768;

    /** ContentVersion.Title / PathOnClient lengths. */
    private static final Integer LEN_TITLE = 255;
    private static final Integer LEN_PATH = 500;

    /** Attachment.Name / Attachment.ContentType lengths. */
    private static final Integer LEN_ATTACHMENT_NAME = 255;
    private static final Integer LEN_CONTENT_TYPE = 120;

    /**
     * ShareType for ROUTED records (Lead / Opportunity / Contact — the reply and repeat
     * branches can resolve to a Contact) — Inferred: file access follows the
     * record's own sharing, so whoever can work the deal can read the OM. It is also what the
     * PLATFORM itself produces: on Database.convertLead the Account / Contact / Opportunity
     * carry-over links are all 'I' (spike S6), so our Lead link and the platform's carry-over
     * agree rather than diverge.
     */
    private static final String SHARE_TYPE_INFERRED = 'I';

    /**
     * ShareType for the STAGING row — Viewer. A deliberate divergence from the routed-record
     * choice, not an inconsistency: the staging row is EVIDENCE, and `Broker_Protection_Access`
     * grants allowEdit on it. Under 'I' an edit grant on the record confers Collaborator on the
     * file — i.e. the right to replace or delete a broker's own submission from an audit row.
     * 'V' grants read and nothing more.
     */
    private static final String SHARE_TYPE_VIEWER = 'V';

    /**
     * Visibility for every link this class creates.
     *
     * ⚠ ShareType 'C' (Collaborator) is REJECTED by the platform on every object type
     * measured — `INSUFFICIENT_ACCESS_OR_READONLY, Invalid sharing type C` (spike S3).
     * Never introduce it; only 'I' and 'V' above are legal here.
     */
    private static final String VISIBILITY_ALL_USERS = 'AllUsers';

    /**
     * Filename extensions kept (decisions G1 / G3). Matched as a UNION with the MIME
     * subtype — never alone — because forwarded attachments routinely arrive as
     * `application/octet-stream`, and a MIME-only filter would drop the offering memorandum:
     * the exact silent loss this feature exists to prevent.
     */
    private static final Set<String> ALLOWED_EXTENSIONS = new Set<String>{
        'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv',
        'png', 'jpg', 'jpeg', 'gif', 'webp', 'tif', 'tiff'
    };

    /**
     * MIME subtypes equivalent to ALLOWED_EXTENSIONS. `mimeTypeSubType` arrives
     * INCONSISTENTLY from the platform — bare ('png') on some messages, fully qualified
     * ('image/png') on others — so it is normalized to the part after the last '/' before
     * being looked up here.
     */
    private static final Set<String> ALLOWED_MIME_SUBTYPES = new Set<String>{
        'pdf', 'x-pdf', 'acrobat', 'vnd.pdf',
        'msword', 'vnd.openxmlformats-officedocument.wordprocessingml.document',
        'vnd.ms-excel', 'vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'vnd.ms-powerpoint', 'vnd.openxmlformats-officedocument.presentationml.presentation',
        'csv', 'comma-separated-values', 'x-comma-separated-values',
        'png', 'jpg', 'jpeg', 'gif', 'webp', 'tif', 'tiff'
    };

    /** MIME subtypes / extensions that identify a CSV, the only textAttachment kept (G3). */
    private static final Set<String> CSV_TOKENS = new Set<String>{
        'csv', 'comma-separated-values', 'x-comma-separated-values'
    };

    /** Image subtypes, used for the IMAGE_MIN_BYTES floor and the vision-candidate choice. */
    private static final Set<String> IMAGE_TOKENS = new Set<String>{
        'png', 'jpg', 'jpeg', 'gif', 'webp', 'tif', 'tiff', 'bmp', 'heic', 'heif', 'svg+xml'
    };

    /** Drop reasons — constants so a test pins the exact text rather than a paraphrase. */
    @TestVisible private static final String REASON_NO_CONTENT = 'no content';
    @TestVisible private static final String REASON_TEXT_NOT_CSV =
        'text attachment is not a .csv (G3: only CSV text attachments are kept)';
    @TestVisible private static final String REASON_TYPE_NOT_ALLOWED =
        'type not in the allow-list';
    @TestVisible private static final String REASON_TOO_LARGE =
        'exceeds ATTACHMENT_MAX_BYTES (4000000)';
    @TestVisible private static final String REASON_TEXT_TOO_LARGE =
        'text attachment exceeds TEXT_MAX_BYTES (1000000) - retaining it would allocate a '
        + 'second copy in heap and could kill the whole email';
    @TestVisible private static final String REASON_IMAGE_FLOOR =
        'image below IMAGE_MIN_BYTES (20000) - likely a signature logo';
    @TestVisible private static final String REASON_COUNT_CAP =
        'MAX_ATTACHMENTS (3) already retained';
    @TestVisible private static final String REASON_HEAP_HEADROOM =
        'heap headroom exhausted (HEAP_HEADROOM_FLOOR 4000000)';

    /**
     * 🔴 The PROJECTED-allocation refusal in stageBytes (C1). Deliberately distinct from
     * REASON_HEAP_HEADROOM: that one says "heap was already high", this one says "heap plus the
     * blob this file WOULD allocate does not fit", which is a different diagnosis and points at
     * a different remedy (a smaller CSV, or a re-send without the image).
     */
    @TestVisible private static final String REASON_SYNC_HEAP_PROJECTION =
        'not saved: converting this text attachment would allocate up to 3 bytes/char and cross '
        + 'the synchronous heap ceiling (HEAP_SYNC_CEILING 5000000 of the 6000000 limit); the '
        + 'file exists only in the original email';
    /**
     * 🔴 The conversion heap ceiling, applied PER ROW inside persist(). Distinct from
     * REASON_HEAP_HEADROOM because the two guard different budgets (12 MB async vs 6 MB
     * synchronous) and conflating them in the audit trail would misdirect a diagnosis.
     */
    @TestVisible private static final String REASON_CONVERT_HEAP_CEILING =
        'not yet saved: converting this file would cross the conversion heap ceiling '
        + '(CONVERT_HEAP_CEILING 9000000 of the 12000000 async limit); the file is still '
        + 'attached to this staging row and will be retried';

    /**
     * 🔴 A TERMINAL mode — one of only three (§7). The carrier insert itself was refused, so the
     * bytes were never captured and no retry can recover them. The copy says so plainly and
     * names where the file still exists.
     */
    @TestVisible private static final String REASON_CARRIER_REFUSED = 'carrier not written | ';

    /**
     * 🔴 A TERMINAL mode. The email was gated (D2 / U2) or was a duplicate delivery, so there is
     * no record to file a file on and there never will be.
     */
    @TestVisible private static final String NOTE_RELEASED =
        'not saved: the email was gated or was a duplicate delivery — there is no record to '
        + 'file it on. The file exists only in the original email.';

    /** Raised only by the forcePersistFailure test seam. */
    public class AttachmentException extends Exception {}

    /**
     * TEST-ONLY seam that makes persist(...) fail deterministically. Also the mechanism UAT U8 —
     * THE ACCEPTANCE TEST for the whole redesign — uses to kill the file job on purpose and then
     * verify from the org that the Lead, the claim, the Task, the staging row AND the carrier
     * bytes all survived.
     *
     * 🔴 **THIS THROWS A CATCHABLE EXCEPTION AND THEREFORE MODELS AN ORDINARY FAILURE, NOT THE
     * `ContentPublication` FAILURE — WHICH CANNOT BE MODELLED IN APEX AT ALL.** That missing
     * sentence is what made v1's acceptance test look sufficient: it armed this seam, asserted
     * that persist's catch held and `result.success` stayed true, and PASSED THROUGHOUT THE
     * OUTAGE. When the risk is "this transaction dies", no assertion written inside that
     * transaction can observe it. The real protection is structural (design §3.4) and the real
     * proof is UAT (§8.3), not this seam.
     *
     * Same precedent and same prohibition as ExtractAddressQueueable.forceClaimRace /
     * forceRouteFailure: NEVER set this outside a test class or a deliberate UAT rehearsal.
     */
    @TestVisible private static Boolean forcePersistFailure = false;

    /**
     * TEST-ONLY seam for the HEAP_HEADROOM_FLOOR branch. classify() reads
     * `Limits.getHeapSize()`, which no test can drive to a chosen value without allocating
     * megabytes of throwaway data (itself a heap risk inside the test). When non-null this
     * value is used instead. NEVER set outside a test class.
     */
    @TestVisible private static Integer heapSizeOverride = null;

    /**
     * Refusals recorded by the most recent linkTo(...) IN THIS TRANSACTION.
     * ⚠ IN-TRANSACTION ONLY — for tests and debugging, NOT monitoring (the R1 lesson: a
     * static that does not survive the job cannot answer "did anything fail last week?").
     * The durable record is Dropped_Attachment_Notes__c on the staging row.
     */
    @TestVisible private static List<String> lastRunLinkFailures = new List<String>();

    /**
     * Refusals recorded by the most recent persist(...) IN THIS TRANSACTION — the
     * ContentVersion insert, the staging ContentDocumentLink insert, and any exception the
     * method swallowed. Same in-transaction-only caveat as lastRunLinkFailures.
     */
    @TestVisible private static List<String> lastRunPersistFailures = new List<String>();

    /**
     * The carrier `Attachment` Ids whose ContentVersion insert SUCCEEDED in the most recent
     * persist(...) IN THIS TRANSACTION.
     *
     * 🔴 THIS IS WHAT MAKES "DELETE ONLY THE ROWS THAT CONVERTED" POSSIBLE, and it is the reason
     * a partial refusal is recoverable rather than a silent loss: without a per-row mapping the
     * caller could only delete all carriers or none, and deleting all of them after a partial
     * failure would destroy the bytes of exactly the files that still needed retrying.
     *
     * Same in-transaction-only caveat as lastRunLinkFailures — NOT a monitoring surface.
     */
    @TestVisible private static List<Id> lastRunPersistedCarrierIds = new List<Id>();

    /**
     * One candidate attachment, marshalled from Messaging.InboundEmail by the handler or
     * rebuilt from a carrier row by AttachmentPersistQueueable.
     * `body` holds a REFERENCE to a Blob already resident in heap — never a copy.
     */
    public class AttachmentRequest {
        /** Original filename as the sender's client supplied it; may be blank. */
        public String fileName;
        /** `mimeTypeSubType` verbatim — bare ('png') or qualified ('image/png'). */
        public String mimeSubType;
        /** Binary content (binaryAttachments). Null for a text attachment. */
        public Blob body;
        /** Text content (textAttachments, .csv only per G3). Null for a binary attachment. */
        public String textBody;
        /** Size used by every cap. Bytes for binary; CHARACTERS for text (see marshalling). */
        public Integer byteSize;
        /** Normalized by classify(); the handler may pre-set it but is not trusted to. */
        public Boolean isImage;
        /**
         * The classic `Attachment` carrier this request was rebuilt from, when it came from
         * `AttachmentPersistQueueable` rather than straight off the inbound email. Null at the
         * synchronous boundary (no carrier exists yet). persist() reports it back through
         * `lastPersistedCarrierIds()` so ONLY the rows that converted are deleted.
         */
        public Id carrierId;
    }

    /** What classify() decided, ready to be stamped straight onto the staging row. */
    public class ClassificationResult {
        /** The files to persist, in the platform's original order. Never null. */
        public List<AttachmentRequest> retained;
        /** One `filename | mime | bytes | reason` line per drop, clipped. Null when none. */
        public String droppedNotes;
        /** Attachment_Count__c — files RETAINED, not files received. */
        public Integer retainedCount;
        /** Attachment_Bytes__c — total retained bytes. */
        public Integer retainedBytes;
    }

    /**
     * Decide which attachments are kept. PURE: no SOQL, no DML, no callouts and NO BLOB
     * COPIES — it only reads sizes and names off references the platform already holds.
     *
     * The order of the checks is the order of the recorded reasons, and it is deliberate:
     * content-based rejections (empty, non-CSV text, disallowed type, oversize, sub-floor
     * image) are evaluated BEFORE the slot-based caps, so a file that was never eligible does
     * not consume one of the three retention slots and mask a file that was.
     *
     * @param candidates Every binary and text attachment on the email, in platform order;
     *                   null or empty yields an empty, zero-valued result.
     * @return retained + dropped notes + the two staging counters. Never null.
     * @example
     * InboundEmailAttachmentService.ClassificationResult classified =
     *     InboundEmailAttachmentService.classify(candidates);
     */
    public static ClassificationResult classify(List<AttachmentRequest> candidates) {
        ClassificationResult outcome = new ClassificationResult();
        outcome.retained = new List<AttachmentRequest>();
        outcome.retainedCount = 0;
        outcome.retainedBytes = 0;

        if (candidates == null || candidates.isEmpty()) {
            return outcome;
        }

        List<String> dropped = new List<String>();
        // Sticky: heap only grows within a transaction, so once the floor is crossed every
        // remaining candidate is dropped for the same reason. Re-reading would be equivalent
        // but makes the recorded reasons non-deterministic under a test seam.
        Boolean heapExhausted = false;

        for (AttachmentRequest att : candidates) {
            if (att == null) {
                continue;
            }
            att.isImage = isImageAttachment(att.mimeSubType, att.fileName);
            Integer bytes = (att.byteSize == null) ? 0 : att.byteSize;
            Boolean isText = (att.body == null && String.isNotBlank(att.textBody));

            if (att.body == null && String.isBlank(att.textBody)) {
                dropped.add(describeDrop(att, REASON_NO_CONTENT));
                continue;
            }
            if (isText && !isCsv(att.mimeSubType, att.fileName)) {
                // G3: a CSV rent roll is real deal data; vCards, calendar invites and
                // plain-text signatures are not. Dropped AND recorded, never silent.
                dropped.add(describeDrop(att, REASON_TEXT_NOT_CSV));
                continue;
            }
            if (!isAllowedType(att.mimeSubType, att.fileName)) {
                dropped.add(describeDrop(att, REASON_TYPE_NOT_ALLOWED));
                continue;
            }
            if (bytes > ATTACHMENT_MAX_BYTES) {
                dropped.add(describeDrop(att, REASON_TOO_LARGE));
                continue;
            }
            if (isText && bytes > TEXT_MAX_BYTES) {
                // 🔴 THE HEAP GUARD FOR THE ONE ALLOCATING PATH. persist() will call
                // Blob.valueOf on this String, holding both copies at once; an uncatchable
                // LimitException there destroys the entire email. Dropped AND recorded.
                dropped.add(describeDrop(att, REASON_TEXT_TOO_LARGE));
                continue;
            }
            if (att.isImage == true && bytes < IMAGE_MIN_BYTES) {
                dropped.add(describeDrop(att, REASON_IMAGE_FLOOR));
                continue;
            }
            if (outcome.retained.size() >= MAX_ATTACHMENTS) {
                dropped.add(describeDrop(att, REASON_COUNT_CAP));
                continue;
            }
            if (heapExhausted || currentHeapSize() > HEAP_HEADROOM_FLOOR) {
                heapExhausted = true;
                dropped.add(describeDrop(att, REASON_HEAP_HEADROOM));
                continue;
            }

            outcome.retained.add(att);
            outcome.retainedBytes += bytes;
        }

        outcome.retainedCount = outcome.retained.size();
        outcome.droppedNotes = dropped.isEmpty()
            ? null
            : InboundEmailFieldUtil.clip(String.join(dropped, '\n'), LEN_DROPPED_NOTES);
        return outcome;
    }

    /**
     * 🔴 THE BYTE CARRIER. Park the retained attachments on the staging row as classic
     * `Attachment` rows, synchronously, so the bytes survive into a later transaction where a
     * `ContentVersion` insert is safe to attempt.
     *
     * ═══ WHY THIS IS ADMISSIBLE AT THE BOUNDARY WHEN persist() IS NOT ═══
     * The bytes exist ONLY inside `Messaging.InboundEmail`, in this one synchronous method call,
     * and are unrecoverable once it returns. Something has to carry them, and every alternative
     * was measured and rejected (design §3.2). This one is admissible because:
     *   • **ZERO ContentPublications.** SP-4.1, definitive — `/limits` read 2500 before and 2500
     *     after. So it cannot hit the quota that caused the 2026-08-06 outage, at all.
     *   • **~152 bytes of heap, at ANY file size.** SP-4.3 measured it identically at 3 MB and
     *     5 MB, because `Body = <blob>` on a fresh row is a reference assignment, not a copy.
     *   • **Ordinary record ownership.** The Email Service context user OWNS the staging row it
     *     inserted microseconds earlier (SP-4.2), so no special grant is involved.
     *   • **It survives everything downstream.** If the file job, the sweeper and the quota all
     *     fail, the bytes are still on the row — which is what turns a quota failure from a loss
     *     into a deferral.
     *
     * 🔴 NOTHING ELSE MAY JOIN IT AT THE BOUNDARY — in particular never a `ContentVersion`
     * insert (M1-M5) and never a byte-carrying `System.enqueueJob` (SP-1 measured an UNCATCHABLE
     * `LimitException: Batchable instance is too big` thrown at the enqueue itself above
     * ~4.2-4.5 MB).
     *
     * COST — exactly **1 DML**, one bulk `Database.insert(attachments, false)`, CONSTANT
     * regardless of file count, and **ZERO** when nothing was retained. Together with the
     * staging insert that pins `EmailToLeadHandler` at 0 SOQL / 2 DML (1 with no attachments).
     * ⚠ On the FAILURE PATH ONLY it additionally records the refusal and stamps
     * `Attachment_Status__c = 'Not Saved'` (+1 SOQL / +2 DML) — outside the pinned budget by
     * design, and a TERMINAL state: a carrier that was never written cannot be retried.
     *
     * 🔴 IT MUST NOT THROW. It is the one file-related call left inside the transaction that
     * owns the email.
     *
     * @param stagingId The Inbound_Email_Staging__c row to park the bytes on; null is a no-op.
     * @param retained  classify(...).retained; null or empty returns an empty list.
     * @return The carrier `Attachment` Ids actually stored; empty when nothing was stored —
     *         never null, never an exception.
     * @example
     * InboundEmailAttachmentService.stageBytes(stagingId, classified.retained);
     */
    public static List<Id> stageBytes(Id stagingId, List<AttachmentRequest> retained) {
        List<Id> carrierIds = new List<Id>();
        List<String> failures = new List<String>();
        Integer candidates = 0;

        try {
            if (stagingId == null || retained == null || retained.isEmpty()) {
                return carrierIds;
            }

            List<Attachment> carriers = new List<Attachment>();
            List<AttachmentRequest> ordered = new List<AttachmentRequest>();
            for (AttachmentRequest att : retained) {
                if (att == null) {
                    continue;
                }
                candidates++;
                Blob data = att.body;
                if (data == null && String.isNotBlank(att.textBody)) {
                    // 🔴 G3 — THE ONE PATH HERE THAT ALLOCATES NEW HEAP, and therefore the only
                    // statement left at the synchronous boundary that can still kill an email.
                    // A heap LimitException is UNCATCHABLE, so prevention is the only mechanism.
                    //
                    // 🔴 THE GUARD PROJECTS THE ALLOCATION; IT DOES NOT MERELY READ HEAP (C1,
                    // 2026-08-06). The previous form — `currentHeapSize() > HEAP_HEADROOM_FLOOR`
                    // — never subtracted what it was about to permit:
                    //
                    //     4,000,000 (a strict `>` lets the floor itself through)
                    //   + 3,000,000 (Blob.valueOf on a TEXT_MAX_BYTES input at UTF-8's 3 B/char)
                    //   = ~7,000,000 peak against a 6,000,000 SYNCHRONOUS limit.
                    //
                    // Reachable in one email: a ~1 MB vision image already puts heap at ~3.67 MB
                    // (see EmailToLeadHandler.VISION_MAX_BYTES), and a large NON-ASCII CSV rent
                    // roll is ~3x its character count in UTF-8 bytes — while `byteSize` here is
                    // a CHARACTER count, which under-counts exactly that case. See
                    // HEAP_SYNC_CEILING for the full arithmetic.
                    //
                    // Now: permit only if the PROJECTED total fits, so peak <= 5,000,000 with a
                    // 1 MB margin, however loaded heap already is.
                    Integer chars = (att.byteSize == null) ? att.textBody.length() : att.byteSize;
                    Integer projected = currentHeapSize() + (chars * UTF8_MAX_BYTES_PER_CHAR);
                    if (projected > HEAP_SYNC_CEILING) {
                        failures.add(describeDrop(att, REASON_SYNC_HEAP_PROJECTION));
                        continue;
                    }
                    data = Blob.valueOf(att.textBody);
                }
                if (data == null) {
                    continue;
                }
                String name = safeFileName(att);
                carriers.add(new Attachment(
                    ParentId = stagingId,
                    Name = InboundEmailFieldUtil.clip(name, LEN_ATTACHMENT_NAME),
                    ContentType = InboundEmailFieldUtil.clip(att.mimeSubType, LEN_CONTENT_TYPE),
                    Body = data
                ));
                ordered.add(att);
            }

            if (!carriers.isEmpty()) {
                // ONE statement. allOrNone = false so a single malformed carrier cannot cost
                // the others — and cannot cost the staging row, the Lead or the claim.
                List<Database.SaveResult> results = Database.insert(carriers, false);
                for (Integer i = 0; i < results.size(); i++) {
                    if (results[i].isSuccess()) {
                        carrierIds.add(results[i].getId());
                    } else {
                        failures.add(describeDrop(ordered[i],
                            REASON_CARRIER_REFUSED + firstError(results[i])));
                    }
                }
            }
        } catch (Exception e) {
            failures.add('carrier staging failed | ' + e.getTypeName() + ' | ' + e.getMessage());
            System.debug(LoggingLevel.ERROR,
                'InboundEmailAttachmentService.stageBytes failed for staging ' + stagingId
                + ': ' + e.getTypeName() + ' | ' + e.getMessage());
        }

        // FAILURE PATH ONLY. When NOTHING was carried the row must say so terminally, or a
        // count with no files and no explanation becomes exactly the silent divergence this
        // module exists to prevent.
        //
        // ⚠ WRAPPED IN ITS OWN try/catch (W7, 2026-08-06) EVEN THOUGH BOTH CALLEES ARE
        // INTERNALLY FAIL-SOFT TODAY. This method's contract is "must not throw", and it sat
        // OUTSIDE the try above — so the contract depended on ANOTHER class staying fail-soft
        // forever. That is a dependency, not a guarantee, and this is the one method still
        // standing in the transaction that owns the email.
        try {
            if (!failures.isEmpty()) {
                if (carrierIds.isEmpty() && candidates > 0) {
                    InboundEmailStagingService.markAttachmentStatus(
                        stagingId,
                        InboundEmailStagingService.ATTACHMENT_STATUS_NOT_SAVED,
                        String.join(failures, '\n'));
                } else {
                    recordFailures(stagingId, failures);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailAttachmentService.stageBytes: could not record '
                + failures.size() + ' refusal(s) on staging ' + stagingId + ': '
                + e.getTypeName() + ' | ' + e.getMessage());
        }
        return carrierIds;
    }

    /**
     * Delete this staging row's carrier bytes because there is no record to file a file on and
     * there never will be — the RELEASED exit of design §6.4, one of only three TERMINAL modes.
     *
     * Called on exactly two paths, both from `ExtractAddressQueueable`: a GATED email (D2's
     * relevance gate or U2's call-for-offers gate produced no routed record) and a DUPLICATE
     * DELIVERY (the Message-ID was already logged, so the original email's files already exist).
     * Both are the highest-volume junk in the pipeline, and releasing here is what makes them
     * cost **zero publications and zero residual bytes**.
     *
     * 🔴 NEVER call it on a path that might still succeed. A released carrier is unrecoverable:
     * the file exists only in the original email after this returns.
     *
     * COST — 1 SOQL (metadata only, no bytes) + 2 DML (the bulk delete + the terminal status
     * stamp), on the gate/duplicate paths ONLY. It cannot move `ExtractAddressQueueable`'s
     * pinned winner-path budgets, which never reach it.
     *
     * Fail-soft: releasing bytes nobody can use must never cost the email its routing.
     *
     * @param stagingId The staging row whose carriers to release; null is a no-op.
     * @param reason    A short human reason recorded alongside the standard note; may be blank.
     * @return How many carrier rows were removed.
     * @example
     * InboundEmailAttachmentService.releaseCarrier(stagingId, 'duplicate delivery');
     */
    public static Integer releaseCarrier(Id stagingId, String reason) {
        Integer released = 0;
        if (stagingId == null) {
            return released;
        }
        try {
            List<Attachment> carriers =
                AttachmentSelector.selectMetadataByParentIds(new Set<Id>{ stagingId });
            if (carriers.isEmpty()) {
                return released;
            }
            List<String> failures = new List<String>();
            List<Database.DeleteResult> results = Database.delete(carriers, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    released++;
                } else {
                    failures.add('carrier not released | ' + carriers[i].Id + ' | '
                        + firstDeleteError(results[i]));
                }
            }
            String note = NOTE_RELEASED
                + (String.isBlank(reason) ? '' : ' (' + reason + ')')
                + (failures.isEmpty() ? '' : '\n' + String.join(failures, '\n'));
            InboundEmailStagingService.markAttachmentStatus(
                stagingId, InboundEmailStagingService.ATTACHMENT_STATUS_NOT_SAVED, note);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailAttachmentService.releaseCarrier failed for staging ' + stagingId
                + ': ' + e.getTypeName() + ' | ' + e.getMessage());
        }
        return released;
    }

    /**
     * Save the retained attachments as Salesforce Files and link them to the staging row.
     *
     * 🔴 **WHO MAY CALL THIS HAS CHANGED, AND IT IS THE WHOLE POINT OF THE 2026-08-06 REDESIGN.**
     * It is called ONLY from `AttachmentPersistQueueable` and `AttachmentCarrierSweepBatch` —
     * transactions that own nothing irreplaceable. It was called from `EmailToLeadHandler`
     * between 2026-08-05 and 2026-08-06 and that DESTROYED EVERY INBOUND BROKER EMAIL CARRYING
     * AN ATTACHMENT (see the FAILURE BOUNDARY section in the class header). Restoring a
     * synchronous call site reproduces the outage exactly.
     *
     * COST — 1 SOQL + 2 DML, CONSTANT regardless of file count:
     *   1. `Database.insert(versions, false)`  — one statement, F rows
     *   2. `ContentVersionSelector.selectByIds` — one query (ContentDocumentId is not
     *      returned on the inserted sObject; it only exists in the database)
     *   3. `Database.insert(links, false)`      — one statement, F rows, ShareType 'V'
     * ⚠ On the FAILURE PATH ONLY it additionally calls
     * `InboundEmailStagingService.appendDroppedNote` (+1 SOQL, +1 DML) to make refusals
     * durable — that is outside the pinned success-path budget by design.
     *
     * ⚠ The platform ALSO creates one owner-personal-library ContentDocumentLink per
     * ContentVersion insert (spike S5), independently of anything this code does. It is
     * platform-created, ours to count but not to control, and MUST NOT be "cleaned up" — nor
     * asserted against as if it were one of our DML statements.
     *
     * IT STILL DOES NOT THROW ON ANY ORDINARY FAILURE — the try/catch and `allOrNone = false`
     * are unchanged and still correct. ⚠ They are simply NOT protection against M1
     * (`ContentPublication Limit exceeded`), which is why the caller matters more than the code.
     *
     * @param stagingId The Inbound_Email_Staging__c row the carriers hang off; null skips the
     *                  staging link.
     * @param retained  The files to convert; null or empty returns an empty list.
     * @return The ContentDocumentIds successfully created, for the caller to link. An empty
     *         list when nothing saved — never null, never an exception. Which CARRIERS converted
     *         is reported separately by `lastPersistedCarrierIds()`.
     * @example
     * List<Id> documentIds = InboundEmailAttachmentService.persist(stagingId, retained);
     */
    public static List<Id> persist(Id stagingId, List<AttachmentRequest> retained) {
        lastRunPersistFailures = new List<String>();
        lastRunPersistedCarrierIds = new List<Id>();
        List<Id> documentIds = new List<Id>();

        try {
            if (forcePersistFailure) {
                throw new AttachmentException('Forced persist failure (test seam).');
            }
            if (retained == null || retained.isEmpty()) {
                return documentIds;
            }

            List<ContentVersion> versions = new List<ContentVersion>();
            List<AttachmentRequest> ordered = new List<AttachmentRequest>();
            for (AttachmentRequest att : retained) {
                if (att == null) {
                    continue;
                }
                // 🔴 THE PER-ROW HEAP RE-CHECK, NOW APPLIED TO **EVERY** ROW (2026-08-06), not
                // only the CSV branch, and compared against CONVERT_HEAP_CEILING rather than
                // HEAP_HEADROOM_FLOOR. Two things changed and both matter:
                //
                //   • THE BUDGET. persist() now runs ASYNCHRONOUSLY (12 MB), not at the 6 MB
                //     synchronous boundary, so the right comparand is the conversion ceiling.
                //   • THE RISK MOVED. SP-4.5 measured `VersionData = att.body` on a body READ
                //     FROM SOQL allocating the bytes A SECOND TIME (peak ~ 2 x BodyLength) —
                //     so a BINARY row is no longer heap-free here the way it was when the Blob
                //     arrived already-resident from Messaging.InboundEmail. The old CSV-only
                //     check would have missed exactly that.
                //
                // AttachmentPersistQueueable's pre-check on BodyLength already chose a subset
                // that provably fits; this is the dynamic backstop for everything the
                // arithmetic could not know about (the link list, the notes, a co-resident
                // job). An Apex heap LimitException is UNCATCHABLE, so a row skipped here is a
                // DEFERRAL — its carrier is left in place and the sweeper retries it.
                //
                // 🔴 IT PROJECTS THE ALLOCATION RATHER THAN JUST READING HEAP (C1, 2026-08-06),
                // the same correction stageBytes needed. The bare form was:
                //
                //     9,000,000 (CONVERT_HEAP_CEILING, and a strict `>` lets it through)
                //   + 3,000,000 (a TEXT_MAX_BYTES textBody at UTF-8's 3 B/char)
                //   = 12,000,000 peak — EXACTLY AT the 12,000,000 async ceiling, zero margin.
                //
                // Lower severity than stageBytes (a throw here costs a deferred file, not an
                // email) but the identical shape, so it gets the identical fix. Projection per
                // row: a text row allocates the Blob AND then VersionData, i.e. up to
                // 2 x 3 bytes/char; a binary row allocates one more copy of an already-resident
                // Blob (SP-4.5's 2x measurement), i.e. byteSize.
                Integer projectedRow = (att.body == null && String.isNotBlank(att.textBody))
                    ? ((att.byteSize == null ? att.textBody.length() : att.byteSize)
                        * UTF8_MAX_BYTES_PER_CHAR * 2)
                    : ((att.byteSize == null) ? 0 : att.byteSize);
                if (currentHeapSize() + projectedRow > CONVERT_HEAP_CEILING) {
                    lastRunPersistFailures.add(describeDrop(att, REASON_CONVERT_HEAP_CEILING));
                    continue;
                }

                Blob data = att.body;
                if (data == null && String.isNotBlank(att.textBody)) {
                    // 🔴 G3 — the text path. Blob.valueOf holds the source String AND an
                    // equal-sized Blob simultaneously. Under the carrier model this branch is
                    // ordinarily UNREACHABLE from the live pipeline (stageBytes already turned
                    // the CSV into carrier bytes), and it is retained because persist() is a
                    // general-purpose method and a caller handing it a textBody must not
                    // silently drop the file.
                    data = Blob.valueOf(att.textBody);
                }
                if (data == null) {
                    continue;
                }
                String name = safeFileName(att);
                versions.add(new ContentVersion(
                    Title = InboundEmailFieldUtil.clip(name, LEN_TITLE),
                    PathOnClient = InboundEmailFieldUtil.clip(name, LEN_PATH),
                    VersionData = data
                ));
                ordered.add(att);
            }
            if (versions.isEmpty()) {
                return documentIds;
            }

            // allOrNone = false: one malformed file must not cost the other nine, the
            // staging row, the Lead or the claim.
            List<Database.SaveResult> saved = Database.insert(versions, false);
            Set<Id> savedVersionIds = new Set<Id>();
            for (Integer i = 0; i < saved.size(); i++) {
                if (saved[i].isSuccess()) {
                    savedVersionIds.add(saved[i].getId());
                    // The per-row mapping that lets the caller delete ONLY the carriers whose
                    // bytes are now safely in Content. Null at the synchronous boundary.
                    if (ordered[i].carrierId != null) {
                        lastRunPersistedCarrierIds.add(ordered[i].carrierId);
                    }
                } else {
                    lastRunPersistFailures.add(
                        describeDrop(ordered[i], 'file not saved: ' + firstError(saved[i])));
                }
            }

            if (!savedVersionIds.isEmpty()) {
                // The inserted sObject does NOT carry ContentDocumentId back — the one read.
                for (ContentVersion version : ContentVersionSelector.selectByIds(savedVersionIds)) {
                    if (version.ContentDocumentId != null) {
                        documentIds.add(version.ContentDocumentId);
                    }
                }
            }

            if (stagingId != null && !documentIds.isEmpty()) {
                List<ContentDocumentLink> links = new List<ContentDocumentLink>();
                for (Id documentId : documentIds) {
                    links.add(new ContentDocumentLink(
                        ContentDocumentId = documentId,
                        LinkedEntityId = stagingId,
                        ShareType = SHARE_TYPE_VIEWER,
                        Visibility = VISIBILITY_ALL_USERS
                    ));
                }
                for (Database.SaveResult link : Database.insert(links, false)) {
                    if (!link.isSuccess()) {
                        lastRunPersistFailures.add(
                            'link refused | ' + stagingId + ' | ' + firstError(link));
                    }
                }
            }
        } catch (Exception e) {
            // Deliberately Exception, not DmlException: a QueryException from the selector,
            // a TypeException, or anything else must be swallowed just as completely. See
            // the FAILURE BOUNDARY note — nothing here is worth an email.
            lastRunPersistFailures.add(
                'attachment persistence failed | ' + e.getTypeName() + ' | ' + e.getMessage());
            System.debug(LoggingLevel.ERROR,
                'InboundEmailAttachmentService.persist failed for staging ' + stagingId
                + ': ' + e.getTypeName() + ' | ' + e.getMessage());
        }

        recordFailures(stagingId, lastRunPersistFailures);
        return documentIds;
    }

    /**
     * Link an already-persisted file set to every record the routing tree filed the email
     * on. Called ONCE per inbound email, from ExtractAddressQueueable.finish(), with the
     * SAME TARGET SET the N Tasks use.
     *
     * ⚠ "SET", NOT "ORDERED LIST" — the caller hands over an ordered list, but this method
     * de-duplicates both axes into `Set<Id>`, and Apex Set iteration order is NOT guaranteed.
     * The Tasks genuinely depend on their ascending-priority order; the links do not, and
     * nothing may be built on an ordering that does not exist here. What IS guaranteed is that
     * both features act on the same MEMBERSHIP, computed once in finish().
     *
     * 🔴 EXACTLY ONE DML STATEMENT, and it MUST NEVER be called per property or per file.
     * That invariant is what holds the queueable's DML budget at a +1 delta at N = 1 AND at
     * N = 10; a per-property call would make the budget scale with N and is precisely what
     * the pinned governor assertions exist to catch.
     *
     * ShareType is 'I' (Inferred) for routed records: file access follows the record's own
     * sharing, and it matches what the platform itself produces on lead conversion (S6).
     *
     * 🔴 IT MUST NOT THROW — same reasoning as persist(), one step further down the pipeline:
     * a link failure must cost neither the Task, nor the claim, nor the staging stamp.
     *
     * @param contentDocumentIds The documents persisted at the boundary; null/empty is a
     *                           no-op returning 0.
     * @param recordIds          The distinct routed records, in priority order; null/empty
     *                           is a no-op returning 0.
     * @return How many links were actually created. Refusals are in lastLinkFailures().
     * @example
     * InboundEmailAttachmentService.linkTo(contentDocumentIds, orderedTargets);
     */
    public static Integer linkTo(List<Id> contentDocumentIds, List<Id> recordIds) {
        lastRunLinkFailures = new List<String>();
        Integer created = 0;

        if (contentDocumentIds == null || contentDocumentIds.isEmpty()
                || recordIds == null || recordIds.isEmpty()) {
            return created;
        }

        try {
            // De-duplicated on BOTH axes: a repeated document Id or a repeated target would
            // otherwise produce a DUPLICATE_VALUE refusal that is noise, not signal.
            Set<Id> documents = new Set<Id>(contentDocumentIds);
            Set<Id> targets = new Set<Id>(recordIds);

            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            List<Id> linkedTo = new List<Id>();
            for (Id documentId : documents) {
                if (documentId == null) {
                    continue;
                }
                for (Id recordId : targets) {
                    if (recordId == null) {
                        continue;
                    }
                    links.add(new ContentDocumentLink(
                        ContentDocumentId = documentId,
                        LinkedEntityId = recordId,
                        ShareType = SHARE_TYPE_INFERRED,
                        Visibility = VISIBILITY_ALL_USERS
                    ));
                    linkedTo.add(recordId);
                }
            }
            if (links.isEmpty()) {
                return created;
            }

            List<Database.SaveResult> results = Database.insert(links, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    created++;
                } else {
                    lastRunLinkFailures.add(
                        'link refused | ' + linkedTo[i] + ' | ' + firstError(results[i]));
                }
            }
        } catch (Exception e) {
            lastRunLinkFailures.add(
                'attachment linking failed | ' + e.getTypeName() + ' | ' + e.getMessage());
            System.debug(LoggingLevel.ERROR,
                'InboundEmailAttachmentService.linkTo failed: '
                + e.getTypeName() + ' | ' + e.getMessage());
        }

        return created;
    }

    /**
     * The refusals recorded by the most recent linkTo(...) in THIS transaction, so the
     * caller — which owns the staging Id — can make them durable via
     * InboundEmailStagingService.appendDroppedNote.
     *
     * ⚠ NOT A MONITORING SURFACE. It does not survive the job (the R1 lesson). The durable
     * record is Dropped_Attachment_Notes__c.
     *
     * @return The refusal lines; an empty list when the last run had none (never null).
     */
    public static List<String> lastLinkFailures() {
        return (lastRunLinkFailures == null) ? new List<String>() : lastRunLinkFailures;
    }

    /**
     * The refusals recorded by the most recent persist(...) in THIS transaction, so
     * `AttachmentPersistQueueable` can fold them into the single terminal status stamp rather
     * than issuing a second staging write.
     *
     * ⚠ NOT A MONITORING SURFACE. It does not survive the job (the R1 lesson). The durable
     * record is Dropped_Attachment_Notes__c.
     *
     * @return The refusal lines; an empty list when the last run had none (never null).
     */
    public static List<String> lastPersistFailures() {
        return (lastRunPersistFailures == null) ? new List<String>() : lastRunPersistFailures;
    }

    /**
     * The carrier `Attachment` Ids whose ContentVersion insert SUCCEEDED in the most recent
     * persist(...) in THIS transaction.
     *
     * 🔴 THE CALLER MUST DELETE ONLY THESE. Deleting every carrier after a partial refusal would
     * destroy the bytes of exactly the files that still needed retrying — turning a recoverable
     * deferral into the permanent loss this whole redesign exists to make impossible.
     *
     * @return The converted carrier Ids; an empty list when none converted (never null).
     */
    public static List<Id> lastPersistedCarrierIds() {
        return (lastRunPersistedCarrierIds == null)
            ? new List<Id>()
            : lastRunPersistedCarrierIds;
    }

    /**
     * Whether an attachment is an image, by MIME subtype OR filename extension — the same
     * union rule the allow-list uses (G1), because `mimeTypeSubType` is unreliable on
     * forwarded mail.
     *
     * @param mimeSubType `mimeTypeSubType` verbatim; may be blank.
     * @param fileName    The original filename; may be blank.
     * @return true when either signal says image.
     */
    public static Boolean isImageAttachment(String mimeSubType, String fileName) {
        return IMAGE_TOKENS.contains(normalizeSubType(mimeSubType))
            || IMAGE_TOKENS.contains(extensionOf(fileName));
    }

    /**
     * One drop/refusal line, in the `filename | mime | bytes | reason` shape
     * Dropped_Attachment_Notes__c documents. Public so the handler can record its
     * vision-gate skip in the IDENTICAL format rather than inventing a second one.
     *
     * @param att    The attachment being reported; null yields an 'unknown' line.
     * @param reason Why it was dropped or refused.
     * @return The formatted line.
     */
    public static String describeDrop(AttachmentRequest att, String reason) {
        if (att == null) {
            return 'unknown | unknown | 0 | ' + reason;
        }
        return (String.isBlank(att.fileName) ? '(no filename)' : att.fileName)
            + ' | ' + (String.isBlank(att.mimeSubType) ? '(no mime)' : att.mimeSubType)
            + ' | ' + ((att.byteSize == null) ? 0 : att.byteSize)
            + ' | ' + reason;
    }

    /**
     * Append refusal lines to the staging row, itself guarded so the recording of a failure
     * can never become a failure.
     *
     * @param stagingId The staging row; null skips.
     * @param failures  The lines to record; null/empty skips.
     */
    private static void recordFailures(Id stagingId, List<String> failures) {
        if (stagingId == null || failures == null || failures.isEmpty()) {
            return;
        }
        try {
            InboundEmailStagingService.appendDroppedNote(stagingId, String.join(failures, '\n'));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailAttachmentService.recordFailures: could not record '
                + failures.size() + ' refusal(s) on staging ' + stagingId + ': ' + e.getMessage());
        }
    }

    /**
     * G1 — keep the file when EITHER the normalized MIME subtype OR the filename extension
     * is allowed. A MIME-only filter is rejected: forwarded attachments routinely arrive as
     * `application/octet-stream`, which would drop the OM.
     *
     * @param mimeSubType `mimeTypeSubType` verbatim; may be blank.
     * @param fileName    The original filename; may be blank.
     * @return true when either signal is in the allow-list.
     */
    private static Boolean isAllowedType(String mimeSubType, String fileName) {
        return ALLOWED_MIME_SUBTYPES.contains(normalizeSubType(mimeSubType))
            || ALLOWED_EXTENSIONS.contains(extensionOf(fileName));
    }

    /**
     * Whether this attachment is a CSV, by either signal (G3).
     *
     * @param mimeSubType `mimeTypeSubType` verbatim; may be blank.
     * @param fileName    The original filename; may be blank.
     * @return true when either signal says CSV.
     */
    private static Boolean isCsv(String mimeSubType, String fileName) {
        return CSV_TOKENS.contains(normalizeSubType(mimeSubType))
            || CSV_TOKENS.contains(extensionOf(fileName));
    }

    /**
     * The comparable form of `mimeTypeSubType`. The platform supplies it inconsistently —
     * bare ('png') on some messages, fully qualified ('image/png') on others — so everything
     * up to and including the last '/' is stripped and the remainder lowercased and trimmed.
     * A trailing parameter (';charset=utf-8') is also removed.
     *
     * @param mimeSubType The raw value; blank returns ''.
     * @return The lowercased bare subtype, or '' when there is nothing to compare.
     */
    private static String normalizeSubType(String mimeSubType) {
        if (String.isBlank(mimeSubType)) {
            return '';
        }
        String value = mimeSubType.trim().toLowerCase();
        Integer semicolon = value.indexOf(';');
        if (semicolon >= 0) {
            value = value.substring(0, semicolon);
        }
        Integer slash = value.lastIndexOf('/');
        if (slash >= 0) {
            value = value.substring(slash + 1);
        }
        return value.trim();
    }

    /**
     * The lowercased extension of a filename, without the dot.
     *
     * @param fileName The filename; blank or extension-less returns ''.
     * @return The extension, or '' when there is none.
     */
    private static String extensionOf(String fileName) {
        if (String.isBlank(fileName)) {
            return '';
        }
        String value = fileName.trim().toLowerCase();
        Integer dot = value.lastIndexOf('.');
        if (dot < 0 || dot == value.length() - 1) {
            return '';
        }
        return value.substring(dot + 1);
    }

    /**
     * A filename safe to put on ContentVersion.Title / PathOnClient. PathOnClient is what the
     * platform reads the file extension from, so a blank name gets a synthetic one with an
     * extension derived from the MIME subtype where possible.
     *
     * @param att The attachment; never null here.
     * @return A non-blank filename.
     */
    private static String safeFileName(AttachmentRequest att) {
        if (String.isNotBlank(att.fileName)) {
            return att.fileName.trim();
        }
        String subType = normalizeSubType(att.mimeSubType);
        return String.isBlank(subType) ? 'attachment.bin' : 'attachment.' + subType;
    }

    /**
     * The first error on a save result, as `STATUSCODE: message` — the shape decision C
     * point 3 asks for ("record Id + StatusCode").
     *
     * @param result A failed Database.SaveResult.
     * @return The formatted first error, or 'UNKNOWN_ERROR' when the platform supplied none.
     */
    private static String firstError(Database.SaveResult result) {
        if (result.getErrors() == null || result.getErrors().isEmpty()) {
            return 'UNKNOWN_ERROR';
        }
        Database.Error error = result.getErrors()[0];
        return String.valueOf(error.getStatusCode()) + ': ' + error.getMessage();
    }

    /**
     * The first error on a failed delete result, in the same `STATUSCODE: message` shape.
     * A separate overload because Database.SaveResult and Database.DeleteResult are unrelated
     * types in Apex — there is no common interface to write this once.
     *
     * @param result A failed Database.DeleteResult.
     * @return The formatted first error, or 'UNKNOWN_ERROR' when the platform supplied none.
     */
    private static String firstDeleteError(Database.DeleteResult result) {
        if (result.getErrors() == null || result.getErrors().isEmpty()) {
            return 'UNKNOWN_ERROR';
        }
        Database.Error error = result.getErrors()[0];
        return String.valueOf(error.getStatusCode()) + ': ' + error.getMessage();
    }

    /**
     * The transaction's current heap usage, or the test override when one is set.
     *
     * @return Heap bytes consumed so far.
     */
    private static Integer currentHeapSize() {
        return (heapSizeOverride == null) ? Limits.getHeapSize() : heapSizeOverride;
    }
}
