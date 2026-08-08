/**
 * Broker-Protection inbound-email FILE JOB — the transaction that owns nothing else.
 *
 * ═══ 🔴 READ THIS BEFORE CHANGING ANYTHING: THE OUTAGE THIS CLASS EXISTS TO PREVENT ═══
 * On 2026-08-05 `InboundEmailAttachmentService.persist(...)` was called from the SYNCHRONOUS
 * `EmailToLeadHandler`. With the org's ContentPublication quota exhausted,
 * `Database.insert(versions, false)` threw `System.UnexpectedException: ContentPublication Limit
 * exceeded`, which **ignores `allOrNone = false`** and **escapes `catch (Exception e)` through two
 * nested layers**. Salesforce rolls back ALL handler DML when `InboundEmailResult.success = false`,
 * so the staging row went with it. Every inbound broker email carrying an attachment was
 * DESTROYED — no Lead, no registry claim, no Task, no bounce, no error record, nothing queryable
 * anywhere. Attachment SIZE was irrelevant; heap peaked at 4,262 bytes.
 *
 * **THE DESIGN RULE, stated once: a `ContentVersion` insert must never sit inside a transaction
 * whose rollback would lose something irreplaceable.** That is the whole reason this class is a
 * separate Queueable rather than a method somewhere more convenient.
 *
 *   Transaction 1  EmailToLeadHandler        owns THE EMAIL   -> no ContentVersion, ever
 *   Transaction 2  ExtractAddressQueueable   owns THE CLAIM   -> no ContentVersion, ever
 *   Transaction 3  THIS CLASS                owns only FILES  -> the ONLY admissible home
 *
 * SP-5 measured that this is real, not a theory: a deliberately-failing Queueable rolled back only
 * its OWN DML while a Lead, Task and staging row committed by an earlier transaction survived
 * byte-for-byte, with a durable, queryable `AsyncApexJob.ExtendedStatus`. And under the carrier
 * design a failure here is not even a lost file — the bytes remain on the staging row as a classic
 * `Attachment` and `AttachmentCarrierSweepBatch` retries them.
 *
 * 🔴 DO NOT "IMPROVE" THIS by moving file work closer to the handler or the router, and DO NOT
 * PROPOSE A BETTER `catch` — M3 is a measurement, not an opinion.
 *
 * ═══ 🔴 IDS ONLY ON THE PAYLOAD. NEVER BYTES. ═══
 * SP-1 measured an **UNCATCHABLE** `System.LimitException: Batchable instance is too big` thrown
 * at `System.enqueueJob` ITSELF at the platform's 6,000,000-char constant (~4.2-4.5 MB raw),
 * surfacing as `[EXTERNAL]` / `FATAL_ERROR` — a `try/catch` wrapped directly around the enqueue
 * did not catch it. Carrying attachment bytes on a Queueable payload would therefore have
 * relocated the outage ONE CALL EARLIER, into the transaction that owns the email, for every
 * scanned OM above ~4.2 MB. The bytes travel as a classic `Attachment` on the staging row
 * instead (zero ContentPublications, ~152 bytes of synchronous heap at any size — SP-4).
 * The existing <= 1 MB vision image stays on `ExtractAddressQueueable`'s payload, where SP-1
 * proved ~4x headroom.
 *
 * ═══ 🔴 THE HEAP GATE IS A PRE-CHECK, NOT A HOPE (design §6.2) ═══
 * SP-4.5 measured ONE 5 MB file converting like this:
 *
 *     heapBeforeRead   =      1,054
 *     heapAfterRead    =  5,244,053    +5,243,000  the SOQL read allocates the full body
 *     heapAfterBuild   = 10,487,036    +5,242,983  VersionData = att.Body allocates it AGAIN
 *
 * **Peak ~ 2 x converted bytes — 10.49 MB of the 12,000,000-byte async ceiling, 87%, for one
 * file.** An Apex heap `LimitException` is UNCATCHABLE, so nothing here could rescue a blow-out.
 * The gate therefore runs BEFORE any byte is allocated, which is possible only because
 * `Attachment.BodyLength` is queryable WITHOUT `Body`:
 *
 *   1. `AttachmentSelector.selectMetadataByParentIds` — NO `Body`. Sizes only.
 *   2. `chooseConvertibleSubset(...)` — pure arithmetic on those sizes.
 *   3. `AttachmentSelector.selectBodiesByIds(chosen)` — bytes for exactly that subset.
 *
 * Two constants bound it, both derived from that measurement and both living on
 * `InboundEmailAttachmentService` (single source of truth, because `persist` applies the second
 * one per row):
 *   • `CONVERT_MAX_TOTAL_BYTES` 4,000,000 -> 8.0 MB peak = 67% of 12 MB, leaving 4 MB for the
 *     reads, the link list and the notes. It equals `ATTACHMENT_MAX_BYTES`, so ANY single
 *     retained file always fits one transaction by itself and nothing can be permanently stuck.
 *   • `CONVERT_HEAP_CEILING` 9,000,000 = 75% of 12 MB, re-checked dynamically immediately before
 *     EACH `VersionData` assignment inside `persist`.
 *
 * 🔴 A green Apex suite does NOT establish this arithmetic. Only UAT U6 (a real ~3.9 MB PDF, with
 * `lastRunHeapPeak` read back from the debug log) does.
 *
 * ═══ GOVERNOR BUDGET — CONSTANT IN BOTH FILE COUNT AND TARGET COUNT ═══
 * That constancy is the load-bearing property; the absolute numbers are secondary.
 *
 *   SOQL = 3, exactly:
 *     1. AttachmentSelector.selectMetadataByParentIds   (no Body)
 *     2. AttachmentSelector.selectBodiesByIds           (the chosen subset)
 *     3. ContentVersionSelector.selectByIds             (inside persist)
 *   DML = 6, exactly, on the full-success path:
 *     1. ContentVersion insert            (inside persist)  — one statement, F rows
 *     2. staging ContentDocumentLink      (inside persist)  — one statement, F rows, ShareType 'V'
 *     3. routed ContentDocumentLink       (inside linkTo)   — one statement, F x N rows, 'I'
 *     4. carrier Attachment delete        — one statement, only the rows that CONVERTED
 *     5. Content_Publication_Budget__c    — the counter upsert
 *     6. Inbound_Email_Staging__c         — the Attachment_Status__c stamp
 *
 * ⚠ **Design §9 pins this at "3 SOQL / 5 DML" and its enumeration names only statements 1-5 —
 * it omits the staging status stamp that its own §11.2 step 10 requires.** The stamp is not
 * optional: without it the sweeper can never learn that the row is done and would retry it
 * forever. So the truthful, implemented number is SIX, and it is stated here rather than
 * quietly reconciled. Both numbers are CONSTANT at 1 file x 1 target and at 3 files x 10 targets.
 *
 * Outside the budget by design, as everywhere else in this module: the failure-path
 * `InboundEmailStagingService.appendDroppedNote` (+1 SOQL / +1 DML) and every write the
 * Finalizer makes (a separate transaction entirely).
 *
 * ═══ WHERE THE REDELIVERY GUARANTEE LIVES — AND IT IS NOT HERE ═══
 * A platform redelivery costs ZERO publications, and the only reason is STRUCTURAL AND IN
 * ANOTHER CLASS: `ExtractAddressQueueable.execute` short-circuits on
 * `InboundEmailActivityService.isAlreadyLogged(...)` and RETURNS WITHOUT CALLING `finish()`, and
 * this job is enqueued only from `finish()`. 🔴 Anyone who moves that enqueue out of `finish()`,
 * or makes the skip path call `finish()`, silently re-opens duplicate files on live Leads. There
 * is no dedupe here to catch it (decision E1, unchanged).
 *
 * ═══ LAYER ═══
 * Queueable orchestrator. It contains NO SOQL and NO DML of its own: reads go through
 * `AttachmentSelector`, file writes through `InboundEmailAttachmentService`, the staging stamp
 * through `InboundEmailStagingService`, the counter through `ContentPublicationBudget`.
 * **Not `Database.AllowsCallouts`** — it makes none.
 *
 * `convert(...)` is `public static` on purpose: `AttachmentCarrierSweepBatch` replays the
 * IDENTICAL code path rather than owning a second copy of the heap gate that could drift from
 * this one.
 *
 * @see AttachmentPersistFinalizer.cls (attached as the FIRST statement of execute)
 * @see AttachmentSelector.cls (the two-query split that makes the gate a pre-check)
 * @see AttachmentCarrierSweepBatch.cls (the retry/expiry path, same convert())
 * @see agent-output/design-requirements-attachment-persistence-v2.md §3.4, §6.2, §9, §11.2
 * @see agent-output/spike-attachment-persistence-v2.md (SP-1, SP-4, SP-5)
 */
