/**
 * Broker-Protection inbound-email intake — staging DML layer (staging model). This is
 * the ONLY place an Inbound_Email_Staging__c row is inserted or updated: it keeps the
 * thin boundary handler (EmailToLeadHandler) and the async orchestrator
 * (ExtractAddressQueueable) free of staging DML, per the layering contract.
 *
 * WHY A STAGING RECORD EXISTS AT ALL. Before this model the pipeline inserted a Lead
 * synchronously so the email "could not be lost", which forced a Lead into existence
 * before anything was known about it — including whether it was a reply to an existing
 * deal, a repeat from a broker who had already submitted, or a redelivery of a message
 * already processed. Staging inverts that: the DURABLE artefact is the raw email plus its
 * RFC headers, written synchronously and never deleted, and the Lead is created only by
 * the routing branch that actually needs one. Every terminal state of the async job is
 * written back here (Processed / Error, the outcome label, the routed record Id), so the
 * object doubles as the pipeline's audit trail and its restart point.
 *
 * LAYER — Service (staging write side). Reads delegate to InboundEmailStagingSelector;
 * this class contains NO SOQL of its own.
 *
 * DML MODEL — SYSTEM MODE, and since 2026-08-15 the SYNCHRONOUS insert DECLARES IT EXPLICITLY
 * rather than inheriting it. The INTENT has never changed and is still right: the inbound-email
 * pipeline runs in an automated context whose "running user" is the Email Service's configured
 * context user, not an interactive user whose FLS is meaningful to enforce on a system-owned
 * audit row. `AccessLevel.USER_MODE` is intentionally NOT applied anywhere in this class. Every
 * write is single-record-shaped (one inbound email == one staging row) and never sits inside a
 * loop.
 *
 * ═══ 🔴 THE 2026-08-15 OUTAGE — "PLAIN DML IS SYSTEM MODE" IS FALSE IN AN EMAIL SERVICE ═══
 * This block used to assert that a bare `insert` gave us system mode. That is the ordinary Apex
 * rule and it holds everywhere else in this module — but it is NOT true at the Email Service
 * boundary, and the difference silently discarded EVERY inbound broker email.
 *
 * MEASURED, ApexLog 07Liw000000CdnBEAS on `usman-dpeg` (2026-08-15, a real forwarded email):
 *
 *     DML_BEGIN|[266]|Op:Insert|Type:Inbound_Email_Staging__c|Rows:1
 *     common.apex.runtime.impl.dmlwithaccess.UserModeFLSDMLExceptionWithResults:
 *       Operation failed due to fields being inaccessible on Sobject Inbound_Email_Staging__c
 *
 * THE MECHANISM. The org has the release update `EmailsimpleRespectProfiles` at Status
 * `Invoked` (active). Under it, Apex invoked BY AN EMAIL SERVICE enforces the run-as user's
 * object and field permissions on otherwise-plain DML. The run-as user here is
 * `junior.dhanani@usmandpeg.uat`, profile `Minimum Access - Salesforce`, whose only grants come
 * from `Broker_Protection_Access` — where `Inbound_Email_Staging__c.Status__c` is
 * `readable=true, editable=FALSE`, the ONLY read-only field of the 24 on this object.
 * `createStaging` stamps `Status__c = STATUS_PENDING`, so the insert was refused.
 * 🔴 THIS IS THE ONLY CONTEXT IN THIS APPLICATION WHERE THAT ENFORCEMENT APPLIES. Everything on
 * the async path (`ExtractAddressQueueable`, the Finalizers, the sweep batches) is an ordinary
 * Queueable/Batch transaction where plain DML genuinely IS system mode — which is why every
 * other write in this class is untouched, and why nothing failed until an email actually arrived.
 *
 * WHY IT WAS INVISIBLE. `EmailToLeadHandler` catches the DmlException fail-soft and returns
 * `success = true`, so the platform recorded Success: zero staging rows, zero Leads, no bounce,
 * no error record, nothing queryable. The staging row IS the durability guarantee, so losing it
 * loses the entire audit of its own loss.
 *
 * 🔴 DO NOT REVERT `createStaging` TO A BARE `insert`. It reintroduces a TOTAL, SILENT inbound-
 * email outage — every broker email discarded, with the Email Service reporting success.
 * 🔴 AND THE CORRECT FIX IS NEVER TO GRANT `editable=true` ON `Status__c`. That grant was flipped
 * true -> false deliberately by code review C3 (2026-08-09) and carries a DO NOT REVERT warning
 * in `Broker_Protection_Access.permissionset-meta.xml`: `Status__c = 'Failed'` is a MACHINE-ONLY
 * instruction, and `RoutingRetrySweepBatch` may replay a row on the sole strength of
 * `isRetryableRoutingState`'s proof that only a Finalizer wrote it. A human able to hand-edit an
 * `'Error'` row to `'Failed'` bypasses that guard and can mint a second Lead or file the winning
 * broker as a competing submission against their own Lead — recoverable only by manual registry
 * surgery. Declaring the access level costs nothing and keeps that control intact.
 * ⚠ C3's own note says "every Apex writer of Status__c uses plain system-mode `update`, so this
 * grant removes nothing the pipeline needs; it is a human-facing bypass only." That premise was
 * correct for the three `update` writers — all async — and FALSE for this one synchronous
 * `insert`. The premise is what was wrong, not the grant.
 *
 * FAIL-SOFT STATUS WRITES — markProcessed / markSkipped / markError swallow their own
 * DmlExceptions. They are the LAST statement of a routing branch that has already
 * committed real work (a Lead, a registry claim, a Task); letting a status-stamp failure
 * throw would replace an accurate "the claim happened" with an unhandled async failure and
 * roll nothing back. A failed stamp leaves the row 'Pending', which is visible and
 * hand-recoverable. appendDroppedNote (2026-08-05) is fail-soft for the same reason and
 * one degree more so — it catches Exception, not just DmlException, because it is the only
 * method here that READS as well as writes and its callers' whole contract is "never throw".
 *
 * ROUTING RESILIENCE (2026-08-08) — markRoutingFailed / markRoutingAbandoned are the write half
 * of the routing transaction's own four-exit lifecycle, mirroring what markAttachmentStatus is to
 * the file pipeline's. 🔴 They are the ONLY writers of Status__c = 'Failed', and 'Failed' is the
 * ONLY status a machine is ever allowed to retry — see STATUS_FAILED's Javadoc for why 'Error'
 * has the opposite property. Both are fail-soft catching Exception (not DmlException) for the same
 * reason appendDroppedNote is: markRoutingFailed READS as well as writes, and its caller is a
 * Finalizer whose entire job is to report a failure that has already happened.
 * 🔴 Their DML runs through the `without sharing` inner class `RoutingWrites` — this object is
 * `sharingModel = Private` and the rows are owned by the Email Service context user, so a
 * scheduled sweep or a Finalizer running as any other principal would otherwise have its update
 * refused and, being fail-soft, would swallow the refusal. Read that class's header before
 * changing it; the outer class stays `with sharing` and every other write here is unaffected.
 *
 * ATTACHMENT CAPTURE (2026-08-05; REDESIGNED 2026-08-06) — createStaging additionally stamps
 * Attachment_Count__c, Attachment_Bytes__c, Dropped_Attachment_Notes__c AND
 * Attachment_Status__c in the SAME insert (zero extra DML), and appendDroppedNote lets the
 * failure paths add refusals afterwards. markAttachmentStatus (new) is how the file job, its
 * Finalizer and the daily sweeper move a row through the file pipeline's own state machine.
 * The DML that writes the FILES and the byte CARRIER belongs to InboundEmailAttachmentService;
 * this class still owns only Inbound_Email_Staging__c.
 *
 * @see EmailToLeadHandler.cls (calls createStaging)
 * @see ExtractAddressQueueable.cls (calls getStaging + the three mark* methods)
 * @see InboundEmailStagingSelector.cls (the read side)
 */