public with sharing class AttachmentPersistQueueable implements Queueable {

    /**
     * Aliases of the single source of truth on `InboundEmailAttachmentService`, declared here so
     * this class's gate and its tests read the constants at the venue design §11.2 names them.
     * They are NOT second copies — changing either value in one place changes it everywhere.
     */
    @TestVisible private static final Integer CONVERT_MAX_TOTAL_BYTES =
        InboundEmailAttachmentService.CONVERT_MAX_TOTAL_BYTES;
    @TestVisible private static final Integer CONVERT_HEAP_CEILING =
        InboundEmailAttachmentService.CONVERT_HEAP_CEILING;

    /**
     * TEST-ONLY TELEMETRY, captured INSIDE the async context.
     *
     * ⚠ `Test.stopTest()` RESTORES the limit counters in effect before `Test.startTest()`, so a
     * `Limits.getQueries()` assertion written after it reflects the pre-test context and is
     * SILENTLY VACUOUS. The same trap is documented on `ExtractAddressQueueable.lastRunQueryCount`
     * and in `EmailThreadAdopterServiceTest`'s header. Assert these statics, never `Limits.*`.
     *
     * `lastRunHeapPeak` is the §6.2 pin — it must stay below `CONVERT_HEAP_CEILING`. A green Apex
     * assertion on it proves the accounting, not the arithmetic; UAT U6 proves the arithmetic.
     */
    @TestVisible private static Integer lastRunQueryCount;
    @TestVisible private static Integer lastRunDmlCount;
    @TestVisible private static Integer lastRunHeapPeak;
    @TestVisible private static Integer lastRunConvertedCount;
    @TestVisible private static Integer lastRunDeferredCount;

    /**
     * TEST-ONLY seam for the heap branches. No test can drive `Limits.getHeapSize()` to a chosen
     * value without allocating megabytes of throwaway data — itself a heap risk inside the test.
     * When non-null this value is used instead. NEVER set outside a test class.
     */
    @TestVisible private static Integer heapSizeOverride = null;

    /** The staging row whose carrier Attachments this job converts. */
    private final Id stagingId;

    /**
     * The records routing filed this email on, in the SAME order the N Tasks used.
     * 🔴 IDS ONLY. NEVER BYTES — see the class header for SP-1's uncatchable enqueue ceiling.
     */
    private final List<Id> targets;

    /**
     * @param stagingId The Inbound_Email_Staging__c row carrying the bytes.
     * @param targets   The routed records to link the files to; may be null/empty, in which case
     *                  the files are still saved and linked to the staging row itself.
     */
    public AttachmentPersistQueueable(Id stagingId, List<Id> targets) {
        this.stagingId = stagingId;
        this.targets = targets;
    }

    /**
     * Attach the failure reporter, then convert.
     *
     * 🔴 `System.attachFinalizer` IS THE FIRST STATEMENT, before anything that can fail. A failure
     * before the finalizer is attached has no reporter at all, which is precisely the invisible
     * failure mode this whole redesign exists to remove.
     *
     * @param ctx The queueable context (unused; required by the interface).
     */
    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new AttachmentPersistFinalizer(stagingId));
        convert(stagingId, targets);
    }

    /**
     * Convert this staging row's carrier Attachments into Salesforce Files, link them, delete the
     * carriers that converted, and stamp the outcome. The ONE code path — `execute()` and
     * `AttachmentCarrierSweepBatch` both run it, so the heap gate cannot drift between the live
     * job and its retry.
     *
     * ⚠ IT DELIBERATELY DOES NOT CATCH. Every ADMISSIBILITY refusal (breaker, budget, deferral,
     * missing carrier) returns quietly with a recorded reason and zero `ContentVersion` DML, so
     * the only way out through an exception is a genuine, unexpected failure — and that must
     * surface as a failed `AsyncApexJob` and reach `AttachmentPersistFinalizer`, not be swallowed
     * into silence.
     *
     * @param stagingId The Inbound_Email_Staging__c row; null is a no-op.
     * @param targets   The routed records to link to; null/empty links to the staging row only.
     * @example
     * AttachmentPersistQueueable.convert(stagingId, orderedTargets);
     */
    public static void convert(Id stagingId, List<Id> targets) {
        lastRunConvertedCount = 0;
        lastRunDeferredCount = 0;
        lastRunHeapPeak = currentHeapSize();

        try {
            if (stagingId == null) {
                return;
            }

            // ── STEP 2. Breaker, then daily budget. Both SKIP AND RECORD; neither throws, and
            // neither issues a single ContentVersion statement. Zero SOQL is spent getting here,
            // so an exhausted window costs nothing at all.
            if (ContentPublicationBudget.isSuspended()) {
                InboundEmailStagingService.markAttachmentStatus(
                    stagingId,
                    InboundEmailStagingService.ATTACHMENT_STATUS_FAILED,
                    ContentPublicationBudget.suspensionNote());
                return;
            }
            if (!ContentPublicationBudget.canPublish(1)) {
                InboundEmailStagingService.markAttachmentStatus(
                    stagingId,
                    InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL,
                    ContentPublicationBudget.budgetNote(1));
                return;
            }

            // ── STEP 3. SOQL 1 — metadata only. NO BYTES IN HEAP YET.
            List<Attachment> carriers =
                AttachmentSelector.selectMetadataByParentIds(new Set<Id>{ stagingId });
            if (carriers.isEmpty()) {
                // Released, expired, or already converted. Returning WITHOUT a stamp is
                // deliberate: whoever removed the carriers already wrote the terminal status,
                // and overwriting it here would erase why the file is not there.
                return;
            }

            // ── STEP 4. The §6.2 pre-check, then the budget cap. Both operate on BodyLength.
            Set<Id> chosen = capToAllowance(chooseConvertibleSubset(carriers), carriers);
            lastRunDeferredCount = carriers.size() - chosen.size();

            if (chosen.isEmpty()) {
                // Nothing fits this transaction. The carriers STAY — this is a deferral, not a
                // loss — and the sweeper picks the row up on its next pass.
                InboundEmailStagingService.markAttachmentStatus(
                    stagingId,
                    InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL,
                    NOTE_DEFERRED);
                return;
            }

            // ── STEP 5. SOQL 2 — the bytes, for EXACTLY the chosen subset.
            List<Attachment> bodies = AttachmentSelector.selectBodiesByIds(chosen);
            recordHeapPeak();

            // Rebuilt in the metadata list's ASCENDING-BodyLength order, so persist's per-row
            // heap re-check sees small files first and the deferral is deterministic.
            List<InboundEmailAttachmentService.AttachmentRequest> retained =
                toRequests(carriers, chosen, bodies);

            // ── STEP 6. SOQL 3 + DML 1, 2. Reused UNCHANGED apart from its per-row heap check.
            List<Id> documentIds = InboundEmailAttachmentService.persist(stagingId, retained);
            recordHeapPeak();

            List<Id> convertedCarriers = InboundEmailAttachmentService.lastPersistedCarrierIds();
            lastRunConvertedCount = convertedCarriers.size();

            List<String> notes = new List<String>();
            notes.addAll(InboundEmailAttachmentService.lastPersistFailures());

            // ── STEP 7. DML 3 — ONE bulk statement for the whole F x N matrix, ONCE.
            // 🔴 NEVER call linkTo per file or per target; that is what makes the budget
            // constant in both dimensions.
            if (!documentIds.isEmpty() && targets != null && !targets.isEmpty()) {
                InboundEmailAttachmentService.linkTo(documentIds, targets);
                notes.addAll(InboundEmailAttachmentService.lastLinkFailures());
            }

            // ── STEP 8. DML 4 — delete ONLY the carriers that actually converted. A carrier
            // whose ContentVersion was refused STAYS, which is the entire recoverability story.
            deleteCarriers(convertedCarriers, notes);

            // ── STEP 9. DML 5 — count AFTER the publish, never before.
            ContentPublicationBudget.record(lastRunConvertedCount);

            // ── STEP 10. DML 6 — the terminal stamp. 'Saved' only when every carrier converted
            // and nothing was refused; anything else is 'Partial' and stays in the sweeper's
            // queue.
            Boolean complete = (lastRunDeferredCount == 0)
                && (lastRunConvertedCount == carriers.size())
                && notes.isEmpty();
            InboundEmailStagingService.markAttachmentStatus(
                stagingId,
                complete
                    ? InboundEmailStagingService.ATTACHMENT_STATUS_SAVED
                    : InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL,
                buildNote(notes, lastRunDeferredCount));
        } finally {
            recordHeapPeak();
            lastRunQueryCount = Limits.getQueries();
            lastRunDmlCount = Limits.getDmlStatements();
        }
    }

    /**
     * 🔴 THE §6.2 HEAP GATE. PURE — no SOQL, no DML, no bytes.
     *
     * Chooses the largest PREFIX of `rows` (which `AttachmentSelector` returned in ascending
     * `BodyLength` order) whose sizes sum to at most `CONVERT_MAX_TOTAL_BYTES`. A prefix rather
     * than a best-fit knapsack on purpose: it is deterministic, it is convergent across sweeper
     * passes (the smallest remaining files always go next), and one oversized carrier can never
     * starve three small ones.
     *
     * Because `CONVERT_MAX_TOTAL_BYTES` equals `ATTACHMENT_MAX_BYTES`, any file this pipeline
     * would RETAIN always fits a transaction by itself, so nothing can become permanently stuck.
     * A LEGACY carrier written under the old 5,000,000-byte cap can exceed it — that row simply
     * never converts and takes the sweeper's `Expired` exit at 14 days, which is a defined exit
     * rather than an accumulation.
     *
     * @param rows Carrier metadata in ascending `BodyLength` order; null/empty yields an empty set.
     * @return The Ids that provably fit ONE async transaction together.
     * @example
     * Set<Id> chosen = AttachmentPersistQueueable.chooseConvertibleSubset(carriers);
     */
    @TestVisible
    private static Set<Id> chooseConvertibleSubset(List<Attachment> rows) {
        Set<Id> chosen = new Set<Id>();
        if (rows == null || rows.isEmpty()) {
            return chosen;
        }
        Long total = 0;
        for (Attachment row : rows) {
            if (row == null || row.Id == null) {
                continue;
            }
            Integer size = (row.BodyLength == null) ? 0 : row.BodyLength;
            if (total + size > CONVERT_MAX_TOTAL_BYTES) {
                break;
            }
            total += size;
            chosen.add(row.Id);
        }
        return chosen;
    }

    /**
     * Trim the chosen subset to what the daily publication budget still permits, preserving the
     * ascending-size order so the trim is deterministic.
     *
     * @param chosen  The heap-gated subset.
     * @param ordered The full carrier list, ascending by `BodyLength`.
     * @return `chosen` unchanged when the budget allows it, else its smallest-first prefix.
     */
    private static Set<Id> capToAllowance(Set<Id> chosen, List<Attachment> ordered) {
        Integer allowance = ContentPublicationBudget.allowance();
        if (allowance >= chosen.size()) {
            return chosen;
        }
        Set<Id> capped = new Set<Id>();
        for (Attachment row : ordered) {
            if (capped.size() >= allowance) {
                break;
            }
            if (row != null && chosen.contains(row.Id)) {
                capped.add(row.Id);
            }
        }
        return capped;
    }

    /**
     * Rebuild the service's DTO from the carrier rows, in the ordered metadata list's order.
     *
     * `req.body = row.Body` is a REFERENCE assignment to the Blob the SOQL read already
     * allocated — never a copy. The carrier Id rides along so `persist` can report exactly which
     * rows converted, which is what lets step 8 delete only those.
     *
     * @param ordered The full carrier metadata, ascending by `BodyLength`.
     * @param chosen  The subset whose bodies were read.
     * @param bodies  The rows returned by `selectBodiesByIds` (order not guaranteed).
     * @return The requests to persist, smallest-first. Never null.
     */
    private static List<InboundEmailAttachmentService.AttachmentRequest> toRequests(
            List<Attachment> ordered, Set<Id> chosen, List<Attachment> bodies) {
        Map<Id, Attachment> byId = new Map<Id, Attachment>(bodies);
        List<InboundEmailAttachmentService.AttachmentRequest> requests =
            new List<InboundEmailAttachmentService.AttachmentRequest>();

        for (Attachment metadata : ordered) {
            if (metadata == null || !chosen.contains(metadata.Id)) {
                continue;
            }
            Attachment row = byId.get(metadata.Id);
            if (row == null || row.Body == null) {
                continue;
            }
            InboundEmailAttachmentService.AttachmentRequest request =
                new InboundEmailAttachmentService.AttachmentRequest();
            request.carrierId = row.Id;
            request.fileName = row.Name;
            request.mimeSubType = row.ContentType;
            request.body = row.Body;
            request.byteSize = (row.BodyLength == null) ? 0 : row.BodyLength;
            request.isImage =
                InboundEmailAttachmentService.isImageAttachment(row.ContentType, row.Name);
            requests.add(request);
        }
        return requests;
    }

    /**
     * Delete the carriers whose files are now safely in Content — ONE bulk statement,
     * `allOrNone = false` so a single refusal cannot cost the others.
     *
     * @param carrierIds The Attachment Ids that converted; null/empty is a no-op (no DML).
     * @param notes      Collected refusal lines, appended to in place.
     */
    private static void deleteCarriers(List<Id> carrierIds, List<String> notes) {
        if (carrierIds == null || carrierIds.isEmpty()) {
            return;
        }
        List<Attachment> rows = new List<Attachment>();
        for (Id carrierId : carrierIds) {
            rows.add(new Attachment(Id = carrierId));
        }
        List<Database.DeleteResult> results = Database.delete(rows, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                notes.add('carrier not removed | ' + carrierIds[i] + ' | '
                    + firstError(results[i]));
            }
        }
    }

    /**
     * The §7 note for the terminal stamp, or null when there is nothing to say. A successful
     * conversion writes NO note at all — silence on this field means "it worked".
     *
     * @param notes    Refusal lines collected during the run.
     * @param deferred How many carriers the heap gate or the budget held back.
     * @return The joined note, or null.
     */
    private static String buildNote(List<String> notes, Integer deferred) {
        List<String> lines = new List<String>();
        if (deferred != null && deferred > 0) {
            lines.add(NOTE_DEFERRED);
        }
        if (notes != null) {
            lines.addAll(notes);
        }
        return lines.isEmpty() ? null : String.join(lines, '\n');
    }

    /**
     * §7 copy for the deferral mode. 🔴 It must say "not yet saved" and name the retry: a
     * deferral is RECOVERABLE, and conflating it with a terminal loss is the single most
     * important distinction this field has to carry.
     */
    @TestVisible private static final String NOTE_DEFERRED =
        'not yet saved: deferred by the conversion heap budget (CONVERT_MAX_TOTAL_BYTES 4000000); '
        + 'the file is still attached to this staging row and will be retried';

    /**
     * Track the transaction's peak heap so the §6.2 pin can be asserted from inside the async
     * context (and read back from the debug log at UAT U6).
     */
    private static void recordHeapPeak() {
        Integer now = currentHeapSize();
        if (lastRunHeapPeak == null || now > lastRunHeapPeak) {
            lastRunHeapPeak = now;
        }
    }

    /**
     * The transaction's current heap usage, or the test override when one is set.
     *
     * @return Heap bytes consumed so far.
     */
    private static Integer currentHeapSize() {
        return (heapSizeOverride == null) ? Limits.getHeapSize() : heapSizeOverride;
    }

    /**
     * The first error on a delete result, as `STATUSCODE: message`.
     *
     * @param result A failed Database.DeleteResult.
     * @return The formatted first error, or 'UNKNOWN_ERROR'.
     */
    private static String firstError(Database.DeleteResult result) {
        if (result.getErrors() == null || result.getErrors().isEmpty()) {
            return 'UNKNOWN_ERROR';
        }
        Database.Error error = result.getErrors()[0];
        return String.valueOf(error.getStatusCode()) + ': ' + error.getMessage();
    }
}