public with sharing class InboundEmailStagingService {

    /** Inbound_Email_Staging__c.Status__c picklist values (restricted value set). */
    private static final String STATUS_PENDING = 'Pending';
    private static final String STATUS_PROCESSED = 'Processed';
    private static final String STATUS_ERROR = 'Error';

    /**
     * The FOURTH Status__c value, added 2026-08-08 with routing resilience: the routing
     * transaction DIED with an unhandled exception and committed nothing.
     *
     * 🔴 IT IS PUBLIC, ALONE AMONG THE FOUR, AND THAT ASYMMETRY IS DELIBERATE. `Pending`,
     * `Processed` and `Error` are written here and read nowhere else, so they stay private.
     * `Failed` is a CROSS-CLASS CONTRACT with **THREE** consumers, every one of which binds to this
     * constant rather than re-typing the literal:
     *
     *   1. `InboundEmailStagingSelector.queryRoutingRetrySweep()` — filters the retry work queue
     *   2. `RoutingRetrySweepBatch`                               — re-checks it as the dispatch
     *                                                               safety guard
     *   3. `AttachmentCarrierSweepBatch.ROUTING_STATUS_FAILED`    — SKIPS such a row, because
     *                                                               routing is unfinished
     *
     * ⚠ (3) was missing from this list until 2026-08-09 and is the one that matters most: it lives
     * in a DIFFERENT feature, so a re-cut of this value that updated only (1) and (2) would leave
     * the file sweeper converting failed rows with no routed target — the §3.6 permanent-loss
     * defect. The `Not_Saved` restricted-picklist trap documented below is proof that such a re-cut
     * happens here.
     *
     * 🔴 `'Failed'` AND `'Error'` ARE NOT SYNONYMS AND MUST NEVER BE CONFLATED — they have
     * OPPOSITE replay-safety properties, which is the entire reason a fourth value was added
     * instead of reusing the third:
     *
     *   Failed   the Finalizer wrote it, so the parent job hit UNHANDLED_EXCEPTION, so (SP-5,
     *            measured in this org) its own DML rolled back. NOTHING committed — no Lead, no
     *            registry claim, no submission, no Task, no stamp. A replay is a first run.
     *            → RETRIED automatically.
     *   Error    execute()'s catch RAN, which means the transaction COMMITTED. It may hold a Lead
     *            with no claim (a replay mints a SECOND Lead) or a registry row with no submission
     *            (a replay files the winning broker as a competing submission against their own
     *            Lead). → A HUMAN QUEUE. Never auto-retried.
     *
     * ⚠ Unlike `ATTACHMENT_STATUS_NOT_SAVED`, this value's `<fullName>` and `<label>` are
     * IDENTICAL (`Failed`), so the restricted-picklist underscore trap recorded below does not
     * recur here. It is still the only place in Apex that names the value.
     */
    public static final String STATUS_FAILED = 'Failed';

    /**
     * Ceiling for `Routing_Attempt_Count__c`, which is Number(2,0). This is a FIELD-CAPACITY clip,
     * NOT the retry policy: the number of attempts allowed lives on `RoutingRetrySweepBatch`,
     * which is the only thing that consults it.
     *
     * 🔴 DO NOT "IMPROVE" THIS INTO A POLICY CAP. Design §3.4 reason 3 is explicit that the
     * counter must be INCREMENTED in one place and CONSULTED in one place; clamping here would
     * make this class a second consumer of the retry policy and put the cap in two files that can
     * drift apart silently.
     */
    private static final Integer MAX_ROUTING_ATTEMPT_COUNT = 99;

    /**
     * Inbound_Email_Staging__c.Attachment_Status__c picklist values (added 2026-08-06).
     *
     * 🔴 THIS FIELD IS THE FILE PIPELINE'S WORK QUEUE, NOT DECORATION. `AttachmentCarrierSweepBatch`
     * selects on `IN ('Pending','Partial','Failed')`, which is exactly why the design made it a
     * required picklist rather than leaving the information in the Long Text notes field — a Long
     * Text field cannot be a work queue. Every writer stamps one of these values; nothing may
     * leave the field blank once an email has been classified.
     *
     * PUBLIC on purpose: these strings are a cross-class contract (the handler, the routing job,
     * the file job, its Finalizer and the sweeper all write them, and an admin filters a list
     * view on them), so every caller binds to the constant rather than re-typing the literal.
     *
     *   None      no attachment arrived at all
     *   Pending   carrier written, conversion not yet attempted (the normal state for seconds)
     *   Saved     every file converted and linked                       — terminal, success
     *   Partial   some converted, or conversion was deferred/budgeted   — RETRIED by the sweeper
     *   Failed    the file job died, or the breaker is tripped          — RETRIED by the sweeper
     *   Not_Saved carrier refused, or released as gated/duplicate       — TERMINAL, unrecoverable
     *   Expired   still unconverted after CARRIER_MAX_AGE_DAYS          — TERMINAL, unrecoverable
     *
     * 🔴 **`ATTACHMENT_STATUS_NOT_SAVED` IS `'Not_Saved'` WITH AN UNDERSCORE, AND THAT IS NOT A
     * TYPO.** The picklist is RESTRICTED, and a restricted picklist enforces the value's
     * `<fullName>` — which the deployed metadata sets to `Not_Saved`, with `Not Saved` as its
     * LABEL only. Writing the label would throw
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` at runtime, where no Apex compile check can see
     * it. ⚠ Design §7 and §10.2 A1 print the LABEL (`Not Saved`); the field metadata is
     * authoritative. If anyone ever re-cuts the value set, this constant must move with it —
     * it is the only place in Apex that names the value.
     */
    public static final String ATTACHMENT_STATUS_NONE = 'None';
    public static final String ATTACHMENT_STATUS_PENDING = 'Pending';
    public static final String ATTACHMENT_STATUS_SAVED = 'Saved';
    public static final String ATTACHMENT_STATUS_PARTIAL = 'Partial';
    public static final String ATTACHMENT_STATUS_FAILED = 'Failed';
    public static final String ATTACHMENT_STATUS_NOT_SAVED = 'Not_Saved';
    public static final String ATTACHMENT_STATUS_EXPIRED = 'Expired';

    /** Destination field lengths — every inbound value is clipped to these before DML. */
    private static final Integer LEN_LONG_TEXT = 131072;
    private static final Integer LEN_REFERENCES = 32768;
    /** Routed_Record_Ids__c is LongTextArea(32768) — the N-result audit trail. */
    private static final Integer LEN_ROUTED_IDS = 32768;
    /** Dropped_Attachment_Notes__c is LongTextArea(32768) — the attachment audit trail. */
    private static final Integer LEN_DROPPED_NOTES = 32768;
    private static final Integer LEN_ERROR = 32000;
    private static final Integer LEN_TEXT = 255;
    private static final Integer LEN_RECORD_ID = 18;

    /**
     * The envelope + header payload of one inbound email, as parsed by
     * EmailToLeadHandler. A DTO rather than a twelve-parameter method signature: the
     * fields are all optional strings of the same type, so positional arguments would be
     * trivially transposable at the call site (swapping `messageId` and `inReplyTo` would
     * compile and silently break threading). Every field is clipped by createStaging, so
     * the caller may populate it with raw, unbounded values.
     */
    public class StagingRequest {
        /** Sender display name from the envelope ("Jane Broker"). */
        public String fromName;
        /** Sender address from the envelope. */
        public String fromAddress;
        /** Inbound subject, verbatim (e.g. 'FW: 100 Main St'). */
        public String subject;
        /** Plain-text body when present, else the HTML body. */
        public String rawBody;
        /** Every RFC header the platform exposed, one 'Name: Value' per line. */
        public String rawHeaders;
        /** RFC Message-ID of this email — the idempotency key. */
        public String messageId;
        /** RFC In-Reply-To — the immediate parent message. */
        public String inReplyTo;
        /** RFC References — the full ancestry, whitespace-delimited. */
        public String references;
        /** The monitored inbox that forwarded this email (header-resolved, else the From). */
        public String forwardedBy;
        /** MIME type of the first inline image, when the email carried one. */
        public String imageMimeType;
        /** True when an inline image was found and handed to the async extractor. */
        public Boolean hasImage;
        /**
         * Attachment_Count__c — files RETAINED by InboundEmailAttachmentService.classify,
         * not files received. Null/absent is stamped as null (added 2026-08-05).
         */
        public Integer attachmentCount;
        /** Attachment_Bytes__c — total retained bytes, which is what makes the oversized-email
         *  risk reportable ("how close do our real emails run to the ceiling?"). */
        public Integer attachmentBytes;
        /**
         * Dropped_Attachment_Notes__c — one `filename | mime | bytes | reason` line per
         * dropped attachment, plus the vision-gate skip when one applied.
         * ⚠ A BLANK VALUE DOES NOT MEAN "the broker sent no attachment": an email rejected
         * by the Email Service for size never reaches Apex and produces no staging row at all.
         */
        public String droppedNotes;
        /**
         * Attachment_Status__c — 'Pending' when a byte carrier was written for this email,
         * 'None' when nothing was retained (added 2026-08-06). Stamped in the SAME insert as
         * everything else, so the file pipeline's work queue costs zero extra DML at the
         * boundary. Blank is treated as 'None'.
         */
        public String attachmentStatus;
    }

    /**
     * Insert the staging row for one inbound email and return its Id. Called
     * SYNCHRONOUSLY from the Email Service boundary, before anything else happens, so the
     * raw email and its headers are durable no matter what the async job later does.
     * Status is stamped 'Pending'; the queueable moves it to 'Processed' or 'Error'.
     *
     * Every value is clipped to its destination field length and any address is
     * sanitized (InboundEmailFieldUtil), because an over-long subject or a malformed
     * envelope address must never bounce an otherwise-valid broker email.
     *
     * @param request The parsed envelope/header payload; must not be null.
     * @return The Id of the inserted Inbound_Email_Staging__c.
     * @throws DmlException when the staging insert itself fails — the handler catches it
     *         and returns success=false so the platform records the bounce.
     * @example
     * Id stagingId = InboundEmailStagingService.createStaging(request);
     */
    public static Id createStaging(StagingRequest request) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = InboundEmailFieldUtil.clip(request.fromName, LEN_TEXT),
            From_Address__c = InboundEmailFieldUtil.sanitizeEmail(request.fromAddress),
            Subject__c = InboundEmailFieldUtil.clip(request.subject, LEN_TEXT),
            Raw_Body__c = InboundEmailFieldUtil.clip(request.rawBody, LEN_LONG_TEXT),
            Raw_Headers__c = InboundEmailFieldUtil.clip(request.rawHeaders, LEN_LONG_TEXT),
            Message_Id__c = InboundEmailFieldUtil.clip(request.messageId, LEN_TEXT),
            In_Reply_To__c = InboundEmailFieldUtil.clip(request.inReplyTo, LEN_TEXT),
            References__c = InboundEmailFieldUtil.clip(request.references, LEN_REFERENCES),
            Forwarded_By__c = InboundEmailFieldUtil.sanitizeEmail(request.forwardedBy),
            Image_Mime_Type__c = InboundEmailFieldUtil.clip(request.imageMimeType, LEN_TEXT),
            Has_Image__c = request.hasImage == true,
            // Attachment capture (2026-08-05). Written in the SAME insert as everything else,
            // so recording what was kept and what was dropped costs zero extra DML.
            Attachment_Count__c = request.attachmentCount,
            Attachment_Bytes__c = request.attachmentBytes,
            Dropped_Attachment_Notes__c =
                InboundEmailFieldUtil.clip(request.droppedNotes, LEN_DROPPED_NOTES),
            // The file pipeline's work queue, stamped in the SAME insert (zero extra DML).
            Attachment_Status__c = String.isBlank(request.attachmentStatus)
                ? ATTACHMENT_STATUS_NONE
                : request.attachmentStatus,
            Status__c = STATUS_PENDING
        );
        // 🔴 THE ACCESS LEVEL IS DECLARED, NOT INHERITED — see THE 2026-08-15 OUTAGE in the class
        // header. This is the one DML in this module that runs inside an Email Service
        // transaction, where the `EmailsimpleRespectProfiles` release update makes a bare
        // `insert` enforce the run-as user's FLS. `Status__c` is deliberately non-editable for
        // that user (C3), so the bare form refused every inbound email, silently.
        //
        // allOrNone = true, deliberately: this row IS the pipeline's durable landing record and
        // its absence is the outage. A partial/soft failure here is precisely what must not
        // happen — the caller's catch turns a thrown DmlException into a reported failure,
        // whereas a swallowed one is indistinguishable from a healthy pipeline.
        Database.insert(staging, true, AccessLevel.SYSTEM_MODE);
        return staging.Id;
    }

    /**
     * Append one or more lines to Dropped_Attachment_Notes__c, preserving whatever
     * createStaging already wrote. Read-then-append: 1 SOQL + 1 DML.
     *
     * ⚠ FAILURE PATH ONLY — it is called when a ContentVersion insert or a
     * ContentDocumentLink insert was REFUSED, never on the success path. It therefore sits
     * OUTSIDE the pinned success-path governor budgets (EmailToLeadHandler 1 SOQL / 3 DML;
     * ExtractAddressQueueable 30/21 at N=1 and 120/61 at N=10). Say so before reading a
     * budget assertion as violated.
     *
     * WHY IT EXISTS AT ALL — the R1 lesson, recorded in ARCHITECTURE.md. A fail-soft write
     * whose entire failure surface is `allOrNone = false` plus a System.debug produces zero
     * writes and NO DURABLE SIGNAL: no exception, no failed job, nothing queryable, and
     * "0 links this week" becomes indistinguishable from "nothing needed linking". Recording
     * the refusal on the audit row is what makes the difference answerable.
     *
     * FAIL-SOFT, and it catches `Exception` rather than `DmlException` — deliberately wider
     * than storeExtractedJson / stamp, because unlike them it also READS: a `WITH USER_MODE`
     * QueryException is reachable here and is NOT a DmlException, so a narrower catch would
     * let it escape into a caller whose whole contract is "never throw". Same shape as the
     * ApprovalAuditService TypeException incident recorded in ARCHITECTURE.md.
     *
     * @param stagingId The staging row to append to; null is a no-op.
     * @param note      The line(s) to append; blank is a no-op.
     * @example
     * InboundEmailStagingService.appendDroppedNote(stagingId, String.join(refusals, '\n'));
     */
    public static void appendDroppedNote(Id stagingId, String note) {
        if (stagingId == null || String.isBlank(note)) {
            return;
        }
        try {
            Inbound_Email_Staging__c row =
                InboundEmailStagingSelector.selectDroppedNotesById(stagingId);
            String existing = (row == null) ? null : row.Dropped_Attachment_Notes__c;
            String merged = String.isBlank(existing) ? note : existing + '\n' + note;
            update new Inbound_Email_Staging__c(
                Id = stagingId,
                Dropped_Attachment_Notes__c =
                    InboundEmailFieldUtil.clip(merged, LEN_DROPPED_NOTES)
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.appendDroppedNote: could not append to staging '
                + stagingId + ': ' + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * Stamp the file pipeline's terminal (or interim) state for this row, and record the
     * human-readable reason alongside it. Added 2026-08-06 with the attachment-persistence
     * redesign.
     *
     * ⚠ TWO FIELDS, TWO AUDIENCES, AND BOTH ARE NEEDED. `Attachment_Status__c` is what
     * `AttachmentCarrierSweepBatch` QUERIES — it is a work queue, and a Long Text notes field
     * cannot be one. `Dropped_Attachment_Notes__c` is what a HUMAN READS. Writing only the note
     * would leave the row invisible to the retry sweep; writing only the status would leave a
     * human unable to tell a deferral (recoverable) from a release (terminal), which design §7
     * calls the single most important thing this copy has to convey.
     *
     * COST — 1 DML for the status. The note, when present, goes through the EXISTING
     * `appendDroppedNote` path (+1 SOQL / +1 DML) so there is ONE formatter and one
     * read-then-append rule rather than two that can drift. That note write is FAILURE-PATH ONLY
     * and sits outside every pinned success-path governor budget, exactly as it does today.
     *
     * FAIL-SOFT, catching `Exception` rather than `DmlException` — the same reasoning as
     * appendDroppedNote, one degree stronger: its callers include `AttachmentPersistFinalizer`,
     * whose entire job is to report a failure that has already happened. A failure to record a
     * failure must never become a second failure.
     *
     * @param stagingId The staging row to stamp; null is a no-op.
     * @param status    An ATTACHMENT_STATUS_* value; blank is a no-op for the status write.
     * @param note      The §7 line explaining it; blank writes no note.
     * @example
     * InboundEmailStagingService.markAttachmentStatus(
     *     stagingId, InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, null);
     */
    public static void markAttachmentStatus(Id stagingId, String status, String note) {
        if (stagingId == null) {
            return;
        }
        try {
            if (String.isNotBlank(status)) {
                update new Inbound_Email_Staging__c(
                    Id = stagingId,
                    Attachment_Status__c = status
                );
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.markAttachmentStatus: could not stamp staging '
                + stagingId + ' as "' + status + '": ' + e.getTypeName() + ' | ' + e.getMessage());
        }
        // Deliberately OUTSIDE the try above: a failed status stamp must not cost the note, and
        // a failed note must not cost the status. appendDroppedNote is itself fail-soft.
        if (String.isNotBlank(note)) {
            appendDroppedNote(stagingId, note);
        }
    }

    /**
     * Load the staging record for the async job. A thin delegation to
     * InboundEmailStagingSelector so ExtractAddressQueueable keeps its invariant of
     * calling services only and holding no data access of its own.
     *
     * @param stagingId The staging Id the job was enqueued for; null returns null.
     * @return The staging record, or null when it is missing (hard-deleted between the
     *         synchronous insert and the async run).
     */
    public static Inbound_Email_Staging__c getStaging(Id stagingId) {
        return InboundEmailStagingSelector.selectById(stagingId);
    }

    /**
     * The full result of routing ONE inbound email, which since D1 can be N results rather
     * than one. A DTO for the same reason StagingRequest is one: the alternative is a
     * six-parameter stamp whose Id and String arguments are trivially transposable.
     *
     * WHY Result_Record_Id__c IS NOT WIDENED (C-16). It is Text(18) and holds exactly one
     * Id; every existing consumer and the operations runbook read it that way. Rather than
     * break them, it keeps its meaning — the PRIMARY routed record — and the complete
     * N-result mapping lives in the new Routed_Record_Ids__c long text. A single-property
     * email therefore stamps byte-identically to how it always has.
     */
    public class RoutingResult {
        /** The PRIMARY routed record: first WINNER Lead, else first COMPETING winner, else
         *  the REPLY/REPEAT target, else null. */
        public Id resultRecordId;
        /** Outcome__c label. For N = 1 this is today's label unchanged; for N > 1 it is the
         *  'Multi-Property (N): ...' summary. */
        public String outcome;
        /** Routed_Record_Ids__c — one line per routed property, in PROCESSING order:
         *  `&lt;normalized address&gt; | &lt;outcome&gt; | &lt;recordId&gt;`. The only place the full
         *  mapping exists. Null for the single-result branches. */
        public String routedRecordIds;
        /** Property_Count__c — how many properties the extraction FOUND (pre-truncation).
         *  When this exceeds the number of lines in routedRecordIds, the difference IS the
         *  truncation signal. */
        public Integer propertyCount;
        /** Error__c text. Blank means the run succeeded; non-blank stamps Status 'Error'
         *  while still recording whatever routing DID achieve. */
        public String errorText;
    }

    /**
     * Store the raw LLM response on the staging row (D3 tier 1), BEFORE any routing
     * decision is taken.
     *
     * The ordering is the point: written first, the extraction survives every branch —
     * including the ones that create no Lead (reply, repeat, competing, gated) and
     * including an exception thrown later in the transaction. It is written through
     * InboundEmailFieldUtil.clip because an over-long response would otherwise throw
     * STRING_TOO_LONG and take the claim down with it.
     *
     * FAIL-SOFT, like the mark* methods: a failure to persist the audit copy must never
     * cost the email its routing.
     *
     * @param stagingId  The staging row to stamp; null is a no-op.
     * @param extractedJson The model's response verbatim, or a `{"skipped":"..."}` marker
     *                      for the branches that deliberately skip the callout (C-6).
     * @example
     * InboundEmailStagingService.storeExtractedJson(stagingId, extraction.rawJson);
     */
    public static void storeExtractedJson(Id stagingId, String extractedJson) {
        if (stagingId == null) {
            return;
        }
        try {
            update new Inbound_Email_Staging__c(
                Id = stagingId,
                Extracted_JSON__c = InboundEmailFieldUtil.clip(extractedJson, LEN_LONG_TEXT)
            );
        } catch (DmlException de) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.storeExtractedJson: could not store the extraction for staging '
                + stagingId + ': ' + de.getMessage());
        }
    }

    /**
     * Stamp the terminal state for a routing run that may have produced N results.
     * Status is derived from the result: 'Error' when `errorText` is non-blank (the routing
     * that DID succeed is still recorded alongside it), 'Processed' otherwise.
     *
     * @param stagingId The staging row to stamp; null is a no-op.
     * @param result    The routing result; must not be null.
     * @example
     * InboundEmailStagingService.markRouted(stagingId, result);
     */
    public static void markRouted(Id stagingId, RoutingResult result) {
        stamp(stagingId,
            String.isBlank(result.errorText) ? STATUS_PROCESSED : STATUS_ERROR,
            result.resultRecordId, result.outcome, result.errorText,
            result.routedRecordIds, result.propertyCount);
    }

    /**
     * Stamp the terminal SUCCESS state: Status 'Processed', the routing outcome label,
     * the Id of the record the email was routed to, and the processed timestamp.
     *
     * @param stagingId      The staging row to stamp.
     * @param resultRecordId The record the email ended up attached to (Lead, Opportunity,
     *                       Contact, ...); may be null when routing produced no record.
     * @param outcome        The routing outcome label (see ExtractAddressQueueable's OUTCOME_* constants).
     */
    public static void markProcessed(Id stagingId, Id resultRecordId, String outcome) {
        stamp(stagingId, STATUS_PROCESSED, resultRecordId, outcome, null, null, null);
    }

    /**
     * Stamp the terminal SKIPPED state. Used by the Message-ID idempotency check: the
     * email is a redelivery of a message already logged, so no routing runs. Recorded as
     * 'Processed' (the row reached a correct terminal state — nothing was lost) with an
     * outcome label that says it was skipped, because Status__c is a restricted picklist
     * of Pending / Processed / Error with no separate "skipped" value.
     *
     * @param stagingId The staging row to stamp.
     * @param outcome   The skip label (e.g. 'Duplicate Delivery (skipped)').
     */
    public static void markSkipped(Id stagingId, String outcome) {
        stamp(stagingId, STATUS_PROCESSED, null, outcome, null, null, null);
    }

    /**
     * Stamp the terminal ERROR state: Status 'Error' plus the full exception text.
     * `resultRecordId` and `outcome` are still written when routing had already succeeded
     * before the failure (e.g. the claim committed and the Task insert then failed), so
     * the row records BOTH what was achieved and what broke rather than discarding the
     * successful half.
     *
     * @param stagingId      The staging row to stamp.
     * @param resultRecordId The record routing produced before the failure, or null.
     * @param outcome        The outcome reached before the failure, or null.
     * @param errorText      Type, message, line number and stack trace of the failure.
     */
    public static void markError(Id stagingId, Id resultRecordId, String outcome, String errorText) {
        stamp(stagingId, STATUS_ERROR, resultRecordId, outcome, errorText, null, null);
    }

    /**
     * Record that the ROUTING transaction died with an unhandled exception: stamp
     * `Status__c = 'Failed'`, increment `Routing_Attempt_Count__c`, and APPEND `note` to whatever
     * `Error__c` already held. Added 2026-08-08; called only by `RoutingFailureFinalizer` and, on
     * its own dispatch-failure path, by `RoutingRetrySweepBatch`.
     *
     * 🔴 STAMPING 'Failed' IS WHAT PUTS THE ROW IN THE RETRY QUEUE. It is not a label — it is the
     * proof that a replay is safe. `RoutingFailureFinalizer` fires only on
     * `ParentJobResult.UNHANDLED_EXCEPTION`, and SP-5 measured (in this org) that such a failure
     * rolls back the queueable's own DML, so the row carries nothing from the failed attempt. See
     * STATUS_FAILED's Javadoc for why the superficially similar 'Error' must never be retried.
     *
     * 🔴 BUT IT ONLY MOVES A ROW THAT IS SAFE TO MOVE — see `isRetryableRoutingState`. A row
     * already sitting on the terminal `Error` or `Processed` (left by a PREVIOUS, completed run,
     * which is what survives this transaction's rollback) keeps its status and receives the note
     * ONLY. Without that check any later uncatchable death would promote an `Error` row into the
     * retry queue, which is precisely what the whole design forbids.
     *
     * ⚠ THIS RUNS IN A FRESH TRANSACTION, AFTER THE PARENT'S ROLLBACK. SP-3 measured a Finalizer's
     * own DML committing durably there. That is also why its cost — 1 SOQL + 1 DML — sits OUTSIDE
     * every pinned `ExtractAddressQueueable` governor budget by construction, exactly as
     * `AttachmentPersistFinalizer`'s does. Do not read a budget assertion as violated on its
     * account.
     *
     * WHY IT READS FIRST. Two of the three writes need the current value: the counter is an
     * increment, and `Error__c` is an APPEND (blowing away a prior failure's text would destroy
     * the only history of a row that has now failed twice). The read goes through
     * `InboundEmailStagingSelector.selectRoutingStateById` — a narrow `WITH SYSTEM_MODE` method
     * that deliberately is NOT `selectById`, so this cannot make the pipeline's critical path
     * depend on a brand-new field's FLS.
     *
     * THE COUNTER IS INCREMENTED HERE AND CONSULTED NOWHERE IN THIS CLASS. Design §3.4 reason 3:
     * one incrementer, one consumer (`RoutingRetrySweepBatch`). The only clamp applied is
     * MAX_ROUTING_ATTEMPT_COUNT, which is the Number(2,0) field's own capacity, not a policy.
     *
     * FAIL-SOFT, catching `Exception` rather than `DmlException` — deliberately wider, and for two
     * independent reasons: it READS as well as writes, so a `QueryException` is reachable and is
     * not a `DmlException`; and its caller is a Finalizer reporting a failure that has already
     * happened. **A failure to record a failure must not become a second failure.**
     *
     * @param stagingId The staging row to stamp; null is a no-op. A row that no longer exists
     *                  (hard-deleted between the failure and this call) is also a no-op.
     * @param note      The durable line explaining the death — the wrapped exception message and
     *                  the AsyncApexJob Id. Blank appends nothing but still stamps the status.
     * @example
     * InboundEmailStagingService.markRoutingFailed(stagingId, 'ROUTING FAILED: ... AsyncApexJob 707...');
     */
    public static void markRoutingFailed(Id stagingId, String note) {
        if (stagingId == null) {
            return;
        }
        try {
            Inbound_Email_Staging__c row =
                InboundEmailStagingSelector.selectRoutingStateById(stagingId);
            if (row == null) {
                return;
            }
            Decimal current = row.Routing_Attempt_Count__c;
            Integer attempts = (current == null) ? 0 : current.intValue();
            if (attempts < MAX_ROUTING_ATTEMPT_COUNT) {
                attempts++;
            }

            Inbound_Email_Staging__c stampRow = new Inbound_Email_Staging__c(
                Id = stagingId,
                Routing_Attempt_Count__c = attempts
            );
            String line = note;
            if (isRetryableRoutingState(row.Status__c)) {
                stampRow.Status__c = STATUS_FAILED;
            } else {
                // 🔴 THE ROW IS ALREADY TERMINAL — RECORD THE DEATH, BUT DO NOT ENQUEUE IT.
                // See isRetryableRoutingState for why this branch is a hard safety requirement
                // rather than tidiness. The note is qualified so nobody reads the Finalizer's
                // standard "it will be retried automatically" copy and waits for a retry that,
                // correctly, will never come.
                line = appendLine(note, NOTE_TERMINAL_NOT_REQUEUED + row.Status__c
                    + '. The death above is recorded for the audit trail only.');
            }
            stampRow.Error__c = InboundEmailFieldUtil.clip(appendLine(row.Error__c, line), LEN_ERROR);
            new RoutingWrites().stampRoutingState(stampRow);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.markRoutingFailed: could not record the routing '
                + 'failure on staging ' + stagingId + ': ' + e.getTypeName() + ' | '
                + e.getMessage());
        }
    }

    /**
     * Give up on retrying a routing-failed row: stamp `Status__c = 'Error'` and APPEND `note` to
     * `Error__c`. Added 2026-08-08; called only by `RoutingRetrySweepBatch`, at the attempt cap or
     * the age cap. This is the ABANDONED exit of the routing row's four-exit lifecycle.
     *
     * Moving the row to 'Error' is what REMOVES it from the retry work queue (which selects only
     * 'Failed') and puts it in the human queue instead. That is the correct destination: a
     * deterministic failure — an FLS gap, or a body that always exhausts heap — will fail
     * identically forever, and the value of this design is that such a row now REACHES a person
     * rather than sitting on 'Pending' invisibly.
     *
     * 🔴 `existingError` IS A PARAMETER, NOT A READ, AND THAT IS THE POINT. The caller is a batch
     * that already selected `Error__c` in its own locator, so re-reading it here would put a SOQL
     * statement inside the sweep loop — prohibited outright by
     * `.claude/rules/apex-layering-rule.md` and a direct breach of design §8's pinned
     * "0 SOQL of its own (locator only)" for this batch. Passing the value the caller already
     * holds costs nothing and keeps this method at **0 SOQL / 1 DML**. (Design §16's prompt sketches
     * a two-argument signature; the third argument is what makes its own governor pin literally
     * true.)
     *
     * FAIL-SOFT catching `Exception` for the same reason as `markRoutingFailed`: this is the last
     * statement of a sweep pass that must not abort over one unstampable row.
     *
     * @param stagingId     The staging row to stamp; null is a no-op.
     * @param existingError The row's current `Error__c`, from the caller's own query; null is
     *                      fine and simply means there is nothing to append to.
     * @param note          The line naming which cap was reached. Blank appends nothing.
     * @example
     * InboundEmailStagingService.markRoutingAbandoned(row.Id, row.Error__c, NOTE_ATTEMPT_CAP);
     */
    public static void markRoutingAbandoned(Id stagingId, String existingError, String note) {
        if (stagingId == null) {
            return;
        }
        try {
            new RoutingWrites().stampRoutingState(new Inbound_Email_Staging__c(
                Id = stagingId,
                Status__c = STATUS_ERROR,
                Error__c = InboundEmailFieldUtil.clip(appendLine(existingError, note), LEN_ERROR)
            ));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.markRoutingAbandoned: could not abandon staging '
                + stagingId + ': ' + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * 🔴 THE ROUTING RETRY ENGINE'S WRITES, WHICH MUST RUN **WITHOUT SHARING** — the exact mirror
     * of `InboundEmailStagingSelector.RoutingReads`, and needed for the same reason.
     *
     * Fixing only the READ half would have been a half-fix that LOOKED complete. Under
     * `sharingModel = Private` with no sharing rules and `viewAllRecords = false`, an `update` of a
     * row the running principal neither owns nor is shared throws `INSUFFICIENT_ACCESS_OR_READONLY`
     * — and because both callers are deliberately fail-soft, that exception is caught and reduced
     * to a `System.debug`. The sweep would therefore read the row (now correctly, without sharing),
     * decide to abandon or re-stamp it, and then **silently fail to write**, leaving the row in the
     * queue to be re-read and re-decided on every pass, forever.
     *
     * Staging rows are owned by whoever inserted them — the Email Service context user, since
     * `createStaging` sets no `OwnerId` — while these writes are performed by the scheduling
     * principal or by a Finalizer running under whatever principal the platform chose. Those are
     * different users by construction, not by misconfiguration.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * `private`, so nothing outside this file can borrow an unshared write of this object; inner
     * classes do not inherit the outer sharing setting, so the outer `InboundEmailStagingService`
     * **stays `with sharing`** and every other write here — `createStaging`, `stamp`,
     * `markAttachmentStatus`, `appendDroppedNote`, `storeExtractedJson` — is untouched. It takes a
     * fully-built row rather than field values precisely so it holds no logic that could diverge
     * from the two public methods above.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method.
     */
    private without sharing class RoutingWrites {

        /**
         * Commit one routing-state stamp, without sharing.
         *
         * @param row A fully-built `Inbound_Email_Staging__c` carrying an Id and the fields to
         *            write; the caller owns all clipping and all decisions.
         */
        private void stampRoutingState(Inbound_Email_Staging__c row) {
            update row;
        }
    }

    /**
     * Whether a routing death on a row in this state may move it into the RETRY queue.
     *
     * 🔴 THIS GUARD IS THE ONE PLACE THE DESIGN'S CENTRAL SAFETY RULE COULD HAVE BEEN LOST, AND IT
     * IS NOT HYPOTHETICAL. `RoutingFailureFinalizer` fires on `UNHANDLED_EXCEPTION` without
     * knowing anything about the row — and an unhandled exception rolls the transaction back, so
     * the status it finds is whatever a PREVIOUS, COMPLETED run left there. Without this check a
     * row already stamped `Error` would be dragged into `Failed` by any later uncatchable death,
     * and `RoutingRetrySweepBatch` would then replay it — the exact thing §3.3 forbids absolutely,
     * because an `Error` row's catch RAN and its work MAY have committed (replaying one can mint a
     * second Lead, or file a winning broker as a competing submission against their own Lead).
     *
     * The same applies, less dangerously, to `Processed`: re-routing a completed row is at best
     * pointless and, on the narrow path where `Message_Id__c` is blank so the redelivery guard
     * cannot catch it, is another route to a duplicate Lead.
     *
     * So only two states may become `Failed`:
     *   Pending  routing never completed — the ordinary case, and the whole point of the feature
     *   Failed   it died again; the counter advances toward the cap
     * Blank is treated as `Pending`, which is what a row written before `Status__c` had a default
     * would read as.
     *
     * @param status The row's CURRENT Status__c, read in the same transaction as the write.
     * @return true when the death may re-queue this row for retry.
     */
    private static Boolean isRetryableRoutingState(String status) {
        return String.isBlank(status)
            || STATUS_PENDING.equals(status)
            || STATUS_FAILED.equals(status);
    }

    /** Qualifier appended when a routing death is recorded on an ALREADY-TERMINAL row, so the
     *  audit trail does not promise a retry that must never happen. */
    private static final String NOTE_TERMINAL_NOT_REQUEUED =
        'NOT RE-QUEUED: this row had already reached the terminal routing status ';

    /**
     * Append one line to an accumulating text field, preserving what is already there.
     *
     * A row that has failed three times must read as three failures, not as the third one — the
     * sequence is the only evidence of whether a failure is transient or deterministic, which is
     * exactly the question a human opening the Errors list view is trying to answer.
     *
     * @param existing The current value; blank means there is nothing to preserve.
     * @param line     The line to add; blank returns `existing` untouched.
     * @return The merged text, newline-separated.
     */
    private static String appendLine(String existing, String line) {
        if (String.isBlank(line)) {
            return existing;
        }
        return String.isBlank(existing) ? line : existing + '\n' + line;
    }

    /**
     * Single update path for all terminal states. Swallows its own DmlException by
     * design — see the FAIL-SOFT note in the class header: this is the last statement of a
     * branch whose real work has already committed, and throwing here would misreport a
     * successful claim as an async failure.
     *
     * @param stagingId       The staging row to stamp; null is a no-op.
     * @param status          Status__c value ('Processed' or 'Error').
     * @param resultRecordId  Result_Record_Id__c (clipped to the field's 18 characters).
     * @param outcome         Outcome__c label.
     * @param errorText       Error__c text, or null on the success paths.
     * @param routedRecordIds Routed_Record_Ids__c — the full N-result audit, or null.
     * @param propertyCount   Property_Count__c — properties found pre-truncation, or null.
     */
    private static void stamp(Id stagingId, String status, Id resultRecordId, String outcome,
                              String errorText, String routedRecordIds, Integer propertyCount) {
        if (stagingId == null) {
            return;
        }
        try {
            update new Inbound_Email_Staging__c(
                Id = stagingId,
                Status__c = status,
                Outcome__c = InboundEmailFieldUtil.clip(outcome, LEN_TEXT),
                Result_Record_Id__c = InboundEmailFieldUtil.clip(
                    resultRecordId == null ? null : String.valueOf(resultRecordId), LEN_RECORD_ID),
                Error__c = InboundEmailFieldUtil.clip(errorText, LEN_ERROR),
                Routed_Record_Ids__c = InboundEmailFieldUtil.clip(routedRecordIds, LEN_ROUTED_IDS),
                Property_Count__c = propertyCount,
                Processed_DateTime__c = Datetime.now()
            );
        } catch (DmlException de) {
            System.debug(LoggingLevel.ERROR,
                'InboundEmailStagingService.stamp: could not stamp staging ' + stagingId
                + ' as "' + status + '": ' + de.getMessage());
        }
    }
}
